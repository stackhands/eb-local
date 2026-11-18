#!/usr/bin/env python3
"""The lines of eb-local doctor that the how-to guides show.

Each is a line doctor writes: its level, then a message whose format is in
src/main.zig, or the line that says whether anything stops a build. A
reworded message fails here until the guides show the new words.
"""
from pathlib import Path
import re
import unittest

import howto

MAIN = Path(__file__).resolve().parents[1] / "src" / "main.zig"
LEVELS = ("ok  ", "info", "warn", "FAIL")
BLOCK = re.compile(r"^ *#\+begin_(src bash|example)\n(.*?)^ *#\+end_(?:src|example)\n", re.M | re.S)


def message(literal):
    """The message a Zig format string LITERAL writes, as a regular
    expression that takes anything for each placeholder, or None for a
    format of placeholders alone, whose words are elsewhere."""
    parts = re.split(r"(\{\{|\}\}|\{[^{}]*\})", re.sub(r"\\(.)", r"\1", literal))
    if not any(re.search("[A-Za-z]", p) for p in parts if not p.startswith("{")):
        return None
    return re.compile("".join(
        "\\{" if p == "{{" else "\\}" if p == "}}" else ".*" if p.startswith("{") else re.escape(p)
        for p in parts))


def messages():
    found = (message(m) for m in re.findall(
        r'\bnote\(a, &?out, (?:[^,]+, )?(?:"(?:ok  |info|warn|FAIL)"|[^,]+), "((?:[^"\\]|\\.)*)"',
        MAIN.read_text()))
    return [m for m in found if m]


def words():
    """The string literals of src/main.zig that hold a letter. The note
    "{s} {s}" writes a variable's name, then one of these, which a function
    such as ownInstallVar returns."""
    found = re.findall(r'"((?:[^"\\\n]|\\.)*)"', MAIN.read_text())
    return {re.sub(r"\\(.)", r"\1", w) for w in found if re.search("[A-Za-z]", w)}


def shown():
    """(page, line) for each line of an example block the how-to guides show
    after a command that runs eb-local doctor."""
    lines = []
    for page in sorted(howto.HOWTO.glob("*.org")):
        command = ""
        for kind, body in BLOCK.findall(page.read_text()):
            if kind.startswith("src"):
                command = body.strip().splitlines()[-1]
            elif "eb-local doctor" in command:
                lines += [(page.name, line.strip()) for line in body.splitlines() if line.strip()]
    return lines


class DoctorLinesInTheGuides(unittest.TestCase):
    def test_the_guides_show_doctor_output(self):
        pages = {page for page, _ in shown()}
        self.assertLessEqual({"write-a-site-file.org", "load-eessi.org", "find-what-is-wrong.org"}, pages)

    def test_each_line_shown_is_one_doctor_writes(self):
        formats = messages()
        self.assertGreater(len(formats), 30)
        source = MAIN.read_text()
        self.assertIn('"{s} {s}", .{ v, why }', source)
        literals = words()
        for page, line in shown():
            with self.subTest(page=page, line=line):
                if line[:4] in LEVELS and line[4:5] == " ":
                    text = line[5:]
                    named = text.partition(" ")[2] in literals
                    self.assertTrue(named or any(f.fullmatch(text) for f in formats),
                                    "no message of doctor's has these words")
                else:
                    self.assertIn(line, source)


if __name__ == "__main__":
    unittest.main()
