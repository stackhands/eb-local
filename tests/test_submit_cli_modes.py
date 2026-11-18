#!/usr/bin/env python3
"""Black-box CLI behavior tests for `eb-local submit` modes and partial failures."""
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary


@unittest.skipUnless(binary.BIN, "submit is a feature of the Zig build")
class SubmitCliModes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-submit-modes-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.prefix = self.root / "prefix"
        self.site = self.root / "site.toml"
        self.site.write_text(
            '[storage]\n'
            'node_local_root = "/local"\n'
            '[build.node_types]\n'
            'cpu = "-p cpu -n 4"\n'
            'gpu = "-p gpu -n 8"\n',
            encoding="utf-8",
        )
        self.site.chmod(0o600)

    def run_submit(self, args, site_path=None, path="/usr/bin:/bin"):
        return subprocess.run(
            [binary.BIN, "submit", *args],
            env={
                "PATH": path,
                "HOME": str(self.root),
                "EB_LOCAL_CONFIG": str(site_path or self.site),
                "EB_LOCAL_PREFIX": str(self.prefix),
            },
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def test_requires_recipe_and_configured_node_types(self):
        no_recipe = self.run_submit([])
        self.assertEqual(no_recipe.returncode, 2, no_recipe.stdout + no_recipe.stderr)
        self.assertIn("submit needs an easyconfig", no_recipe.stderr)

        empty_site = self.root / "empty-site.toml"
        empty_site.write_text('[storage]\nnode_local_root = "/local"\n', encoding="utf-8")
        empty_site.chmod(0o600)
        no_nt = self.run_submit(["recipe.eb"], site_path=empty_site)
        self.assertEqual(no_nt.returncode, 2, no_nt.stdout + no_nt.stderr)
        self.assertIn("no build.node_types", no_nt.stderr)

    def test_print_works_without_sbatch_and_forwards_options_after_recipe(self):
        missing_sbatch = self.run_submit(["recipe.eb"], path="/nonexistent")
        self.assertEqual(missing_sbatch.returncode, 2, missing_sbatch.stdout + missing_sbatch.stderr)
        self.assertIn("sbatch is not on PATH", missing_sbatch.stderr)

        printed = self.run_submit(["--print", "--on=cpu", "recipe.eb", "--on", "gpu"], path="/nonexistent")
        self.assertEqual(printed.returncode, 0, printed.stdout + printed.stderr)
        self.assertIn("# cpu: sbatch -p cpu -n 4", printed.stdout)
        self.assertNotIn("# gpu:", printed.stdout)
        self.assertIn("recipe.eb --on gpu\n", printed.stdout)
        self.assertFalse(self.prefix.exists())

    def test_partial_sbatch_failure_runs_all_targets_and_exits_one(self):
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        calls = self.root / "sbatch.calls"
        sbatch = bin_dir / "sbatch"
        sbatch.write_text(
            "#!/bin/sh\n"
            f'printf "%s\\n" "$*" >> "{calls}"\n'
            'case " $* " in\n'
            '  *" -p cpu "*) exit 5 ;;\n'
            "esac\n"
            "exit 0\n",
            encoding="utf-8",
        )
        sbatch.chmod(0o755)

        got = self.run_submit(["recipe.eb"], path=f"{bin_dir}:/usr/bin:/bin")
        self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
        self.assertIn("sbatch refused the cpu job (exit 5)", got.stderr)
        recorded = calls.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(recorded), 2)
        self.assertIn("-p cpu", recorded[0])
        self.assertIn("-p gpu", recorded[1])


if __name__ == "__main__":
    unittest.main()
