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
        lib.mkdir(parents=True, exist_ok=True)
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

    def install_elf(self, *flags, dest="tree"):
        """An ELF program and a text file under `dest`, and a link to the program."""
        lib = self.tree("x86_64/amd/zen4")
        prog = self.program(lib, f"-Wl,-rpath,{lib}", *flags)
        tree = self.root / dest
        (tree / "bin").mkdir(parents=True)
        (tree / "bin" / "prog").write_bytes(prog.read_bytes())
        (tree / "notes.txt").write_text("not elf\n")
        (tree / "bin" / "alias").symlink_to("prog")
        outside = self.root / "outside"
        outside.mkdir(exist_ok=True)
        (outside / "other").write_bytes(prog.read_bytes())
        link = tree / "linked"
        if not link.exists():
            link.symlink_to(outside)
        return tree

    def test_prefix_audits_elf_files_and_skips_the_rest(self):
        tree = self.install_elf("-Wl,--disable-new-dtags")
        run = self.check("--prefix", tree, EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn(str(tree / "bin" / "prog"), run.stdout)
        self.assertIn("no problems", run.stdout)
        self.assertNotIn("notes.txt", run.stdout + run.stderr)
        self.assertNotIn("is not a 64-bit", run.stderr)
        self.assertNotIn("alias", run.stdout)
        self.assertNotIn("other", run.stdout)
        self.assertEqual(run.stdout.count(str(tree / "bin" / "prog")), 1)

    def test_quiet_prints_a_file_only_when_it_has_a_problem(self):
        tree = self.install_elf("-Wl,--enable-new-dtags", dest="noisy")
        run = self.check("--prefix", tree, "--quiet")
        self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
        self.assertIn(str(tree / "bin" / "prog"), run.stdout)
        self.assertIn("problem:", run.stdout)
        self.assertIn("--disable-new-dtags", run.stdout)
        self.assertNotIn("loader", run.stdout)
        self.assertNotIn("notes.txt", run.stdout + run.stderr)
        clean = self.install_elf("-Wl,--disable-new-dtags", dest="quiet")
        run = self.check("--prefix", clean, "--quiet", EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(run.stdout.strip(), "eb-local check: no problems")

    def test_a_tree_with_no_elf_file_says_so(self):
        tree = self.root / "empty"
        (tree / "doc").mkdir(parents=True)
        (tree / "doc" / "readme").write_text("text\n")
        run = self.check("--prefix", tree)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("eb-local check: no ELF files", run.stdout)
        self.assertIn("eb-local check: no problems", run.stdout)
        self.assertNotIn("is not a 64-bit", run.stderr)

    def test_module_audits_each_installation(self):
        lib = self.tree("x86_64/amd/zen4")
        prog = self.program(lib, f"-Wl,-rpath,{lib}", "-Wl,--disable-new-dtags")
        prefix = self.root / "eessi"
        install = prefix / "versions/2026.06/software/linux/x86_64/amd/zen4/software/demo/1.0"
        (install / "bin").mkdir(parents=True)
        (install.parent.parent.parent / "modules").mkdir(parents=True)
        (install / "bin" / "demo").write_bytes(prog.read_bytes())
        (install / "README").write_text("not elf\n")
        run = self.check("--module", "demo/1.0", EB_LOCAL_PREFIX=str(prefix),
                         EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn(str(install / "bin" / "demo"), run.stdout)
        self.assertNotIn("README", run.stdout + run.stderr)
        missing = self.check("--module", "missing/1.0", EB_LOCAL_PREFIX=str(prefix))
        self.assertEqual(missing.returncode, 2, missing.stdout + missing.stderr)
        self.assertIn("is not installed", missing.stderr)

    def test_dev_uses_the_dev_prefix_or_the_eessi_target(self):
        lib = self.tree("x86_64/amd/zen4")
        prog = self.program(lib, f"-Wl,-rpath,{lib}", "-Wl,--disable-new-dtags")
        named = self.root / "named-dev"
        (named / "bin").mkdir(parents=True)
        (named / "bin" / "prog").write_bytes(prog.read_bytes())
        run = self.check("--dev", EB_LOCAL_DEV_PREFIX=str(named), EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn(str(named / "bin" / "prog"), run.stdout)
        prefix = self.root / "eessi"
        computed = prefix / "dev/2026.06/x86_64/amd/zen4/accel"
        (computed / "bin").mkdir(parents=True)
        (computed / "bin" / "prog").write_bytes(prog.read_bytes())
        run = self.check("--dev", EB_LOCAL_PREFIX=str(prefix), EESSI_VERSION="2026.06",
                         EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4", EESSI_ACCELERATOR_TARGET="accel")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn(str(computed / "bin" / "prog"), run.stdout)
        absent = self.check("--dev")
        self.assertNotEqual(absent.returncode, 0)
        self.assertIn("EB_LOCAL_DEV_PREFIX", absent.stderr)

    def test_the_tree_modes_are_alternatives(self):
        run = self.check("--dev", "--prefix", str(self.root))
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("one of --module, --dev and --prefix", run.stderr)
        run = self.check(self.root / "notes.txt", "--dev")
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("one of --module, --dev and --prefix", run.stderr)


if __name__ == "__main__":
    unittest.main()
