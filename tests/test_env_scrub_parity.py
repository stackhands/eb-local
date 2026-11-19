#!/usr/bin/env python3
"""The shared install-location list is one list in three places.

share/env-scrub.json is the copy of zig-common's src/env-scrub.json.
The Bash program's scrub_names and the Zig program's install_vars name
the same names in the same order. The sha256 is the file's own: a copy
that drifts from zig-common fails here.
"""
from pathlib import Path
import hashlib
import json
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
# zig-common src/env-scrub.json, the list childClearNames reads.
POLICY_SHA256 = "07ff930b0a4064619dc9ee7b982aa27f33593566bced1c856a5ad376d6ef4d20"


def script_names(text):
    body = re.search(r"^scrub_names=\((.*?)\n\)", text, re.S | re.M)
    if body is None:
        raise AssertionError("eb-local has no scrub_names array")
    return re.findall(r"[A-Z][A-Z0-9_]*", body.group(1))


def zig_names(text):
    body = re.search(r"const install_vars = \[_\]\[\]const u8\{(.*?)\};", text, re.S)
    if body is None:
        raise AssertionError("src/main.zig has no install_vars")
    return re.findall(r'"([A-Z0-9_]+)"', body.group(1))


class EnvScrubParity(unittest.TestCase):
    def test_the_shell_the_zig_program_and_the_file_name_one_list(self):
        raw = (ROOT / "share" / "env-scrub.json").read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(), POLICY_SHA256)
        policy = json.loads(raw)
        self.assertIsInstance(policy, list)
        script = (ROOT / "eb-local").read_text()
        self.assertEqual(script_names(script), policy)
        self.assertEqual(zig_names((ROOT / "src" / "main.zig").read_text()), policy)
        # The four unset lines eb-local env has always printed, built from
        # the one array: four names, one name, three names, four names.
        self.assertIn("printf 'unset %s %s %s %s\\n' \"${scrub_names[@]:0:4}\"", script)
        self.assertIn("printf 'unset %s\\n' \"${scrub_names[4]}\"", script)
        self.assertIn("printf 'unset %s %s %s\\n' \"${scrub_names[@]:5:3}\"", script)
        self.assertIn("printf 'unset %s %s %s %s\\n' \"${scrub_names[@]:8:4}\"", script)
        lines = [
            "unset " + " ".join(policy[0:4]),
            "unset " + policy[4],
            "unset " + " ".join(policy[5:8]),
            "unset " + " ".join(policy[8:12]),
        ]
        self.assertEqual(lines, [
            "unset EESSI_CVMFS_INSTALL EESSI_SITE_INSTALL EESSI_USER_INSTALL EESSI_PROJECT_INSTALL",
            "unset EESSI_SITE_SOFTWARE_PREFIX",
            "unset EESSI_SOFTWARE_SUBDIR_OVERRIDE EESSI_ACCELERATOR_TARGET_OVERRIDE EESSI_OVERRIDE_GPU_CHECK",
            "unset EASYBUILD_INSTALLPATH EASYBUILD_INSTALLPATH_SOFTWARE EASYBUILD_INSTALLPATH_MODULES EASYBUILD_PREFIX",
        ])
