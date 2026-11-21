#!/usr/bin/env python3
"""The usage the Zig build prints names every option its parser takes."""
from pathlib import Path
import re
import subprocess
import unittest

import binary

MAIN = Path(__file__).resolve().parents[1] / "src" / "main.zig"


def parsed_options():
    """Each option main() compares an argument with, in the order it does."""
    text = MAIN.read_text()
    body = text[text.index("pub fn main("):]
    names = re.findall(r'(?:std\.mem\.eql\(u8, (?:x|first), |joined\(x, )"(-[^"]*)"', body)
    return list(dict.fromkeys(names))


@unittest.skipUnless(binary.BIN, "usage checks need a directly named Zig test build")
class Usage(unittest.TestCase):
    def test_the_usage_names_every_option_the_parser_takes(self):
        run = subprocess.run([binary.BIN, "--help"], capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        options = parsed_options()
        self.assertIn("--logs-older-than", options)
        # The usage is what -h and --help print.
        missing = [o for o in options if o not in ("-h", "--help")
                   and not re.search(rf"(?<![\w-]){re.escape(o)}(?![\w-])", run.stdout)]
        self.assertEqual(missing, [])

    def test_the_usage_says_eb_takes_the_global_options(self):
        usage = subprocess.run([binary.BIN, "--help"], capture_output=True, text=True).stdout
        self.assertIn("Every configured command, including eb, takes --profile NAME, --project DIR", usage)


if __name__ == "__main__":
    unittest.main()
