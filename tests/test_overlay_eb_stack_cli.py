#!/usr/bin/env python3
"""Black-box CLI behavior tests for `eb-local overlay` action dispatch and `eb-stack` forwarding."""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest

import binary


@unittest.skipUnless(binary.ZIG, "overlay is a feature of the Zig build")
class OverlayEbStackCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-overlay-cli-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()

    def run_overlay(self, args, path="/usr/bin:/bin"):
        return subprocess.run(
            [binary.ZIG, "overlay", *args],
            env={"PATH": path, "HOME": str(self.root)},
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def test_missing_or_unknown_overlay_action_exits_two(self):
        empty = self.run_overlay([])
        self.assertEqual(empty.returncode, 2, empty.stdout + empty.stderr)
        self.assertEqual(empty.stdout, "")
        self.assertIn("overlay takes materialize, bump or plan", empty.stderr)

        unknown = self.run_overlay(["unknown"])
        self.assertEqual(unknown.returncode, 2, unknown.stdout + unknown.stderr)
        self.assertEqual(unknown.stdout, "")
        self.assertIn("got 'unknown'", unknown.stderr)

    def test_materialize_refuses_eb_stack_and_double_dash(self):
        stub = self.root / "eb-stack"
        stub.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        stub.chmod(0o755)

        for args in (
            ["materialize", "--eb-stack", str(stub)],
            ["materialize", "--"],
            ["materialize", "--bogus"],
        ):
            with self.subTest(args=args):
                got = self.run_overlay(args)
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")
                self.assertIn("overlay materialize does not", got.stderr)

    def test_bump_and_plan_require_eb_stack_and_propagate_exit_and_signal(self):
        no_stack = self.run_overlay(["bump"], path="/nonexistent")
        self.assertEqual(no_stack.returncode, 2, no_stack.stdout + no_stack.stderr)
        self.assertIn("eb-stack is not on PATH", no_stack.stderr)

        exit_stub = self.root / "eb-stack"
        exit_stub.write_text('#!/bin/sh\nprintf "%s\\n" "$*"\nexit 7\n', encoding="utf-8")
        exit_stub.chmod(0o755)
        for action in ("bump", "plan"):
            with self.subTest(action=action):
                got = self.run_overlay([action, "--eb-stack", str(exit_stub), "--", "--strict"])
                self.assertEqual(got.returncode, 7, got.stdout + got.stderr)
                self.assertEqual(got.stdout.strip(), f"package {action} --strict")

        sig_stub = self.root / "eb-stack-sig"
        sig_stub.write_text("#!/bin/sh\nkill -TERM $$\n", encoding="utf-8")
        sig_stub.chmod(0o755)
        sig_run = self.run_overlay(["plan", "--eb-stack", str(sig_stub)])
        self.assertEqual(sig_run.returncode, -signal.SIGTERM, sig_run.stdout + sig_run.stderr)

    def test_action_must_precede_extra_positional_words(self):
        got = self.run_overlay(["foo", "materialize"])
        self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
        self.assertIn("overlay action must come first", got.stderr)


if __name__ == "__main__":
    unittest.main()
