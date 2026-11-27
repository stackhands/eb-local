#!/usr/bin/env python3
"""Black-box CLI tests for `--cpu-target`: option parsing, refusals and the
preflight that decides whether a masked build may start. None of them needs
CPUID faulting, KVM or EESSI."""
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary

ZEN4_GOOD = (
    "x86_64/amd/zen4",
    "cpuid",
    "yes",
    "x86_64/amd/zen4:x86_64/amd/zen3:x86_64/generic\n",
    "zen4\n",
    "znver4",
    "vendor=AuthenticAMD family=25 model=17 faulting=on\n",
)


@unittest.skipUnless(binary.ZIG, "--cpu-target is a feature of the Zig build")
class CpuTargetCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-cpu-target-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        (self.root / "home").mkdir()

    def run_cli(self, *args):
        env = {"PATH": "/usr/bin:/bin", "HOME": str(self.root / "home"), "EB_LOCAL_CONFIG": ""}
        return subprocess.run([binary.ZIG, *args], env=env, cwd=self.root, capture_output=True, text=True)

    def preflight(self, **changes):
        words = list(ZEN4_GOOD)
        for key, value in changes.items():
            words[{"target": 0, "route": 1, "devfd": 2, "detect": 3, "spec": 4, "gcc": 5, "probe": 6}[key]] = value
        return self.run_cli("__mask-preflight", *words)

    def test_preflight_passes_when_every_detector_names_the_target(self):
        r = self.preflight()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("preflight ok: EESSI archdetect names x86_64/amd/zen4", r.stdout)
        self.assertIn("preflight ok: gcc -march=native is znver4", r.stdout)
        self.assertNotIn("FAILED", r.stdout)

    def test_preflight_refuses_each_mismatch(self):
        cases = {
            "devfd": ("no", "/dev/fd is missing"),
            "detect": ("x86_64/generic", "archdetect names 'x86_64/generic'"),
            "spec": ("x86_64_v4", "archspec names 'x86_64_v4'"),
            "gcc": ("znver5", "gcc -march=native is 'znver5'"),
            "probe": ("vendor=GenuineIntel family=6 model=106 faulting=on", "CPUID vendor is 'GenuineIntel'"),
        }
        for key, (value, text) in cases.items():
            with self.subTest(key=key):
                r = self.preflight(**{key: value})
                self.assertEqual(r.returncode, 1)
                self.assertIn("preflight FAILED", r.stdout)
                self.assertIn(text, r.stdout)
                self.assertIn("nothing was built", r.stderr)

    def test_preflight_refuses_a_cpuid_build_whose_faulting_is_off(self):
        r = self.preflight(probe="vendor=AuthenticAMD family=25 model=17 faulting=off")
        self.assertEqual(r.returncode, 1)
        self.assertIn("CPUID faulting is not active", r.stdout)

    def test_preflight_refuses_missing_answers(self):
        r = self.preflight(detect="", gcc="")
        self.assertEqual(r.returncode, 1)
        self.assertIn("archdetect gave no answer", r.stdout)
        self.assertIn("gcc gave no -march=native value", r.stdout)

    def test_preflight_notes_an_archspec_that_cannot_be_imported(self):
        r = self.preflight(spec="")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("archspec is not importable here", r.stdout)

    def test_a_short_name_two_architectures_share_is_refused(self):
        r = self.run_cli("--cpu-target", "generic", "--explain", "x.eb")
        self.assertEqual(r.returncode, 2)
        self.assertIn("more than one CPU target", r.stderr)

    def test_an_unknown_target_is_refused(self):
        r = self.run_cli("--cpu-target", "zen9", "--explain", "x.eb")
        self.assertEqual(r.returncode, 2)
        self.assertIn("not a CPU target eb-local knows", r.stderr)

    def test_mask_takes_four_routes(self):
        r = self.run_cli("--cpu-target", "zen4", "--mask", "vm", "--explain", "x.eb")
        self.assertEqual(r.returncode, 2)
        self.assertIn("--mask takes auto, cpuid, kvm or tcg", r.stderr)

    def test_cpu_target_needs_a_value(self):
        r = self.run_cli("--cpu-target")
        self.assertEqual(r.returncode, 2)
        self.assertIn("--cpu-target needs a value", r.stderr)

    def test_doctor_names_what_it_checks(self):
        r = self.run_cli("doctor", "--cpu-target", "zen4")
        self.assertIn("host: ", r.stdout)
        self.assertIn("CPUID", r.stdout)
        self.assertIn("/dev/kvm", r.stdout)
        self.assertIn("a mask profile exists for x86_64/amd/zen4", r.stdout)


if __name__ == "__main__":
    unittest.main()
