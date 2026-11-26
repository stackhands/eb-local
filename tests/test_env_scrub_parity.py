#!/usr/bin/env python3
"""share/env-scrub.json is the install list env and a build unset.

The sha256 is zig-common's env-scrub policy. `eb-local env` and a build
each unset those names, in that order, in the four groups the list has
always used. A shell function named unset records every call, so the test
sees what each shell unset and in which order. The test artifact can read
another list of names (EB_LOCAL_TEST_INSTALL_VARS), which shows that env and
the build take their names from one list, not from a copy each.
"""
from pathlib import Path
import hashlib
import json
import os
import pwd
import subprocess
import tempfile
import unittest

import binary
import test_environment as controls

ROOT = Path(__file__).resolve().parents[1]
# zig-common src/env-scrub.json, the list childClearNames reads.
POLICY_SHA256 = "07ff930b0a4064619dc9ee7b982aa27f33593566bced1c856a5ad376d6ef4d20"
GROUPS = (4, 1, 3, 4)
RECORD_UNSET = r'''
unset() {
    printf '%s\n' "$*" >> "$CONTROL_ROOT/unset.log"
    builtin unset "$@"
}
'''


def policy():
    raw = (ROOT / "share" / "env-scrub.json").read_bytes()
    assert hashlib.sha256(raw).hexdigest() == POLICY_SHA256
    names = json.loads(raw)
    assert isinstance(names, list) and len(names) == sum(GROUPS)
    return names


def grouped(names):
    lines, start = [], 0
    for size in GROUPS:
        lines.append(" ".join(names[start:start + size]))
        start += size
    return lines


class EnvScrubParity(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="env-scrub-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        nodes = self.root / "node-mounts"
        job = nodes / (pwd.getpwuid(os.getuid()).pw_name + ".123")
        job.mkdir(parents=True)
        self.script = self.root / "eb-local"
        self.script.write_text(controls.SCRIPT.read_text())
        config = self.root / "site.conf"
        config.write_text(f"node_local_root = {nodes}\n")
        config.chmod(0o600)
        (self.root / "doubles.sh").write_text(controls.DOUBLE + RECORD_UNSET)
        (self.root / "capture.py").write_text(controls.CAPTURE)
        prefix = self.root / "prefix"
        prefix.mkdir()
        self.env = dict(os.environ, BASH_ENV=str(self.root / "doubles.sh"),
                        CONTROL_ROOT=str(self.root), CONTROL_CLEAR=" ".join(controls.CLEAR),
                        CONTROL_PREFIX=str(prefix), CONTROL_MODE="EESSI_USER_INSTALL",
                        EB_LOCAL_PREFIX=str(prefix), USER="fixture", SLURM_JOB_ID="123",
                        TMPDIR=str(job), CONTROL_JOB_ROOT=str(job), EB_LOCAL_CONFIG=str(config),
                        EESSI_ARCH_GUARD="0")
        self.env.update({name: "inherited" for name in controls.CLEAR})

    def run_wrapper(self, arguments, **extra):
        argv, env = binary.command(self.script, arguments, dict(self.env, **extra))
        return subprocess.run(argv, env=env, cwd=self.root, text=True, capture_output=True)

    def install_unsets(self):
        """What the shell unset of the install variables, one entry per call."""
        log = self.root / "unset.log"
        calls = log.read_text().splitlines() if log.exists() else []
        log.unlink(missing_ok=True)
        return [call for call in calls if call.startswith(("EESSI_", "EASYBUILD_"))]

    def unset_by_env(self, **extra):
        run = self.run_wrapper(["env"], **extra)
        self.assertEqual(run.returncode, 0, run.stderr)
        (self.root / "selected-env.sh").write_text(run.stdout)
        replay = subprocess.run(["bash", "-c", 'source "$1"', "environment", str(self.root / "selected-env.sh")],
                                env=dict(self.env, **extra), cwd=self.root, text=True, capture_output=True)
        self.assertEqual(replay.returncode, 0, replay.stdout + replay.stderr)
        return self.install_unsets()

    def unset_by_build(self, **extra):
        run = self.run_wrapper(["recipe.eb"], **extra)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        return self.install_unsets()

    def test_env_and_a_build_unset_the_shared_list_in_order(self):
        expected = grouped(policy())
        self.assertEqual(self.unset_by_env(), expected)
        self.assertEqual(self.unset_by_build(), expected)

    def test_env_and_a_build_unset_the_names_of_one_list(self):
        other = list(reversed(policy()))
        expected = grouped(other)
        seam = {"EB_LOCAL_TEST_INSTALL_VARS": " ".join(other)}
        self.assertEqual(self.unset_by_env(**seam), expected)
        self.assertEqual(self.unset_by_build(**seam), expected)


if __name__ == "__main__":
    unittest.main()
