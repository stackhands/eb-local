#!/usr/bin/env python3
"""`env --strict` and the load-eessi how-to stay aligned."""
from pathlib import Path
import re
import subprocess
import unittest

import binary
import support

ROOT = Path(__file__).resolve().parents[1]
MAIN = ROOT / "src" / "main.zig"
HOWTO = ROOT / "docs" / "orgmode" / "howto" / "load-eessi.org"


class EnvStrictSource(unittest.TestCase):
    def test_strict_prelude_checks_the_eessi_init_path(self):
        text = MAIN.read_text()
        self.assertIn("env_strict_prelude", text)
        self.assertIn("mount EESSI with CVMFS", text)

    def test_load_eessi_page_names_strict(self):
        page = HOWTO.read_text()
        self.assertIn("eb-local env --strict", page)
        self.assertIn("EB_LOCAL_ENV_STRICT=1", page)


@unittest.skipUnless(binary.BIN, "env --strict needs the Zig build")
class EnvStrictCli(unittest.TestCase):
    def test_strict_exits_when_init_is_missing(self):
        env = support.isolated_env({"PATH": "/usr/bin:/bin", "HOME": "/tmp"})
        run = subprocess.run(
            [binary.BIN, "env", "--strict"],
            capture_output=True,
            text=True,
            env=env,
        )
        script = run.stdout
        self.assertIn("init=${repo}/versions/${ver}/init/lmod/bash", script)
        proc = subprocess.run(
            ["bash", "-c", script],
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(proc.returncode, 2, proc.stderr + proc.stdout)
        self.assertIn("missing", proc.stderr)
        self.assertIn("CVMFS", proc.stderr)

    def test_dev_without_strict_is_unchanged_raw_bytes(self):
        import os
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            env = support.isolated_env({"PATH": os.environ["PATH"], "HOME": tmp, "EB_LOCAL_PREFIX": f"{tmp}/eessi"})
            default_dev = subprocess.run([binary.BIN, "dev"], capture_output=True, text=False, env=env)
            self.assertEqual((default_dev.returncode, default_dev.stderr), (0, b""))
            self.assertTrue(default_dev.stdout.startswith(b"if ! type module >/dev/null 2>&1; then\n"))
            self.assertNotIn(b"init=${repo}/versions/${ver}/init/lmod/bash", default_dev.stdout)

            strict_dev = subprocess.run([binary.BIN, "dev", "--strict"], capture_output=True, text=False, env=env)
            self.assertEqual((strict_dev.returncode, strict_dev.stderr), (0, b""))
            self.assertTrue(strict_dev.stdout.endswith(default_dev.stdout))
            prelude = strict_dev.stdout[: len(strict_dev.stdout) - len(default_dev.stdout)]
            self.assertIn(b"init=${repo}/versions/${ver}/init/lmod/bash", prelude)

            custom_be = subprocess.run(
                [binary.BIN, "dev", "--buildenv", "buildenv/site-gcc", "FFTW/3.3.10"],
                capture_output=True,
                text=False,
                env=env,
            )
            self.assertEqual((custom_be.returncode, custom_be.stderr), (0, b""))
            self.assertTrue(custom_be.stdout.startswith(b"if ! type module >/dev/null 2>&1; then\n"))
            self.assertIn(b"module load FFTW/3.3.10\n", custom_be.stdout)
            self.assertIn(b"module load buildenv/site-gcc\n", custom_be.stdout)

    def test_dev_strict_exits_2_when_init_is_absent(self):
        env = support.isolated_env({"PATH": "/usr/bin:/bin", "HOME": "/tmp"})
        run = subprocess.run(
            [binary.BIN, "dev", "--strict", "--buildenv", "buildenv/site-gcc", "FFTW/3.3.10"],
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual((run.returncode, run.stderr), (0, ""))
        self.assertIn("init=${repo}/versions/${ver}/init/lmod/bash", run.stdout)
        self.assertIn("module load FFTW/3.3.10", run.stdout)
        proc = subprocess.run(
            ["bash", "-c", run.stdout],
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(proc.returncode, 2, proc.stderr + proc.stdout)
        self.assertIn("CVMFS", proc.stderr)


if __name__ == "__main__":
    unittest.main()
