#!/usr/bin/env python3
"""Verify that replaying `eb-local --explain eb` in a clean shell matches `eb-local eb`."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_storage import StorageFixture

INIT = r'''
export EESSI_VERSION=2026.06
export EESSI_SOFTWARE_PATH="$EESSI_CVMFS_REPO/versions/2026.06/software/linux/x86_64/amd/zen4"
export EESSI_SITE_SOFTWARE_PATH="$EESSI_CVMFS_REPO/host_injections/2026.06/software/linux/x86_64/amd/zen4"
module() {
    if [ "$1" = load ]; then
        export EASYBUILD_PREFIX="${WORKING_DIR:-/tmp/$USER}/easybuild"
        if [ -n "${EESSI_CVMFS_INSTALL+set}" ]; then
            installpath=$EESSI_SOFTWARE_PATH
        elif [ -n "${EESSI_SITE_INSTALL+set}" ]; then
            installpath=$EESSI_SITE_SOFTWARE_PATH
        else
            installpath="${EESSI_USER_INSTALL:-${EESSI_PROJECT_INSTALL:-$HOME/eessi}}/versions/2026.06/software/linux/x86_64/amd/zen4"
        fi
        export EASYBUILD_INSTALLPATH="${CONTROL_INSTALLPATH:-$installpath}"
        return 0
    fi
    return 99
}
'''

EB_CAPTURE = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

mask = os.umask(0)
os.umask(mask)
keys = (
    "EESSI_USER_INSTALL",
    "EESSI_PROJECT_INSTALL",
    "EESSI_SITE_INSTALL",
    "EESSI_CVMFS_INSTALL",
    "EESSI_CUSTOM_SITE_OPT",
    "EESSI_SITE_TOP_LEVEL_TOOLCHAINS_2026_06",
    "EASYBUILD_SOURCEPATH",
    "EASYBUILD_INSTALLPATH",
    "EBLOCAL_EB_SOURCEPATH",
    "EBLOCAL_EB_SITE_TOOLCHAINS",
)
payload = {
    "argv": sys.argv[1:],
    "umask": mask,
    "env": {name: os.environ.get(name) for name in keys},
}
Path(os.environ["CONTROL_ROOT"]).joinpath("eb.json").write_text(
    json.dumps(payload, sort_keys=True),
    encoding="utf-8",
)
'''


class ExplainEbReplayCli(StorageFixture):
    def setUp(self):
        super().setUp()
        self.work_tmp = tempfile.TemporaryDirectory(
            prefix=f"eb-local-explain-eb-replay-{os.getpid()}-"
        )
        self.addCleanup(self.work_tmp.cleanup)
        self.work = Path(self.work_tmp.name).resolve()
        self.home = self.work / "home"
        self.home.mkdir()
        self.prefix = self.work / "durable" / "owned prefix"
        self.config = self.work / "site.toml"
        self.config.write_text(
            f'prefix = "{self.prefix}"\n'
            "[build]\n"
            'site_toolchains = ["intel/2026.1"]\n'
            "[eessi]\n"
            'EESSI_CUSTOM_SITE_OPT = "configured"\n',
            encoding="utf-8",
        )
        self.config.chmod(0o600)

        init = self.work / "repo" / "versions" / "2026.06" / "init" / "lmod" / "bash"
        init.parent.mkdir(parents=True)
        init.write_text(INIT, encoding="utf-8")

        self.bin_dir = self.work / "bin"
        self.bin_dir.mkdir()
        eb_double = self.bin_dir / "eb"
        eb_double.write_text(EB_CAPTURE, encoding="utf-8")
        eb_double.chmod(0o755)

        # Replace StorageFixture's default environment with a clean minimal
        # environment so host EasyBuild/EESSI variables, BASH_ENV, and
        # EB_LOCAL_PREFIX do not leak into `eb-local` or the replayed shell.
        self.env = {
            "PATH": f"{self.bin_dir}:{Path(sys.executable).parent}:/usr/bin:/bin",
            "HOME": str(self.home),
            "USER": "alice",
            "EESSI_CVMFS_REPO": str(self.work / "repo"),
            "CONTROL_ROOT": str(self.work),
            "EB_LOCAL_CONFIG": str(self.config),
        }

    def replay_shell(self):
        # `--explain eb` prints the Bash launcher script (using Bash-only
        # associative arrays and indirect expansion); resolve bash on PATH
        # instead of hard-coding `/bin/bash`.
        shell = shutil.which("bash")
        self.assertIsNotNone(shell, "bash is not installed")
        return shell

    def replay_in_clean_shell(self, shell, script, **overrides):
        command = [
            shell,
            *(["--noprofile", "--norc"] if Path(shell).name == "bash" else ["-f"]),
            "-c",
            script,
        ]
        return subprocess.run(
            command,
            env=dict(self.env, **overrides),
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def run_and_compare(self, explain_args, eb_args, cleanup_paths=(), **overrides):
        marker = self.work / "eb.json"
        if marker.exists():
            marker.unlink()

        explained = self.run_wrapper(explain_args, **overrides)
        self.assertEqual(explained.returncode, 0, explained.stdout + explained.stderr)
        self.assertFalse(marker.exists(), "--explain eb must not run eb")
        for path in cleanup_paths:
            self.assertFalse(path.exists(), f"--explain eb must not create {path}")

        replay = self.replay_in_clean_shell(
            self.replay_shell(),
            explained.stdout,
            **overrides,
        )
        self.assertEqual(replay.returncode, 0, replay.stdout + replay.stderr)
        self.assertTrue(marker.exists(), "replayed script did not invoke eb")
        replay_got = json.loads(marker.read_text(encoding="utf-8"))

        marker.unlink()
        for path in cleanup_paths:
            if path.exists():
                shutil.rmtree(path)

        real = self.run_wrapper(eb_args, **overrides)
        self.assertEqual(real.returncode, 0, real.stdout + real.stderr)
        self.assertTrue(marker.exists(), "eb-local eb did not invoke eb")
        real_got = json.loads(marker.read_text(encoding="utf-8"))

        self.assertEqual(replay_got, real_got)
        return explained.stdout, replay_got

    def test_configured_user_prefix_explain_replay_matches_eb(self):
        _, got = self.run_and_compare(
            ["--explain", "eb", "--", "my recipe.eb", "--robot"],
            ["eb", "--", "my recipe.eb", "--robot"],
            cleanup_paths=(self.prefix,),
        )
        self.assertEqual(got["argv"], ["my recipe.eb", "--robot"])
        self.assertEqual(got["umask"], 0o077)
        self.assertEqual(got["env"]["EESSI_USER_INSTALL"], str(self.prefix))
        self.assertIsNone(got["env"]["EESSI_PROJECT_INSTALL"])
        self.assertEqual(got["env"]["EESSI_CUSTOM_SITE_OPT"], "configured")
        self.assertEqual(
            got["env"]["EESSI_SITE_TOP_LEVEL_TOOLCHAINS_2026_06"],
            '[{"name": "intel", "version": "2026.1"}]',
        )
        self.assertEqual(
            got["env"]["EASYBUILD_SOURCEPATH"],
            str(self.prefix / ".eb-local" / "sources"),
        )
        self.assertIsNone(got["env"]["EBLOCAL_EB_SOURCEPATH"])
        self.assertIsNone(got["env"]["EBLOCAL_EB_SITE_TOOLCHAINS"])

    def test_configured_project_and_flag_explain_replay_match_eb(self):
        project = self.work / "project team"
        project.mkdir()
        project.chmod(0o2770)

        _, got = self.run_and_compare(
            ["--explain", "--project", str(project), "eb", "--", "recipe.eb"],
            ["--project", str(project), "eb", "--", "recipe.eb"],
        )
        self.assertEqual(got["umask"], 0o002)
        self.assertIsNone(got["env"]["EESSI_USER_INSTALL"])
        self.assertEqual(got["env"]["EESSI_PROJECT_INSTALL"], str(project))
        self.assertEqual(got["env"]["EESSI_CUSTOM_SITE_OPT"], "configured")
        self.assertEqual(
            got["env"]["EESSI_SITE_TOP_LEVEL_TOOLCHAINS_2026_06"],
            '[{"name": "intel", "version": "2026.1"}]',
        )
        self.assertEqual(
            got["env"]["EASYBUILD_SOURCEPATH"],
            str(project / ".eb-local" / "sources"),
        )

        self.config.write_text(
            self.config.read_text(encoding="utf-8").replace(
                f'prefix = "{self.prefix}"',
                f'project = "{project}"',
            ),
            encoding="utf-8",
        )
        _, from_config = self.run_and_compare(
            ["--explain", "eb", "--", "recipe.eb"],
            ["eb", "--", "recipe.eb"],
        )
        self.assertEqual(from_config["env"]["EESSI_PROJECT_INSTALL"], str(project))
        self.assertIsNone(from_config["env"]["EESSI_USER_INSTALL"])

    def test_profile_and_config_explain_replay_match_eb(self):
        profile_prefix = self.work / "profile prefix"
        with self.config.open("a", encoding="utf-8") as handle:
            handle.write(f'\n[profile.alt]\nprefix = "{profile_prefix}"\n')

        _, got = self.run_and_compare(
            ["--explain", "--profile", "alt", "eb", "--", "recipe.eb"],
            ["--profile", "alt", "eb", "--", "recipe.eb"],
            cleanup_paths=(profile_prefix,),
        )
        self.assertEqual(got["env"]["EESSI_USER_INSTALL"], str(profile_prefix))
        self.assertEqual(
            got["env"]["EASYBUILD_SOURCEPATH"],
            str(profile_prefix / ".eb-local" / "sources"),
        )

        other = self.work / "other.toml"
        config_prefix = self.work / "config prefix"
        other.write_text(
            f'prefix = "{config_prefix}"\n'
            "[eessi]\n"
            'EESSI_CUSTOM_SITE_OPT = "from-other"\n',
            encoding="utf-8",
        )
        other.chmod(0o600)
        _, got_other = self.run_and_compare(
            ["--explain", "--config", str(other), "eb", "--", "recipe.eb"],
            ["--config", str(other), "eb", "--", "recipe.eb"],
            cleanup_paths=(config_prefix,),
            EB_LOCAL_CONFIG="",
        )
        self.assertEqual(got_other["env"]["EESSI_USER_INSTALL"], str(config_prefix))
        self.assertEqual(got_other["env"]["EESSI_CUSTOM_SITE_OPT"], "from-other")
        self.assertEqual(
            got_other["env"]["EASYBUILD_SOURCEPATH"],
            str(config_prefix / ".eb-local" / "sources"),
        )

    def test_caller_overrides_preserved_when_replaying_explain_eb(self):
        chosen = self.work / "chosen"
        sources = self.work / "chosen-sources"
        _, got = self.run_and_compare(
            ["--explain", "eb", "--", "recipe.eb"],
            ["eb", "--", "recipe.eb"],
            cleanup_paths=(chosen,),
            EESSI_USER_INSTALL=str(chosen),
            EESSI_CUSTOM_SITE_OPT="shell",
            EESSI_SITE_TOP_LEVEL_TOOLCHAINS_2026_06="shell-toolchains",
            EASYBUILD_SOURCEPATH=str(sources),
        )
        self.assertEqual(got["env"]["EESSI_USER_INSTALL"], str(chosen))
        self.assertEqual(got["env"]["EESSI_CUSTOM_SITE_OPT"], "shell")
        self.assertEqual(
            got["env"]["EESSI_SITE_TOP_LEVEL_TOOLCHAINS_2026_06"],
            "shell-toolchains",
        )
        self.assertEqual(got["env"]["EASYBUILD_SOURCEPATH"], str(sources))

        chosen_derived = self.work / "chosen-derived"
        _, derived = self.run_and_compare(
            ["--explain", "eb", "--", "recipe.eb"],
            ["eb", "--", "recipe.eb"],
            cleanup_paths=(chosen_derived,),
            EESSI_USER_INSTALL=str(chosen_derived),
        )
        self.assertEqual(derived["env"]["EESSI_USER_INSTALL"], str(chosen_derived))
        self.assertEqual(
            derived["env"]["EASYBUILD_SOURCEPATH"],
            str(chosen_derived / ".eb-local" / "sources"),
        )
        self.assertEqual(derived["env"]["EESSI_CUSTOM_SITE_OPT"], "configured")
        self.assertEqual(
            derived["env"]["EESSI_SITE_TOP_LEVEL_TOOLCHAINS_2026_06"],
            '[{"name": "intel", "version": "2026.1"}]',
        )

    def test_site_and_cvmfs_install_explain_replay_matches_eb(self):
        for var in ("EESSI_SITE_INSTALL", "EESSI_CVMFS_INSTALL"):
            with self.subTest(var=var):
                _, got = self.run_and_compare(
                    ["--explain", "eb", "--", "recipe.eb"],
                    ["eb", "--", "recipe.eb"],
                    **{var: "1"},
                )
                self.assertEqual(got["umask"], 0o022)
                self.assertIsNone(got["env"]["EESSI_USER_INSTALL"])
                self.assertIsNone(got["env"]["EESSI_PROJECT_INSTALL"])
                self.assertEqual(got["env"][var], "1")
                self.assertIsNone(got["env"]["EASYBUILD_SOURCEPATH"])
                self.assertEqual(got["env"]["EESSI_CUSTOM_SITE_OPT"], "configured")
                self.assertEqual(
                    got["env"]["EESSI_SITE_TOP_LEVEL_TOOLCHAINS_2026_06"],
                    '[{"name": "intel", "version": "2026.1"}]',
                )

    def test_shell_metacharacters_in_eessi_settings_replay_safely(self):
        sentinel = self.work / "injected"
        tricky = f"a'b $(touch {sentinel}) `touch {sentinel}` ; $HOME"
        self.config.write_text(
            f'prefix = "{self.prefix}"\n'
            "[eessi]\n"
            f"EESSI_CUSTOM_SITE_OPT = {json.dumps(tricky)}\n",
            encoding="utf-8",
        )
        _, got = self.run_and_compare(
            ["--explain", "eb", "--", "recipe.eb"],
            ["eb", "--", "recipe.eb"],
            cleanup_paths=(self.prefix,),
        )
        self.assertEqual(got["env"]["EESSI_CUSTOM_SITE_OPT"], tricky)
        self.assertFalse(
            sentinel.exists(),
            "replaying --explain eb must not evaluate [eessi] values",
        )


if __name__ == "__main__":
    unittest.main()
