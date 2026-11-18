#!/usr/bin/env python3
"""Verify `tests/site/rtrash-job.sh` resolves both two-part and three-part EESSI CPU targets."""
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
RTRASH_JOB = REPO / "tests" / "site" / "rtrash-job.sh"


class RtrashJobPathsTests(unittest.TestCase):
    def test_pigz_paths_resolve_for_two_and_three_component_targets(self):
        lines = RTRASH_JOB.read_text(encoding="utf-8").splitlines()
        inst_line = next(l for l in lines if l.startswith("inst=$("))
        mod_line = next(l for l in lines if l.startswith("mod=$("))

        for target in ("aarch64/neoverse_v1", "x86_64/amd/zen4"):
            with self.subTest(target=target):
                with tempfile.TemporaryDirectory(prefix="eb-local-rtrash-paths-") as td:
                    root = Path(td)
                    base = root / "eessi" / "versions" / "2026.06" / "software" / "linux" / target
                    inst = base / "software" / "pigz" / "2.8-GCCcore-15.2.0"
                    mod = base / "modules" / "all" / "pigz" / "2.8-GCCcore-15.2.0.lua"
                    inst.mkdir(parents=True)
                    mod.parent.mkdir(parents=True)
                    mod.write_text("-- lua\n", encoding="utf-8")

                    script = (
                        f"set -eo pipefail\nT='{root}'\n"
                        f"{inst_line}\n{mod_line}\n"
                        'printf "%s|%s\\n" "$inst" "$mod"\n'
                    )
                    run = subprocess.run(["/bin/bash", "-c", script], capture_output=True, text=True, check=False)
                    self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                    self.assertEqual(run.stdout.strip(), f"{inst}|{mod}")


if __name__ == "__main__":
    unittest.main()
