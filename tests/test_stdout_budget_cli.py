#!/usr/bin/env python3
"""The test build can let some writes to standard output through and fail the rest.

EB_LOCAL_TEST_STDOUT_WRITES=N lets N writes succeed, then fails the next and
every later one as a full disk does. The tests that follow use it to fail the
write after any step of a command.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import binary
from stdout_scene import Scene, make_front_ends

NO_SPACE = "cannot write output ([Errno 28] No space left on device)"


@unittest.skipUnless(binary.ZIG, "needs the Zig build")
class StdoutBudget(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix=f"eb-local-budget-{os.getpid()}-")
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name).resolve()
        self.front_ends = make_front_ends(self.tmp)
        self.count = 0

    def clean_dry_run(self, front_end, budget):
        """`clean --dry-run` over one old log writes the log's path, then a summary."""
        self.count += 1
        scene = Scene(self.tmp / f"scene-{self.count}")
        log = scene.old_log()
        env = dict(scene.env)
        if budget is not None:
            env["EB_LOCAL_TEST_STDOUT_WRITES"] = str(budget)
        done = subprocess.run(
            [*self.front_ends[front_end], "clean", "--dry-run"],
            env=env,
            cwd=scene.root,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=60,
        )
        return done.returncode, done.stdout.decode(), done.stderr.decode(), str(log)

    def test_writes_up_to_the_budget_succeed_and_the_next_one_fails(self):
        for front_end in self.front_ends:
            with self.subTest(front_end=front_end, budget="none"):
                code, out, err, log = self.clean_dry_run(front_end, None)
                self.assertEqual(code, 0, err)
                self.assertEqual(out.splitlines()[0], f"  {log}")
                self.assertIn("dry run, nothing removed", out.splitlines()[1])
            with self.subTest(front_end=front_end, budget=0):
                code, out, err, _ = self.clean_dry_run(front_end, 0)
                self.assertEqual((code, out), (1, ""))
                self.assertIn(NO_SPACE, err)
            with self.subTest(front_end=front_end, budget=1):
                code, out, err, log = self.clean_dry_run(front_end, 1)
                self.assertEqual((code, out), (1, f"  {log}\n"))
                self.assertIn(NO_SPACE, err)
            with self.subTest(front_end=front_end, budget=2):
                code, out, err, _ = self.clean_dry_run(front_end, 2)
                self.assertEqual(code, 0, err)
                self.assertEqual(len(out.splitlines()), 2)


if __name__ == "__main__":
    unittest.main()
