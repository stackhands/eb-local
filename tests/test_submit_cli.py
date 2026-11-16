#!/usr/bin/env python3
"""eb-local submit, through the command line of the Zig build.

submit writes one batch script per node type the site file lists in
build.targets and hands each to sbatch, here a double that records its
arguments.
"""
import os
from pathlib import Path
import shlex
import subprocess
import unittest

import binary
from test_storage import StorageFixture

SBATCH = r'''#!/bin/sh
printf '%s\n' "$*" >> "$CONTROL_ROOT/sbatch-calls"
echo "Submitted batch job 4242"
'''


@unittest.skipUnless(binary.BIN, "submit is a feature of the Zig build")
class Submit(StorageFixture):
    def setUp(self):
        super().setUp()
        self.site = self.root / "site.toml"
        self.write_site(
            "[build.targets]\n"
            'rome = "-p rome -n 16 -t 02:00:00 --constraint=scratch-node"\n'
            'genoa = "-p genoa -n 16 -t 02:00:00"\n')
        self.env["EB_LOCAL_CONFIG"] = str(self.site)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "sbatch").write_text(SBATCH)
        (self.bin / "sbatch").chmod(0o755)
        self.env["PATH"] = f"{self.bin}:/usr/bin:/bin"

    def write_site(self, extra):
        self.site.write_text(
            "[storage]\n"
            f'node_local_root = "{self.nodes}"\n'
            'node_local_fstype = "xfs"\n'
            f'shared_scratch = ["/scratch", "{self.nodes.parent / "shared"}"]\n' + extra)
        self.site.chmod(0o644)

    def run_tool(self, args, **extra):
        argv, env = binary.command(self.script, args, dict(self.env, **extra))
        return subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)

    def calls(self):
        f = self.root / "sbatch-calls"
        return f.read_text().splitlines() if f.exists() else []

    def test_one_job_per_target_runs_this_program_with_the_recipe(self):
        run = self.run_tool(["submit", "my recipe.eb", "--robot"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        calls = self.calls()
        self.assertEqual(len(calls), 2)
        self.assertTrue(calls[0].startswith("-p rome -n 16 -t 02:00:00 --constraint=scratch-node "), calls[0])
        self.assertTrue(calls[1].startswith("-p genoa -n 16 -t 02:00:00 "), calls[1])
        self.assertEqual(run.stdout.count("Submitted batch job 4242"), 2)
        scripts = sorted((self.prefix / ".eb-local" / "jobs").iterdir())
        self.assertEqual([s.name.split("-", 1)[1] for s in scripts],
                         ["genoa-my_recipe.eb.sh", "rome-my_recipe.eb.sh"])
        text = scripts[1].read_text()
        self.assertIn("#SBATCH --job-name=eb-local-rome-my_recipe.eb", text)
        self.assertIn(f"#SBATCH --chdir={os.path.realpath(self.root)}", text)
        last = text.rstrip().splitlines()[-1]
        self.assertEqual(shlex.split(last)[0], "exec")
        self.assertEqual(shlex.split(last)[-2:], ["my recipe.eb", "--robot"])
        self.assertEqual(os.stat(scripts[1]).st_mode & 0o777, 0o700)

    def test_on_chooses_targets_and_names_the_known_ones(self):
        run = self.run_tool(["submit", "--on", "genoa", "recipe.eb"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(len(self.calls()), 1)
        self.assertTrue(self.calls()[0].startswith("-p genoa "))
        run = self.run_tool(["submit", "--on", "milan", "recipe.eb"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 2)
        self.assertIn("rome, genoa", run.stderr)

    def test_print_shows_the_jobs_and_submits_nothing(self):
        run = self.run_tool(["submit", "--print", "recipe.eb", "--dry-run"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(self.calls(), [])
        self.assertFalse(self.prefix.exists())
        self.assertIn("# rome: ", run.stdout)
        self.assertIn("#SBATCH --job-name=eb-local-genoa-recipe.eb", run.stdout)
        # --dry-run after the recipe is eb's, not submit's.
        self.assertIn("recipe.eb --dry-run", run.stdout)

    def test_without_targets_there_is_nothing_to_submit(self):
        self.write_site("")
        run = self.run_tool(["submit", "recipe.eb"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 2)
        self.assertIn("no build.targets", run.stderr)
        self.assertEqual(self.calls(), [])

    def test_targets_are_checked_and_belong_to_the_site_file(self):
        for bad in ('rome = "-p rome; touch injected"\n', 'rome = "-p $(id)"\n', 'rome = "rome"\n'):
            with self.subTest(bad=bad):
                self.write_site("[build.targets]\n" + bad)
                run = self.run_tool(["config"], SLURM_JOB_ID="")
                self.assertEqual(run.returncode, 2, run.stdout)
                self.assertIn("build.targets", run.stderr)
        self.assertFalse((self.root / "injected").exists())
        self.write_site("")
        user = self.root / "xdg" / "eb-local" / "config.toml"
        user.parent.mkdir(parents=True)
        user.write_text('[build.targets]\nrome = "-p rome"\n')
        run = self.run_tool(["config"], SLURM_JOB_ID="", XDG_CONFIG_HOME=str(self.root / "xdg"))
        self.assertEqual(run.returncode, 2)
        self.assertIn("build.targets is a site setting", run.stderr)

    def test_config_shows_the_targets(self):
        run = self.run_tool(["config"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stderr)
        rows = {l.split()[0]: l for l in run.stdout.splitlines() if l.startswith("build.targets")}
        self.assertIn("-p rome -n 16 -t 02:00:00 --constraint=scratch-node", rows["build.targets.rome"])
        self.assertIn("-p genoa -n 16 -t 02:00:00", rows["build.targets.genoa"])
        self.write_site("")
        run = self.run_tool(["config"], SLURM_JOB_ID="")
        self.assertRegex(run.stdout, r"(?m)^build\.targets\s+\(none\)")


if __name__ == "__main__":
    unittest.main()
