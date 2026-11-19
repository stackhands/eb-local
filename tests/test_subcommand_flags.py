#!/usr/bin/env python3
"""Subcommand flag parsing across every command that takes flags."""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import binary
from test_storage import StorageFixture


@unittest.skipUnless(binary.BIN, "subcommand flag audit tests run against the Zig binary")
class SubcommandFlags(StorageFixture):
    def run_bin(self, args, *, cwd=None, text=True, **extra):
        argv, env = binary.command(self.script, args, dict(self.env, **extra))
        return subprocess.run(argv, env=env, cwd=cwd or self.root, capture_output=True, text=text)

    def test_every_flagged_subcommand_rejects_unknown_flags_with_exit_2(self):
        cases = [
            (["rpath-wrappers", "--bogus"], "rpath-wrappers takes only"),
            (["check", "--bogus"], "check does not know '--bogus'"),
            (["env", "--bogus"], "env takes only"),
            (["profiles", "--bogus"], "profiles takes only"),
            (["doctor", "--bogus"], "doctor takes"),
            (["lmod-cache", "--bogus"], "lmod-cache does not know '--bogus'"),
            (["modulerc", "--bogus"], "modulerc does not know '--bogus'"),
            (["overlay", "--bogus"], "overlay does not know '--bogus'"),
            (["list", "--bogus"], "list does not know '--bogus'"),
            (["config", "--bogus"], "config does not know '--bogus'"),
            (["site", "--bogus"], "site does not know '--bogus'"),
            (["dev", "--bogus"], "dev does not know the option '--bogus'"),
            (["clean", "--bogus"], "clean does not know '--bogus'"),
            (["uninstall", "--bogus"], "uninstall does not know '--bogus'"),
            (["restore", "--bogus"], "restore does not know '--bogus'"),
            (["submit", "--bogus", "demo.eb"], "submit does not know '--bogus'"),
        ]
        for args, needle in cases:
            with self.subTest(args=args):
                got = self.run_bin(args, SLURM_JOB_ID="")
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")
                self.assertIn(needle, got.stderr)

    def test_flags_after_positionals_are_parsed_as_flags(self):
        # dev: --strict and --buildenv after a module name stay options, not modules.
        dev = self.run_bin(["dev", "FFTW/3.3.10-GCC-15.2.0", "--strict", "--buildenv", "buildenv/mine"], SLURM_JOB_ID="")
        self.assertEqual(dev.returncode, 0, dev.stderr)
        self.assertIn("if [[ ! -e $init ]]; then", dev.stdout)
        self.assertIn("module load buildenv/mine || return $?\n", dev.stdout)
        self.assertNotIn("--strict", dev.stdout)

        # list: --missing after a filter narrows and stays an option, not a filter.
        tree = self.prefix / "versions/2026.06/software/linux/x86_64/amd/zen2"
        (tree / "software/demo/1.0").mkdir(parents=True)
        (tree / "modules/all/demo/1.0.lua").parent.mkdir(parents=True)
        (tree / "modules/all/demo/1.0.lua").write_text("-- m\n")
        lst = self.run_bin(
            ["list", "demo", "--missing"],
            SLURM_JOB_ID="",
            EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4",
            EESSI_VERSION="2026.06",
        )
        self.assertEqual(lst.returncode, 0, lst.stderr)
        self.assertEqual(lst.stdout, "demo/1.0\n")

        # site: --json after list still outputs JSON rather than looking up a template named --json.
        site = self.run_bin(["site", "list", "--json"])
        self.assertEqual(site.returncode, 0, site.stderr)
        self.assertIn('"kind":"site_list"', site.stdout)

        # uninstall & restore: --dry-run after module names acts as dry-run, not a module name.
        uninst = self.run_bin(["uninstall", "demo/1.0", "--dry-run"], SLURM_JOB_ID="")
        self.assertEqual(uninst.returncode, 0, uninst.stderr)
        self.assertIn("dry run, nothing removed", uninst.stdout)
        self.assertTrue((tree / "software/demo/1.0").is_dir())

        rtrash = self.root / "bin/rtrash"
        rtrash.parent.mkdir(parents=True, exist_ok=True)
        rtrash.write_text('#!/bin/sh\necho "[]"\n')
        rtrash.chmod(0o755)
        rest = self.run_bin(["restore", "demo/1.0", "--dry-run"], PATH=f"{rtrash.parent}:{os.environ['PATH']}")
        self.assertEqual(rest.returncode, 2, rest.stdout + rest.stderr)
        self.assertIn("is not in the trash", rest.stderr)

        # submit: --print before recipe prints job without sbatch; post-recipe flags forward to eb.
        site = self.root / "submit-site.toml"
        site.write_text(f'[storage]\nnode_local_root = "{self.nodes}"\n[build.node_types]\ncpu = "-p cpu -n 4"\n')
        site.chmod(0o644)
        sub = self.run_bin(["--config", str(site), "submit", "--print", "--on", "cpu", "demo.eb", "--robot"])
        self.assertEqual(sub.returncode, 0, sub.stderr)
        self.assertIn("demo.eb --robot", sub.stdout)

        # check: --recursive --quiet after target file still audit without treating flags as files.
        gcc = shutil.which("gcc")
        if gcc:
            (self.root / "p.c").write_text("int main(void) { return 0; }\n")
            prog = self.root / "p"
            subprocess.run([gcc, "-o", str(prog), str(self.root / "p.c")], check=True)
            chk = self.run_bin(["check", str(prog), "--recursive", "--quiet"])
            self.assertEqual(chk.returncode, 0, chk.stdout + chk.stderr)
            self.assertEqual(chk.stdout, "eb-local check: no problems\n")

        # env, rpath-wrappers, profiles, doctor, config, clean, lmod-cache, modulerc: verify valid flag acceptance.
        self.assertEqual(self.run_bin(["env", "--strict"], SLURM_JOB_ID="").returncode, 0)
        self.assertEqual(self.run_bin(["rpath-wrappers", "--unwrapped"], PATH="/nonexistent").returncode, 0)
        self.assertEqual(self.run_bin(["profiles", "--json"], SLURM_JOB_ID="").returncode, 0)
        doc = self.run_bin(["doctor", "--json"], SLURM_JOB_ID="")
        self.assertIn(doc.returncode, (0, 1), doc.stderr)
        self.assertIn('"kind":"doctor"', doc.stdout)
        self.assertEqual(self.run_bin(["config", "--env"], SLURM_JOB_ID="").returncode, 0)
        self.assertEqual(self.run_bin(["clean", "--dry-run", "--no-logs"], SLURM_JOB_ID="").returncode, 0)
        both_clean = self.run_bin(["clean", "--no-logs", "--logs-older-than", "7"], SLURM_JOB_ID="")
        self.assertEqual(both_clean.returncode, 2, both_clean.stdout + both_clean.stderr)
        self.assertEqual(both_clean.stdout, "")
        self.assertIn("clean takes --no-logs or --logs-older-than, not both", both_clean.stderr)
        dup_days = self.run_bin(["clean", "--logs-older-than", "7", "--logs-older-than", "14"], SLURM_JOB_ID="")
        self.assertEqual(dup_days.returncode, 2, dup_days.stdout + dup_days.stderr)
        self.assertEqual(dup_days.stdout, "")
        self.assertIn("clean takes one --logs-older-than", dup_days.stderr)
        self.assertEqual(self.run_bin(["lmod-cache", "--prefix", str(self.prefix), "--dry-run"]).returncode, 0)
        self.assertEqual(
            self.run_bin(["modulerc", "--module-tree", str(tree / "modules/all"), "--default", "demo/1.0", "--dry-run"]).returncode,
            0,
        )

    def test_overlay_rejects_unknown_or_misplaced_flags_and_preserves_default_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            content = b"easyblock = 'ConfigureMake'\nname = 'demo'\nversion = '1.0'\n"
            digest = hashlib.sha256(content).hexdigest()
            (root / "base.eb").write_bytes(content)
            (root / "site.overlay.toml").write_text(
                f'overlay_version = 1\nbase_digest = "{digest}"\n',
                encoding="utf-8",
            )

            # Raw-byte parity for valid materialize.
            good = self.run_bin(
                ["overlay", "materialize", "--overlay", "site.overlay.toml", "--base", "base.eb", "--out-dir", "good-out"],
                cwd=root,
                text=False,
            )
            self.assertEqual(
                (good.returncode, good.stdout, good.stderr),
                (0, b"wrote good-out/materialized-base.eb and good-out/provenance.toml\n", b""),
            )

            # Unknown flag (such as --dryrun typo) or stray positional on materialize exits 2 and writes nothing.
            for extra in (["--dryrun"], ["unexpected"], ["--eb-stack", "/bin/true"], ["--", "--dry-run"]):
                with self.subTest(extra=extra):
                    bad = self.run_bin(
                        [
                            "overlay",
                            "materialize",
                            "--overlay",
                            "site.overlay.toml",
                            "--base",
                            "base.eb",
                            "--out-dir",
                            "bad-out",
                            *extra,
                        ],
                        cwd=root,
                    )
                    self.assertEqual(bad.returncode, 2, bad.stdout + bad.stderr)
                    self.assertEqual(bad.stdout, "")
                    self.assertFalse((root / "bad-out").exists())

            # materialize-only flags before -- are refused on bump/plan, while --dry-run after -- passes through.
            stub = root / "eb-stack"
            stub.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            stub.chmod(0o755)
            for action in ("bump", "plan"):
                refused = self.run_bin(["overlay", action, "--eb-stack", str(stub), "--dry-run"], cwd=root)
                self.assertEqual(refused.returncode, 2, refused.stdout + refused.stderr)
                self.assertIn("does not take materialize options", refused.stderr)

                fwd = self.run_bin(["overlay", action, "--eb-stack", str(stub), "--", "--dry-run"], cwd=root)
                self.assertEqual(fwd.returncode, 0, fwd.stderr)
                self.assertEqual(fwd.stdout.splitlines(), ["package", action, "--dry-run"])


if __name__ == "__main__":
    unittest.main()
