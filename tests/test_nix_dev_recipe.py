#!/usr/bin/env python3
"""The Nix how-to records the link this machine measured."""
from pathlib import Path
import shutil
import subprocess
import unittest

REPO = Path(__file__).resolve().parents[1]
PAGE = REPO / "docs" / "orgmode" / "howto" / "nix.org"
INDEX = REPO / "docs" / "orgmode" / "howto" / "index.org"
SCRIPT = REPO / "tests" / "site" / "nix-dev.sh"


class NixRecipeTests(unittest.TestCase):
    def test_page_states_the_recipe(self):
        page = PAGE.read_text(encoding="utf-8")
        index = INDEX.read_text(encoding="utf-8")
        self.assertIn("\nnix\n", index)
        for phrase in (
            "nix-shell -p gcc",
            "nix-shell --pure -p gcc",
            "--disable-new-dtags",
            "DT_RPATH",
            "DT_RUNPATH",
            "glibc 2.44",
            "glibc 2.39",
            "NIX_ENFORCE_PURITY",
            "cannot find -lanswer",
            "env -i",
            "tests/site/nix-dev.sh",
        ):
            self.assertIn(phrase, page)

    def test_script_matches_the_page_on_this_nix(self):
        nix = Path.home() / ".nix-profile" / "etc" / "profile.d" / "nix.sh"
        if shutil.which("nix-shell") is None and not nix.is_file():
            return
        run = subprocess.run(
            ["bash", str(SCRIPT)],
            check=True,
            capture_output=True,
            text=True,
        )
        facts = {}
        for line in run.stdout.splitlines():
            key, value = line.split(":", 1)
            facts[key] = value
        page = PAGE.read_text(encoding="utf-8")
        self.assertEqual(facts["nix-version"], "2.35.6")
        self.assertEqual(facts["host-glibc"], "2.39")
        self.assertEqual(facts["nix-glibc"], "2.44")
        self.assertEqual(facts["impure-rpath-kept"], "1")
        self.assertEqual(facts["pure-rpath-kept"], "1")
        self.assertEqual(facts["runpath-absent"], "1")
        self.assertEqual(facts["unloaded-exit"], "0")
        self.assertEqual(facts["sandbox-cannot-find"], "1")
        self.assertEqual(facts["nix-enforce-purity"], "unset")
        self.assertTrue(facts["interpreter"].startswith("/nix/store/"))
        self.assertIn("glibc " + facts["nix-glibc"], page)
        self.assertIn("glibc " + facts["host-glibc"], page)
        self.assertIn("Nix " + facts["nix-version"], page)


if __name__ == "__main__":
    unittest.main()
