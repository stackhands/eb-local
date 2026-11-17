#!/usr/bin/env python3
"""The pages docs/export.el writes from docs/orgmode.

Each Org source has its page, listed once in the table of contents of
the front page or of its section's index, and each written page has its
source. Where Emacs is installed, a fresh export must match the
committed pages; another Org than the one that wrote them may lay a
page out differently, and then the comparison is skipped.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

DOCS = Path(__file__).resolve().parents[1] / "docs"
ORG = DOCS / "orgmode"
GENERATED = "<!-- Generated from docs/orgmode/"
WRITTEN_WITH = "9.6."
# Written from the code as the site is built; neither committed nor from Org.
API = "reference/api/"


def sources():
    return sorted(path.relative_to(ORG) for path in ORG.rglob("*.org"))


def toctree_entries(page):
    """The pages the toctrees of PAGE list, as paths under docs/ without a suffix."""
    entries = []
    for toctree in re.findall(r"```\{toctree\}\n(.*?)```", (DOCS / page).read_text(), re.S):
        for line in toctree.splitlines():
            if line and not line.startswith(":"):
                entries.append(str(Path(page).parent / line))
    return entries


class OrgPages(unittest.TestCase):
    def test_each_org_source_has_its_page_in_one_table_of_contents(self):
        listed, pending = [], ["index.md"]
        while pending:
            entries = [entry for entry in toctree_entries(pending.pop()) if not entry.startswith(API)]
            listed += entries
            pending += [entry + ".md" for entry in entries]
        self.assertEqual(sorted(listed), [str(rel.with_suffix("")) for rel in sources() if rel != Path("index.org")])
        for rel in sources():
            page = DOCS / rel.with_suffix(".md")
            self.assertTrue(page.read_text().startswith(f"{GENERATED}{rel} by docs/export.el; edit that file. -->\n"), page)

    def test_each_written_page_has_its_org_source(self):
        for page in DOCS.rglob("*.md"):
            if "_build" not in page.parts and page.read_text().startswith(GENERATED):
                self.assertTrue((ORG / page.relative_to(DOCS).with_suffix(".org")).is_file(), page)

    def test_the_api_pages_are_not_committed(self):
        tracked = subprocess.run(["git", "ls-files", "docs/" + API], cwd=DOCS.parent, capture_output=True, text=True)
        if tracked.returncode != 0:
            self.skipTest("not in a git checkout")
        self.assertEqual(tracked.stdout, "")
        ignored = subprocess.run(["git", "check-ignore", "-q", "docs/" + API + "zig/index.md"], cwd=DOCS.parent)
        self.assertEqual(ignored.returncode, 0, "docs/.gitignore or .gitignore should ignore the API pages")

    @unittest.skipUnless(shutil.which("emacs"), "exporting the Org sources needs Emacs")
    def test_the_pages_are_what_their_org_sources_export_to(self):
        with tempfile.TemporaryDirectory() as out:
            run = subprocess.run(["emacs", "--batch", "-Q", "-l", str(DOCS / "export.el")],
                                 env=dict(os.environ, EB_LOCAL_DOCS_OUT=out), capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            stale = [str(rel) for rel in sources()
                     if (Path(out) / rel.with_suffix(".md")).read_text() != (DOCS / rel.with_suffix(".md")).read_text()]
        if stale:
            org = subprocess.run(["emacs", "--batch", "-Q", "--eval", "(progn (require 'org) (princ (org-version)))"],
                                 capture_output=True, text=True).stdout
            if not org.startswith(WRITTEN_WITH):
                self.skipTest(f"Org {org} lays pages out differently from Org {WRITTEN_WITH}x")
        self.assertEqual(stale, [], "run: emacs --batch -Q -l docs/export.el")

    @unittest.skipUnless(shutil.which("emacs"), "exporting the Org sources needs Emacs")
    def test_an_inline_source_block_comes_out_as_code(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shutil.copy(DOCS / "export.el", root)
            (root / "orgmode").mkdir()
            (root / "orgmode" / "page.org").write_text("#+TITLE: Page\n\nRun src_sh{eb-local env} first.\n")
            run = subprocess.run(["emacs", "--batch", "-Q", "-l", str(root / "export.el")], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertIn("Run `eb-local env` first.\n", (root / "page.md").read_text())


if __name__ == "__main__":
    unittest.main()
