#!/usr/bin/env python3
"""zig build -Dtest-ops=true test, the step that runs this suite.

The scratch project points its module at a stub, so the step under test
is the suite command and src/main.zig is not compiled. The tests share
the copy, and so its build cache.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import binary

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
STUB_BUILD = '''const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.option(bool, "test-ops", "accepted by the real build");
    const mod = b.createModule(.{
        .root_source_file = b.path("stub.zig"),
        .target = b.graph.host,
    });
    const run_unit = b.addRunArtifact(b.addTest(.{ .root_module = mod }));
    const suite = b.addSystemCommand(&.{ "python3", "-m", "unittest", "discover", "-s", "tests" });
    suite.setCwd(b.path("."));
    suite.stdio = .inherit;
    suite.addFileInput(b.path("tests/test_one.py"));
    const test_step = b.step("test", "run the suite");
    test_step.dependOn(&run_unit.step);
    test_step.dependOn(&suite.step);
}
'''


@unittest.skipUnless(binary.ZIG and shutil.which("zig"), "runs under zig build -Dtest-ops=true test")
class SuiteStep(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="eb-local-build-")
        cls.root = Path(cls.tmp.name)
        (cls.root / "build.zig").write_text(STUB_BUILD)
        (cls.root / "stub.zig").write_text("test \"stub\" {}\n")
        (cls.root / "tests").mkdir()

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def build(self, test):
        (self.root / "tests" / "test_one.py").write_text(test)
        env = dict(os.environ, ZIG_LOCAL_CACHE_DIR=str(self.root / ".zig-cache"))
        env.pop("EB_LOCAL_BIN", None)
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
