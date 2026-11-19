#!/usr/bin/env python3
"""`eb-local overlay bump` and `plan` run the real `eb-stack package` commands.

test_overlay_eb_stack_cli.py answers with a stand-in that prints its arguments.
These run the eb-stack named by EB_STACK_BIN and compare what eb-local passes
on with what that program does when started directly.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary

EB_STACK = os.environ.get("EB_STACK_BIN", "")


@unittest.skipUnless(binary.BIN, "overlay is a feature of the Zig build")
@unittest.skipUnless(EB_STACK, "EB_STACK_BIN names no eb-stack program")
class OverlayRealEbStack(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-overlay-real-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.env = {"PATH": "/usr/bin:/bin", "HOME": str(self.root)}

    def through_eb_local(self, action, args):
        return subprocess.run(
            [binary.BIN, "overlay", action, "--eb-stack", EB_STACK, "--", *args],
            env=self.env,
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def direct(self, action, args):
        return subprocess.run(
            [EB_STACK, "package", action, *args],
            env=self.env,
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def test_help_is_the_help_of_the_package_command(self):
        for action in ("bump", "plan"):
            with self.subTest(action=action):
                got = self.through_eb_local(action, ["--help"])
                self.assertEqual(got.returncode, 0, got.stdout + got.stderr)
                self.assertIn(f"Usage: eb-stack package {action}", got.stdout)
                self.assertEqual(got.stdout, self.direct(action, ["--help"]).stdout)

    def test_exit_status_and_messages_are_the_programs_own(self):
        cases = {
            "unknown option": ["--no-such-option"],
            "missing inputs": ["--source", str(self.root / "missing.eb")],
        }
        for action in ("bump", "plan"):
            for label, args in cases.items():
                with self.subTest(action=action, case=label):
                    got = self.through_eb_local(action, args)
                    want = self.direct(action, args)
                    self.assertNotEqual(want.returncode, 0, want.stderr)
                    self.assertEqual(got.returncode, want.returncode, got.stderr)
                    self.assertEqual(got.stdout, want.stdout)
                    self.assertEqual(got.stderr, want.stderr)


if __name__ == "__main__":
    unittest.main()
