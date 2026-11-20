#!/usr/bin/env python3
"""`eb-local modulerc` stdout write-error diagnostics on `/dev/full` and `1>&-`."""

from pathlib import Path
import subprocess
import tempfile
import unittest

import binary


def run_sink(argv, sink, *, env, cwd):
    if sink == "closed":
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
    with open("/dev/full", "wb") as dev_full:
        return subprocess.run(
            argv,
            env=env,
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=dev_full,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5,
        )


@unittest.skipUnless(binary.BIN, "modulerc stdout diagnostics belong to the Zig binary")
class ModulercStdoutErrorsCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-modulerc-stdout-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.env = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(self.root),
            "EB_LOCAL_CONFIG": "",
            "SLURM_JOB_ID": "",
        }

    def test_write_mode_reports_stdout_write_errors(self):
        for sink, expected in (("devfull", "No space left on device"), ("closed", "Bad file descriptor")):
            with self.subTest(sink=sink):
                tree = self.root / f"modules-write-{sink}"
                got = run_sink(
                    [binary.BIN, "modulerc", "--module-tree", str(tree), "--default", "Demo/1.0"],
                    sink,
                    env=self.env,
                    cwd=self.root,
                )
                self.assertEqual(got.returncode, 1, got.stderr)
                self.assertIn("eb-local: cannot write the result:", got.stderr)
                self.assertIn(expected, got.stderr)

    def test_dry_run_reports_os_errno_on_stdout_write_errors(self):
        tree = self.root / "modules-dry"
        tree.mkdir()
        for sink, expected in (("devfull", "No space left on device"), ("closed", "Bad file descriptor")):
            with self.subTest(sink=sink):
                got = run_sink(
                    [binary.BIN, "modulerc", "--module-tree", str(tree), "--default", "Demo/1.0", "--dry-run"],
                    sink,
                    env=self.env,
                    cwd=self.root,
                )
                self.assertEqual(got.returncode, 1, got.stderr)
                self.assertIn("eb-local: cannot write the result:", got.stderr)
                self.assertIn(expected, got.stderr)

    def test_check_up_to_date_exits_one_and_reports_os_errno_on_stdout_write_errors(self):
        tree = self.root / "modules-check"
        subprocess.run(
            [binary.BIN, "modulerc", "--module-tree", str(tree), "--default", "Demo/1.0"],
            env=self.env,
            cwd=self.root,
            check=True,
            capture_output=True,
            text=True,
        )
        for sink, expected in (("devfull", "No space left on device"), ("closed", "Bad file descriptor")):
            with self.subTest(sink=sink):
                got = run_sink(
                    [binary.BIN, "modulerc", "--module-tree", str(tree), "--default", "Demo/1.0", "--check"],
                    sink,
                    env=self.env,
                    cwd=self.root,
                )
                self.assertEqual(got.returncode, 1, got.stderr)
                self.assertIn("eb-local: cannot write the result:", got.stderr)
                self.assertIn(expected, got.stderr)


if __name__ == "__main__":
    unittest.main()
