#!/usr/bin/env python3
"""Black-box CLI behavior tests for `eb-local doctor` option validation, environment warnings, and init checks."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary


@unittest.skipUnless(binary.BIN, "doctor is a feature of the Zig build")
class DoctorCliModes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-doctor-modes-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.repo = self.root / "repo"
        init_file = self.repo / "versions" / "2026.06" / "init" / "lmod" / "bash"
        init_file.parent.mkdir(parents=True)
        init_file.write_text("# init\n", encoding="utf-8")

    def run_doctor(self, args, **env_overrides):
        env = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(self.root),
            "EB_LOCAL_CONFIG": "",
            "EESSI_CVMFS_REPO": str(self.repo),
        }
        for name in ("LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT", "LMOD_CMD", "MODULESHOME"):
            env.pop(name, None)
        env.update(env_overrides)
        return subprocess.run(
            [binary.BIN, *args],
            env=env,
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def test_option_validation_and_explain_refusal(self):
        cases = (
            (["doctor", "--cvmfs-parallel", "0"], "--cvmfs-parallel needs a number from 1 to 8"),
            (["doctor", "--cvmfs-parallel=9"], "--cvmfs-parallel needs a number from 1 to 8"),
            (["doctor", "--cvmfs-parallel", "abc"], "--cvmfs-parallel needs a number from 1 to 8"),
            (["doctor", "--unknown"], "doctor takes --json, --strict"),
            (["--explain", "doctor"], "--explain goes with a recipe or with eb"),
        )
        for args, msg in cases:
            with self.subTest(args=args):
                got = self.run_doctor(args)
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")
                self.assertIn(msg, got.stderr)

    def test_ld_audit_and_mixed_ld_preload_warn_while_strict_exits_one(self):
        got = self.run_doctor(
            ["doctor", "--json", "--strict"],
            LD_AUDIT="/tmp/audit.so",
            LD_PRELOAD="/tmp/other.so:libxalt_init.so",
        )
        self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
        doc = json.loads(got.stdout)
        self.assertTrue(doc["failed"])
        warns = [entry["text"] for entry in doc["lines"] if entry["level"] == "warn"]
        self.assertTrue(any("LD_AUDIT is set" in m for m in warns), warns)
        self.assertTrue(any("LD_PRELOAD is set" in m for m in warns), warns)
        self.assertIn("warnings fail under --strict", doc["summary"])

    @unittest.expectedFailure
    def test_doctor_fails_when_eessi_init_path_is_a_directory(self):
        bad_repo = self.root / "bad-repo"
        (bad_repo / "versions" / "2026.06" / "init" / "lmod" / "bash").mkdir(parents=True)
        got = self.run_doctor(["doctor", "--json"], EESSI_CVMFS_REPO=str(bad_repo))
        self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
        doc = json.loads(got.stdout)
        self.assertTrue(doc["failed"])


if __name__ == "__main__":
    unittest.main()
