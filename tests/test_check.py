#!/usr/bin/env python3
"""eb-local check: a program's loader, run paths and libraries.

The programs are built here with the host's gcc into fake EESSI trees, so
the tests skip without gcc and for the Bash 1.x script, which has no check.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import binary

GCC = shutil.which("gcc")


@unittest.skipUnless(binary.BIN and GCC, "needs the Zig build and gcc")
class Check(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.env = {"PATH": os.environ["PATH"], "HOME": str(self.root)}

    def tearDown(self):
        self.tmp.cleanup()

    def tree(self, target):
        """A library directory in an EESSI software tree for `target`."""
        lib = self.root / "versions/2026.06/software/linux" / target / "software/libdemo/1.0/lib"
        lib.mkdir(parents=True)
        (self.root / "demo.c").write_text("int demo(void) { return 7; }\n")
        subprocess.run([GCC, "-shared", "-fPIC", "-o", str(lib / "libdemo.so"), str(self.root / "demo.c")], check=True)
        return lib

    def program(self, lib, *flags):
        (self.root / "prog.c").write_text("int demo(void);\nint main(void) { return demo() == 7 ? 0 : 1; }\n")
        out = self.root / "prog"
        subprocess.run([GCC, "-o", str(out), str(self.root / "prog.c"), f"-L{lib}", "-ldemo", *flags], check=True)
        return out

    def check(self, *files, **env):
        e = dict(self.env)
        e.update(env)
        return subprocess.run([binary.BIN, "check", *map(str, files)], env=e, text=True, capture_output=True)

    def test_a_program_with_its_rpath_in_this_target_passes(self):
        lib = self.tree("x86_64/amd/zen4")
        prog = self.program(lib, f"-Wl,-rpath,{lib}", "-Wl,--disable-new-dtags")
        run = self.check(prog, EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn(f"RPATH    {lib}", run.stdout)
        self.assertIn(f"libdemo.so => {lib}/libdemo.so   [RPATH]", run.stdout)
        self.assertIn("no problems", run.stdout)

    def test_a_run_path_into_another_target_is_a_problem(self):
        lib = self.tree("x86_64/amd/zen2")
        prog = self.program(lib, f"-Wl,-rpath,{lib}", "-Wl,--disable-new-dtags")
        run = self.check(prog, EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4")
        self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
        self.assertIn("into the x86_64/amd/zen2 software tree; this shell is x86_64/amd/zen4", run.stdout)

    def test_runpath_is_a_problem(self):
        lib = self.tree("x86_64/amd/zen4")
        prog = self.program(lib, f"-Wl,-rpath,{lib}", "-Wl,--enable-new-dtags")
        run = self.check(prog)
        self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
        self.assertIn("RUNPATH", run.stdout)
        self.assertIn("--disable-new-dtags", run.stdout)

    def test_origin_is_expanded(self):
        lib = self.tree("x86_64/amd/zen4")
        prog = self.program(lib, "-Wl,-rpath,$ORIGIN/versions/2026.06/software/linux/x86_64/amd/zen4/software/libdemo/1.0/lib",
                            "-Wl,--disable-new-dtags")
        run = self.check(prog)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn(f"=> {lib}/libdemo.so   [RPATH]", run.stdout)

    def test_a_library_found_only_through_ld_library_path_is_a_problem(self):
        lib = self.tree("x86_64/amd/zen4")
        prog = self.program(lib)
        run = self.check(prog, LD_LIBRARY_PATH=str(lib))
        self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
        self.assertIn("libdemo.so is found only through LD_LIBRARY_PATH", run.stdout)

    def test_a_missing_library_is_a_problem(self):
        lib = self.tree("x86_64/amd/zen4")
        prog = self.program(lib, f"-Wl,-rpath,{lib}", "-Wl,--disable-new-dtags")
        (lib / "libdemo.so").unlink()
        run = self.check(prog)
        self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
        self.assertIn("libdemo.so => not found", run.stdout)

    def test_the_host_loader_and_libc_are_problems_under_eessi(self):
        lib = self.tree("x86_64/amd/zen4")
        prog = self.program(lib, f"-Wl,-rpath,{lib}", "-Wl,--disable-new-dtags")
        run = self.check(prog, EESSI_EPREFIX=str(self.root / "compat"))
        self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
        self.assertIn("the loader is the host's", run.stdout)
        self.assertIn("libc.so.6 comes from the host", run.stdout)

    def test_a_file_that_is_not_elf_exits_2(self):
        text = self.root / "notes.txt"
        text.write_text("hello\n")
        run = self.check(text)
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn("is not a 64-bit little-endian ELF file", run.stderr)

    def test_a_truncated_program_exits_2(self):
        lib = self.tree("x86_64/amd/zen4")
        prog = self.program(lib)
        data = prog.read_bytes()
        for size in (70, 200, len(data) // 2):
            with self.subTest(size=size):
                cut = self.root / f"cut{size}"
                cut.write_bytes(data[:size])
                run = self.check(cut)
                self.assertIn(run.returncode, (1, 2), run.stdout + run.stderr)
                self.assertNotIn("panic", run.stderr)

    def test_no_file_is_an_error(self):
        run = self.check()
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("check needs", run.stderr)


if __name__ == "__main__":
    unittest.main()
