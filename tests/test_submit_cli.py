#!/usr/bin/env python3
"""eb-local submit, through the command line of the Zig build.

submit writes one batch script per node type the site file lists in
build.node_types and hands each to sbatch, here a double that records its
arguments.
"""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import unittest

import binary
from test_storage import StorageFixture

README = Path(__file__).resolve().parents[1] / "README.md"

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
            "[build.node_types]\n"
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

    def test_one_job_per_node_type_runs_this_program_with_the_recipe(self):
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

    def test_on_chooses_node_types_and_names_the_known_ones(self):
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

    def readme_section(self):
        text = README.read_text()
        start = text.index("\n## Build for every node type\n")
        return text[start:text.index("\n## ", start + 1)]

    def test_the_readme_commands_run_against_the_readme_node_types(self):
        section = self.readme_section()
        site = re.search(r"```toml\n(.*?)```", section, re.S).group(1)
        self.assertTrue(site.startswith("[build.node_types]\n"), site)
        self.write_site(site)
        commands = re.search(r"```sh\n(.*?)```", section, re.S).group(1).splitlines()
        self.assertEqual(len(commands), 3, commands)
        for line in commands:
            argv = shlex.split(line, comments=True)
            self.assertEqual(argv[:2], ["eb-local", "submit"])
            with self.subTest(command=line):
                run = self.run_tool(argv[1:], SLURM_JOB_ID="")
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(len(self.calls()), 3, self.calls())
        self.assertTrue(self.calls()[2].startswith("-p gpu "), self.calls())

    def test_the_readme_shows_the_lines_explain_prints(self):
        section = self.readme_section()
        self.write_site(re.search(r"```toml\n(.*?)```", section, re.S).group(1))
        shown = re.search(r"```console\n\$ (.*?)\n(.*?)```", section, re.S)
        run = self.run_tool(shlex.split(shown.group(1))[1:], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stderr)
        printed = run.stdout.replace(str(Path(binary.BIN).resolve()), "/usr/local/bin/eb-local")
        for line in shown.group(2).splitlines():
            self.assertIn(line + "\n", printed)

    def batch_lines(self, text, indent):
        return [shlex.split(l[len(indent):]) for l in text.splitlines() if l.startswith(indent + "sbatch ")]

    def test_explain_and_the_refusal_outside_a_job_print_an_sbatch_line_per_node_type(self):
        explained = self.run_tool(["--explain", "my recipe.eb", "--robot"], SLURM_JOB_ID="")
        self.assertEqual(explained.returncode, 0, explained.stderr)
        lines = self.batch_lines(explained.stdout, "#   ")
        self.assertEqual([l[:3] for l in lines], [["sbatch", "-p", "rome"], ["sbatch", "-p", "genoa"]])
        self.assertIn("--job-name=eb-local-rome-my_recipe.eb", lines[0])
        self.assertIn("--output=%x-%j.out", lines[0])
        refused = self.run_tool(["my recipe.eb", "--robot"], SLURM_JOB_ID="")
        self.assertEqual(refused.returncode, 2, refused.stdout + refused.stderr)
        self.assertEqual(self.batch_lines(refused.stderr, "  "), lines)
        # Each job runs what submit's job for that node type runs.
        run = self.run_tool(["submit", "my recipe.eb", "--robot"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        script = next((self.prefix / ".eb-local" / "jobs").glob("*-rome-*"))
        wrap = next(w for w in lines[0] if w.startswith("--wrap="))[len("--wrap="):]
        self.assertEqual(wrap, script.read_text().rstrip().splitlines()[-1])

    def test_the_printed_job_builds_in_its_allocation(self):
        explained = self.run_tool(["--explain", "my recipe.eb", "--robot"], SLURM_JOB_ID="")
        line = self.batch_lines(explained.stdout, "#   ")[1]
        wrap = next(w for w in line if w.startswith("--wrap="))[len("--wrap="):]
        _, env = binary.command(self.script, [], dict(self.env))
        job = subprocess.run(["sh", "-c", wrap], env=env, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(job.returncode, 0, job.stdout + job.stderr)
        self.assertEqual(json.loads((self.root / "eb.json").read_text())["argv"], ["my recipe.eb", "--robot"])

    def test_submit_says_it_is_deprecated_and_still_submits(self):
        run = self.run_tool(["submit", "recipe.eb"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("eb-local: submit is deprecated and is removed in 4.0.0; eb-local --explain RECIPE"
                      " prints an sbatch line for each node type\n", run.stderr)
        self.assertEqual(len(self.calls()), 2)

    def test_without_node_types_there_is_nothing_to_submit(self):
        self.write_site("")
        run = self.run_tool(["submit", "recipe.eb"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 2)
        self.assertIn("no build.node_types", run.stderr)
        self.assertEqual(self.calls(), [])

    def test_node_types_are_checked_and_belong_to_the_site_file(self):
        for bad in ('rome = "-p rome; touch injected"\n', 'rome = "-p $(id)"\n', 'rome = "rome"\n'):
            with self.subTest(bad=bad):
                self.write_site("[build.node_types]\n" + bad)
                run = self.run_tool(["config"], SLURM_JOB_ID="")
                self.assertEqual(run.returncode, 2, run.stdout)
                self.assertIn("build.node_types.rome", run.stderr)
        self.assertFalse((self.root / "injected").exists())
        self.write_site("")
        user = self.root / "xdg" / "eb-local" / "config.toml"
        user.parent.mkdir(parents=True)
        user.write_text('[build.node_types]\nrome = "-p rome"\n')
        run = self.run_tool(["config"], SLURM_JOB_ID="", XDG_CONFIG_HOME=str(self.root / "xdg"))
        self.assertEqual(run.returncode, 2)
        self.assertIn("build.node_types is a site setting", run.stderr)

    def test_config_shows_the_node_types(self):
        run = self.run_tool(["config"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stderr)
        rows = {l.split()[0]: l for l in run.stdout.splitlines() if l.startswith("build.node_types")}
        self.assertIn("-p rome -n 16 -t 02:00:00 --constraint=scratch-node", rows["build.node_types.rome"])
        self.assertIn("-p genoa -n 16 -t 02:00:00", rows["build.node_types.genoa"])
        self.write_site("")
        run = self.run_tool(["config"], SLURM_JOB_ID="")
        self.assertRegex(run.stdout, r"(?m)^build\.node_types\s+\(none\)")

    def test_config_gives_each_node_type_its_own_line(self):
        run = self.run_tool(["config"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stderr)
        lines = self.site.read_text().splitlines()
        rows = [l for l in run.stdout.splitlines() if l.startswith("build.node_types.")]
        self.assertEqual(len(rows), 2, run.stdout)
        for row in rows:
            name = row.split()[0][len("build.node_types."):]
            line = next(i for i, text in enumerate(lines, 1) if text.startswith(f"{name} = "))
            self.assertTrue(row.endswith(f"[site {self.site}:{line}]"), row)

    def test_the_old_name_build_targets_is_read_with_a_warning(self):
        self.write_site('[build.targets]\ncpu = "-p cpu -n 16"\n')
        warning = (f"eb-local: site {self.site}:5: [build.targets] is now [build.node_types];"
                   " eb-local reads the old name until 4.0.0")
        run = self.run_tool(["config"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertRegex(run.stdout, r"(?m)^build\.node_types\.cpu\s+-p cpu -n 16\s")
        self.assertIn(warning, run.stderr)
        run = self.run_tool(["submit", "recipe.eb"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(run.stderr.count(warning), 1, run.stderr)
        self.assertTrue(self.calls()[0].startswith("-p cpu -n 16 "), self.calls())
        self.write_site('[build.node_types]\ncpu = "-p cpu"\n[build.targets]\ngpu = "-p gpu"\n')
        run = self.run_tool(["config"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 2, run.stdout)
        self.assertIn("build.targets is the old name of build.node_types, which line 5 sets; keep one", run.stderr)


if __name__ == "__main__":
    unittest.main()
