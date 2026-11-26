#!/usr/bin/env python3
"""Verify `docs/tools/zig_api.zig` falls back to `main` when ref variables are empty."""
from pathlib import Path
import shutil
import subprocess
import unittest

REPO = Path(__file__).resolve().parents[1]
TOOL = REPO / "docs" / "tools" / "zig_api.zig"


@unittest.skipUnless(shutil.which("zig"), "zig_api runs with zig")
class ZigApiTests(unittest.TestCase):
    def test_empty_source_ref_env_falls_back_to_main(self):
        run = subprocess.run(
            ["zig", "test", str(TOOL)],
            cwd=REPO,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == "__main__":
    unittest.main()
