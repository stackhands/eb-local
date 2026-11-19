#!/usr/bin/env python3
"""What the documentation says about run paths, as a cluster with EESSI 2026.06 showed it.

GSL loaded before and after the build environment gives the same RPATH
entries: the modules set LIBRARY_PATH, and the wrappers read it when the
program links, so the load order is not why a program gets its run paths.
"""
from pathlib import Path
import unittest

PAGE = Path(__file__).resolve().parents[1] / "docs" / "orgmode" / "explanation" / "run-paths.org"


class RunPaths(unittest.TestCase):
    def setUp(self):
        text = PAGE.read_text()
        start = text.index("\n* Where the run paths come from\n")
        self.dev = text[start:text.index("\n* ", start + 1)]

    def test_the_build_environment_records_rpath_entries(self):
        self.assertIn("gives the same RPATH entries", self.dev)
        self.assertNotIn("RUNPATH", self.dev)

    def test_the_load_order_is_not_the_reason_for_run_paths(self):
        self.assertIn("does not matter, because the modules set =LIBRARY_PATH= and the wrappers read it when you link",
                      self.dev)
        self.assertNotIn("still loads it last, so that", self.dev)
        self.assertIn("one real =gcc= or one real =ld= ahead of them on =PATH= does no harm", self.dev)

    def test_a_link_that_calls_neither_wrapper_loses_its_run_paths(self):
        self.assertNotIn("only when both are bypassed", self.dev)
        self.assertIn("when the link never goes through either wrapper", self.dev)

    def test_cargo_julia_node_r_and_python_are_on_the_page(self):
        text = PAGE.read_text()
        later = text[text.index("\n* Linkers the wrappers never see\n"):]
        for needle in (
            "rust-lld",
            "Rust/1.94.1-GCCcore-15.2.0",
            "CARGO_TARGET_<target>_LINKER",
            "Julia/1.13.2",
            "JULIA_DEPOT_PATH",
            "JULIA_LOAD_PATH",
            "nodejs/24.16.0-GCCcore-15.2.0",
            "NODE_PATH",
            "R_MAKEVARS_USER",
            "R_MAKEVARS_SITE",
            "R/4.6.1-gfbf-2026.1",
            "Python/3.14.2-GCCcore-15.2.0",
            "PYTHONPATH",
            "tests/site/lang-dev-tasks.sh",
        ):
            self.assertIn(needle, later)
        self.assertNotIn("RUNPATH", self.dev)

    def test_the_site_script_runs_each_language_with_no_modules(self):
        script = Path(__file__).resolve().parents[1] / "tests" / "site" / "lang-dev-tasks.sh"
        text = script.read_text(encoding="utf-8")
        for needle in (
            "Rust/1.94.1-GCCcore-15.2.0",
            "CARGO_TARGET_${_triple_env}_LINKER",
            "Julia/1.13.2",
            "JULIA_DEPOT_PATH",
            "nodejs/24.16.0-GCCcore-15.2.0",
            "unset NODE_PATH",
            "R/4.6.1-gfbf-2026.1",
            "unset R_MAKEVARS_USER R_MAKEVARS_SITE",
            "Python/3.14.2-GCCcore-15.2.0",
            "unset PYTHONPATH",
            "bare ",
        ):
            self.assertIn(needle, text)


if __name__ == "__main__":
    unittest.main()
