#!/usr/bin/env python3
"""Verify docs/howto/compile.md notes the 2026.06 buildenv fallback behavior."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
PAGE = ROOT / "docs" / "howto" / "compile.md"


class CompileFallbackDocTests(unittest.TestCase):
    def test_compile_guide_notes_missing_lfoss_and_intel_buildenv_on_2026_06(self):
        text = PAGE.read_text(encoding="utf-8")
        self.assertIn("EESSI 2026.06 ships `buildenv/default-foss-2026.1`", text)
        self.assertIn("default-lfoss", text)
        self.assertIn("default-intel", text)


if __name__ == "__main__":
    unittest.main()
