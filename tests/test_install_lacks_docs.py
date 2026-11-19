#!/usr/bin/env python3
"""Verify the missing-module how-to documents installing without a site file."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
PAGE = ROOT / "docs" / "howto" / "install-what-eessi-lacks.md"


class InstallLacksDocsTests(unittest.TestCase):
    def test_documents_eb_local_eb_when_no_site_file_exists(self):
        text = PAGE.read_text(encoding="utf-8")
        self.assertIn('eb-local eb -- "$recipe" --robot', text)


if __name__ == "__main__":
    unittest.main()
