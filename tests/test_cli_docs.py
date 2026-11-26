#!/usr/bin/env python3
"""The command reference, docs/orgmode/reference/cli.org, against the program.

Its --help block is what the Zig build prints, it names every option the
parser takes, and it has a section for every command.
"""
from pathlib import Path
import re
import subprocess
import unittest

import binary
from test_usage import parsed_options

ROOT = Path(__file__).resolve().parents[1]
PAGE = ROOT / "docs" / "orgmode" / "reference" / "cli.org"
MAIN = ROOT / "src" / "main.zig"


def help_block(page):
    """The example block after the line that introduces --help."""
    lines = page.splitlines(keepends=True)
    begin = lines.index("#+begin_example\n", lines.index("=eb-local --help= prints:\n")) + 1
    return "".join(lines[begin:lines.index("#+end_example\n", begin)])


def commands():
    """The commands the Command enum of main.zig names, but the build."""
    enum = re.search(r"const Command = enum \{ (.*?) \};", MAIN.read_text()).group(1)
    words = [re.sub(r'^@"(.*)"$', r"\1", word.strip()) for word in enum.split(",")]
    return [word for word in words if word != "build"]


class CliReference(unittest.TestCase):
    @unittest.skipUnless(binary.ZIG, "the help of the Zig build")
    def test_the_help_block_is_what_the_program_prints(self):
        run = subprocess.run([binary.ZIG, "--help"], capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(help_block(PAGE.read_text()), run.stdout, f"{PAGE}: the `eb-local --help` block")

    def test_the_page_names_every_option_the_parser_takes(self):
        page = PAGE.read_text()
        missing = [o for o in parsed_options() if not re.search(rf"(?<![\w-]){re.escape(o)}(?![\w-])", page)]
        self.assertEqual(missing, [])

    def test_each_subcommand_section_names_its_synopsis_flags(self):
        page = PAGE.read_text()
        synopsis = page.split("\n* Synopsis\n", 1)[1].split("\n#+end_example\n", 1)[0]
        synopsis = synopsis.split("#+begin_example\n", 1)[1]
        entries = []
        for line in synopsis.splitlines():
            if line.startswith(" ") and entries:
                entries[-1] += " " + line.strip()
            elif line.strip():
                entries.append(line.strip())
        parts = re.split(r"(?m)^\*\* (.+)$", page)
        sections = {parts[i].strip(): parts[i + 1] for i in range(1, len(parts), 2)}
        for entry in entries:
            m = re.match(r"^eb-local (?:\[OPTION\]\.\.\. )?([a-z][a-z0-9-]*)", entry)
            if not m or m.group(1) == "help":
                continue
            cmd = m.group(1)
            sec = sections.get(cmd, "")
            for flag in re.findall(r"--[a-z][a-z0-9-]*", entry):
                self.assertRegex(
                    sec,
                    rf"(?<![\w-]){re.escape(flag)}(?![\w-])",
                    f"{PAGE} section '** {cmd}' omits Synopsis flag {flag}",
                )

    def test_each_command_has_its_section(self):
        names = commands()
        self.assertIn("rpath-wrappers", names)
        sections = re.findall(r"^\*\* (.+)$", PAGE.read_text(), re.M)
        self.assertEqual([name for name in names if name not in sections], [])

    def test_doctor_json_exit_note_includes_strict(self):
        page = PAGE.read_text()
        doctor = page.split("\n** doctor\n", 1)[1].split("\n** ", 1)[0]
        note = next(line for line in doctor.splitlines() if line.startswith("With =--json=, exit 1"))
        self.assertIn("--strict", note)


if __name__ == "__main__":
    unittest.main()
