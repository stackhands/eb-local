#!/usr/bin/env python3
"""eb-local check: a program's loader, run paths and libraries.

The programs are built here with the host's gcc into fake EESSI trees, so
the tests skip without gcc and for the Bash 1.x script, which has no check.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import binary
from test_json_cli import load_schema, validate

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

    def test_duplicate_module_arguments_are_checked_once(self):
        lib = self.tree("x86_64/amd/zen4")
        prog = self.program(lib, f"-Wl,-rpath,{lib}", "-Wl,--enable-new-dtags")
        prefix = self.root / "eessi-dup"
        install = prefix / "versions/2026.06/software/linux/x86_64/amd/zen4/software/demo/1.0"
        (install / "bin").mkdir(parents=True)
        (install.parent.parent.parent / "modules").mkdir(parents=True)
        (install / "bin" / "demo").write_bytes(prog.read_bytes())
        run = self.check(
            "--module",
            "demo/1.0",
            "demo/1.0",
            "--quiet",
            "--json",
            EB_LOCAL_PREFIX=str(prefix),
            EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4",
        )
        self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
        doc = json.loads(run.stdout.splitlines()[-1])
        self.assertEqual(doc["elf_count"], 1, doc)
        self.assertEqual(len(doc["files"]), 1, doc)
        self.assertEqual(doc["problem_count"], 1, doc)

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

    def _build_transitive_chain(self, lib_flags=("-Wl,--disable-new-dtags",), drop_sub=False):
        """Build prog -> libdemo.so -> libsub.so in separate software directories."""
        base = self.root / "versions/2026.06/software/linux/x86_64/amd/zen4/software"
        sub_dir = base / "libsub/1.0/lib"
        demo_dir = base / "libdemo/1.0/lib"
        sub_dir.mkdir(parents=True, exist_ok=True)
        demo_dir.mkdir(parents=True, exist_ok=True)

        (self.root / "sub.c").write_text("int sub(void) { return 3; }\n")
        subprocess.run(
            [GCC, "-shared", "-fPIC", "-o", str(sub_dir / "libsub.so"), str(self.root / "sub.c")],
            check=True,
        )

        (self.root / "demo.c").write_text("int sub(void);\nint demo(void) { return 4 + sub(); }\n")
        subprocess.run(
            [
                GCC,
                "-shared",
                "-fPIC",
                "-o",
                str(demo_dir / "libdemo.so"),
                str(self.root / "demo.c"),
                f"-L{sub_dir}",
                "-lsub",
                f"-Wl,-rpath,{sub_dir}",
                *lib_flags,
            ],
            check=True,
        )

        prog = self.program(demo_dir, f"-Wl,-rpath,{demo_dir}", "-Wl,--disable-new-dtags")
        if drop_sub:
            (sub_dir / "libsub.so").unlink()
        return prog, demo_dir / "libdemo.so", sub_dir / "libsub.so"

    def test_default_check_bytes_unchanged_with_transitive_dependencies(self):
        prog, _, _ = self._build_transitive_chain(lib_flags=("-Wl,--enable-new-dtags",), drop_sub=True)

        raw = subprocess.run(
            [binary.BIN, "check", str(prog)],
            env=dict(self.env, EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4"),
            capture_output=True,
            text=False,
        )
        self.assertEqual(raw.returncode, 0, raw.stderr)
        self.assertEqual(raw.stderr, b"")
        self.assertTrue(raw.stdout.endswith(b"eb-local check: no problems\n"))
        self.assertNotIn(b"libsub.so", raw.stdout)

        quiet = subprocess.run(
            [binary.BIN, "check", "--quiet", str(prog)],
            env=dict(self.env, EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4"),
            capture_output=True,
            text=False,
        )
        self.assertEqual((quiet.returncode, quiet.stdout, quiet.stderr), (0, b"eb-local check: no problems\n", b""))

    def test_recursive_catches_transitive_runpath_and_missing_library(self):
        prog, libdemo, _ = self._build_transitive_chain(lib_flags=("-Wl,--enable-new-dtags",), drop_sub=True)

        default_run = self.check(prog, EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4")
        self.assertEqual(default_run.returncode, 0, default_run.stdout + default_run.stderr)

        rec = self.check("--recursive", prog, EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4")
        self.assertEqual(rec.returncode, 1, rec.stdout + rec.stderr)
        self.assertIn(str(libdemo), rec.stdout)
        self.assertIn("RUNPATH", rec.stdout)
        self.assertIn("libsub.so is not found", rec.stdout)

        quiet = self.check("--recursive", "--quiet", prog, EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4")
        self.assertEqual(quiet.returncode, 1, quiet.stdout + quiet.stderr)
        self.assertNotIn(str(prog), quiet.stdout)
        self.assertIn(str(libdemo), quiet.stdout)
        self.assertIn("problem:", quiet.stdout)

    def test_recursive_handles_cycles_and_symlinks_without_repeating(self):
        cyc_dir = self.root / "cycle"
        cyc_dir.mkdir()
        (self.root / "a.c").write_text("int b_fn(void);\nint a_fn(void) { return 1 + b_fn(); }\n")
        (self.root / "b.c").write_text("int a_fn(void);\nint b_fn(void) { return 2; }\n")

        subprocess.run(
            [GCC, "-shared", "-fPIC", "-Wl,-soname,libb.so", "-o", str(cyc_dir / "libb.so"), str(self.root / "b.c")],
            check=True,
        )
        subprocess.run(
            [
                GCC,
                "-shared",
                "-fPIC",
                "-Wl,-soname,liba.so.1",
                "-o",
                str(cyc_dir / "liba.so.1.0"),
                str(self.root / "a.c"),
                f"-L{cyc_dir}",
                "-lb",
                f"-Wl,-rpath,{cyc_dir}",
                "-Wl,--disable-new-dtags",
            ],
            check=True,
        )
        (cyc_dir / "liba.so.1").symlink_to("liba.so.1.0")
        (cyc_dir / "liba.so").symlink_to("liba.so.1")
        subprocess.run(
            [
                GCC,
                "-shared",
                "-fPIC",
                "-Wl,-soname,libb.so",
                "-o",
                str(cyc_dir / "libb.so"),
                str(self.root / "b.c"),
                f"-L{cyc_dir}",
                "-la",
                f"-Wl,-rpath,{cyc_dir}",
                "-Wl,--disable-new-dtags",
            ],
            check=True,
        )

        (self.root / "main_cyc.c").write_text("int a_fn(void);\nint main(void) { return a_fn() == 3 ? 0 : 1; }\n")
        prog = self.root / "prog_cyc"
        subprocess.run(
            [
                GCC,
                "-o",
                str(prog),
                str(self.root / "main_cyc.c"),
                f"-L{cyc_dir}",
                "-la",
                f"-Wl,-rpath,{cyc_dir}",
                "-Wl,--disable-new-dtags",
            ],
            check=True,
        )

        run = self.check("--recursive", "--quiet", "--json", prog, EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        doc = json.loads(run.stdout)
        validate(doc, load_schema("check.schema.json"))
        self.assertEqual(doc["problem_count"], 0)
        paths = [f["path"] for f in doc["files"]]
        self.assertEqual(len(paths), len(set(paths)))
        self.assertIn(str(prog), paths)
        self.assertTrue(any(p.endswith("liba.so.1") for p in paths), paths)
        self.assertIn(str(cyc_dir / "libb.so"), paths)

    def test_recursive_with_prefix_and_json(self):
        prog, libdemo, libsub = self._build_transitive_chain()
        tree = self.root / "prefix-tree"
        (tree / "bin").mkdir(parents=True)
        (tree / "bin" / "prog").write_bytes(prog.read_bytes())

        run = self.check("--prefix", tree, "--recursive", "--json", EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        doc = json.loads(run.stdout.splitlines()[-1])
        validate(doc, load_schema("check.schema.json"))
        paths = [f["path"] for f in doc["files"]]
        self.assertEqual(paths.count(str(tree / "bin" / "prog")), 1)
        self.assertEqual(paths.count(str(libdemo)), 1)
        self.assertEqual(paths.count(str(libsub)), 1)
        self.assertEqual(doc["elf_count"], len(paths))

        # Also when a needed library lives inside the audited prefix tree, audit it once.
        (tree / "lib").mkdir()
        (tree / "lib" / "libdemo.so").write_bytes(libdemo.read_bytes())
        (self.root / "local_prog.c").write_text("int demo(void);\nint main(void) { return demo() == 7 ? 0 : 1; }\n")
        subprocess.run(
            [
                GCC,
                "-o",
                str(tree / "bin" / "local_prog"),
                str(self.root / "local_prog.c"),
                f"-L{tree / 'lib'}",
                "-ldemo",
                f"-Wl,-rpath,{tree / 'lib'}",
                "-Wl,--disable-new-dtags",
            ],
            check=True,
        )
        run2 = self.check("--prefix", tree, "--recursive", "--quiet", "--json", EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4")
        self.assertEqual(run2.returncode, 0, run2.stdout + run2.stderr)
        doc2 = json.loads(run2.stdout)
        validate(doc2, load_schema("check.schema.json"))
        paths2 = [f["path"] for f in doc2["files"]]
        self.assertEqual(paths2.count(str(tree / "lib" / "libdemo.so")), 1)
        self.assertEqual(doc2["elf_count"], len(paths2))

    def test_compat_ld_so_conf_resolves_relative_and_root_includes_under_loader_root(self):
        compat = self.root / "compat"
        (compat / "etc" / "ld.so.conf.d").mkdir(parents=True)
        (compat / "etc" / "extra.conf.d").mkdir(parents=True)
        custom_rel = compat / "custom-rel" / "lib"
        custom_abs = compat / "custom-abs" / "lib"
        custom_rel.mkdir(parents=True)
        custom_abs.mkdir(parents=True)

        (self.root / "demo.c").write_text("int demo(void) { return 7; }\n")
        (self.root / "extra.c").write_text("int extra(void) { return 5; }\n")
        subprocess.run(
            [GCC, "-shared", "-fPIC", "-nostdlib", "-o", str(custom_rel / "libdemo.so"), str(self.root / "demo.c")],
            check=True,
        )
        subprocess.run(
            [GCC, "-shared", "-fPIC", "-nostdlib", "-o", str(custom_abs / "libextra.so"), str(self.root / "extra.c")],
            check=True,
        )

        (compat / "etc" / "ld.so.conf").write_text(
            "include ld.so.conf.d/*.conf\ninclude /etc/extra.conf.d/*.conf\n",
            encoding="utf-8",
        )
        (compat / "etc" / "ld.so.conf.d" / "rel.conf").write_text(f"{custom_rel}\n", encoding="utf-8")
        (compat / "etc" / "extra.conf.d" / "abs.conf").write_text(f"{custom_abs}\n", encoding="utf-8")

        (self.root / "compat_prog.c").write_text(
            "int demo(void);\nint extra(void);\nvoid _start(void) { (void)demo(); (void)extra(); }\n"
        )
        prog = self.root / "compat_prog"
        interp = compat / "lib64" / "ld-linux-x86-64.so.2"
        subprocess.run(
            [
                GCC,
                "-nostdlib",
                "-e",
                "_start",
                "-o",
                str(prog),
                str(self.root / "compat_prog.c"),
                f"-L{custom_rel}",
                "-ldemo",
                f"-L{custom_abs}",
                "-lextra",
                f"-Wl,--dynamic-linker={interp}",
            ],
            check=True,
        )
        run = self.check(prog)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn(f"libdemo.so => {custom_rel}/libdemo.so   [the loader's directories]", run.stdout)
        self.assertIn(f"libextra.so => {custom_abs}/libextra.so   [the loader's directories]", run.stdout)

    def test_duplicate_file_arguments_are_checked_once(self):
        lib = self.tree("x86_64/amd/zen4")
        prog = self.program(lib, f"-Wl,-rpath,{lib}", "-Wl,--enable-new-dtags")
        link = self.root / "prog-link"
        link.symlink_to(prog)

        plain = self.check(prog, prog, "--quiet", "--json", EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4")
        self.assertEqual(plain.returncode, 1, plain.stdout + plain.stderr)
        doc_plain = json.loads(plain.stdout.splitlines()[-1])
        self.assertEqual(doc_plain["elf_count"], 1, doc_plain)
        self.assertEqual(len(doc_plain["files"]), 1, doc_plain)
        self.assertEqual(doc_plain["problem_count"], 1, doc_plain)

        rec = self.check("--recursive", prog, link, "--quiet", "--json", EESSI_SOFTWARE_SUBDIR="x86_64/amd/zen4")
        self.assertEqual(rec.returncode, 1, rec.stdout + rec.stderr)
        doc_rec = json.loads(rec.stdout.splitlines()[-1])
        paths = [f["path"] for f in doc_rec["files"]]
        self.assertEqual(len(paths), len(set(paths)), doc_rec)
        self.assertNotIn(str(link), paths)
        self.assertEqual(doc_rec["elf_count"], len(paths), doc_rec)
        self.assertEqual(doc_rec["problem_count"], 1, doc_rec)


if __name__ == "__main__":
    unittest.main()
