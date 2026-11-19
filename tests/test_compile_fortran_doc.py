#!/usr/bin/env python3
"""Verify docs/howto/compile.md covers Fortran OpenMP and MPI compiler commands."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
PAGE = ROOT / "docs" / "howto" / "compile.md"


class CompileFortranDocTests(unittest.TestCase):
    def test_compile_guide_lists_gfortran_and_mpifort(self):
        text = PAGE.read_text(encoding="utf-8")
        self.assertIn("gfortran -O2 -fopenmp", text)
        self.assertIn("mpifort", text)


if __name__ == "__main__":
    unittest.main()
