#!/usr/bin/env python3
"""Prefix behavior on read-only or full filesystems (EROFS and ENOSPC)."""

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


@unittest.skipUnless(binary.ZIG, "prefix filesystem checks target the Zig build")
class PrefixFilesystemErrors(StorageFixture):
    def setUp(self):
        super().setUp()
        for name in ("LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT"):
            self.env.pop(name, None)

    def test_full_prefix_filesystem_stops_build_before_workspace(self):
        self.prefix.mkdir(parents=True, exist_ok=True)
        for cap, needle in (("0:100", "no space left on device"), ("4096:0", "0 free inodes")):
            with self.subTest(cap=cap):
                run = self.run_wrapper(EB_LOCAL_TEST_PREFIX_CAPACITY=cap)
                self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
                self.assertNotIn("eb-local: installing into", run.stdout)
                self.assertNotIn("eb-local: done.", run.stdout)
                self.assertIn(str(self.prefix), run.stderr)
                self.assertIn(needle, run.stderr)
                self.assertEqual(list(self.job.iterdir()), [])

    def test_prefix_on_a_file_system_without_an_inode_count_builds(self):
        self.prefix.mkdir(parents=True, exist_ok=True)
        run = self.run_wrapper(EB_LOCAL_TEST_PREFIX_CAPACITY="4096:0:uncounted")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertNotIn("no space left on device", run.stderr)
        self.assertIn("eb-local: done.", run.stdout)

    @unittest.skipUnless(_can_mount_tmpfs(), "user-namespace tmpfs mounts unavailable in this environment")
    def test_tmpfs_ro_and_full_prefix_stop_build_before_workspace(self):
        self.prefix.mkdir(parents=True, exist_ok=True)
        site = self.root / "site-ro.toml"
        site.write_text(f'[storage]\nnode_local_root = "{self.nodes}"\nnode_local_mount = "ubuntu.%j"\n')
        site.chmod(0o600)
        argv, env = binary.command(self.script, ["--config", str(site), "recipe.eb"], dict(self.env))

        ro_cmd = [
            "unshare",
            "-r",
            "-m",
            "python3",
            "-c",
            (
                "import subprocess, sys\n"
                "prefix, argv = sys.argv[1], sys.argv[2:]\n"
                "subprocess.run(['mount', '-t', 'tmpfs', '-o', 'size=64k,ro', 'tmpfs', prefix], check=True)\n"
                "try:\n"
                "    p = subprocess.run(argv)\n"
                "    sys.exit(p.returncode)\n"
                "finally:\n"
                "    subprocess.run(['umount', prefix], check=False)\n"
            ),
            str(self.prefix),
            *argv,
        ]
        ro_run = subprocess.run(ro_cmd, env=env, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(ro_run.returncode, 2, ro_run.stdout + ro_run.stderr)
        self.assertIn(str(self.prefix), ro_run.stderr)
        self.assertIn("[Errno 30] Read-only file system", ro_run.stderr)
        self.assertEqual(list(self.job.iterdir()), [])

        full_cmd = [
            "unshare",
            "-r",
            "-m",
            "python3",
            "-c",
            (
                "import os, subprocess, sys\n"
                "prefix, argv = sys.argv[1], sys.argv[2:]\n"
                "subprocess.run(['mount', '-t', 'tmpfs', '-o', 'size=64k', 'tmpfs', prefix], check=True)\n"
                "try:\n"
                "    os.makedirs(os.path.join(prefix, '.eb-local', 'sources'), exist_ok=True)\n"
                "    os.makedirs(os.path.join(prefix, '.eb-local', 'logs'), exist_ok=True)\n"
                "    open(os.path.join(prefix, '.eb-local', '.lock'), 'wb').close()\n"
                "    try:\n"
                "        with open(os.path.join(prefix, 'fill'), 'wb', buffering=0) as f:\n"
                "            while True:\n"
                "                f.write(b'x' * 4096)\n"
                "    except OSError:\n"
                "        pass\n"
                "    p = subprocess.run(argv)\n"
                "    sys.exit(p.returncode)\n"
                "finally:\n"
                "    subprocess.run(['umount', prefix], check=False)\n"
            ),
            str(self.prefix),
            *argv,
        ]
        full_run = subprocess.run(full_cmd, env=env, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(full_run.returncode, 2, full_run.stdout + full_run.stderr)
        self.assertNotIn("eb-local: installing into", full_run.stdout)
        self.assertIn(str(self.prefix), full_run.stderr)
        self.assertIn("no space left on device", full_run.stderr)
        self.assertEqual(list(self.job.iterdir()), [])


    def test_doctor_reports_full_and_readonly_prefix_as_fail(self):
        self.prefix.mkdir(parents=True, exist_ok=True)
        full = self.run_tool_doctor(EB_LOCAL_TEST_PREFIX_CAPACITY="0:100")
        self.assertEqual(full.returncode, 1, full.stdout + full.stderr)
        self.assertIn("FAIL installation prefix", full.stdout)
        self.assertIn("no space left on device", full.stdout)

        inodes = self.run_tool_doctor(EB_LOCAL_TEST_PREFIX_CAPACITY="4096:0")
        self.assertEqual(inodes.returncode, 1, inodes.stdout + inodes.stderr)
        self.assertIn("FAIL installation prefix", inodes.stdout)
        self.assertIn("0 free inodes", inodes.stdout)

        # btrfs reports zero total and zero free inodes; that is not a full
        # file system, and a prefix there with free bytes is accepted.
        uncounted = self.run_tool_doctor(EB_LOCAL_TEST_PREFIX_CAPACITY="4096:0:uncounted")
        self.assertNotIn("no space left on device", uncounted.stdout)
        self.assertNotIn("FAIL installation prefix", uncounted.stdout)
        empty = self.run_tool_doctor(EB_LOCAL_TEST_PREFIX_CAPACITY="0:0:uncounted")
        self.assertEqual(empty.returncode, 1, empty.stdout + empty.stderr)
        self.assertIn("no space left on device", empty.stdout)

        missing_prefix = self.prefix / "child" / "eessi"
        full_missing = self.run_tool_doctor(
            EB_LOCAL_PREFIX=str(missing_prefix),
            EB_LOCAL_TEST_PREFIX_CAPACITY="0:100",
        )
        self.assertEqual(full_missing.returncode, 1, full_missing.stdout + full_missing.stderr)
        self.assertIn("FAIL installation prefix", full_missing.stdout)
        self.assertIn("no space left on device", full_missing.stdout)

        ro_parent = self.root / "ro-parent"
        ro_parent.mkdir()
        ro_parent.chmod(0o555)
        try:
            ro_missing = self.run_tool_doctor(EB_LOCAL_PREFIX=str(ro_parent / "child" / "eessi"))
            self.assertEqual(ro_missing.returncode, 1, ro_missing.stdout + ro_missing.stderr)
            self.assertIn("FAIL", ro_missing.stdout)
            self.assertIn("[Errno 13] Permission denied", ro_missing.stdout)
        finally:
            ro_parent.chmod(0o755)

    def run_tool_doctor(self, **extra):
        argv, env = binary.command(self.script, ["doctor"], dict(self.env, **extra))
        return subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)


if __name__ == "__main__":
    unittest.main()
