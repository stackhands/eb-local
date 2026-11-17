#!/usr/bin/env python3
"""The messages of eb-local that the how-to guides show.

Each line of an example block that starts with eb-local: is a line of a
message in src/, so a reworded message fails here until the guides show
the new words.
"""
from pathlib import Path
import re
import unittest

import howto

SRC = Path(__file__).resolve().parents[1] / "src"
PREFIX = "eb-local: "
OPERAND = r'"(?:[^"\\\n]|\\.)*"|[A-Za-z_][\w.]*'
# A string literal, or literals and names that ++ joins.
JOINED = re.compile(rf'(?:{OPERAND})(?:\s*\+\+\s*(?:{OPERAND}))+|"(?:[^"\\\n]|\\.)*"')
CONST = re.compile(r'^\s*(?:pub\s+)?const\s+(\w+)\s*=\s*"((?:[^"\\\n]|\\.)*)";', re.M)
# What the build script, a multiline string, echoes as eb-local.
ECHO = re.compile(r'^\s*\\\\.*?\becho "eb-local: ([^"]*)"', re.M)
EXAMPLE = re.compile(r"^ *#\+begin_example\n(.*?)^ *#\+end_example\n", re.M | re.S)


def pattern(line):
    """The regular expression for one line of a Zig format string, still
    escaped, that takes anything for each placeholder; None for a line
    with too few words of its own to tell one message from another."""
    parts = re.split(r"(\{\{|\}\}|\{[^{}]*\})", line)
    if len(re.findall("[A-Za-z]", "".join(p for p in parts if not p.startswith("{")))) < 10:
        return None
    return re.compile("".join(
        "\\{" if p == "{{" else "\\}" if p == "}}" else ".*" if p.startswith("{")
        else re.escape(re.sub(r"\\(.)", r"\1", p)) for p in parts))


def messages():
    """Each line of each string in src/, without the eb-local: prefix, and
    each line the build script echoes, with anything for a variable."""
    found, echoed = set(), []
    for path in sorted(SRC.rglob("*.zig")):
        text = path.read_text()
        consts = dict(CONST.findall(text))
        for joined in JOINED.findall(text):
            # A name joined in is a string constant of the file, or any text.
            whole = "".join(o[1:-1] if o.startswith('"') else consts.get(o, "{s}")
                            for o in re.findall(OPERAND, joined))
            for line in whole.split("\\n"):
                found.add(line.removeprefix(PREFIX))
        for line in ECHO.findall(text):
            parts = re.split(r"(\$\{[^}]*\}|\$\w+)", line)
            echoed.append(re.compile("".join(".*" if p.startswith("$") else re.escape(p) for p in parts)))
    return [p for p in map(pattern, sorted(found)) if p] + echoed


def shown():
    """(page, line) for each line of an example block in the how-to guides
    that starts with eb-local:, without that prefix."""
    return [(page.name, line.strip()[len(PREFIX):])
            for page in sorted(howto.HOWTO.glob("*.org"))
            for block in EXAMPLE.findall(page.read_text())
            for line in block.splitlines() if line.strip().startswith(PREFIX)]


class MessagesInTheGuides(unittest.TestCase):
    def test_the_guides_show_messages(self):
        self.assertGreaterEqual(len(shown()), 15)

    def test_each_message_shown_is_one_eb_local_writes(self):
        formats = messages()
        for page, line in shown():
            with self.subTest(page=page, line=line):
                self.assertTrue(any(f.fullmatch(line) for f in formats), "no message in src/ has these words")


if __name__ == "__main__":
    unittest.main()
