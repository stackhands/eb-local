#!/usr/bin/env python3
"""Black-box CLI behavior tests for `eb-local env` and `--env`."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary


@unittest.skipUnless(binary.BIN, "env is a feature of the Zig build")
class EnvCliModes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-env-modes-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.prefix = self.root / "prefix"
        self.site = self.root / "site.toml"
        self.site.write_text(
            '[storage]\n'
            'node_local_root = "/local"\n'
            '[build]\n'
            'site_toolchains = ["intel/2026.1"]\n'
            '[eessi]\n'
            'EESSI_CUSTOM_SITE_OPT = "alpha"\n',
            encoding="utf-8",
        )
        self.site.chmod(0o600)
        self.module_sh = self.root / "module.sh"
        self.module_sh.write_text("module() { return 0; }\n")

    def run_env(self, args, **env_overrides):
        env = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(self.root),
            "EB_LOCAL_CONFIG": str(self.site),
            "EB_LOCAL_PREFIX": str(self.prefix),
        }
        env.update(env_overrides)
        env.setdefault("BASH_ENV", str(self.module_sh))
        return subprocess.run(
            [binary.BIN, *args],
            env=env,
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def test_json_is_the_change_the_lines_make_to_the_environment(self):
        got = self.run_env(
            ["env", "--json"],
            EESSI_SITE_INSTALL="1",
            EASYBUILD_PREFIX="/elsewhere",
            KEPT="as it was",
        )
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertEqual(got.stdout.count("\n"), 1, got.stdout)
        change = json.loads(got.stdout)
        self.assertEqual(change["schema_version"], 1)
        self.assertEqual(change["kind"], "env")
        names = [var["name"] for var in change["set"]]
        self.assertEqual(names, sorted(names))
        values = {var["name"]: var["value"] for var in change["set"]}
        # what the lines export, and nothing the caller already had with that value
        self.assertEqual(values["EESSI_USER_INSTALL"], str(self.prefix))
        self.assertEqual(values["EESSI_CUSTOM_SITE_OPT"], "alpha")
        self.assertNotIn("KEPT", values)
        self.assertNotIn("HOME", values)
        # what the lines unset
        self.assertIn("EESSI_SITE_INSTALL", change["unset"])
        self.assertIn("EASYBUILD_PREFIX", change["unset"])
        self.assertNotIn("KEPT", change["unset"])
        self.assertEqual(change["unset"], sorted(change["unset"]))
        # bash's own bookkeeping and exported functions are not part of the change
        for name in list(values) + change["unset"]:
            self.assertNotIn(name, ("_", "SHLVL", "PWD", "OLDPWD"))
            self.assertFalse(name.startswith("BASH_FUNC_"), name)
        # the lines themselves are not printed
        self.assertNotIn("module load", got.stdout)

    def test_global_env_flag_matches_env_subcommand(self):
        sub = self.run_env(["env"])
        flag = self.run_env(["--env"])
        self.assertEqual(sub.returncode, 0, sub.stderr)
        self.assertEqual((flag.returncode, flag.stdout, flag.stderr), (sub.returncode, sub.stdout, sub.stderr))

    def test_strict_env_var_and_prefix_existence_control_emitted_lines(self):
        absent_prefix = self.run_env(["env"])
        self.assertEqual(absent_prefix.returncode, 0, absent_prefix.stderr)
        self.assertNotIn("module load EESSI-extend", absent_prefix.stdout)
        self.assertIn("export EESSI_CUSTOM_SITE_OPT=alpha\n", absent_prefix.stdout)
        self.assertIn("EESSI_SITE_TOP_LEVEL_TOOLCHAINS_", absent_prefix.stdout)

        self.prefix.mkdir()
        with_prefix = self.run_env(["env"])
        self.assertEqual(with_prefix.returncode, 0, with_prefix.stderr)
        self.assertIn("module load EESSI-extend", with_prefix.stdout)

        strict_flag = self.run_env(["env", "--strict"])
        strict_env_1 = self.run_env(["env"], EB_LOCAL_ENV_STRICT="1")
        strict_env_0 = self.run_env(["env"], EB_LOCAL_ENV_STRICT="0")
        strict_env_false = self.run_env(["env"], EB_LOCAL_ENV_STRICT="false")
        self.assertEqual(strict_flag.stdout, strict_env_1.stdout)
        self.assertIn("mount EESSI with CVMFS", strict_flag.stdout)
        self.assertEqual(strict_env_0.stdout, with_prefix.stdout)
        self.assertEqual(strict_env_false.stdout, with_prefix.stdout)

    def test_extra_positional_arguments_to_env_exit_two(self):
        got = self.run_env(["env", "extra"])
        self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
        self.assertIn("env takes only", got.stderr)

    def test_strict_env_exits_two_when_eessi_init_path_is_a_directory(self):
        repo = self.root / "repo"
        init_dir = repo / "versions" / "2026.06" / "init" / "lmod" / "bash"
        init_dir.mkdir(parents=True)
        got = self.run_env(["env", "--strict"], EESSI_CVMFS_REPO=str(repo))
        self.assertEqual(got.returncode, 0, got.stderr)
        proc = subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", "-c", got.stdout],
            env={
                "PATH": "/usr/bin:/bin",
                "HOME": str(self.root),
                "EESSI_CVMFS_REPO": str(repo),
                "LMOD_PKG": str(self.root / "no-lmod"),
            },
            cwd=self.root,
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        self.assertIn("CVMFS", proc.stderr)


if __name__ == "__main__":
    unittest.main()
