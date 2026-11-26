#!/usr/bin/env python3
"""Black-box CLI behavior tests for default recipe build refusals, `--explain`, `help`, and `--version`."""
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary


@unittest.skipUnless(binary.ZIG, "build and --explain modes are features of the Zig build")
class BuildCliModes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-build-modes-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.prefix = self.root / "prefix"
        self.site = self.root / "site.toml"
        self.site.write_text(
            '[storage]\nnode_local_root = "/local"\n'
            '[build]\nallocation_hint = "salloc --nodes=1"\n'
            'secrets = ["KEEP"]\n'
            '[build.node_types]\nmilan = "--constraint=milan"\n'
            '[secrets]\nKEEP = "env:KEEP_VAL"\nDROP = "env:DROP_VAL"\n',
            encoding="utf-8",
        )
        self.site.chmod(0o600)

    def run_cli(self, args, **env_overrides):
        env = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(self.root),
            "EB_LOCAL_CONFIG": str(self.site),
            "EB_LOCAL_PREFIX": str(self.prefix),
        }
        env.pop("SLURM_JOB_ID", None)
        env.update(env_overrides)
        return subprocess.run(
            [binary.ZIG, *args],
            env=env,
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def test_help_and_version_exit_zero_and_missing_operands_exit_two(self):
        for help_args in (["help"], ["-h"], ["--help"]):
            with self.subTest(help_args=help_args):
                got = self.run_cli(help_args)
                self.assertEqual(got.returncode, 0, got.stderr)
                self.assertEqual(got.stderr, "")
                self.assertIn("eb-local <easyconfig>", got.stdout)

        ver = self.run_cli(["--version"])
        self.assertEqual(ver.returncode, 0, ver.stderr)
        self.assertEqual(ver.stderr, "")
        self.assertTrue(ver.stdout.startswith("eb-local "))

        for bad_args in ([], ["--explain"]):
            with self.subTest(bad_args=bad_args):
                got = self.run_cli(bad_args)
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")
                self.assertIn("eb-local <easyconfig>", got.stderr)

        for opt in ("--profile", "--project", "--config"):
            with self.subTest(opt=opt):
                got = self.run_cli([opt])
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")

        missing_cfg = self.run_cli(["--config", str(self.root / "no-such.toml"), "zlib.eb"])
        self.assertEqual(missing_cfg.returncode, 2, missing_cfg.stdout + missing_cfg.stderr)

    def test_recipe_outside_slurm_job_exits_two_and_prints_sbatch_hints(self):
        got = self.run_cli(["zlib.eb", "--robot"], SLURM_CLUSTER_NAME="cluster")
        self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
        self.assertEqual(got.stdout, "")
        self.assertIn("SLURM_JOB_ID is unset or empty", got.stderr)
        self.assertIn("salloc --nodes=1", got.stderr)
        self.assertIn("sbatch --constraint=milan", got.stderr)
        self.assertFalse(self.prefix.exists())

    def test_explain_recipe_prints_plan_and_secrets_policy_without_creating_prefix(self):
        got = self.run_cli(["--explain", "zlib.eb", "--robot"])
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertIn("# eb-local --explain:", got.stdout)
        self.assertIn("sbatch --constraint=milan", got.stdout)
        self.assertIn("KEEP reaches eb's environment from env:KEEP_VAL", got.stdout)
        self.assertIn("DROP stays out of eb's environment", got.stdout)
        self.assertIn("exec eb", got.stdout)
        self.assertFalse(self.prefix.exists())


if __name__ == "__main__":
    unittest.main()
