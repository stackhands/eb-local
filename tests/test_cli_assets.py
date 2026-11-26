#!/usr/bin/env python3
"""Tests for tools/cli_assets.py completion and manpage generation."""
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest

import binary
import hostile_fs

REPO = Path(__file__).resolve().parents[1]
TOOL = REPO / "tools" / "cli_assets.py"


@unittest.skipUnless(binary.ZIG, "cli_assets runs against the compiled eb-local binary")
class CliAssets(unittest.TestCase):
    def test_completions_exclude_prose_and_include_subcommands_and_actions(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "share"
            cp = subprocess.run(
                ["python3", str(TOOL), "--out", str(out), "--tool", f"eb-local::{binary.ZIG}"],
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
        h = subprocess.run([binary.ZIG, "--help"], capture_output=True, text=False)
        self.assertEqual(h.returncode, 0)
        self.assertEqual(h.stderr, b"")
        self.assertTrue(h.stdout.startswith(b"eb-local: install and build software on top of EESSI"))

        repro = subprocess.run(
            ["python3", str(TOOL), "--check-repro", "--tool", f"eb-local::{binary.ZIG}"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(repro.returncode, 0, repro.stderr)

    def test_manpage_escapes_leading_dot_and_apostrophe_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / "fake.sh"
            fake.write_text(
                "#!/bin/sh\n"
                "printf 'fake: demo\\n\\n.modulerc.lua\\n\\047quoted\\n'\n",
                encoding="utf-8",
            )
            fake.chmod(0o755)
            out = Path(tmp) / "share"
            cp = subprocess.run(
                ["python3", str(TOOL), "--out", str(out), "--tool", f"fake::{fake}"],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(cp.returncode, 0, cp.stderr)
            man = (out / "man" / "fake.1").read_text(encoding="utf-8")
            self.assertIn(r"\&.modulerc.lua", man)
            self.assertIn(r"\&'quoted", man)

    def test_bash_completion_loads_under_posix_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "share"
            cp = subprocess.run(
                ["python3", str(TOOL), "--out", str(out), "--tool", f"eb-local::{binary.ZIG}"],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(cp.returncode, 0, cp.stderr)
            bash_comp = out / "completions" / "eb-local.bash"
            posix = subprocess.run(
                ["/bin/bash", "--posix", "-c", '. "$1"', "_", str(bash_comp)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(posix.returncode, 0, posix.stdout + posix.stderr)

    def test_hostile_destinations_refuse_and_preserve_targets(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out_ro = root / "ro-share"
            comps_ro = out_ro / "completions"
            comps_ro.mkdir(parents=True)
            with hostile_fs.readonly_dir(comps_ro):
                cp_ro = subprocess.run(
                    ["python3", str(TOOL), "--out", str(out_ro), "--tool", f"eb-local::{binary.ZIG}"],
                    capture_output=True,
                    text=True,
                    check=False,
                )
            self.assertEqual(cp_ro.returncode, 1, cp_ro.stdout + cp_ro.stderr)
            self.assertNotIn("Traceback", cp_ro.stderr)
            self.assertIn("cli_assets:", cp_ro.stderr)

            out_dir_collision = root / "dir-collision"
            (out_dir_collision / "completions" / "eb-local.bash").mkdir(parents=True)
            cp_dir = subprocess.run(
                ["python3", str(TOOL), "--out", str(out_dir_collision), "--tool", f"eb-local::{binary.ZIG}"],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(cp_dir.returncode, 1, cp_dir.stdout + cp_dir.stderr)
            self.assertNotIn("Traceback", cp_dir.stderr)
            self.assertIn("cli_assets:", cp_dir.stderr)

            for rel in ("completions/eb-local.bash", "man/eb-local.1"):
                with self.subTest(rel=rel):
                    out_sym = root / f"sym-{rel.replace('/', '-')}"
                    link_path = out_sym / rel
                    link_path.parent.mkdir(parents=True)
                    outside = root / f"outside-{rel.replace('/', '-')}"
                    hostile_fs.dangling_symlink(link_path, outside)
                    cp_sym = subprocess.run(
                        ["python3", str(TOOL), "--out", str(out_sym), "--tool", f"eb-local::{binary.ZIG}"],
                        capture_output=True,
                        text=True,
                        check=False,
                    )
                    self.assertEqual(cp_sym.returncode, 1, cp_sym.stdout + cp_sym.stderr)
                    self.assertNotIn("Traceback", cp_sym.stderr)
                    self.assertIn("symlink", cp_sym.stderr)
                    self.assertFalse(outside.exists())
                    if rel == "man/eb-local.1":
                        self.assertFalse((out_sym / "completions").exists())

    def test_enospc_on_the_generator_write_keeps_destination_clean(self):
        import os

        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "share"
            env = dict(os.environ, EB_LOCAL_TEST_CLI_ASSETS_WRITE="ENOSPC")
            cp = subprocess.run(
                ["python3", str(TOOL), "--out", str(out), "--tool", f"eb-local::{binary.ZIG}"],
                capture_output=True,
                text=True,
                check=False,
                env=env,
            )
            self.assertEqual(cp.returncode, 1, cp.stdout + cp.stderr)
            self.assertNotIn("Traceback", cp.stderr)
            self.assertIn("cli_assets:", cp.stderr)
            self.assertFalse(out.exists())

if __name__ == "__main__":
    unittest.main()
