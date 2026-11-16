#!/usr/bin/env python3
"""What the README says about run paths, as a cluster with EESSI 2026.06 showed it.

GSL loaded before and after the build environment gives the same RPATH
entries: the modules set LIBRARY_PATH, and the wrappers read it when the
program links, so the load order is not why a program gets its run paths.
"""
from pathlib import Path
import unittest

README = Path(__file__).resolve().parents[1] / "README.md"


class RunPaths(unittest.TestCase):
    def setUp(self):
        text = README.read_text()
        start = text.index("`eb-local dev` loads EESSI")
        self.dev = text[start:text.index("\n\n", start)]

    def test_the_build_environment_records_rpath_entries(self):
        self.assertIn("gives the same RPATH entries", self.dev)
        self.assertNotIn("RUNPATH", self.dev)

    def test_the_load_order_is_not_the_reason_for_run_paths(self):
        self.assertIn("does not matter, because the modules set `LIBRARY_PATH` and the wrappers read it when you link",
                      self.dev)
        self.assertNotIn("still loads it last, so that", self.dev)
        self.assertIn("one real `gcc` or one real `ld` ahead of them on `PATH` does no harm", self.dev)


if __name__ == "__main__":
    unittest.main()
