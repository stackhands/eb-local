#!/usr/bin/env python3
"""`eb-local overlay bump` and `plan` run the real `eb-stack package` commands.

test_overlay_eb_stack_cli.py answers with a stand-in that prints its arguments.
These run the eb-stack named by EB_STACK_BIN (or eb-stack 0.8.0+ on PATH when
EB_STACK_BIN is unset) and compare what eb-local passes on with what that
program does when started directly.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

import binary

MIN_EB_STACK_VERSION = (0, 8, 0)
_VERSION_RE = re.compile(r"\beb-stack\s+v?(\d+)\.(\d+)\.(\d+)\b")


def resolve_eb_stack(env=None, which=shutil.which):
    environ = os.environ if env is None else env
    if "EB_STACK_BIN" in environ:
        explicit = environ["EB_STACK_BIN"]
        if not explicit:
            return "", "EB_STACK_BIN names no eb-stack program"
        return explicit, ""

    candidate = which("eb-stack")
    if not candidate:
        return "", "EB_STACK_BIN is unset and eb-stack was not found on PATH"

    try:
        probe = subprocess.run(
            [candidate, "--version"],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return "", f"eb-stack on PATH ({candidate}) failed version check: {exc}"

    if probe.returncode != 0:
        return "", f"eb-stack on PATH ({candidate}) exited {probe.returncode} on version check"

    output = probe.stdout.strip()
    match = _VERSION_RE.search(output)
    if not match:
        return "", f"eb-stack on PATH ({candidate}) reported unrecognised version {output!r}; need 0.8.0 or newer"

    found = tuple(int(part) for part in match.groups())
    if found < MIN_EB_STACK_VERSION:
        found_str = ".".join(str(part) for part in found)
        return "", f"eb-stack on PATH ({candidate}) is {found_str}; need 0.8.0 or newer"

    return candidate, ""


EB_STACK, EB_STACK_SKIP_REASON = resolve_eb_stack()


@unittest.skipUnless(binary.ZIG, "overlay is a feature of the Zig build")
@unittest.skipUnless(EB_STACK, EB_STACK_SKIP_REASON or "EB_STACK_BIN names no eb-stack program")
class OverlayRealEbStack(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-overlay-real-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.env = {"PATH": "/usr/bin:/bin", "HOME": str(self.root)}

    def through_eb_local(self, action, args):
        return subprocess.run(
            [binary.ZIG, "overlay", action, "--eb-stack", EB_STACK, "--", *args],
            env=self.env,
            cwd=self.root,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def direct(self, action, args):
        return subprocess.run(
            [EB_STACK, "package", action, *args],
            env=self.env,
            cwd=self.root,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=10,
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
