#!/usr/bin/env python3
"""The environment reference, docs/orgmode/reference/environment.org,
against the source: it names every EB_LOCAL_* variable a user may set and
none the program does not read, every variable a build sets for its script
or leaves out of it, and every variable env unsets.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
PAGE = ROOT / "docs" / "orgmode" / "reference" / "environment.org"
MAIN = ROOT / "src" / "main.zig"
NAME = re.compile(r"EB_LOCAL_[A-Z0-9_]+")


def mentioned(text):
    """The whole EB_LOCAL_* names in TEXT, without the prefixes of families
    (EB_LOCAL_SECRET_<NAME>) and the example secrets of messages."""
    return {name for name in NAME.findall(text) if not name.endswith("_") and not name.startswith("EB_LOCAL_SECRET_")}


def section(page, title):
    return page.split(f"\n* {title}\n", 1)[1].split("\n* ", 1)[0]


def array(text, name):
    """The strings of `const NAME = [_][]const u8{ ... };`."""
    body = re.search(r"const " + name + r" = \[_\]\[\]const u8\{(.*?)\};", text, re.S).group(1)
    return re.findall(r'"([A-Z_]+)"', body)


class EnvironmentReference(unittest.TestCase):
    def setUp(self):
        self.page = PAGE.read_text()
        self.main = MAIN.read_text()
        self.source = "".join(path.read_text() for path in sorted((ROOT / "src").glob("*.zig")))

    def test_the_page_names_each_variable_a_user_may_set(self):
        # The test artifact's own variables, and the one eb-local passes to
        # its build script, which a build removes from what it inherits.
        internal = {name for name in mentioned(self.source) if name.startswith("EB_LOCAL_TEST_")}
        internal.add("EB_LOCAL_SITE_TOOLCHAINS")
        self.assertIn("EB_LOCAL_EESSI_EXTEND", mentioned(self.source))
        self.assertEqual(sorted(mentioned(self.source) - internal - mentioned(self.page)), [])

    def test_the_page_names_no_variable_the_program_does_not_know(self):
        self.assertEqual(sorted(mentioned(self.page) - mentioned(self.source)), [])

    def test_the_build_section_names_what_a_build_sets_and_leaves_out(self):
        body = self.main[self.main.index("fn buildVariables("):]
        sets = re.findall(r'\.\{ "([A-Z_]+)",', body[:body.index("\n}\n")])
        self.assertIn("EASYBUILD_BUILDPATH", sets)
        left_out = array(self.main, "shell_startup") + array(self.main, "host_loader")
        build = section(self.page, "Set for a build")
        self.assertEqual([name for name in sets + left_out if f"={name}=" not in build], [])

    def test_the_env_section_names_what_env_unsets(self):
        unset = array(self.main, "install_vars")
        self.assertIn("EESSI_USER_INSTALL", unset)
        env = section(self.page, "Set by env and dev")
        self.assertEqual([name for name in unset if f"={name}=" not in env], [])


if __name__ == "__main__":
    unittest.main()
