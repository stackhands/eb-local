#!/usr/bin/env python3
"""`eb-local modulerc` writes only operator-selected Lmod directives."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import binary


def run(args, *, text=True):
    return subprocess.run(
        [binary.BIN, "modulerc", *args],
        capture_output=True,
        text=text,
    )


@unittest.skipUnless(binary.BIN, "EB_LOCAL_BIN names the Zig build")
class Modulerc(unittest.TestCase):
    def test_default_output_and_status_are_unchanged_raw_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            tree = Path(tmp) / "modules"
            control = tree / ".modulerc.lua"
            got = run(
                [
                    "--module-tree",
                    str(tree),
                    "--default",
                    "Example/2.0",
                ],
                text=False,
            )
            self.assertEqual(
                (got.returncode, got.stdout, got.stderr),
                (0, f"wrote {control}\n".encode(), b""),
            )

    def test_check_reports_drift_without_creating_the_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            tree = Path(tmp) / "modules"
            control = tree / ".modulerc.lua"
            args = [
                "--module-tree",
                str(tree),
                "--default",
                "Example/2.0",
            ]
            drift = run([*args, "--check"])
            self.assertEqual(
                (drift.returncode, drift.stdout, drift.stderr),
                (1, f"would update {control}\n", ""),
            )
            self.assertFalse(tree.exists())

            written = run(args)
            self.assertEqual(written.returncode, 0, written.stderr)
            before = (control.read_bytes(), control.stat().st_mtime_ns)
            current = run([*args, "--check"])
            self.assertEqual(
                (current.returncode, current.stdout, current.stderr),
                (0, f"up to date {control}\n", ""),
            )
            self.assertEqual(
                (control.read_bytes(), control.stat().st_mtime_ns),
                before,
            )

    def test_writes_and_idempotently_updates_the_module_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            tree = Path(tmp) / "modules"
            tree.mkdir()
            control = tree / ".modulerc.lua"
            control.write_text("-- an operator comment\n")
            args = [
                "--module-tree",
                str(tree),
                "--default",
                "Example/2.0",
                "--alias",
                "Example/latest=Example/2.0",
                "--hide",
                "Example/1.0",
            ]
            first = run(args)
            self.assertEqual(first.returncode, 0, first.stderr)
            expected = (
                "-- an operator comment\n"
                'module_version("Example/2.0", "default")\n'
                'module_alias("Example/latest", "Example/2.0")\n'
                'hide_version("Example/1.0")\n'
            )
            self.assertEqual(control.read_text(), expected)
            before = control.read_bytes()
            second = run(args)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(control.read_bytes(), before)

            modulecmd = shutil.which("modulecmd")
            if modulecmd:
                checked = subprocess.run(
                    [modulecmd, "bash", "avail"],
                    env={**os.environ, "MODULEPATH": str(tree)},
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(checked.returncode, 0, checked.stderr)

    def test_dry_run_prints_the_complete_file_without_writing_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            tree = Path(tmp) / "modules"
            tree.mkdir()
            control = tree / ".modulerc.lua"
            control.write_text('hide_version("Old/1.0")\n')
            got = run(
                [
                    "--module-tree",
                    str(tree),
                    "--default",
                    "New/2.0",
                    "--dry-run",
                ]
            )
            self.assertEqual(got.returncode, 0, got.stderr)
            self.assertEqual(
                got.stdout,
                'hide_version("Old/1.0")\n'
                'module_version("New/2.0", "default")\n',
            )
            self.assertEqual(control.read_text(), 'hide_version("Old/1.0")\n')

    def test_check_and_dry_run_are_alternatives(self):
        with tempfile.TemporaryDirectory() as tmp:
            got = run(
                [
                    "--module-tree",
                    tmp,
                    "--default",
                    "Example/2.0",
                    "--dry-run",
                    "--check",
                ]
            )
            self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
            self.assertEqual(got.stdout, "")
            self.assertEqual(
                got.stderr,
                "eb-local: modulerc takes --dry-run or --check, not both\n",
            )
            self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_never_selects_a_default_without_one_on_the_command_line(self):
        with tempfile.TemporaryDirectory() as tmp:
            got = run(["--module-tree", tmp, "--hide", "Example/1.0"])
            self.assertEqual(got.returncode, 0, got.stderr)
            text = (Path(tmp) / ".modulerc.lua").read_text()
            self.assertEqual(text, 'hide_version("Example/1.0")\n')
            self.assertNotIn("module_version", text)


if __name__ == "__main__":
    unittest.main()
