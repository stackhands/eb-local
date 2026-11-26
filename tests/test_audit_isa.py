#!/usr/bin/env python3
"""Black-box tests for `eb-local audit-isa`.

Two kinds. Some run the command against a recorded disassembly: a stand-in
for objdump prints a fixed listing, so every instruction, feature and exit
code is known and no disassembler is needed. The others compile C with
`zig cc` for the architecture under test and audit the object files with the
host's real objdump; where the host's objdump cannot read that architecture
the command must refuse with exit 2 and say so.
"""
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest

import binary
from test_json_cli import load_schema, validate

X86_LISTING = """\

lib.so:     file format elf64-x86-64


Disassembly of section .text:

0000000000001000 <kernel>:
    1000:\t55                   \tpush   rbp
    1001:\t48 89 e5             \tmov    rbp,rsp
    1004:\t62 f1 7c 48 58 c1    \tvaddps zmm0,zmm0,zmm1
    100a:\t62 f1 7c 48 58 c2    \tvaddps zmm0,zmm0,zmm2
    1010:\tc5 f4 58 c2          \tvaddps ymm0,ymm1,ymm2
    1014:\t62 f5 7e 08 6e c0    \tvmovw  xmm0,eax
    101a:\tc7 f8 00 00 00 00    \txbegin 1020 <kernel+0x20>
    1020:\tf3 48 0f 1e c8       \trdsspq rax
    1024:\tc3                   \tret
"""

AARCH64_LISTING = """\

lib.so:\tfile format elf64-littleaarch64

Disassembly of section .text:

0000000000000000 <kernel>:
       0: d503233f     \tpaciasp
       4: 2518e3e0     \tptrue\tp0.s
       8: a5404000     \tld1w\t{z0.s}, p0/z, [x0]
       c: 4e80a400     \tsmmla\tv0.4s, v0.16b, v0.16b
      10: 4e40fc00     \tbfdot\tv0.4s, v1.8h, v2.8h
      14: 4e8f9420     \tsdot\tv0.4s, v1.16b, v15.16b
      18: 4522b400     \tbdep\tz0.s, z0.s, z2.s
      1c: f8e10000     \tldaddal\tx1, x0, [x0]
      20: 4ea1d400     \tfadd\tv0.4s, v0.4s, v1.4s
      24: d65f03c0     \tret
"""


def elf_header(machine):
    """The 64 bytes of a little-endian ELF64 header for a shared object."""
    ident = b"\x7fELF" + bytes([2, 1, 1, 0]) + bytes(8)
    return ident + struct.pack("<HHIQQQIHHHHHH", 3, machine, 1, 0, 64, 0, 0, 64, 56, 0, 64, 0, 0)


def fake_objdump(directory, listing):
    """An executable named objdump that prints `listing` whatever it is given."""
    listing_file = directory / "listing.txt"
    listing_file.write_text(listing)
    tool = directory / "objdump"
    tool.write_text(f'#!/bin/sh\nexec cat "{listing_file}"\n')
    tool.chmod(0o755)
    return tool


def run_audit(args, cwd, path=None):
    env = {"PATH": path or os.environ["PATH"], "HOME": str(cwd), "EB_LOCAL_CONFIG": ""}
    return subprocess.run([binary.ZIG, "audit-isa", *args], env=env, cwd=cwd,
                          capture_output=True, text=True)


def disassembler_reads(arch):
    """Whether an objdump on PATH reads `arch`, as audit-isa decides it."""
    needle = {"x86_64": "elf64-x86-64", "aarch64": "elf64-littleaarch64"}[arch]
    names = {"x86_64": ["objdump", "x86_64-linux-gnu-objdump"],
             "aarch64": ["aarch64-linux-gnu-objdump", "objdump"]}[arch]
    for name in names:
        exe = shutil.which(name)
        if exe:
            got = subprocess.run([exe, "-i"], capture_output=True, text=True)
            if got.returncode == 0 and needle in got.stdout:
                return True
    exe = shutil.which("llvm-objdump")
    if exe:
        got = subprocess.run([exe, "--version"], capture_output=True, text=True)
        if got.returncode == 0 and ("x86-64" if arch == "x86_64" else "aarch64 ") in got.stdout.lower():
            return True
    return False


@unittest.skipUnless(binary.ZIG, "audit-isa is a feature of the Zig build")
class AuditIsaCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-audit-isa-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir()

    def tree(self, package, machine, name="libkernel.so"):
        """A prefix with one shared object, at software/PACKAGE/1.0/lib."""
        lib = self.root / "software" / package / "1.0" / "lib"
        lib.mkdir(parents=True, exist_ok=True)
        (lib / name).write_bytes(elf_header(machine))
        return self.root / "software" / package

    def test_the_command_line_is_checked(self):
        prefix = self.tree("Demo", 62)
        cases = [
            ([], "takes one PATH"),
            ([str(prefix)], "needs --target"),
            ([str(prefix), "--target", "x86_64/amd/zen9"], "does not know the target"),
            ([str(prefix), str(prefix), "--target", "zen3"], "takes one PATH"),
            ([str(prefix), "--target", "zen3", "--bogus"], "does not know '--bogus'"),
            ([str(self.root / "missing"), "--target", "zen3"], "cannot read"),
            ([str(prefix), "--target", "zen3", "--allow", str(self.root / "nope")], "cannot read the allow list"),
        ]
        for args, message in cases:
            with self.subTest(args=args):
                got = run_audit(args, self.root)
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")
                self.assertIn(message, got.stderr)
        listing = run_audit([str(prefix), "--target", "x86_64/amd/zen9"], self.root).stderr
        for known in ("x86_64/amd/zen3", "x86_64/amd/zen4", "aarch64/neoverse_v1", "x86_64/generic"):
            self.assertIn(known, listing)

    def test_x86_64_beyond_zen3_fails_and_is_reported_per_feature(self):
        prefix = self.tree("Demo", 62)
        fake_objdump(self.bin, X86_LISTING)
        got = run_audit([str(prefix), "--target", "x86_64/amd/zen3", "--objdump", str(self.bin / "objdump")], self.root)
        self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
        self.assertIn("target x86_64/amd/zen3, 1 ELF files, 9 instructions", got.stdout)
        # Two EVEX zmm adds, one EVEX vmovw: AVX512F twice for the adds,
        # AVX512_FP16 once, plus the xbegin of RTM. The VEX ymm add and
        # RDSSP are fine.
        self.assertRegex(got.stdout, r"violation: avx512f x2 in \S+libkernel\.so, first at 0x1004: vaddps zmm0,zmm0,zmm1")
        self.assertRegex(got.stdout, r"violation: avx512fp16 x1 in \S+, first at 0x1014: vmovw xmm0,eax")
        self.assertRegex(got.stdout, r"violation: rtm x1 in \S+, first at 0x101a: xbegin 1020")
        self.assertNotIn("violation: avx:", got.stdout)
        self.assertNotIn("shstk", got.stdout)
        self.assertIn("2 zmm instructions", got.stdout)
        self.assertIn("4 instruction(s) beyond x86_64/amd/zen3 in 1 file(s)", got.stdout)

    def test_x86_64_zen4_lacks_only_what_it_lacks(self):
        prefix = self.tree("Demo", 62)
        fake_objdump(self.bin, X86_LISTING)
        got = run_audit([str(prefix), "--target", "amd/zen4", "--objdump", str(self.bin / "objdump")], self.root)
        self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
        self.assertNotRegex(got.stdout, r"violation: avx512f x")
        self.assertIn("violation: avx512fp16 x1", got.stdout)
        self.assertIn("violation: rtm x1", got.stdout)

    def test_a_target_that_has_everything_exits_zero(self):
        prefix = self.tree("Demo", 62)
        fake_objdump(self.bin, X86_LISTING.replace("62 f5 7e 08 6e c0    \tvmovw  xmm0,eax", "90                   \tnop")
                     .replace("c7 f8 00 00 00 00    \txbegin 1020 <kernel+0x20>", "90                   \tnop"))
        got = run_audit([str(prefix), "--target", "x86_64/amd/zen4", "--objdump", str(self.bin / "objdump")], self.root)
        self.assertEqual(got.returncode, 0, got.stdout + got.stderr)
        self.assertIn("no instruction beyond x86_64/amd/zen4", got.stdout)
        self.assertIn("2 zmm instructions", got.stdout)

    def test_dispatch_packages_are_reported_and_do_not_fail(self):
        # OpenSSL may carry RTM and XOP behind a CPU check, nothing else.
        listing = X86_LISTING.replace("62 f1 7c 48 58 c1    \tvaddps zmm0,zmm0,zmm1", "90                   \tnop") \
                             .replace("62 f1 7c 48 58 c2    \tvaddps zmm0,zmm0,zmm2", "90                   \tnop") \
                             .replace("62 f5 7e 08 6e c0    \tvmovw  xmm0,eax", "90                   \tnop")
        fake_objdump(self.bin, listing)
        prefix = self.tree("OpenSSL", 62)
        argv = ["--target", "x86_64/amd/zen4", "--objdump", str(self.bin / "objdump")]
        got = run_audit([str(prefix), *argv], self.root)
        self.assertEqual(got.returncode, 0, got.stdout + got.stderr)
        self.assertIn("dispatch: rtm x1", got.stdout)
        self.assertIn("no instruction beyond", got.stdout)
        other = self.tree("Other", 62)
        got = run_audit([str(other), *argv], self.root)
        self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
        self.assertIn("violation: rtm x1", got.stdout)
        allow = self.root / "allow.txt"
        allow.write_text("# custom\nOther rtm  # reason\n")
        got = run_audit([str(other), *argv, "--allow", str(allow)], self.root)
        self.assertEqual(got.returncode, 0, got.stdout + got.stderr)
        self.assertIn("dispatch: rtm x1", got.stdout)
        got = run_audit([str(prefix), *argv, "--allow", str(allow)], self.root)
        self.assertEqual(got.returncode, 1, got.stdout + got.stderr)

    def test_json_follows_the_schema(self):
        prefix = self.tree("Demo", 62)
        fake_objdump(self.bin, X86_LISTING)
        got = run_audit([str(prefix), "--target", "x86_64/amd/zen3", "--json", "--objdump", str(self.bin / "objdump")], self.root)
        self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
        self.assertEqual(len(got.stdout.splitlines()), 1)
        doc = json.loads(got.stdout)
        validate(doc, load_schema("audit-isa.schema.json"))
        self.assertEqual(doc["kind"], "audit-isa")
        self.assertEqual(doc["target"], "x86_64/amd/zen3")
        self.assertTrue(doc["failed"])
        self.assertEqual(doc["zmm"], 2)
        features = {f["feature"]: f for f in doc["files"][0]["findings"]}
        self.assertEqual(features["avx512f"]["count"], 2)
        self.assertEqual(features["avx512f"]["address"], "0x1004")
        self.assertEqual(sorted(features), ["avx512f", "avx512fp16", "rtm"])
        clean = run_audit([str(prefix), "--target", "x86_64/amd/zen4", "--json", "--objdump", str(self.bin / "objdump")], self.root)
        validate(json.loads(clean.stdout), load_schema("audit-isa.schema.json"))

    def test_aarch64_sve_needs_neoverse_v1_and_sve2_neoverse_v2(self):
        prefix = self.tree("Demo", 183)
        fake_objdump(self.bin, AARCH64_LISTING)
        objdump = str(self.bin / "objdump")
        n1 = run_audit([str(prefix), "--target", "aarch64/neoverse_n1", "--objdump", objdump], self.root)
        self.assertEqual(n1.returncode, 1, n1.stdout + n1.stderr)
        for feature, count in (("sve", 2), ("i8mm", 1), ("bf16", 1), ("sve2-bitperm", 1)):
            self.assertRegex(n1.stdout, rf"violation: {feature} x{count} in ")
        self.assertNotIn("violation: dotprod", n1.stdout)
        self.assertNotIn("violation: lse", n1.stdout)
        self.assertNotIn("pauth", n1.stdout)
        self.assertIn("first at 0x4: ptrue p0.s", n1.stdout)
        v1 = run_audit([str(prefix), "--target", "aarch64/neoverse_v1", "--objdump", objdump], self.root)
        self.assertEqual(v1.returncode, 1, v1.stdout + v1.stderr)
        self.assertEqual(sorted(line.split()[1] for line in v1.stdout.splitlines() if line.startswith("violation")), ["sve2-bitperm"])
        v2 = run_audit([str(prefix), "--target", "aarch64/neoverse_v2", "--objdump", objdump], self.root)
        self.assertEqual(v2.returncode, 1, v2.stdout + v2.stderr)
        self.assertIn("violation: sve2-bitperm", v2.stdout)
        generic = run_audit([str(prefix), "--target", "aarch64/generic", "--objdump", objdump], self.root)
        self.assertIn("violation: lse x1", generic.stdout)
        self.assertIn("violation: dotprod x1", generic.stdout)

    def test_files_of_another_architecture_are_skipped(self):
        prefix = self.tree("Demo", 183)
        fake_objdump(self.bin, X86_LISTING)
        (prefix / "notes.txt").write_text("not ELF\n")
        got = run_audit([str(prefix), "--target", "x86_64/amd/zen3", "--json", "--objdump", str(self.bin / "objdump")], self.root)
        self.assertEqual(got.returncode, 0, got.stdout + got.stderr)
        doc = json.loads(got.stdout)
        self.assertEqual((doc["files_audited"], doc["files_skipped"]), (0, 1))

    def test_a_failing_objdump_is_a_tool_error(self):
        prefix = self.tree("Demo", 62)
        tool = self.bin / "objdump"
        tool.write_text("#!/bin/sh\necho 'file format not recognized' >&2\nexit 1\n")
        tool.chmod(0o755)
        got = run_audit([str(prefix), "--target", "x86_64/amd/zen3", "--objdump", str(tool)], self.root)
        self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
        self.assertIn("error: ", got.stdout)
        self.assertIn("file format not recognized", got.stdout)

    def test_a_missing_disassembler_is_named(self):
        prefix = self.tree("Demo", 62)
        got = run_audit([str(prefix), "--target", "x86_64/amd/zen3"], self.root, path=str(self.bin))
        self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
        self.assertIn("no disassembler for x86_64", got.stderr)
        self.assertIn("--objdump PATH", got.stderr)


@unittest.skipUnless(binary.ZIG, "audit-isa is a feature of the Zig build")
class AuditIsaCompiled(unittest.TestCase):
    """Objects built with zig cc, audited with the host's objdump."""

    C_SOURCE = "void f(float *a, const float *b, int n) { for (int i = 0; i < n; i++) a[i] = a[i] * b[i] + 1.0f; }\n"
    SVE_SOURCE = "#include <arm_sve.h>\nsvfloat32_t g(svfloat32_t a, svfloat32_t b) { return svadd_f32_x(svptrue_b32(), a, b); }\n"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-audit-isa-cc-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()

    def compile(self, name, source, *flags):
        zig = shutil.which("zig")
        self.assertIsNotNone(zig, "zig cc compiles the test objects, and zig is not on PATH")
        src = self.root / (name + ".c")
        src.write_text(source)
        out = self.root / name
        out.mkdir()
        env = dict(os.environ, ZIG_LOCAL_CACHE_DIR=str(self.root / "zcache"), ZIG_GLOBAL_CACHE_DIR=os.environ.get("ZIG_GLOBAL_CACHE_DIR", str(self.root / "zglobal")))
        built = subprocess.run([zig, "cc", *flags, "-O3", "-c", str(src), "-o", str(out / (name + ".o"))],
                               capture_output=True, text=True, env=env)
        self.assertEqual(built.returncode, 0, built.stderr)
        return out

    def audit(self, arch, path, target, *extra):
        got = run_audit([str(path), "--target", target, *extra], self.root)
        if not disassembler_reads(arch):
            self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
            self.assertIn(f"no disassembler for {arch}", got.stderr)
            return None
        return got

    def test_x86_64_znver4_code_needs_avx512_and_znver3_code_does_not(self):
        z4 = self.compile("z4", self.C_SOURCE, "-target", "x86_64-linux-gnu", "-mcpu=znver4", "-mprefer-vector-width=512")
        z3 = self.compile("z3", self.C_SOURCE, "-target", "x86_64-linux-gnu", "-mcpu=znver3")
        against_zen3 = self.audit("x86_64", z4, "x86_64/amd/zen3", "--json")
        if against_zen3 is None:
            return
        self.assertEqual(against_zen3.returncode, 1, against_zen3.stdout + against_zen3.stderr)
        doc = json.loads(against_zen3.stdout)
        validate(doc, load_schema("audit-isa.schema.json"))
        found = {f["feature"] for f in doc["files"][0]["findings"]}
        self.assertIn("avx512f", found)
        self.assertGreater(doc["zmm"], 0)
        against_zen4 = self.audit("x86_64", z4, "x86_64/amd/zen4")
        self.assertEqual(against_zen4.returncode, 0, against_zen4.stdout + against_zen4.stderr)
        for target in ("x86_64/amd/zen3", "x86_64/amd/zen4"):
            clean = self.audit("x86_64", z3, target)
            self.assertEqual(clean.returncode, 0, clean.stdout + clean.stderr)
            self.assertEqual([l for l in clean.stdout.splitlines() if l.startswith("unclassified")], [])
        generic = self.audit("x86_64", z3, "x86_64/generic")
        self.assertEqual(generic.returncode, 1, generic.stdout + generic.stderr)
        self.assertRegex(generic.stdout, r"violation: (avx|avx2|bmi|bmi2|fma|f16c|sse3|ssse3|sse41|sse42|popcnt|lzcnt|movbe) x\d+")

    def test_aarch64_sve_object_needs_neoverse_v1(self):
        sve = self.compile("v1", self.SVE_SOURCE, "-target", "aarch64-linux-gnu", "-mcpu=neoverse_v1")
        plain = self.compile("n1", self.C_SOURCE, "-target", "aarch64-linux-gnu", "-mcpu=neoverse_n1")
        against_n1 = self.audit("aarch64", sve, "aarch64/neoverse_n1")
        if against_n1 is None:
            return
        self.assertEqual(against_n1.returncode, 1, against_n1.stdout + against_n1.stderr)
        self.assertIn("violation: sve x", against_n1.stdout)
        against_v1 = self.audit("aarch64", sve, "aarch64/neoverse_v1")
        self.assertEqual(against_v1.returncode, 0, against_v1.stdout + against_v1.stderr)
        for target in ("aarch64/neoverse_n1", "aarch64/neoverse_v1"):
            clean = self.audit("aarch64", plain, target)
            self.assertEqual(clean.returncode, 0, clean.stdout + clean.stderr)


if __name__ == "__main__":
    unittest.main()
