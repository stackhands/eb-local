#!/usr/bin/env python3
"""Julia and R library directories dev prints, evaluated by Bash and zsh."""
import os
from pathlib import Path
import subprocess
import unittest

import binary
from test_storage import StorageFixture

SHELLS = ("bash", "zsh")


class DevLangDirs(StorageFixture):
    def dev_stdout(self, *args):
        run = self.run_wrapper(["dev", *args], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stderr)
        return run.stdout

    def evaluate(self, shell, stdout, **preset):
        """Run the dev lines under nounset and print the two variables."""
        script = self.root / f"lang-{shell}.sh"
        script.write_text(
            "set -u\n"
            "module() {\n"
            "  if [ \"$1\" = load ]; then\n"
            "    export EESSI_VERSION=2026.06\n"
            "    export EESSI_SOFTWARE_SUBDIR=x86_64/amd/zen4\n"
            "    export EESSI_ACCELERATOR_TARGET=\n"
            "  fi\n"
            "  return 0\n"
            "}\n"
            + stdout
            + "printf 'JULIA=%s\\n' \"${JULIA_DEPOT_PATH-}\"\n"
            "printf 'R=%s\\n' \"${R_LIBS_USER-}\"\n",
            encoding="utf-8",
        )
        env = {"PATH": "/usr/bin:/bin", "HOME": str(self.root)}
        env.update(preset)
        return subprocess.run([shell, str(script)], env=env, cwd=self.root,
                              text=True, capture_output=True)

    def test_unset_library_directories_follow_the_dev_prefix(self):
        stdout = self.dev_stdout()
        root = f"{self.prefix}/dev/2026.06/x86_64/amd/zen4"
        expect = {
            "JULIA": f"{root}/julia:",
            "R": f"{root}/R/%p-library/%v",
        }
        for shell in SHELLS:
            with self.subTest(shell=shell, case="unset"):
                got = self.evaluate(shell, stdout)
                self.assertEqual(got.returncode, 0, got.stdout + got.stderr)
                found = dict(line.split("=", 1) for line in got.stdout.splitlines() if line[:1].isalpha())
                self.assertEqual(found, expect, got.stderr)

        for shell in SHELLS:
            with self.subTest(shell=shell, case="kept"):
                got = self.evaluate(shell, stdout, JULIA_DEPOT_PATH="/chosen/depot",
                                    R_LIBS_USER="/chosen/library")
                self.assertEqual(got.returncode, 0, got.stdout + got.stderr)
                self.assertIn("JULIA=/chosen/depot\n", got.stdout)
                self.assertIn("R=/chosen/library\n", got.stdout)

        for shell in SHELLS:
            with self.subTest(shell=shell, case="empty"):
                got = self.evaluate(shell, stdout, JULIA_DEPOT_PATH="", R_LIBS_USER="")
                self.assertEqual(got.returncode, 0, got.stdout + got.stderr)
                self.assertIn("JULIA=\n", got.stdout)
                self.assertIn("R=\n", got.stdout)
                self.assertNotIn("/julia:", got.stdout)
                self.assertNotIn("%p-library", got.stdout)

        snippet = (Path(__file__).resolve().parents[1] / "src" / "dev-lang-dirs.sh").read_text(encoding="utf-8")
        self.assertEqual(stdout.count(snippet), 1)
        main = (Path(__file__).resolve().parents[1] / "src" / "main.zig").read_text(encoding="utf-8")
        self.assertEqual(main.count('@embedFile("dev-lang-dirs.sh")'), 1)
        bash = (Path(__file__).resolve().parents[1] / "eb-local").read_text(encoding="utf-8")
        self.assertEqual(bash.count('cat -- "$script_dir/src/dev-lang-dirs.sh"'), 1)
        self.assertEqual(bash.count("JULIA_DEPOT_PATH"), 0)
        self.assertEqual(main.count("JULIA_DEPOT_PATH"), 0)

    @unittest.skipIf(binary.BIN, "the Zig program embeds the language file")
    def test_bash_dev_skips_a_missing_language_file(self):
        lang = self.root / "src" / "dev-lang-dirs.sh"
        self.assertTrue(lang.is_file())
        lang.unlink()
        run = self.run_wrapper(["dev"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertNotIn("dev-lang-dirs.sh", run.stderr)

    @unittest.skipUnless(binary.BIN, "locked dev is a feature of the Zig build")
    def test_locked_dev_prints_the_same_library_lines(self):
        self.prefix.mkdir(parents=True)
        resolved = dict(
            LOADEDMODULES="EESSI/2026.06",
            EESSI_VERSION="2026.06",
            EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4",
            EESSI_ACCELERATOR_TARGET="",
        )
        made = self.run_wrapper(["dev", "--lock"], SLURM_JOB_ID="", **resolved)
        self.assertEqual(made.returncode, 0, made.stderr)
        stdout = self.dev_stdout("--locked")
        root = f"{self.prefix}/dev/2026.06/x86_64/amd/zen4"
        for shell in SHELLS:
            with self.subTest(shell=shell):
                got = self.evaluate(shell, stdout, EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4",
                                    EESSI_VERSION="2026.06")
                self.assertEqual(got.returncode, 0, got.stdout + got.stderr)
                self.assertIn(f"JULIA={root}/julia:\n", got.stdout)
                self.assertIn(f"R={root}/R/%p-library/%v\n", got.stdout)


if __name__ == "__main__":
    unittest.main()
