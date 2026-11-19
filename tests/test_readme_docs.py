#!/usr/bin/env python3
"""Keep the README EasyBuild example aligned with a recipe EESSI 2026.06 lacks."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
README = ROOT / "README.md"
HOWTO = ROOT / "docs" / "howto" / "install-software.md"


class ReadmeInstallExampleTests(unittest.TestCase):
    def test_readme_uses_a_recipe_eessi_lacks(self):
        readme = README.read_text(encoding="utf-8")
        howto = HOWTO.read_text(encoding="utf-8")
        self.assertNotIn("GSL-2.8-GCC-15.2.0.eb", readme)
        self.assertIn("eb-local pigz-2.8-GCCcore-15.2.0.eb --robot", readme)
        self.assertIn("eb-local pigz-2.8-GCCcore-15.2.0.eb --robot", howto)


if __name__ == "__main__":
    unittest.main()
