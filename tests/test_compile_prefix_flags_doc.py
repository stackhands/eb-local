#!/usr/bin/env python3
"""Verify prefix flags export cleanly as inline code in docs/howto/compile.md."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
PAGE = ROOT / "docs" / "howto" / "compile.md"


class CompilePrefixFlagsDocTests(unittest.TestCase):
    def test_prefix_flags_export_without_broken_org_verbatim(self):
        text = PAGE.read_text(encoding="utf-8")
        self.assertNotIn("=configure`", text)
        self.assertNotIn("\\_LOCAL\\_DEV\\_PREFIX", text)
        self.assertIn('`-DCMAKE_INSTALL_PREFIX="$EB_LOCAL_DEV_PREFIX"`', text)
        self.assertIn('`--prefix="$EB_LOCAL_DEV_PREFIX"`', text)


if __name__ == "__main__":
    unittest.main()
