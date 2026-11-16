#!/usr/bin/env python3
"""Site file templates, configuration carried in EB_LOCAL_* variables, and
how nimvault is run, through the command line of the Zig build
(EB_LOCAL_BIN). The Bash script has none of these.
"""
import os
from pathlib import Path
import shlex
import stat
import subprocess
import unittest

import binary
from test_storage import StorageFixture

VAULT_TOOL = r'''#!/bin/sh
printf '%s\n' "$@" > "$CONTROL_ROOT/nimvault-args"
[ "$1" = get ] || exit 64
printf 'vault-value\n'
'''


@unittest.skipUnless(binary.BIN, "site templates and EB_LOCAL_SECRET_* are features of the Zig build")
class SitesCli(StorageFixture):
    def setUp(self):
        super().setUp()
        self.home = self.root / "home"
        self.home.mkdir()
        self.env.update(HOME=str(self.home), SLURM_JOB_ID="")
        self.env.pop("XDG_CONFIG_HOME", None)
        for name in list(self.env):
            if name.startswith("EB_LOCAL_") and name not in ("EB_LOCAL_CONFIG", "EB_LOCAL_PREFIX", "EB_LOCAL_BIN"):
                self.env.pop(name)

    def run_tool(self, args, **extra):
        argv, env = binary.command(self.script, args, dict(self.env, **extra))
        return subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)

    # -- templates -------------------------------------------------------------

    def test_list_names_each_template_and_its_placeholders(self):
        run = self.run_tool(["site", "list"])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertRegex(run.stdout, r"snellius\s+placeholders: partition")
        self.assertRegex(run.stdout, r"slurm\s+placeholders: node_local_root, node_local_fstype, shared_scratch, partition")

    def test_show_fills_defaults_and_set_values(self):
        run = self.run_tool(["site", "show", "snellius"])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn('node_local_root = "/scratch-node"', run.stdout)
        self.assertIn("salloc -p rome ", run.stdout)
        self.assertNotIn("{{", run.stdout)
        run = self.run_tool(["site", "show", "snellius", "--set", "partition=genoa"])
        self.assertIn("salloc -p genoa ", run.stdout)

    def test_install_writes_a_site_file_the_program_then_reads(self):
        target = self.root / "etc" / "config.toml"
        target.parent.mkdir()
        run = self.run_tool(["site", "install", "slurm", "--to", str(target),
                             "--set", "node_local_root=/local", "--set", "shared_scratch=/scratch"])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o644)
        self.assertIn('node_local_root = "/local"', target.read_text())
        run = self.run_tool(["config", "--config", str(target)])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertRegex(run.stdout, r"storage\.node_local_root\s+/local\s+\[site ")
        self.assertRegex(run.stdout, r"storage\.shared_scratch\s+/scratch\s+\[site ")

    def test_install_refusals(self):
        target = self.root / "config.toml"
        cases = [
            (["site", "install", "slurm", "--to", str(target)], "needs --set node_local_root=VALUE"),
            (["site", "install", "slurm", "--to", str(target), "--set", "node_local_root=relative",
              "--set", "shared_scratch=/s"], "node_local_root"),
            (["site", "install", "snellius", "--to", str(target), "--set", 'partition=a"b'], "without quotes"),
            (["site", "install", "snellius", "--to", str(target), "--set", "colour=blue"], "no placeholder colour"),
            (["site", "install", "nowhere"], "no site template 'nowhere'"),
            (["site", "frobnicate", "snellius"], "site takes list, show NAME or install NAME"),
        ]
        for argv, needle in cases:
            with self.subTest(argv=argv):
                run = self.run_tool(argv)
                self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
                self.assertIn(needle, run.stderr)
                self.assertFalse(target.exists())

    def test_install_does_not_replace_unless_forced_and_never_through_a_link(self):
        target = self.root / "config.toml"
        target.write_text("# the site's own\n")
        run = self.run_tool(["site", "install", "snellius", "--to", str(target)])
        self.assertEqual(run.returncode, 2)
        self.assertIn("--force replaces it", run.stderr)
        self.assertEqual(target.read_text(), "# the site's own\n")
        run = self.run_tool(["site", "install", "snellius", "--to", str(target), "--force"])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("/scratch-node", target.read_text())
        elsewhere = self.root / "elsewhere"
        elsewhere.write_text("untouched\n")
        link = self.root / "link.toml"
        link.symlink_to(elsewhere)
        run = self.run_tool(["site", "install", "snellius", "--to", str(link), "--force"])
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(elsewhere.read_text(), "untouched\n")

    # -- configuration in the environment -------------------------------------

    def test_config_env_round_trips(self):
        user = self.home / ".config" / "eb-local" / "config.toml"
        user.parent.mkdir(parents=True)
        user.write_text('dev.modules = ["FFTW/3.3.10-GCC-15.2.0"]\n'
                        '[nimvault]\nvault = "~/vault"\n'
                        '[secrets]\nTOKEN = "nimvault:tokens/mirror"\n')
        user.chmod(0o600)
        first = self.run_tool(["config", "--env"])
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn("export EB_LOCAL_DEV_MODULES=FFTW/3.3.10-GCC-15.2.0\n", first.stdout)
        self.assertIn("export EB_LOCAL_NIMVAULT_VAULT='~/vault'\n", first.stdout)
        self.assertIn("export EB_LOCAL_SECRET_TOKEN=nimvault:tokens/mirror\n", first.stdout)
        # Without the user file, the exported lines alone give the same settings.
        user.unlink()
        carried = {}
        for line in first.stdout.splitlines():
            if line.startswith("export "):
                name, _, value = line[len("export "):].partition("=")
                carried[name] = shlex.split(value)[0]
        second = self.run_tool(["config", "--env"], **carried)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(second.stdout, first.stdout)
        shown = self.run_tool(["config"], **carried)
        self.assertRegex(shown.stdout, r"TOKEN\s+nimvault:tokens/mirror\s+\[environment EB_LOCAL_SECRET_TOKEN\]")

    def test_secret_variables_are_checked_like_the_file(self):
        cases = {
            "EB_LOCAL_SECRET_TOKEN": ("hunter2", "never written in a variable"),
            "EB_LOCAL_SECRET_PATH": ("env:X", "not a variable name a secret may set"),
            "EB_LOCAL_SECRET_OPT": ("nimvault:--recipient", "a source is"),
        }
        for name, (value, needle) in cases.items():
            with self.subTest(name=name):
                run = self.run_tool(["env"], **{name: value})
                self.assertEqual(run.returncode, 2, run.stdout)
                self.assertEqual(run.stdout, "")
                self.assertIn(needle, run.stderr)
                self.assertNotIn("hunter2", run.stderr)

    # -- nimvault ---------------------------------------------------------------

    def test_nimvault_program_and_vault_come_from_the_configuration(self):
        tool = self.root / "tools" / "vault-tool"
        tool.parent.mkdir()
        tool.write_text(VAULT_TOOL)
        tool.chmod(0o755)
        run = self.run_tool(["config", "--check"], PATH="/usr/bin:/bin",
                            EB_LOCAL_SECRET_TOKEN="nimvault:tokens/mirror",
                            EB_LOCAL_NIMVAULT_PROGRAM=str(tool), EB_LOCAL_NIMVAULT_VAULT="~/vault")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertRegex(run.stdout, r"TOKEN\s+nimvault:tokens/mirror\s+ok")
        self.assertNotIn("vault-value", run.stdout + run.stderr)
        args = (self.root / "nimvault-args").read_text().splitlines()
        self.assertEqual(args, ["get", "tokens/mirror", "--vault", str(self.home / "vault")])
        run = self.run_tool(["config"], EB_LOCAL_NIMVAULT_PROGRAM="relative/tool")
        self.assertEqual(run.returncode, 2)
        self.assertIn("EB_LOCAL_NIMVAULT_PROGRAM must be an absolute path", run.stderr)


if __name__ == "__main__":
    unittest.main()
