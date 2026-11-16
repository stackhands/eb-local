#!/usr/bin/env python3
"""zig build -Dtest-ops=true test, the step that runs this suite.

It runs in a scratch copy of the project whose tests directory holds one
test, so the suite does not run itself.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import binary

ROOT = Path(__file__).resolve().parent.parent
PASSING = '''import sys, unittest
class One(unittest.TestCase):
    def test_passes(self):
        print("a passing test may write to stderr", file=sys.stderr)
'''
FAILING = '''import unittest
class One(unittest.TestCase):
    def test_fails(self):
        self.fail("the edited test fails")
'''


@unittest.skipUnless(binary.BIN and shutil.which("zig"), "runs under zig build -Dtest-ops=true test")
class SuiteStep(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-build-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ("build.zig", "build.zig.zon", "LICENSE", "README.md"):
            shutil.copy(ROOT / name, self.root / name)
        shutil.copytree(ROOT / "src", self.root / "src")
        if (ROOT / "zig-pkg").is_dir():
            shutil.copytree(ROOT / "zig-pkg", self.root / "zig-pkg", symlinks=True)
        (self.root / "tests").mkdir()

    def build(self, test):
        (self.root / "tests" / "test_one.py").write_text(test)
        env = dict(os.environ, ZIG_LOCAL_CACHE_DIR=str(self.root / ".zig-cache"))
        env.pop("EB_LOCAL_BIN")
        run = subprocess.run(["zig", "build", "-Dtest-ops=true", "test"], cwd=self.root, env=env,
                             capture_output=True, text=True)
        return run.returncode, run.stdout + run.stderr

    def test_a_passing_suite_is_not_a_failed_command(self):
        status, output = self.build(PASSING)
        self.assertEqual(status, 0, output)
        self.assertIn("Ran 1 test", output)
        self.assertNotIn("failed command", output)

    def test_an_edited_test_runs_again_and_its_failure_fails_the_build(self):
        status, output = self.build(PASSING)
        self.assertEqual(status, 0, output)
        status, output = self.build(FAILING)
        self.assertNotEqual(status, 0, output)
        self.assertIn("the edited test fails", output)


if __name__ == "__main__":
    unittest.main()
