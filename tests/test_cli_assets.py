#!/usr/bin/env python3
"""Tests for tools/cli_assets.py completion and manpage generation."""
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest

import binary

REPO = Path(__file__).resolve().parents[1]
TOOL = REPO / "tools" / "cli_assets.py"


@unittest.skipUnless(binary.BIN, "cli_assets runs against the compiled eb-local binary")
class CliAssets(unittest.TestCase):
    def test_completions_exclude_prose_and_include_subcommands_and_actions(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "share"
            cp = subprocess.run(
                ["python3", str(TOOL), "--out", str(out), "--tool", f"eb-local::{binary.BIN}"],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(cp.returncode, 0, cp.stderr)

            bash = (out / "completions" / "eb-local.bash").read_text(encoding="utf-8")
            m = re.search(r"compgen -W ('[^']*'|\"[^\"]*\"|\S+)", bash)
            self.assertIsNotNone(m, bash)
            words = set(shlex.split(m.group(1))[0].split())

            for prose in ("the", "you", "and", "an", "a", "writes", "what", "Deprecated", "CPU", "DIR"):
                self.assertNotIn(prose, words, f"prose leaked into completions: {prose}")

            for expected in (
                "check", "clean", "config", "dev", "doctor", "eb", "env", "help",
                "list", "lmod-cache", "modulerc", "overlay", "profiles", "restore",
                "rpath-wrappers", "site", "submit", "uninstall",
                "show", "install", "materialize", "bump", "plan",
                "--help", "--version", "--json", "--recursive", "--strict", "--get", "--target",
            ):
                self.assertIn(expected, words, f"missing expected completion token: {expected}")

            zsh = (out / "completions" / "_eb-local").read_text(encoding="utf-8")
            fish = (out / "completions" / "eb-local.fish").read_text(encoding="utf-8")
            self.assertNotIn("'the'", zsh)
            self.assertNotIn("complete -c eb-local -f -a the\n", fish)
            self.assertTrue((out / "man" / "eb-local.1").is_file())

    def test_help_and_version_raw_bytes_and_repro(self):
        h = subprocess.run([binary.BIN, "--help"], capture_output=True, text=False)
        self.assertEqual(h.returncode, 0)
        self.assertEqual(h.stderr, b"")
        self.assertTrue(h.stdout.startswith(b"eb-local: install and build software on top of EESSI"))

        repro = subprocess.run(
            ["python3", str(TOOL), "--check-repro", "--tool", f"eb-local::{binary.BIN}"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(repro.returncode, 0, repro.stderr)


if __name__ == "__main__":
    unittest.main()
