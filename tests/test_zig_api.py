#!/usr/bin/env python3
"""Verify `docs/tools/zig_api.zig` falls back to `main` when ref variables are empty."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
TOOL = REPO / "docs" / "tools" / "zig_api.zig"


@unittest.skipUnless(shutil.which("zig"), "zig_api runs with zig")
class ZigApiTests(unittest.TestCase):
    def test_empty_source_ref_env_falls_back_to_main(self):
        with tempfile.TemporaryDirectory(prefix="eb-local-zig-api-") as td:
            out = Path(td) / "api"
            env = dict(os.environ, DOCS_SOURCE_REF="", GITHUB_SHA="")
            run = subprocess.run(
                [
                    "zig", "run", str(TOOL), "--",
                    "--module", "eb-local",
                    "--root", "src/main.zig",
                    "--out", str(out),
                    "--source-url", "https://github.com/stackhands/eb-local/blob/{ref}/",
                ],
                cwd=REPO,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            page = (out / "eb-local.md").read_text(encoding="utf-8")
            self.assertIn(":source: https://github.com/stackhands/eb-local/blob/main/src/main.zig", page)
            self.assertNotIn("/blob//", page)


if __name__ == "__main__":
    unittest.main()
