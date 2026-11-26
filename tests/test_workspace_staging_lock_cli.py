#!/usr/bin/env python3
"""Workspace lock staging so `clean --workspaces` preserves builds waiting on `.eb-local/.lock`."""
import fcntl
import json
import os
import subprocess
import unittest

import binary
from test_storage import StorageFixture


def stop_proc(proc):
    if proc.poll() is None:
        proc.kill()
        proc.wait()
    if proc.stdout:
        proc.stdout.close()
    if proc.stderr:
        proc.stderr.close()


@unittest.skipUnless(binary.ZIG, "workspace staging lock targets the Zig build")
class WorkspaceStagingLock(StorageFixture):
    def setUp(self):
        super().setUp()
        for name in ("LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT"):
            self.env.pop(name, None)

    def hold_prefix_lock(self):
        eb_dir = self.prefix / ".eb-local"
        eb_dir.mkdir(parents=True, exist_ok=True)
        fd = os.open(eb_dir / ".lock", os.O_RDWR | os.O_CREAT, 0o666)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd

    def wait_until_waiting_on_lock(self, proc):
        line = proc.stderr.readline()
        self.assertIn("waiting for lock", line, f"unexpected stderr line: {line!r}")
        return line

    def test_clean_workspaces_preserves_build_waiting_on_contended_prefix_lock(self):
        verify_eb = r'''
eb() {
    for d in "$EASYBUILD_BUILDPATH" "$TMPDIR" "$XDG_CACHE_HOME" "$CARGO_HOME" "$WORKING_DIR"; do
        [ -d "$d" ] || { echo "missing workspace dir: $d" >&2; exit 44; }
    done
}
export -f eb
'''
        doubles = self.root / "doubles-ws-wait.sh"
        doubles.write_text((self.root / "doubles.sh").read_text(encoding="utf-8") + "\n" + verify_eb, encoding="utf-8")
        lock_fd = self.hold_prefix_lock()
        closed = False
        try:
            argv, env = binary.command(
                self.script,
                ["recipe.eb"],
                dict(self.env, BASH_ENV=str(doubles), EB_LOCAL_LOCK_TIMEOUT_MS="10000"),
            )
            proc = subprocess.Popen(
                argv,
                env=env,
                cwd=self.root,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.addCleanup(lambda p=proc: stop_proc(p))
            first_err = self.wait_until_waiting_on_lock(proc)
            self.assertEqual(len(list(self.job.iterdir())), 1)

            argv_c, env_c = binary.command(
                self.script,
                ["clean", "--workspaces", "--no-logs", "--json"],
                dict(self.env),
            )
            clean_run = subprocess.run(argv_c, env=env_c, cwd=self.root, capture_output=True, text=True, timeout=5)
            self.assertEqual(clean_run.returncode, 0, clean_run.stdout + clean_run.stderr)
            doc = json.loads(clean_run.stdout)
            self.assertEqual(doc["removed_workspaces"], 0, doc)
            self.assertEqual(len(list(self.job.iterdir())), 1)

            os.close(lock_fd)
            closed = True
            out, rest_err = proc.communicate(timeout=10)
            self.assertEqual(proc.returncode, 0, out + first_err + rest_err)
            self.assertEqual(list(self.job.iterdir()), [])
        finally:
            if not closed:
                os.close(lock_fd)


if __name__ == "__main__":
    unittest.main()
