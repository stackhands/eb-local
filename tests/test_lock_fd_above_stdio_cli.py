#!/usr/bin/env python3
"""Held lock descriptors never occupy closed stdio slots (`1>&-`)."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary


def run_closed_stdout(argv, *, env, cwd):
    return subprocess.run(
        ["/bin/sh", "-c", 'exec "$@" 1>&-', "sh", *argv],
        env=env,
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=5,
    )


@unittest.skipUnless(binary.ZIG, "lock descriptor placement belongs to the Zig binary")
class LockFdAboveStdioCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-lock-fd-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.prefix = self.root / "prefix"
        self.bins = self.root / "bin"
        self.bins.mkdir()

    def base_env(self, **extra):
        env = {
            "PATH": f"{self.bins}:/usr/bin:/bin",
            "HOME": str(self.root),
            "EB_LOCAL_CONFIG": "",
            "EB_LOCAL_PREFIX": str(self.prefix),
            "SLURM_JOB_ID": "",
        }
        env.update(extra)
        return env

    def test_clean_json_closed_stdout_reports_bad_fd_and_makes_no_lock(self):
        logs = self.prefix / ".eb-local" / "logs"
        logs.mkdir(parents=True)
        old = logs / "easybuild-old.log"
        old.write_text("log\n", encoding="utf-8")
        os.utime(old, (1_000_000_000, 1_000_000_000))

        got = run_closed_stdout(
            [binary.ZIG, "clean", "--delete", "--json"],
            env=self.base_env(),
            cwd=self.root,
        )
        lock_file = self.prefix / ".eb-local" / ".lock"
        self.assertFalse(lock_file.exists())
        self.assertTrue(old.exists())
        self.assertEqual(got.returncode, 1, got.stderr)
        self.assertIn("cannot write output", got.stderr)
        self.assertIn("Bad file descriptor", got.stderr)

    def test_uninstall_closed_stdout_makes_no_lock(self):
        arch = self.prefix / "versions" / "2026.06" / "software" / "linux" / "x86_64" / "amd" / "zen4"
        inst = arch / "software" / "Demo" / "1.0"
        mod = arch / "modules" / "all" / "Demo" / "1.0.lua"
        inst.mkdir(parents=True)
        (inst / "payload").write_text("ok\n", encoding="utf-8")
        mod.parent.mkdir(parents=True)
        mod.write_text("-- lua\n", encoding="utf-8")

        run_closed_stdout(
            [binary.ZIG, "uninstall", "--delete", "Demo/1.0"],
            env=self.base_env(),
            cwd=self.root,
        )
        self.assertFalse((self.prefix / ".eb-local").exists())

    def test_restore_closed_stdout_makes_no_lock(self):
        arch = self.prefix / "versions" / "2026.06" / "software" / "linux" / "x86_64" / "amd" / "zen4"
        (arch / "software").mkdir(parents=True)
        (arch / "modules" / "all").mkdir(parents=True)
        inst = arch / "software" / "Demo" / "1.0"
        mod = arch / "modules" / "all" / "Demo" / "1.0.lua"
        payload = json.dumps(
            [
                {"original": str(inst), "trash_dir": "/tmp/trash"},
                {"original": str(mod), "trash_dir": "/tmp/trash"},
            ]
        )
        rtrash = self.bins / "rtrash"
        rtrash.write_text(
            "#!/bin/sh\n"
            'if [ "$1" = "list" ]; then\n'
            f"  printf '%s\\n' '{payload}'\n"
            "  exit 0\n"
            "fi\n"
            "exit 0\n",
            encoding="utf-8",
        )
        rtrash.chmod(0o755)

        run_closed_stdout(
            [binary.ZIG, "restore", "Demo/1.0"],
            env=self.base_env(),
            cwd=self.root,
        )
        self.assertFalse((self.prefix / ".eb-local").exists())


if __name__ == "__main__":
    unittest.main()
