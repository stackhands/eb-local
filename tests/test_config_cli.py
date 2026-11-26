#!/usr/bin/env python3
"""TOML configuration, profiles, EB_LOCAL_* overrides and secrets, through
the command line of the Zig build, so the tests run only when there is a
Zig build: the one EB_LOCAL_BIN names, or the one the shell shim runs.
"""
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import unittest

import binary
from test_storage import StorageFixture

SITE = '''
[storage]
node_local_root = "{nodes}"
node_local_fstype = "xfs"
shared_scratch = ["/scratch"]

[build]
allocation_hint = "salloc -p cpu -n 16"

[profile.gpu]
dev.modules = ["CUDA/13.3.0"]
'''

USER = '''
default_profile = "mine"

[profile.mine]
dev.modules = ["FFTW/3.3.10-GCC-15.2.0"]

[profile.licensed.secrets]
LM_LICENSE_FILE = "nimvault:licences/flexlm"

[secrets]
SOURCE_TOKEN = "file:{token}"
OTHER_TOKEN = "env:MY_OTHER"
'''

NIMVAULT = r'''#!/bin/sh
[ "$1" = get ] || exit 64
case "$2" in
  licences/flexlm) printf '27000@licence.example\n' ;;
  *) echo "no entry $2" >&2; exit 1 ;;
esac
'''

# An eb that records what it received and echoes its environment into the
# build log, as a careless easyblock might.
EB = r'''
eb() {
    python3 - "$@" <<'PY'
import json, os, sys
root = os.environ["CONTROL_ROOT"]
names = ["SOURCE_TOKEN", "OTHER_TOKEN", "LM_LICENSE_FILE"]
seen = {n: os.environ.get(n) for n in names}
site = {n: v for n, v in os.environ.items() if "TOP_LEVEL_TOOLCHAINS" in n or n == "EB_LOCAL_SITE_TOOLCHAINS"}
open(os.path.join(root, "eb.json"), "w").write(json.dumps({"argv": sys.argv[1:], "secrets": seen, "site": site, "eessi": os.environ.get("EESSI_IGNORE_LMOD_ERROR_ZEN4_GCC1220"), "MY_OTHER": os.environ.get("MY_OTHER")}))
log = os.path.join(os.environ["EASYBUILD_TMP_LOGDIR"], "easybuild-test.log")
open(log, "w").write("".join(f"{n}={v}\n" for n, v in seen.items()))
PY
}
export -f eb
'''


@unittest.skipUnless(binary.ZIG, "configuration files and secrets are features of the Zig build")
class ConfigCli(StorageFixture):
    def setUp(self):
        super().setUp()
        self.home = self.root / "home"
        (self.home / ".config" / "eb-local").mkdir(parents=True)
        self.token = self.home / "token"
        self.token.write_text("file-secret-value\n")
        self.token.chmod(0o600)
        self.site = self.root / "site.toml"
        self.site.write_text(SITE.format(nodes=self.nodes))
        self.site.chmod(0o644)
        self.user = self.home / ".config" / "eb-local" / "config.toml"
        self.user.write_text(USER.format(token=self.token))
        self.user.chmod(0o600)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "nimvault").write_text(NIMVAULT)
        (self.bin / "nimvault").chmod(0o755)
        self.env.update(EB_LOCAL_CONFIG="", HOME=str(self.home), MY_OTHER="env-secret-value",
                        PATH=f"{self.bin}:{os.environ['PATH']}")
        self.env.pop("XDG_CONFIG_HOME", None)
        with open(self.root / "doubles.sh", "a") as handle:
            handle.write(EB)

    def run_tool(self, args, **extra):
        # The site file is named with --config; the user file is found
        # through HOME.
        argv, env = binary.command(self.script, args, dict(self.env, **extra))
        return subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)

    def test_config_shows_each_value_and_where_it_came_from(self):
        run = self.run_tool(["config"])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("profile                      mine", run.stdout)
        self.assertRegex(run.stdout, r"dev\.modules\s+FFTW/3\.3\.10-GCC-15\.2\.0\s+\[user profile mine, .*config\.toml:5\]")
        self.assertIn("SOURCE_TOKEN", run.stdout)
        self.assertNotIn("file-secret-value", run.stdout + run.stderr)

    def test_config_shows_every_setting_when_the_project_directory_cannot_be_used(self):
        # config is where a profile's user finds out that its project
        # directory is missing or unsafe, so it shows everything and warns;
        # --check counts it as a failure, and the other commands still stop.
        project = self.root / "projects" / "eessi"
        with open(self.user, "a") as handle:
            handle.write(f'\n[profile.group]\nproject = "{project}"\n')
        project.parent.mkdir()
        cases = {
            "does not exist": lambda: None,
            "is not a directory": lambda: project.write_text(""),
            "is writable by others": lambda: (project.mkdir(), project.chmod(0o2777)),
        }
        for needle, make in cases.items():
            if project.is_dir():
                project.rmdir()
            elif project.exists():
                project.unlink()
            make()
            with self.subTest(needle):
                run = self.run_tool(["config", "--profile", "group"])
                self.assertEqual(run.returncode, 0, run.stderr)
                row = next(line for line in run.stdout.splitlines() if line.startswith("project "))
                self.assertIn(str(project), row)
                self.assertIn("storage.shared_scratch", run.stdout)
                self.assertIn("OTHER_TOKEN", run.stdout)
                self.assertIn(f"project directory {project} {needle}", run.stderr)
                check = self.run_tool(["config", "--check", "--profile", "group"])
                self.assertEqual(check.returncode, 1, check.stdout + check.stderr)
                self.assertEqual(check.stdout.count("   ok"), 2, check.stdout)
                self.assertIn(needle, check.stderr)
                run = self.run_tool(["env", "--profile", "group"])
                self.assertEqual(run.returncode, 2, run.stdout)
                self.assertEqual(run.stdout, "")

    def test_config_check_reads_secrets_without_showing_them(self):
        run = self.run_tool(["config", "--check", "--profile", "licensed"])
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(run.stdout.count("   ok"), 3, run.stdout)
        for value in ("file-secret-value", "env-secret-value", "27000@licence.example"):
            self.assertNotIn(value, run.stdout + run.stderr)
        self.token.chmod(0o644)
        run = self.run_tool(["config", "--check"])
        self.assertEqual(run.returncode, 1)
        self.assertIn("chmod 600", run.stdout)

    def test_config_env_prints_the_canonical_prefix(self):
        run = self.run_tool(["config", "--env"], EB_LOCAL_PREFIX="rel-prefix")
        self.assertEqual(run.returncode, 0, run.stderr)
        absolute = str(self.root / "rel-prefix")
        self.assertIn(f"export EB_LOCAL_PREFIX={shlex.quote(absolute)}", run.stdout)
        self.assertNotIn("EB_LOCAL_PREFIX=rel-prefix", run.stdout)
        link = self.root / "prefix-link"
        self.prefix.mkdir(parents=True)
        link.symlink_to(self.prefix)
        run = self.run_tool(["config", "--env"], EB_LOCAL_PREFIX=str(link))
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn(f"export EB_LOCAL_PREFIX={shlex.quote(str(self.prefix))}", run.stdout)
        self.assertNotIn("prefix-link", run.stdout)
        run = self.run_tool(["config", "--env"], EB_LOCAL_PREFIX="~/from-home")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn(f"export EB_LOCAL_PREFIX={shlex.quote(str(self.home / 'from-home'))}", run.stdout)
        self.assertNotIn("~", run.stdout)

    def test_the_environment_and_options_win(self):
        run = self.run_tool(["dev"], EB_LOCAL_DEV_MODULES="GSL/2.8-GCC-15.2.0", SLURM_JOB_ID="")
        self.assertIn("module load GSL/2.8-GCC-15.2.0\n", run.stdout)
        run = self.run_tool(["dev", "--profile", "mine", "--buildenv", "buildenv/mine"], SLURM_JOB_ID="")
        self.assertIn("module load FFTW/3.3.10-GCC-15.2.0\n", run.stdout)
        self.assertIn("\nmodule load buildenv/mine\n", run.stdout)

    def test_dev_loads_a_module_the_profile_and_the_command_line_both_name_once(self):
        run = self.run_tool(["dev", "GSL/2.8-GCC-15.2.0", "FFTW/3.3.10-GCC-15.2.0"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("module load FFTW/3.3.10-GCC-15.2.0 GSL/2.8-GCC-15.2.0\n", run.stdout)
        self.assertEqual(run.stdout.count("FFTW/3.3.10-GCC-15.2.0"), 1, run.stdout)

    def test_global_options_may_come_before_the_command(self):
        # The command reference's form, eb-local --profile NAME dev, with the user file's profile.
        before = self.run_tool(["--profile", "licensed", "dev"], SLURM_JOB_ID="")
        after = self.run_tool(["dev", "--profile", "licensed"], SLURM_JOB_ID="")
        self.assertEqual(before.returncode, 0, before.stderr)
        self.assertNotIn("FFTW", before.stdout)
        self.assertEqual(before.stdout, after.stdout)
        run = self.run_tool(["--config", str(self.site), "config"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("storage.node_local_root", run.stdout)
        run = self.run_tool(["--profile", "mine", "env", "extra"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 2)
        self.assertIn("env takes only", run.stderr)

    def test_a_named_file_replaces_only_its_own_layer(self):
        # --config FILE, or EB_LOCAL_CONFIG=FILE without it, is read in place
        # of the site file when root or the program's owner owns it (the
        # caller owns the program here), and in place of the user file when
        # only the caller does; the other file is still read.
        for how, extra in ((["--config", str(self.site)], {}), ([], {"EB_LOCAL_CONFIG": str(self.site)})):
            with self.subTest(how=how or extra):
                run = self.run_tool(how + ["config"], SLURM_JOB_ID="", **extra)
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertRegex(run.stdout, r"storage\.node_local_root\s+\S+\s+\[site .*site\.toml:")
                self.assertIn("profile                      mine", run.stdout)
                self.assertRegex(run.stdout, r"dev\.modules\s+FFTW/3\.3\.10-GCC-15\.2\.0\s+\[user profile mine, ")
        mine = self.root / "mine.toml"
        mine.write_text('dev.modules = ["GSL/2.8-GCC-15.2.0"]\n')
        mine.chmod(0o600)
        run = self.run_tool(["--config", str(mine), "config"], SLURM_JOB_ID="",
                            EB_LOCAL_TEST_SELF_OWNER=str(os.getuid() + 1))
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("profile                      (none)", run.stdout)
        self.assertRegex(run.stdout, r"dev\.modules\s+GSL/2\.8-GCC-15\.2\.0\s+\[user .*mine\.toml:1\]")

    def test_an_option_takes_its_value_after_an_equals_sign_as_after_a_space(self):
        # --config=FILE was a word of a build's: eb got it, the file went
        # unread, and env refused it while naming --config as its own.
        named = "--config=" + str(self.site)
        for args in ([named, "config"], ["config", named]):
            with self.subTest(args=args):
                run = self.run_tool(args, SLURM_JOB_ID="")
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertRegex(run.stdout, r"storage\.node_local_root\s+\S+\s+\[site .*site\.toml:")
        run = self.run_tool(["env", named], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stderr)
        run = self.run_tool([named, "--explain", "recipe.eb"])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("\nset -- ", run.stdout)
        self.assertNotIn("--config=", run.stdout)
        # An empty --project= made the current directory the project.
        for args in (["--project=", "config"], ["--profile=", "config"], ["--config=", "config"],
                     ["dev", "--buildenv="], ["submit", "--on=", "recipe.eb"],
                     ["rpath-wrappers", "--for="], ["site", "list", "--set="],
                     ["site", "list", "--to="], ["clean", "--logs-older-than="]):
            with self.subTest(args=args):
                run = self.run_tool(args, SLURM_JOB_ID="")
                option = next(a for a in args if a.endswith("="))[:-1]
                self.assertEqual((run.returncode, run.stdout), (2, ""), run.stderr)
                self.assertEqual(run.stderr, f"eb-local: {option} needs a value\n")

    def test_subcommand_value_options_match_between_space_and_equals(self):
        # rpath-wrappers --for=FAMILY
        fake_cc_bin = self.root / "cc-bin"
        fake_cc_bin.mkdir()
        (fake_cc_bin / "gcc").write_text("#!/bin/sh\nexit 0\n")
        (fake_cc_bin / "gcc").chmod(0o755)
        rw_env = dict(self.env, PATH=f"{fake_cc_bin}:/usr/bin:/bin", XDG_CACHE_HOME=str(self.root / "xdg-cache"))
        argv_sp, env_sp = binary.command(self.script, ["rpath-wrappers", "--for", "llvm"], rw_env)
        argv_eq, env_eq = binary.command(self.script, ["rpath-wrappers", "--for=llvm"], rw_env)
        rw_sp = subprocess.run(argv_sp, env=env_sp, cwd=self.root, capture_output=True, text=False)
        rw_eq = subprocess.run(argv_eq, env=env_eq, cwd=self.root, capture_output=True, text=False)
        self.assertEqual(rw_sp.returncode, 0, rw_sp.stderr)
        self.assertEqual((rw_eq.returncode, rw_eq.stdout, rw_eq.stderr), (rw_sp.returncode, rw_sp.stdout, rw_sp.stderr))

        # site show/install --set=KEY=VALUE and --to=FILE
        argv_sp, env_sp = binary.command(
            self.script,
            ["site", "show", "slurm", "--set", "node_local_root=/local", "--set", "shared_scratch=/scratch"],
            dict(self.env),
        )
        argv_eq, env_eq = binary.command(
            self.script,
            ["site", "show", "slurm", "--set=node_local_root=/local", "--set=shared_scratch=/scratch"],
            dict(self.env),
        )
        sh_sp = subprocess.run(argv_sp, env=env_sp, cwd=self.root, capture_output=True, text=False)
        sh_eq = subprocess.run(argv_eq, env=env_eq, cwd=self.root, capture_output=True, text=False)
        self.assertEqual(sh_sp.returncode, 0, sh_sp.stderr)
        self.assertEqual((sh_eq.returncode, sh_eq.stdout, sh_eq.stderr), (sh_sp.returncode, sh_sp.stdout, sh_sp.stderr))

        dest_sp = self.root / "site-sp.toml"
        dest_eq = self.root / "site-eq.toml"
        ins_sp = self.run_tool(
            ["site", "install", "slurm", "--set", "node_local_root=/local", "--set", "shared_scratch=/scratch", "--to", str(dest_sp)]
        )
        ins_eq = self.run_tool(
            ["site", "install", "slurm", "--set=node_local_root=/local", "--set=shared_scratch=/scratch", f"--to={dest_eq}"]
        )
        self.assertEqual(ins_sp.returncode, 0, ins_sp.stderr)
        self.assertEqual(ins_eq.returncode, 0, ins_eq.stderr)
        self.assertEqual(dest_eq.read_bytes(), dest_sp.read_bytes())

        # clean --logs-older-than=DAYS
        argv_sp, env_sp = binary.command(self.script, ["clean", "--dry-run", "--logs-older-than", "5"], dict(self.env, SLURM_JOB_ID=""))
        argv_eq, env_eq = binary.command(self.script, ["clean", "--dry-run", "--logs-older-than=5"], dict(self.env, SLURM_JOB_ID=""))
        cl_sp = subprocess.run(argv_sp, env=env_sp, cwd=self.root, capture_output=True, text=False)
        cl_eq = subprocess.run(argv_eq, env=env_eq, cwd=self.root, capture_output=True, text=False)
        self.assertEqual(cl_sp.returncode, 0, cl_sp.stderr)
        self.assertEqual((cl_eq.returncode, cl_eq.stdout, cl_eq.stderr), (cl_sp.returncode, cl_sp.stdout, cl_sp.stderr))

    def test_profiles_lists_every_profile(self):
        run = self.run_tool(["profiles"])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("mine", run.stdout)
        self.assertIn("licensed", run.stdout)

    def test_default_profile_type_checked_when_overridden(self):
        self.user.write_text('default_profile = 123\n\n[profile.mine]\nprefix = "/tmp/p"\n')
        for args, extra_env in (
            (["config"], {}),
            (["--profile", "mine", "config"], {}),
            (["config"], {"EB_LOCAL_PROFILE": "mine"}),
            (["config"], {"EB_LOCAL_PROFILE": ""}),
        ):
            with self.subTest(args=args, extra_env=extra_env):
                got = self.run_tool(args, **extra_env)
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")
                self.assertIn("config.toml:1: default_profile must be a string, not an integer", got.stderr)

    def test_a_build_gets_its_secrets_and_its_log_does_not_keep_them(self):
        self.user.write_text(USER.format(token=self.token).replace(
            "[profile.licensed.secrets]", "[profile.licensed.secrets]"))
        # The storage settings come from the site layer: name it explicitly.
        self.site.write_text(SITE.format(nodes=self.nodes))
        argv, env = binary.command(self.script, ["--config", str(self.site), "--profile", "gpu", "recipe.eb"], dict(self.env))
        # SOURCE_TOKEN and OTHER_TOKEN come from the user file, LM_LICENSE_FILE
        # from the site file.
        with open(self.site, "a") as handle:
            handle.write('[secrets]\nLM_LICENSE_FILE = "nimvault:licences/flexlm"\n')
        run = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn('eval "$(eb-local --config ', run.stdout)
        self.assertIn("--profile gpu env)", run.stdout)
        seen = json.loads((self.root / "eb.json").read_text())["secrets"]
        self.assertEqual(seen, {"SOURCE_TOKEN": "file-secret-value", "OTHER_TOKEN": "env-secret-value",
                                "LM_LICENSE_FILE": "27000@licence.example"})
        log = self.prefix / ".eb-local" / "logs" / "easybuild-test.log"
        text = log.read_text()
        for value in seen.values():
            self.assertNotIn(value, text)
        self.assertIn("<secret SOURCE_TOKEN removed by eb-local>", text)
        self.assertIn("removed secret values from 1 log file(s)", run.stdout)
        self.assertIn("secret LM_LICENSE_FILE: the nimvault: source is deprecated and is removed in 4.0.0", run.stderr)
        self.assertNotIn("secret SOURCE_TOKEN: the nimvault", run.stderr)
        for value in seen.values():
            self.assertNotIn(value, run.stdout + run.stderr)

    def test_a_missing_secret_stops_the_build_before_anything_is_made(self):
        with open(self.site, "a") as handle:
            handle.write('[secrets]\nGONE = "env:NOT_SET_ANYWHERE"\n')
        run = self.run_tool(["--config", str(self.site), "recipe.eb"])
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn("NOT_SET_ANYWHERE is not set", run.stderr)
        self.assertEqual(list(self.job.iterdir()), [])
        self.assertFalse((self.root / "eb.json").exists())

    def test_a_build_gets_only_the_secrets_build_secrets_names(self):
        with open(self.user, "a") as handle:
            handle.write('\n[build]\nsecrets = ["SOURCE_TOKEN"]\n')
        # OTHER_TOKEN's source is not set, and a build that does not get it
        # does not read it.
        env = dict(self.env)
        del env["MY_OTHER"]
        argv, env = binary.command(self.script, ["--config", str(self.site), "recipe.eb"], env)
        run = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        seen = json.loads((self.root / "eb.json").read_text())["secrets"]
        self.assertEqual(seen, {"SOURCE_TOKEN": "file-secret-value", "OTHER_TOKEN": None, "LM_LICENSE_FILE": None})
        text = (self.prefix / ".eb-local" / "logs" / "easybuild-test.log").read_text()
        self.assertNotIn("file-secret-value", text)
        self.assertIn("<secret SOURCE_TOKEN removed by eb-local>", text)

        run = self.run_tool(["--config", str(self.site), "--profile", "licensed", "recipe.eb"],
                            EB_LOCAL_BUILD_SECRETS="OTHER_TOKEN LM_LICENSE_FILE")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        seen = json.loads((self.root / "eb.json").read_text())["secrets"]
        self.assertEqual(seen, {"SOURCE_TOKEN": None, "OTHER_TOKEN": "env-secret-value",
                                "LM_LICENSE_FILE": "27000@licence.example"})

        run = self.run_tool(["--config", str(self.site), "recipe.eb"], EB_LOCAL_BUILD_SECRETS="")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        received = json.loads((self.root / "eb.json").read_text())
        self.assertEqual(received["secrets"], {"SOURCE_TOKEN": None, "OTHER_TOKEN": None, "LM_LICENSE_FILE": None})
        self.assertNotIn("removed secret values", run.stdout)
        # Nor does OTHER_TOKEN's value arrive as MY_OTHER, its env: source,
        # where the logs would not be cleaned of it.
        self.assertIsNone(received["MY_OTHER"])

        run = self.run_tool(["--config", str(self.site), "recipe.eb"], EB_LOCAL_BUILD_SECRETS="LM_LICENSE_FILE")
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn("build.secrets [environment EB_LOCAL_BUILD_SECRETS] names LM_LICENSE_FILE, but no secret "
                      "LM_LICENSE_FILE is defined: add it to [secrets], or set EB_LOCAL_SECRET_LM_LICENSE_FILE=SOURCE",
                      run.stderr)

    def test_config_and_explain_say_which_secrets_a_build_gets(self):
        run = self.run_tool(["config"])
        self.assertRegex(run.stdout, r"build\.secrets\s+\(every secret\)\s+\[default\]")
        run = self.run_tool(["config", "--env"])
        self.assertNotIn("EB_LOCAL_BUILD_SECRETS", run.stdout)

        with open(self.user, "a") as handle:
            handle.write('\n[build]\nsecrets = ["SOURCE_TOKEN"]\n\n[profile.none]\nbuild.secrets = []\n')
        lines = self.user.read_text().splitlines()
        top = lines.index('secrets = ["SOURCE_TOKEN"]') + 1
        run = self.run_tool(["config"])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertRegex(run.stdout, rf"build\.secrets\s+SOURCE_TOKEN\s+\[user .*config\.toml:{top}\]")
        run = self.run_tool(["config", "--profile", "none"])
        self.assertRegex(run.stdout, rf"build\.secrets\s+\(none\)\s+\[user profile none, .*config\.toml:{len(lines)}\]")
        run = self.run_tool(["config", "--env", "--profile", "none"])
        self.assertIn("export EB_LOCAL_BUILD_SECRETS=''\n", run.stdout)
        run = self.run_tool(["config", "--env"])
        self.assertIn("export EB_LOCAL_BUILD_SECRETS=SOURCE_TOKEN\n", run.stdout)

        run = self.run_tool(["--config", str(self.site), "--explain", "recipe.eb"])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn(f"# SOURCE_TOKEN reaches eb's environment from file:{self.token}; logs are cleaned of it afterwards.\n",
                      run.stdout)
        self.assertIn(f"# OTHER_TOKEN stays out of eb's environment and is not read: build.secrets [user {self.user}:{top}] "
                      "does not name it. MY_OTHER, the variable it comes from, stays out too.\n", run.stdout)

    def test_site_toolchains_reach_the_eessi_hooks(self):
        text = self.site.read_text()
        self.assertIn('allocation_hint = "salloc -p cpu -n 16"\n', text)
        self.site.write_text(text.replace('allocation_hint = "salloc -p cpu -n 16"\n',
                                          'allocation_hint = "salloc -p cpu -n 16"\n'
                                          'site_toolchains = ["intel/2026.1", "nvidia-compilers/26.3"]\n'))
        # A value the caller exports is replaced by the site's.
        run = self.run_tool(["--config", str(self.site), "recipe.eb"],
                            EESSI_SITE_TOP_LEVEL_TOOLCHAINS_2026_06="[]", EB_LOCAL_SITE_TOOLCHAINS="[]")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        site = json.loads((self.root / "eb.json").read_text())["site"]
        self.assertEqual(site, {"EESSI_SITE_TOP_LEVEL_TOOLCHAINS_2026_06": json.dumps(
            [{"name": "intel", "version": "2026.1"}, {"name": "nvidia-compilers", "version": "26.3"}])})
        run = self.run_tool(["config", "--config", str(self.site)], SLURM_JOB_ID="")
        self.assertRegex(run.stdout, r"build\.site_toolchains\s+intel/2026\.1 nvidia-compilers/26\.3\s+\[site ")

    def test_without_site_toolchains_the_caller_keeps_its_own(self):
        run = self.run_tool(["--config", str(self.site), "recipe.eb"], EESSI_SITE_TOP_LEVEL_TOOLCHAINS_2026_06="[x]")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        site = json.loads((self.root / "eb.json").read_text())["site"]
        self.assertEqual(site, {"EESSI_SITE_TOP_LEVEL_TOOLCHAINS_2026_06": "[x]"})

    def test_eessi_settings_reach_the_build_and_the_printed_lines(self):
        text = self.site.read_text()
        self.site.write_text(text.replace('allocation_hint = "salloc -p cpu -n 16"\n',
                                          'allocation_hint = "salloc -p cpu -n 16"\n'
                                          'site_toolchains = ["intel/2026.1"]\n')
                             + "[eessi]\nEESSI_IGNORE_LMOD_ERROR_ZEN4_GCC1220 = '1 2'\n")
        run = self.run_tool(["--config", str(self.site), "recipe.eb"])
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(json.loads((self.root / "eb.json").read_text())["eessi"], "1 2")
        run = self.run_tool(["env", "--config", str(self.site)], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stderr)
        line = "export EESSI_IGNORE_LMOD_ERROR_ZEN4_GCC1220='1 2'\n"
        self.assertIn(line, run.stdout)
        self.assertLess(run.stdout.index(line), run.stdout.index("module load EESSI/2026.06"))
        # site_toolchains after the stack loads, under the version it set.
        replay = subprocess.run(["bash", "-c", 'module() { export EESSI_VERSION=2026.06; }\n' + run.stdout
                                 + 'printf %s "$EESSI_SITE_TOP_LEVEL_TOOLCHAINS_2026_06"'],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(replay.stdout, '[{"name": "intel", "version": "2026.1"}]', replay.stderr)
        run = self.run_tool(["config", "--config", str(self.site)])
        self.assertRegex(run.stdout, r"eessi\.EESSI_IGNORE_LMOD_ERROR_ZEN4_GCC1220\s+'1 2'\s+\[site .*site\.toml:\d+\]")
        run = self.run_tool(["config", "--env", "--config", str(self.site)])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("export EESSI_IGNORE_LMOD_ERROR_ZEN4_GCC1220='1 2'\n", run.stdout)

    def test_an_empty_eessi_override_is_exported(self):
        self.site.write_text(
            SITE.format(nodes=self.nodes)
            + "\n[eessi]\nEESSI_OVERRIDE_TOOLCHAIN_CHECK = \"1\"\n"
            + "[profile.cleared.eessi]\nEESSI_OVERRIDE_TOOLCHAIN_CHECK = \"\"\n"
        )
        run = self.run_tool(["config", "--env", "--config", str(self.site), "--profile", "cleared"])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("export EESSI_OVERRIDE_TOOLCHAIN_CHECK=''\n", run.stdout)
        self.assertNotIn("export EESSI_OVERRIDE_TOOLCHAIN_CHECK='1'\n", run.stdout)
        run = self.run_tool(["env", "--config", str(self.site), "--profile", "cleared"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("export EESSI_OVERRIDE_TOOLCHAIN_CHECK=''\n", run.stdout)

    def test_refusals(self):
        cases = {
            'TOKEN = "hunter2"\n': "never written",
            'colour = "blue"\n': "unknown key colour",
            '[storage]\nnode_local_root = "/tmp"\n': "site setting",
            '[secrets]\nLD_PRELOAD = "env:X"\n': "not a variable name",
            '[secrets]\nLICENCE = "nimvault:-x"\n': "config.toml:2: secret LICENCE: a nimvault entry may not start with -",
            '[secrets]\nTOKEN = "file:token"\n': "config.toml:2: secret TOKEN: file: takes an absolute path or one starting ~/",
            '[profile.p]\nstack.module = "EESSI;id"\n': "not a module name",
            '[build]\nsite_toolchains = ["intel/2026.1"]\n': "site setting",
            '[profile.p.build]\nsite_toolchains = ["intel/2026.1"]\n': "site setting",
            '[eessi]\nEESSI_USER_INSTALL = "/x"\n': "install and target",
        }
        for text, needle in cases.items():
            with self.subTest(text=text):
                body = text if not text.startswith("TOKEN") else "[secrets]\n" + text
                self.user.write_text(body)
                run = self.run_tool(["env"], SLURM_JOB_ID="")
                self.assertEqual(run.returncode, 2, run.stdout)
                self.assertEqual(run.stdout, "")
                self.assertIn(needle, run.stderr)
        self.user.write_text("")
        self.user.chmod(0o620)
        run = self.run_tool(["env"])
        self.assertEqual(run.returncode, 2)
        self.assertIn("writable by group or others", run.stderr)

    def test_default_config_bytes_unchanged(self):
        argv, env = binary.command(self.script, ["config", "--config", str(self.site)], dict(self.env))
        raw = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=False)
        self.assertEqual(raw.returncode, 0, raw.stderr)
        self.assertEqual(raw.stderr, b"")
        self.assertIn(b"profile                      mine\n", raw.stdout)
        self.assertIn(b"storage.node_local_fstype    xfs", raw.stdout)
        self.assertNotIn(b"file-secret-value", raw.stdout)

        argv_env, env_env = binary.command(self.script, ["config", "--env", "--config", str(self.site)], dict(self.env))
        raw_env = subprocess.run(argv_env, env=env_env, cwd=self.root, capture_output=True, text=False)
        self.assertEqual(raw_env.returncode, 0, raw_env.stderr)
        self.assertEqual(raw_env.stderr, b"")
        self.assertTrue(raw_env.stdout.startswith(b"# eb-local configuration;"))
        self.assertIn(b"export EB_LOCAL_PROFILE=''\n", raw_env.stdout)

    def test_config_get_prints_resolved_keys_and_enforces_modes(self):
        base_site = SITE.format(nodes=self.nodes).replace(
            'allocation_hint = "salloc -p cpu -n 16"\n',
            'allocation_hint = "salloc -p cpu -n 16"\n'
            'site_toolchains = ["intel/2026.1", "nvidia-compilers/26.3"]\n',
        )
        self.site.write_text(
            base_site
            + '[build.node_types]\ncpu = "-p cpu -n 16"\n'
            + '[dev.buildenv_for]\nllvm = "buildenv/site-llvm"\n'
            + '[doctor]\napproved_prefixes = ["/opt/site"]\nmpi_transports = ["ofi", "ucx"]\n'
            + '[eessi]\nEESSI_CVMFS_REPO = "/cvmfs/custom"\nEESSI_EMPTY = ""\n'
        )

        def get(key, *extra_args, **extra_env):
            return self.run_tool(["config", "--config", str(self.site), *extra_args, "--get", key], **extra_env)

        self.assertEqual((get("profile").returncode, get("profile").stdout), (0, "mine\n"))
        self.assertEqual((get("prefix").returncode, get("prefix").stdout), (0, f"{self.prefix}\n"))
        self.assertEqual((get("project").returncode, get("project").stdout), (1, ""))
        proj = self.root / "proj"
        proj.mkdir()
        self.assertEqual((get("project", "--project", str(proj)).returncode, get("project", "--project", str(proj)).stdout), (0, f"{proj}\n"))
        self.assertEqual((get("prefix", "--project", str(proj)).returncode, get("prefix", "--project", str(proj)).stdout), (1, ""))

        self.assertEqual((get("storage.node_local_root").returncode, get("storage.node_local_root").stdout), (0, f"{self.nodes}\n"))
        self.assertEqual((get("storage.node_local_mount").returncode, get("storage.node_local_mount").stdout), (0, "%u.%j\n"))
        self.assertEqual((get("storage.node_local_fstype").returncode, get("storage.node_local_fstype").stdout), (0, "xfs\n"))
        self.assertEqual((get("storage.shared_scratch").returncode, get("storage.shared_scratch").stdout), (0, "/scratch\n"))
        self.assertEqual((get("build.allocation_hint").returncode, get("build.allocation_hint").stdout), (0, "salloc -p cpu -n 16\n"))
        self.assertEqual((get("build.node_types.cpu").returncode, get("build.node_types.cpu").stdout), (0, "-p cpu -n 16\n"))
        self.assertEqual((get("build.node_types.gpu").returncode, get("build.node_types.gpu").stdout), (1, ""))
        self.assertEqual((get("build.clear_foreign_prefixes").returncode, get("build.clear_foreign_prefixes").stdout), (0, "false\n"))
        self.assertEqual((get("dev.buildenv_for.llvm").returncode, get("dev.buildenv_for.llvm").stdout), (0, "buildenv/site-llvm\n"))
        self.assertEqual((get("dev.buildenv_for.cuda").returncode, get("dev.buildenv_for.cuda").stdout), (0, "buildenv/default-foss-2026.1-CUDA-13.3.0\n"))
        self.assertEqual((get("dev.buildenv_for.intel").returncode, get("dev.buildenv_for.intel").stdout), (0, "buildenv/default-intel-2026.1\n"))
        self.assertEqual((get("dev.buildenv_for.nvhpc").returncode, get("dev.buildenv_for.nvhpc").stdout), (1, ""))
        self.assertEqual((get("doctor.cvmfs_parallel").returncode, get("doctor.cvmfs_parallel").stdout), (0, "0\n"))
        self.assertEqual((get("clean.trash").returncode, get("clean.trash").stdout), (0, "auto\n"))
        self.assertEqual((get("clean.logs_older_than_days").returncode, get("clean.logs_older_than_days").stdout), (0, "30\n"))
        self.assertEqual((get("eessi.EESSI_CVMFS_REPO").returncode, get("eessi.EESSI_CVMFS_REPO").stdout), (0, "/cvmfs/custom\n"))
        self.assertEqual((get("eessi.EESSI_EMPTY").returncode, get("eessi.EESSI_EMPTY").stdout), (1, ""))
        self.assertEqual((get("eessi.OTHER").returncode, get("eessi.OTHER").stdout), (1, ""))

        self.assertEqual((get("dev.modules").returncode, get("dev.modules").stdout), (0, "FFTW/3.3.10-GCC-15.2.0\n"))
        self.assertEqual((get("dev.modules", "--profile", "gpu").returncode, get("dev.modules", "--profile", "gpu").stdout), (0, "CUDA/13.3.0\n"))
        self.assertEqual((get("build.site_toolchains").returncode, get("build.site_toolchains").stdout), (0, "intel/2026.1\nnvidia-compilers/26.3\n"))
        self.assertEqual((get("doctor.approved_prefixes").returncode, get("doctor.approved_prefixes").stdout), (0, "/opt/site\n"))
        self.assertEqual((get("doctor.mpi_transports").returncode, get("doctor.mpi_transports").stdout), (0, "ofi\nucx\n"))
        self.assertEqual((get("build.secrets").returncode, get("build.secrets").stdout), (0, "SOURCE_TOKEN\nOTHER_TOKEN\n"))

        sec = self.run_tool(["config", "--config", str(self.site), "--get=secrets.SOURCE_TOKEN"])
        self.assertEqual(sec.returncode, 0, sec.stderr)
        self.assertEqual(sec.stdout, f"file:{self.token}\n")
        self.assertNotIn("file-secret-value", sec.stdout + sec.stderr)
        self.assertEqual((get("secrets.NO_SUCH").returncode, get("secrets.NO_SUCH").stdout), (1, ""))

        unknown = get("not.a.key")
        self.assertEqual(unknown.returncode, 2)
        self.assertIn("unknown configuration key 'not.a.key'", unknown.stderr)

        for conflict in (["--check"], ["--env"], ["--json"]):
            bad = self.run_tool(["config", "--config", str(self.site), *conflict, "--get", "prefix"])
            self.assertEqual(bad.returncode, 2, bad.stdout + bad.stderr)
            self.assertEqual(bad.stdout, "")

        dup = self.run_tool(["config", "--config", str(self.site), "--get", "prefix", "--get", "stack.module"])
        self.assertEqual(dup.returncode, 2, dup.stdout + dup.stderr)
        self.assertEqual(dup.stdout, "")
        self.assertIn("config takes one --get", dup.stderr)

    def test_config_get_rejects_malformed_dynamic_keys(self):
        for bad_key in (
            "build.node_types.",
            "build.node_types.bad!name",
            "build.node_types." + ("x" * 33),
            "secrets.",
            "secrets.1BAD",
            "secrets.PATH",
            "secrets.LD_PRELOAD",
            "secrets.a-b",
        ):
            with self.subTest(bad_key=bad_key):
                got = self.run_tool(["config", "--config", str(self.site), "--get", bad_key])
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")
                self.assertIn(f"unknown configuration key '{bad_key}'", got.stderr)


if __name__ == "__main__":
    unittest.main()
