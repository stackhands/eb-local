#!/usr/bin/env python3
"""Black-box CLI behavior tests for `eb-local eb` and `EB_LOCAL_EESSI_EXTEND`."""
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary


@unittest.skipUnless(binary.ZIG, "eb and EB_LOCAL_EESSI_EXTEND are features of the Zig build")
class EbCliModes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-eb-modes-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()

    def run_bin(self, args, **env_overrides):
        env = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(self.root),
            "EB_LOCAL_CONFIG": "",
        }
        for name in (
            "EESSI_USER_INSTALL",
            "EESSI_PROJECT_INSTALL",
            "EESSI_SITE_INSTALL",
            "EESSI_CVMFS_INSTALL",
            "EB_LOCAL_EESSI_EXTEND",
        ):
            env.pop(name, None)
        env.update(env_overrides)
        return subprocess.run(
            [binary.ZIG, *args],
            env=env,
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def test_multiple_install_variables_exit_three_for_eb_and_explain_eb(self):
        for sub in (["eb", "x.eb"], ["--explain", "eb", "x.eb"]):
            with self.subTest(sub=sub):
                got = self.run_bin(
                    sub,
                    EESSI_USER_INSTALL=str(self.root / "u"),
                    EESSI_PROJECT_INSTALL=str(self.root / "p"),
                )
                self.assertEqual(got.returncode, 3, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")
                self.assertIn("are both set", got.stderr)

        empty_site = self.run_bin(
            ["eb", "x.eb"],
            EESSI_USER_INSTALL=str(self.root / "u"),
            EESSI_SITE_INSTALL="",
        )
        self.assertEqual(empty_site.returncode, 3, empty_site.stdout + empty_site.stderr)
        self.assertIn("EESSI_SITE_INSTALL=''", empty_site.stderr)

    def test_extend_switch_zero_leaves_version_intact_and_one_engages_eb(self):
        ver = self.run_bin(["--version"], EB_LOCAL_EESSI_EXTEND="0")
        self.assertEqual(ver.returncode, 0, ver.stderr)
        self.assertTrue(ver.stdout.startswith("eb-local "))

        engaged = self.run_bin(
            ["x.eb"],
            EB_LOCAL_EESSI_EXTEND="1",
            EESSI_USER_INSTALL=str(self.root / "u"),
            EESSI_SITE_INSTALL="",
        )
        self.assertEqual(engaged.returncode, 3, engaged.stdout + engaged.stderr)
        self.assertIn("EESSI_SITE_INSTALL=''", engaged.stderr)

    def test_double_dash_forwards_help_to_eb_and_absent_init_exits_two(self):
        got = self.run_bin(
            ["eb", "--", "--help"],
            EESSI_CVMFS_REPO=str(self.root / "absent-repo"),
        )
        self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
        self.assertNotIn("install and build software on top of EESSI", got.stdout)
        self.assertIn("missing", got.stderr)


if __name__ == "__main__":
    unittest.main()
