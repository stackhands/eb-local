#!/usr/bin/env python3
"""Verify `tests/site/build-job.sh`'s `setting` parser handles quoted TOML and legacy lines."""
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
BUILD_JOB = REPO / "tests" / "site" / "build-job.sh"


class BuildJobSettingTests(unittest.TestCase):
    def test_setting_strips_optional_toml_quotes(self):
        fn_line = next(
            line for line in BUILD_JOB.read_text(encoding="utf-8").splitlines()
            if line.startswith("setting()")
        )
        with tempfile.TemporaryDirectory(prefix="eb-local-build-job-") as td:
            root = Path(td)
            toml_cfg = root / "config.toml"
            toml_cfg.write_text('[storage]\nnode_local_root = "/local"\nnode_local_mount = "%u.%j"\n', encoding="utf-8")
            legacy_cfg = root / "eb-local.conf"
            legacy_cfg.write_text("node_local_root = /local/scratch\nnode_local_mount = %j\n", encoding="utf-8")

            for cfg, want_root, want_mount in (
                (toml_cfg, "/local", "%u.%j"),
                (legacy_cfg, "/local/scratch", "%j"),
            ):
                script = (
                    f"{fn_line}\n"
                    f"EB_LOCAL_CONFIG='{cfg}'\n"
                    "printf '%s|%s\\n' \"$(setting node_local_root)\" \"$(setting node_local_mount)\"\n"
                )
                run = subprocess.run(["/bin/bash", "-c", script], capture_output=True, text=True, check=True)
                self.assertEqual(run.stdout.strip(), f"{want_root}|{want_mount}")


if __name__ == "__main__":
    unittest.main()
