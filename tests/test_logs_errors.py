#!/usr/bin/env python3
"""Logs directory behavior on read-only or full filesystems (EROFS, ENOSPC, RLIMIT_FSIZE)."""

import os
from pathlib import Path
import subprocess
import unittest

import binary
from test_storage import StorageFixture


def _can_mount_tmpfs():
    probe = subprocess.run(
        [
            "unshare",
            "-r",
            "-m",
            "sh",
            "-c",
            "d=$(mktemp -d) && mount -t tmpfs -o size=64k tmpfs \"$d\" && umount \"$d\" && rmdir \"$d\"",
        ],
        capture_output=True,
        text=True,
    )
    return probe.returncode == 0


@unittest.skipUnless(binary.BIN, "logs directory filesystem checks target the Zig build")
class LogsDirFilesystemErrors(StorageFixture):
    def setUp(self):
        super().setUp()
        for name in ("LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT"):
            self.env.pop(name, None)

    def test_clean_build_output_bytes_stay_unchanged(self):
        argv, env = binary.command(self.script, ["recipe.eb"], dict(self.env))
        run = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=False)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(run.stderr, b"")
        self.assertIn(b"eb-local: done. To use the modules in a new shell or job:\n", run.stdout)

    def test_readonly_logs_dir_stops_before_build_and_names_path_and_errno(self):
        logs = self.prefix / ".eb-local" / "logs"
        logs.mkdir(parents=True)
        logs.chmod(0o555)
        try:
            run = self.run_wrapper()
        finally:
            logs.chmod(0o755)
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertNotIn("eb-local: installing into", run.stdout)
        self.assertNotIn("eb-local: done.", run.stdout)
        self.assertIn(str(logs), run.stderr)
        self.assertIn("[Errno 13] Permission denied", run.stderr)
        self.assertEqual(list(self.job.iterdir()), [])

    @unittest.skipUnless(_can_mount_tmpfs(), "user-namespace tmpfs mounts unavailable in this environment")
    def test_tmpfs_erofs_precheck_stops_before_build(self):
        logs = self.prefix / ".eb-local" / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        token = self.root / "token"
        token.write_text("tok-3141-secret\n")
        token.chmod(0o600)
        site_nosec = self.root / "site-nosec.toml"
        site_nosec.write_text(f'[storage]\nnode_local_root = "{self.nodes}"\nnode_local_mount = "ubuntu.%j"\n')
        site_nosec.chmod(0o600)
        site_sec = self.root / "site-sec.toml"
        site_sec.write_text(
            f'[storage]\nnode_local_root = "{self.nodes}"\nnode_local_mount = "ubuntu.%j"\n'
            f'[secrets]\nSOURCE_TOKEN = "file:{token}"\n'
        )
        site_sec.chmod(0o600)

        for cfg in (site_nosec, site_sec):
            argv, env = binary.command(self.script, ["--config", str(cfg), "recipe.eb"], dict(self.env))
            ro_cmd = [
                "unshare",
                "-r",
                "-m",
                "python3",
                "-c",
                (
                    "import subprocess, sys\n"
                    "logs, argv = sys.argv[1], sys.argv[2:]\n"
                    "subprocess.run(['mount', '-t', 'tmpfs', '-o', 'size=64k,ro', 'tmpfs', logs], check=True)\n"
                    "try:\n"
                    "    p = subprocess.run(argv)\n"
                    "    sys.exit(p.returncode)\n"
                    "finally:\n"
                    "    subprocess.run(['umount', logs], check=False)\n"
                ),
                str(logs),
                *argv,
            ]
            ro_run = subprocess.run(ro_cmd, env=env, cwd=self.root, capture_output=True, text=True)
            self.assertEqual(ro_run.returncode, 2, ro_run.stdout + ro_run.stderr)
            self.assertNotIn("eb-local: installing into", ro_run.stdout)
            self.assertNotIn("eb-local: done.", ro_run.stdout)
            self.assertIn(str(logs), ro_run.stderr)
            self.assertIn("[Errno 30] Read-only file system", ro_run.stderr)
            self.assertEqual(list(self.job.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
