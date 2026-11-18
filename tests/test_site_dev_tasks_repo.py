#!/usr/bin/env python3
"""Verify `tests/site/dev-tasks.sh` honors `EESSI_CVMFS_REPO` in helper checks."""
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
DEV_TASKS = REPO / "tests" / "site" / "dev-tasks.sh"


class DevTasksRepoTests(unittest.TestCase):
    def test_from_eessi_honors_eessi_cvmfs_repo(self):
        lines = [
            line for line in DEV_TASKS.read_text(encoding="utf-8").splitlines()
            if line.startswith(("eessi_runpath()", "from_eessi()"))
        ]
        self.assertEqual(len(lines), 2)
        with tempfile.TemporaryDirectory(prefix="eb-local-dev-tasks-") as td:
            repo = Path(td) / "custom-eessi"
            tool_dir = repo / "versions" / "2026.06" / "bin"
            tool_dir.mkdir(parents=True)
            mpicc = tool_dir / "mpicc"
            mpicc.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            mpicc.chmod(0o755)

            script = "\n".join(lines) + "\nfrom_eessi mpicc\n"
            run = subprocess.run(
                ["/bin/bash", "-c", script],
                env={"PATH": f"{tool_dir}:/usr/bin:/bin", "EESSI_CVMFS_REPO": str(repo)},
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == "__main__":
    unittest.main()
