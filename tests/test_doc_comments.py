#!/usr/bin/env python3
"""Every file in src/ starts with a //! comment, and every pub declaration has a /// one.

The API reference is written from these comments, so a declaration
without one has an entry there with nothing to say.
"""
from pathlib import Path
import re
import unittest

SRC = Path(__file__).resolve().parents[1] / "src"
PUB = re.compile(r"\s*pub (?:const|var|fn|inline fn)\b")


def undocumented():
    found = []
    for path in sorted(SRC.glob("*.zig")):
        lines = path.read_text().splitlines()
        if not lines or not lines[0].startswith("//!"):
            found.append(f"{path.name}:1: no //! comment")
        for number, line in enumerate(lines):
            if PUB.match(line) and not (number > 0 and lines[number - 1].strip().startswith("///")):
                found.append(f"{path.name}:{number + 1}: {line.strip()}")
    return found


class DocComments(unittest.TestCase):
    def test_every_pub_declaration_has_a_doc_comment(self):
        self.assertEqual(undocumented(), [])


if __name__ == "__main__":
    unittest.main()
