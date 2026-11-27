#!/usr/bin/env python3
"""The internal helper `eb-local __vm-run`.

The refusals need no VM and run everywhere. The runs boot a KVM guest or an
emulated user space, which GitHub-hosted runners do not offer in general, so
they run only with EB_LOCAL_VM_TESTS=1, on a host with /dev/kvm, QEMU,
virtiofsd and EESSI (EB_LOCAL_QEMU_DIR and EB_LOCAL_VIRTIOFSD name the
tools when they are not on PATH).
"""
import os
import platform
import subprocess
import time
import unittest

import binary

HOST = "aarch64" if platform.machine() in ("aarch64", "arm64") else "x86_64"
RUN_VMS = os.environ.get("EB_LOCAL_VM_TESTS") == "1"


def vm_run(*args, env=None):
    full = dict(os.environ, **(env or {}))
    return subprocess.run([binary.ZIG, "__vm-run", *args], capture_output=True, text=True, env=full)


@unittest.skipUnless(binary.ZIG, "the helper is a feature of the Zig build")
class Refusals(unittest.TestCase):
    def test_a_missing_option_is_named_and_exits_2(self):
        for args, word in [
            ([], "--mode"),
            (["--mode", "kvm", "--", "true"], "--cpu-target"),
            (["--mode", "kvm", "--cpu-target", "x86_64/amd/zen4"], "COMMAND"),
            (["--mode", "vm", "--cpu-target", "x86_64/amd/zen4", "--", "true"], "kvm or tcg"),
            (["--mode", "kvm", "--cpu-target", "x86_64/amd/zen4", "--bogus", "--", "true"], "--bogus"),
        ]:
            run = vm_run(*args)
            self.assertEqual(run.returncode, 2, (args, run.stderr))
            self.assertIn(word, run.stderr)
            self.assertTrue(run.stderr.startswith("eb-local: vm-run: "), run.stderr)

    def test_an_unknown_target_lists_the_known_ones(self):
        run = vm_run("--mode", "kvm", "--cpu-target", "x86_64/amd/zen9", "--", "true")
        self.assertEqual(run.returncode, 2)
        self.assertIn("x86_64/amd/zen4", run.stderr)

    def test_a_target_the_mode_cannot_present_is_refused_with_the_reason(self):
        other = "aarch64/neoverse_n1" if HOST == "x86_64" else "x86_64/amd/zen3"
        same = "x86_64/amd/zen4" if HOST == "x86_64" else "aarch64/neoverse_n1"
        run = vm_run("--mode", "kvm", "--cpu-target", other, "--", "true")
        self.assertEqual(run.returncode, 2, run.stderr)
        run = vm_run("--mode", "tcg", "--cpu-target", same, "--", "true")
        self.assertEqual(run.returncode, 2, run.stderr)
        self.assertIn("another architecture", run.stderr)
        run = vm_run("--mode", "kvm", "--cpu-target", "x86_64/amd/zen5", "--", "true")
        self.assertEqual(run.returncode, 2, run.stderr)

    def test_a_host_without_the_tools_refuses_and_does_not_start_a_vm(self):
        target = "x86_64/amd/zen4" if HOST == "x86_64" else "x86_64/amd/zen3"
        mode = "kvm" if HOST == "x86_64" else "tcg"
        run = vm_run("--mode", mode, "--cpu-target", target, "--",
                     "true", env={"PATH": "/nonexistent", "EB_LOCAL_QEMU_DIR": "/nonexistent",
                                  "EB_LOCAL_VIRTIOFSD": "/nonexistent/virtiofsd",
                                  "EB_LOCAL_VM_KERNEL": "/nonexistent/vmlinuz"})
        self.assertEqual(run.returncode, 2, run.stderr)
        self.assertTrue(run.stderr.startswith("eb-local: vm-run: "), run.stderr)


# Defined only when asked for, so that a host without KVM lists no skipped tests.
if binary.ZIG and RUN_VMS:
    class Runs(unittest.TestCase):
        def timed(self, *args, **kw):
            start = time.monotonic()
            run = vm_run(*args, **kw)
            print(f"\n{' '.join(args[:4])}: {time.monotonic() - start:.1f} s, status {run.returncode}")
            return run

        @unittest.skipUnless(HOST == "x86_64", "KVM targets are of the host architecture")
        def test_kvm_zen4_reports_znver4_and_passes_the_status_through(self):
            run = self.timed("--mode", "kvm", "--cpu-target", "x86_64/amd/zen4", "--",
                             "bash", "-c", "gcc -march=native -Q --help=target | grep -- '-march='; exit 7")
            self.assertEqual(run.returncode, 7, run.stderr)
            self.assertIn("znver4", run.stdout)
            self.assertIn("archdetect=x86_64/amd/zen4", run.stderr)
            self.assertIn("archspec=zen4", run.stderr)

        @unittest.skipUnless(HOST == "x86_64", "KVM targets are of the host architecture")
        def test_kvm_icelake_reports_an_intel_part(self):
            run = self.timed("--mode", "kvm", "--cpu-target", "x86_64/intel/icelake", "--",
                             "bash", "-c", "gcc -march=native -Q --help=target | grep -- '-march='; grep -m1 vendor_id /proc/cpuinfo")
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertIn("icelake-server", run.stdout)
            self.assertIn("GenuineIntel", run.stdout)
            self.assertIn("archspec=icelake", run.stderr)

        @unittest.skipUnless(HOST == "x86_64", "KVM targets are of the host architecture")
        def test_kvm_zen2_and_zen3_report_their_compiler_names(self):
            for target, gcc, archspec in [("x86_64/amd/zen2", "znver2", "zen2"), ("x86_64/amd/zen3", "znver3", "zen3")]:
                run = self.timed("--mode", "kvm", "--cpu-target", target, "--",
                                 "bash", "-c", "gcc -march=native -Q --help=target | grep -- '-march='; grep -m1 vendor_id /proc/cpuinfo")
                self.assertEqual(run.returncode, 0, (target, run.stderr))
                self.assertIn(gcc, run.stdout)
                self.assertIn("AuthenticAMD", run.stdout)
                self.assertIn(f"archdetect={target}", run.stderr)
                self.assertIn(f"archspec={archspec}", run.stderr)

        @unittest.skipUnless(HOST == "x86_64", "the aarch64 emulation runs on an x86_64 host here")
        def test_tcg_sve_vector_length_follows_the_core(self):
            probe = ("printf '%s\\n' '#include <stdio.h>' '#include <sys/prctl.h>' "
                     "'int main(void){printf(\"vl_bytes=%d\\n\", prctl(51) & 0xffff);return 0;}' > /tmp/vl.c; "
                     "gcc -mcpu=native -### -c /tmp/vl.c 2>&1 | grep -o -- '-mcpu=[^ ]*' | head -n 1; "
                     "gcc -o /tmp/vl /tmp/vl.c && /tmp/vl")
            for target, cpu, vl in [("aarch64/neoverse_v1", "neoverse-v1", 32), ("aarch64/a64fx", "a64fx", 64)]:
                run = self.timed("--mode", "tcg", "--cpu-target", target, "--allow-archspec-mismatch", "--",
                                 "bash", "-c", probe)
                self.assertEqual(run.returncode, 0, (target, run.stderr))
                self.assertIn(cpu, run.stdout)
                self.assertIn(f"vl_bytes={vl}", run.stdout)
                self.assertIn(f"archdetect={target}", run.stderr)

        @unittest.skipUnless(HOST == "x86_64", "KVM targets are of the host architecture")
        def test_a_cpu_view_that_does_not_name_the_target_is_refused_before_the_command(self):
            marker = f"/tmp/eb-local-vm-test-{os.getpid()}"
            run = self.timed("--mode", "kvm", "--cpu-target", "x86_64/amd/zen4", "--",
                             "bash", "-c", f"touch {marker}", env={"EB_LOCAL_VM_GCC": "/nonexistent/gcc"})
            self.assertEqual(run.returncode, 126, run.stderr)
            self.assertIn("refused", run.stderr)
            self.assertFalse(os.path.exists(marker))

        @unittest.skipUnless(HOST == "x86_64", "the aarch64 emulation runs on an x86_64 host here")
        def test_tcg_neoverse_n1_runs_the_eessi_aarch64_stack(self):
            run = self.timed("--mode", "tcg", "--cpu-target", "aarch64/neoverse_n1",
                             "--allow-archspec-mismatch", "--",
                             "bash", "-c", "uname -m; echo 'int main(void){return 0;}' > /tmp/x.c; gcc -mcpu=native -### -c /tmp/x.c 2>&1 | grep -o -- '-mcpu=[^ ]*'")
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertIn("aarch64", run.stdout)
            self.assertIn("neoverse-n1", run.stdout)
            self.assertIn("archdetect=aarch64/neoverse_n1", run.stderr)


if __name__ == "__main__":
    unittest.main()
