#!/usr/bin/env python3
"""`env --strict` and the load-eessi how-to stay aligned."""
from pathlib import Path
import re
import subprocess
import unittest

import binary

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
        run = subprocess.run(
            [binary.BIN, "env", "--strict"],
            capture_output=True,
            text=True,
            env={"PATH": "/usr/bin:/bin", "HOME": "/tmp"},
        )
        script = run.stdout
        self.assertIn("init=${repo}/versions/${ver}/init/lmod/bash", script)
        proc = subprocess.run(
            ["bash", "-c", script],
            capture_output=True,
            text=True,
            env={"PATH": "/usr/bin:/bin", "HOME": "/tmp"},
        )
        self.assertEqual(proc.returncode, 2, proc.stderr + proc.stdout)
        self.assertIn("missing", proc.stderr)
        self.assertIn("CVMFS", proc.stderr)


if __name__ == "__main__":
    unittest.main()