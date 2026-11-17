#!/usr/bin/env python3
"""Site file templates, configuration carried in EB_LOCAL_* variables, and
how nimvault is run, through the command line of the Zig build
(EB_LOCAL_BIN). The Bash script has none of these.
"""
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import unittest

import binary
import howto
from test_storage import StorageFixture

EXAMPLES = Path(__file__).resolve().parents[1] / "examples" / "sites"
PATHS = ["--set", "node_local_root=/local", "--set", "shared_scratch=/scratch"]

VAULT_TOOL = r'''#!/bin/sh
printf '%s\n' "$@" > "$CONTROL_ROOT/nimvault-args"
[ "$1" = get ] || exit 64
printf 'vault-value\n'
'''


def site_settings(text):
    """Each `key = "value"` and `key = ["a", "b"]` line of a rendered site
    file, by table.key, a list's values joined by spaces as config prints them."""
    table, settings = "", {}
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("["):
            table = line.strip("[]")
        elif line and not line.startswith("#"):
            key, _, value = line.partition(" = ")
            settings[f"{table}.{key}"] = " ".join(re.findall(r'"([^"]*)"', value))
    return settings


def exported(text):
    """The variables config --env output sets when a shell sources it."""
    carried = {}
    for line in text.splitlines():
        if line.startswith("export "):
            name, _, value = line[len("export "):].partition("=")
            carried[name] = shlex.split(value)[0]
    return carried


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

    def test_list_names_each_built_in_template_and_its_placeholders(self):
        run = self.run_tool(["site", "list"])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual([line.split()[0] for line in run.stdout.splitlines()], ["slurm"])
        self.assertRegex(run.stdout, r"slurm\s+placeholders: node_local_root, node_local_mount, node_local_fstype, shared_scratch, partition")

    def test_show_fills_defaults_and_set_values(self):
        run = self.run_tool(["site", "show", "slurm"] + PATHS)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn('node_local_root = "/local"', run.stdout)
        self.assertIn('node_local_mount = "%u.%j"', run.stdout)
        self.assertIn('node_local_fstype = "xfs"', run.stdout)
        self.assertIn("salloc -p cpu ", run.stdout)
        self.assertNotIn("{{", run.stdout)
        run = self.run_tool(["site", "show", "slurm", "--set", "partition=gpu",
                             "--set", "node_local_mount=job-%j"] + PATHS)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("salloc -p gpu ", run.stdout)
        self.assertIn('node_local_mount = "job-%j"', run.stdout)
        run = self.run_tool(["site", "show", "slurm", "--set", "node_local_mount=%u"] + PATHS)
        self.assertEqual(run.returncode, 2, run.stdout)
        self.assertIn("storage.node_local_mount must be one file name", run.stderr)

    def test_the_how_to_shows_what_list_and_show_print(self):
        commands = [(c, out) for c, out in howto.shown("write-a-site-file") if c.startswith("eb-local site ")]
        self.assertEqual([c.split()[2] for c, _ in commands], ["list", "show", "install"])
        for command, out in commands[:2]:
            with self.subTest(command=command):
                run = self.run_tool(shlex.split(command)[1:])
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertEqual(run.stdout, out)
        # The page installs beside the program, as /usr/local/bin/eb-local.
        command, out = commands[2]
        target = self.root / "config.toml"
        run = self.run_tool(shlex.split(command)[1:] + ["--to", str(target)])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(run.stdout, out.replace("/usr/local/bin/config.toml", str(target)))

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
            (["site", "install", "slurm", "--to", str(target), "--set", 'partition=a"b'] + PATHS, "without quotes"),
            (["site", "install", "slurm", "--to", str(target), "--set", "colour=blue"] + PATHS, "no placeholder colour"),
            (["site", "install", "nowhere"], "no site template 'nowhere'"),
            (["site", "frobnicate", "slurm"], "site takes list, show NAME or install NAME"),
        ]
        for argv, needle in cases:
            with self.subTest(argv=argv):
                run = self.run_tool(argv)
                self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
                self.assertIn(needle, run.stderr)
                self.assertFalse(target.exists())

    def test_a_value_that_does_not_load_is_named_by_the_template_line(self):
        # The default target may be the site file in use; neither show nor a
        # refused install writes it, so the message names the template.
        target = self.root / "config.toml"
        for argv in (["site", "show", "slurm"], ["site", "install", "slurm"], ["site", "install", "slurm", "--to", str(target)]):
            with self.subTest(argv=argv):
                run = self.run_tool(argv + ["--set", "node_local_root=relative", "--set", "shared_scratch=/s"])
                self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
                self.assertEqual(run.stderr, "eb-local: template slurm:10: storage.node_local_root must be one absolute path "
                                             "without a trailing slash\n")
                self.assertFalse(target.exists())

    def test_install_does_not_replace_unless_forced_and_never_through_a_link(self):
        target = self.root / "config.toml"
        target.write_text("# the site's own\n")
        run = self.run_tool(["site", "install", "slurm", "--to", str(target)] + PATHS)
        self.assertEqual(run.returncode, 2)
        self.assertIn("--force replaces it", run.stderr)
        self.assertEqual(target.read_text(), "# the site's own\n")
        run = self.run_tool(["site", "install", "slurm", "--to", str(target), "--force"] + PATHS)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn('node_local_root = "/local"', target.read_text())
        elsewhere = self.root / "elsewhere"
        elsewhere.write_text("untouched\n")
        link = self.root / "link.toml"
        link.symlink_to(elsewhere)
        run = self.run_tool(["site", "install", "slurm", "--to", str(link), "--force"] + PATHS)
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(elsewhere.read_text(), "untouched\n")

    def test_every_site_example_installs_the_settings_it_names(self):
        examples = sorted(EXAMPLES.glob("*.toml"))
        self.assertTrue(examples)
        for example in examples:
            with self.subTest(example=example.name):
                target = self.root / example.name
                run = self.run_tool(["site", "install", str(example), "--to", str(target)])
                self.assertEqual(run.returncode, 0, run.stderr)
                settings = site_settings(target.read_text())
                self.assertIn("storage.node_local_root", settings)
                shown = self.run_tool(["config", "--config", str(target)])
                self.assertEqual(shown.returncode, 0, shown.stderr)
                for key, value in settings.items():
                    self.assertRegex(shown.stdout, rf"(?m)^{re.escape(key)}\s+{re.escape(value)}\s+\[site ")

    def test_a_template_file_renders_and_installs_as_a_built_in_one_does(self):
        template = self.root / "templates" / "site.toml"
        template.parent.mkdir()
        template.write_text('[storage]\nnode_local_root = "{{node_local_root:/local}}"\n'
                            'shared_scratch = ["/scratch"]\n'
                            '[build]\nallocation_hint = "salloc -p {{partition}} -n 16"\n')
        template.chmod(0o644)
        run = self.run_tool(["site", "show", str(template)])
        self.assertEqual(run.returncode, 2, run.stdout)
        self.assertIn(f"template {template} needs --set partition=VALUE", run.stderr)
        target = self.root / "etc" / "config.toml"
        target.parent.mkdir()
        run = self.run_tool(["site", "install", "templates/site.toml", "--to", str(target),
                             "--set", "partition=gpu"])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("from template templates/site.toml", run.stdout + run.stderr)
        self.assertNotIn("{{", target.read_text())
        run = self.run_tool(["config", "--config", str(target)])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertRegex(run.stdout, r"storage\.node_local_root\s+/local\s+\[site ")
        self.assertRegex(run.stdout, r"build\.allocation_hint\s+salloc -p gpu -n 16\s+\[site ")

    def test_template_file_refusals(self):
        template = self.root / "site.toml"
        template.write_text('[storage]\nnode_local_root = "/local"\n')
        template.chmod(0o664)
        target = self.root / "config.toml"
        cases = [
            (["site", "show", "./missing.toml"], "cannot open ./missing.toml"),
            (["site", "install", "./site.toml", "--to", str(target)], "writable by group or others"),
            (["site", "show", "site.toml"], "a template file is named with a slash, as ./site.toml"),
        ]
        for argv, needle in cases:
            with self.subTest(argv=argv):
                run = self.run_tool(argv)
                self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
                self.assertIn(needle, run.stderr)
                self.assertFalse(target.exists())

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
        carried = exported(first.stdout)
        second = self.run_tool(["config", "--env"], **carried)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(second.stdout, first.stdout)
        shown = self.run_tool(["config"], **carried)
        self.assertRegex(shown.stdout, r"TOKEN\s+nimvault:tokens/mirror\s+\[environment EB_LOCAL_SECRET_TOKEN\]")

    def test_config_env_carries_empty_values_and_selects_no_profile(self):
        # A job that sources the lines still has the files: neither the
        # default profile nor a value the chosen profile cleared may come back
        # beneath the variables.
        user = self.home / ".config" / "eb-local" / "config.toml"
        user.parent.mkdir(parents=True)
        user.write_text('default_profile = "mine"\n'
                        'build.allocation_hint = "salloc -p cpu"\n'
                        '[profile.mine]\ndev.modules = ["FFTW/3.3.10-GCC-15.2.0"]\n'
                        '[profile.mine.secrets]\nMINE_TOKEN = "env:MY_TOKEN"\n'
                        '[profile.bare]\nbuild.allocation_hint = ""\n')
        user.chmod(0o600)
        self.env["EB_LOCAL_CONFIG"] = ""
        first = self.run_tool(["--profile", "bare", "config", "--env"])
        self.assertEqual(first.returncode, 0, first.stderr)
        for line in ("EB_LOCAL_PROFILE=''", "EB_LOCAL_DEV_MODULES=''", "EB_LOCAL_BUILD_ALLOCATION_HINT=''"):
            self.assertIn(f"export {line}\n", first.stdout)
        carried = exported(first.stdout)
        second = self.run_tool(["config", "--env"], **carried)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(exported(second.stdout), carried)
        shown = self.run_tool(["config"], **carried)
        self.assertRegex(shown.stdout, r"build\.allocation_hint\s+\(none\)\s+\[environment EB_LOCAL_BUILD_ALLOCATION_HINT\]")
        self.assertNotIn("MINE_TOKEN", shown.stdout)
        dev = self.run_tool(["dev"], **carried)
        self.assertEqual(dev.returncode, 0, dev.stderr)
        self.assertNotIn("FFTW", dev.stdout)

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
