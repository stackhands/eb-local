#!/usr/bin/env python3
"""Site file templates, configuration carried in EB_LOCAL_* variables, and
how nimvault is run, through the command line of the Zig build, which
is the one EB_LOCAL_BIN names, or the one the shell shim runs.
"""
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import unittest

import binary
import hostile_fs
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


@unittest.skipUnless(binary.ZIG, "site templates and EB_LOCAL_SECRET_* are features of the Zig build")
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
        self.assertEqual([line.split()[0] for line in run.stdout.splitlines()], ["slurm", "workstation"])
        self.assertRegex(run.stdout, r"slurm\s+placeholders: node_local_root, node_local_mount, node_local_fstype, shared_scratch, partition")
        self.assertRegex(run.stdout, r"workstation\s+placeholders: prefix")

    def test_workstation_template_installs_local_mode_without_slurm_storage(self):
        target = self.root / "workstation.toml"
        run = self.run_tool(["site", "install", "workstation", "--to", str(target)])
        self.assertEqual(run.returncode, 0, run.stderr)
        text = target.read_text()
        self.assertIn('mode = "local"', text)
        self.assertNotIn("node_local_root", text)
        shown = self.run_tool(["config", "--config", str(target)])
        self.assertEqual(shown.returncode, 0, shown.stderr)
        self.assertRegex(shown.stdout, r"storage\.mode\s+local\s+\[site ")

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
            (["site", "install", "slurm", "--to", str(target)], "needs --set node_local_root=VALUE and --set shared_scratch=VALUE"),
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

    def test_unclosed_placeholder_in_template_is_refused(self):
        template = self.root / "bad-template.toml"
        template.write_text('[storage]\nnode_local_root = "/local"\n'
                            '[build]\nallocation_hint = "salloc -p {{partition"\n')
        template.chmod(0o644)
        target = self.root / "bad-config.toml"
        for argv in (["site", "show", "./bad-template.toml"], ["site", "install", "./bad-template.toml", "--to", str(target)]):
            with self.subTest(argv=argv):
                run = self.run_tool(argv)
                self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
                self.assertEqual(run.stdout, "")
                self.assertIn("unclosed placeholder", run.stderr)
                self.assertFalse(target.exists())

    def test_template_placeholder_errors_report_line_numbers(self):
        cases = {
            "unclosed.toml": ('[storage]\nnode_local_root = "/local"\n[build]\nallocation_hint = "salloc -p {{partition"\n', ":4: unclosed placeholder"),
            "badname.toml": ('[storage]\nnode_local_root = "/local"\n[build]\nallocation_hint = "salloc -p {{BAD}}"\n', ":4: invalid placeholder 'BAD'"),
            "baddefault.toml": ('[storage]\nnode_local_root = "/local"\n[build]\nallocation_hint = "salloc -p {{partition:}}"\n', ":4: invalid default for 'partition'"),
        }
        for name, (body, needle) in cases.items():
            with self.subTest(name=name):
                tmpl = self.root / name
                tmpl.write_text(body)
                tmpl.chmod(0o644)
                run = self.run_tool(["site", "show", f"./{name}"])
                self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
                self.assertEqual(run.stdout, "")
                self.assertIn(f"template ./{name}{needle}", run.stderr)

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
            "EB_LOCAL_SECRET_OPT": ("nimvault:--recipient", "EB_LOCAL_SECRET_OPT: a nimvault entry may not start with -"),
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

    def test_default_site_outputs_and_statuses_are_unchanged_raw_bytes(self):
        def run_raw(args):
            argv, env = binary.command(self.script, args, dict(self.env))
            return subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=False)

        listed = run_raw(["site", "list"])
        expected_list = (
            b"slurm        placeholders: node_local_root, node_local_mount, node_local_fstype, shared_scratch, partition\n"
            b"workstation  placeholders: prefix\n"
        )
        self.assertEqual((listed.returncode, listed.stdout, listed.stderr), (0, expected_list, b""))

        shown = run_raw(["site", "show", "slurm"] + PATHS)
        self.assertEqual((shown.returncode, shown.stderr), (0, b""))
        self.assertIn(b'node_local_root = "/local"\n', shown.stdout)

        target = self.root / "installed-raw.toml"
        installed = run_raw(["site", "install", "slurm", "--to", str(target)] + PATHS)
        expected_install = f"wrote {target} from template slurm; eb-local config shows what it sets\n".encode()
        self.assertEqual((installed.returncode, installed.stdout, installed.stderr), (0, expected_install, b""))

        ro_parent = self.root / "ro-parent"
        ro_parent.mkdir()
        ro_parent.chmod(0o555)
        try:
            ro_target = ro_parent / "site.toml"
            ro_err = self.run_tool(["site", "install", "slurm", "--to", str(ro_target)] + PATHS)
            self.assertEqual(ro_err.returncode, 2, ro_err.stdout + ro_err.stderr)
            self.assertIn(str(ro_target), ro_err.stderr)
            self.assertIn("[Errno 13] Permission denied", ro_err.stderr)
        finally:
            ro_parent.chmod(0o755)

    def test_site_check_validates_toml_and_conf_files_as_site_layer(self):
        staged = self.root / "staged-site.toml"
        staged.write_text(
            '[storage]\n'
            'node_local_root = "/local"\n'
            'shared_scratch = ["/scratch"]\n'
            '[build.node_types]\n'
            'cpu = "-p cpu -n 8"\n'
        )
        staged.chmod(0o644)
        ok = self.run_tool(["site", "check", str(staged)])
        self.assertEqual((ok.returncode, ok.stdout, ok.stderr), (0, f"site file {staged} is valid\n", ""))

        legacy = self.root / "staged-site.conf"
        legacy.write_text("node_local_root = /local\nshared_scratch = /scratch\n")
        legacy.chmod(0o644)
        ok_legacy = self.run_tool(["site", "check", str(legacy)])
        self.assertEqual(ok_legacy.returncode, 0, ok_legacy.stderr)

        bad_toml = self.root / "bad-site.toml"
        bad_toml.write_text('[storage]\nnode_local_root = "relative"\n')
        bad_toml.chmod(0o644)
        refused = self.run_tool(["site", "check", str(bad_toml)])
        self.assertEqual(refused.returncode, 2)
        self.assertIn("storage.node_local_root", refused.stderr)

        bad_mode = self.root / "open-site.toml"
        bad_mode.write_text('[storage]\nnode_local_root = "/local"\n')
        bad_mode.chmod(0o664)
        mode_err = self.run_tool(["site", "check", str(bad_mode)])
        self.assertEqual(mode_err.returncode, 2)
        self.assertIn("chmod go-w", mode_err.stderr)

        link = self.root / "link-site.toml"
        link.symlink_to(staged)
        link_err = self.run_tool(["site", "check", str(link)])
        self.assertEqual(link_err.returncode, 2)
        self.assertIn("symbolic link", link_err.stderr)

        json_err = self.run_tool(["site", "check", str(staged), "--json"])
        self.assertEqual(json_err.returncode, 2)
        self.assertIn("--json goes with site list", json_err.stderr)

        flag_err = self.run_tool(["site", "check", str(staged), "--force"])
        self.assertEqual(flag_err.returncode, 2)
        self.assertIn("site check takes only a configuration file", flag_err.stderr)

    def test_site_install_refuses_directory_target_with_helpful_message(self):
        target_dir = self.root / "site-dir"
        target_dir.mkdir()
        for extra in ([], ["--force"]):
            with self.subTest(extra=extra):
                got = self.run_tool(
                    [
                        "site",
                        "install",
                        "slurm",
                        "--set",
                        "node_local_root=/local",
                        "--set",
                        "shared_scratch=/scratch",
                        "--to",
                        str(target_dir),
                        *extra,
                    ]
                )
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertIn("is a directory", got.stderr)
                self.assertIn(f"{target_dir}/config.toml", got.stderr)
                self.assertTrue(target_dir.is_dir())

    def test_site_rejects_duplicate_to_flag(self):
        p1 = self.root / "site1.toml"
        p2 = self.root / "site2.toml"
        got = self.run_tool(
            [
                "site",
                "install",
                "slurm",
                "--set",
                "node_local_root=/local",
                "--set",
                "shared_scratch=/scratch",
                "--to",
                str(p1),
                "--to",
                str(p2),
            ]
        )
        self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
        self.assertEqual(got.stdout, "")
        self.assertIn("site takes one --to", got.stderr)
        self.assertFalse(p1.exists())
        self.assertFalse(p2.exists())

    def test_site_install_refuses_live_and_dangling_symlink_targets(self):
        real_target = self.root / "real.toml"
        real_target.write_text("keep\n", encoding="utf-8")
        live_link = self.root / "live-site.toml"
        live_link.symlink_to(real_target)
        dangling_link = self.root / "dangling-site.toml"
        dangling_link.symlink_to(self.root / "absent.toml")

        for link in (live_link, dangling_link):
            with self.subTest(link=link):
                got = self.run_tool(
                    [
                        "site",
                        "install",
                        "slurm",
                        "--set",
                        "node_local_root=/local",
                        "--set",
                        "shared_scratch=/scratch",
                        "--to",
                        str(link),
                    ]
                )
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertIn("is a symbolic link", got.stderr)
                self.assertEqual(real_target.read_text(encoding="utf-8"), "keep\n")

    def test_site_install_tmpfs_enospc_keeps_destination_clean(self):
        mnt = hostile_fs.enter_full_tmpfs(self)
        if mnt is None:
            return
        target = mnt / "config.toml"
        got = self.run_tool(["site", "install", "slurm", *PATHS, "--to", str(target)])
        self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
        self.assertEqual(got.stdout, "")
        self.assertIn("No space left on device", got.stderr)
        self.assertFalse(target.exists())
        self.assertEqual([p.name for p in mnt.iterdir()], ["fill"])

    def test_legacy_conf_rejects_bom_and_bad_comment_bytes(self):
        cases = {
            "bom.conf": (b"\xef\xbb\xbfnode_local_root = /local\n", "line 1: the file starts with a UTF-8 BOM"),
            "nul-comment.conf": (b"node_local_root = /local\n# bad \x00\n", "line 2: the file holds a NUL byte"),
            "bad-utf8-comment.conf": (b"node_local_root = /local\n# bad \xff\n", "line 2: the file is not UTF-8"),
        }
        for name, (payload, needle) in cases.items():
            with self.subTest(name=name):
                conf = self.root / name
                conf.write_bytes(payload)
                conf.chmod(0o644)
                got = self.run_tool(["site", "check", str(conf)])
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")
                self.assertIn(needle, got.stderr)


if __name__ == "__main__":
    unittest.main()
