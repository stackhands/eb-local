#!/usr/bin/env python3
"""Black-box CLI behavior tests for `eb-local rpath-wrappers`."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary
import hostile_fs


@unittest.skipUnless(binary.ZIG, "rpath-wrappers is a feature of the Zig build")
class RpathWrappersCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-rpath-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.home = self.root / "home"
        self.cache = self.root / "cache"
        self.home.mkdir()
        self.cache.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.lld_bin = self.root / "lld-bin"
        self.lld_bin.mkdir()
        self.log = self.root / "calls.log"
        for directory, tools in (
            (self.bin, ("gcc", "clang", "ld", "icx", "ifx")),
            (self.lld_bin, ("ld.lld",)),
        ):
            for tool in tools:
                p = directory / tool
                p.write_text(
                    "#!/bin/sh\n"
                    f'printf "%s:%s\\n" "{tool}" "$*" >> "{self.log}"\n',
                    encoding="utf-8",
                )
                p.chmod(0o755)

    def run_cmd(self, args, **env_overrides):
        env = {
            "PATH": str(self.bin),
            "HOME": str(self.home),
            "XDG_CACHE_HOME": str(self.cache),
        }
        env.update(env_overrides)
        return subprocess.run(
            [binary.ZIG, "rpath-wrappers", *args],
            env=env,
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def test_rejects_mutually_exclusive_and_invalid_for_flags_with_exit_two(self):
        both = self.run_cmd(["--for", "gcc", "--unwrapped"])
        self.assertEqual(both.returncode, 2, both.stdout + both.stderr)
        self.assertEqual(both.stdout, "")
        self.assertIn("takes --for FAMILY or --unwrapped, not both", both.stderr)

        bad_fam = self.run_cmd(["--for", "gcc-15"])
        self.assertEqual(bad_fam.returncode, 2, bad_fam.stdout + bad_fam.stderr)
        self.assertEqual(bad_fam.stdout, "")
        self.assertIn("--for takes a compiler family name", bad_fam.stderr)

    def test_requires_absolute_cache_home_or_home(self):
        for env in (
            {"XDG_CACHE_HOME": "", "HOME": ""},
            {"XDG_CACHE_HOME": "relative/cache", "HOME": str(self.home)},
            {"XDG_CACHE_HOME": "", "HOME": "relative/home"},
        ):
            with self.subTest(env=env):
                got = self.run_cmd(["--for", "gcc"], **env)
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")
                self.assertIn("needs an absolute XDG_CACHE_HOME or HOME", got.stderr)

    def test_for_exits_one_when_no_compilers_on_path(self):
        empty = self.root / "empty-bin"
        empty.mkdir()
        got = self.run_cmd(["--for", "gcc"], PATH=str(empty))
        self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
        self.assertEqual(got.stdout, "")
        self.assertIn("no compiler or linker on PATH to wrap", got.stderr)

    def test_generated_wrappers_bypass_help_equals_queries(self):
        got = self.run_cmd(["--for", "gcc"])
        self.assertEqual(got.returncode, 0, got.stderr)
        script = got.stdout + "gcc --help=target\n" + "gcc -o prog a.o\n"
        run = subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", "-c", script],
            env={"PATH": f"{self.bin}:/usr/bin:/bin", "LIBRARY_PATH": "/opt/mylib"},
            cwd=self.root,
            capture_output=True,
            text=True,
        )
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(
            self.log.read_text(encoding="utf-8").splitlines(),
            [
                "gcc:--help=target",
                "gcc:-o prog a.o -Wl,-rpath,/opt/mylib -Wl,--disable-new-dtags",
            ],
        )

    def test_unwrapped_skips_easybuild_wrapped_compilers_and_wraps_bare_clang(self):
        eb_wrap = self.root / "eb" / "rpath_wrappers" / "clang_wrapper"
        eb_wrap.mkdir(parents=True)
        (eb_wrap / "clang").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        (eb_wrap / "clang").chmod(0o755)

        already = self.run_cmd(["--unwrapped"], PATH=f"{eb_wrap}:{self.bin}")
        self.assertEqual(already.returncode, 0, already.stderr)
        self.assertEqual(already.stdout, "")
        self.assertEqual(already.stderr, "")

        bare = self.run_cmd(["--unwrapped"], PATH=str(self.bin))
        self.assertEqual(bare.returncode, 0, bare.stderr)
        self.assertIn("does not wrap clang", bare.stderr)
        self.assertIn("export PATH=", bare.stdout)
        self.assertIn("export EB_LOCAL_RPATH_WRAPPERS=", bare.stdout)

    def test_wrappers_bypass_llvm_intel_nonlinking_flags(self):
        llvm_got = self.run_cmd(["--for", "llvm"], PATH=f"{self.lld_bin}:{self.bin}")
        self.assertEqual(llvm_got.returncode, 0, llvm_got.stderr)
        intel_got = self.run_cmd(["--for", "intel"])
        self.assertEqual(intel_got.returncode, 0, intel_got.stderr)

        nonlinking = [
            ("clang", ["-help"]),
            ("clang", ["--help-hidden"]),
            ("clang", ["--help-list"]),
            ("clang", ["--help-list-hidden"]),
            ("clang", ["-version"]),
            ("clang", ["--version"]),
            ("clang", ["-qversion"]),
            ("clang", ["-dumpversion"]),
            ("clang", ["-dumpfullversion"]),
            ("clang", ["--target=x86_64-linux-gnu", "-dumpmachine"]),
            ("clang", ["-print-resource-dir"]),
            ("clang", ["--target=x86_64-linux-gnu", "--print-resource-dir"]),
            ("clang", ["-###"]),
            ("clang", ["--analyze", "foo.c"]),
            ("clang", ["--precompile", "foo.hpp"]),
            ("clang", ["--preprocess", "foo.c"]),
            ("clang", ["-emit-ast", "foo.c"]),
            ("clang", ["-emit-pch", "foo.h"]),
            ("clang", ["-v"]),
            ("ld.lld", ["-help"]),
            ("ld.lld", ["--help-hidden"]),
            ("ld.lld", ["--help-list"]),
            ("ld.lld", ["--help-list-hidden"]),
            ("ld.lld", ["-version"]),
            ("ld.lld", ["--version"]),
            ("icx", ["-help"]),
            ("icx", ["--help-hidden"]),
            ("icx", ["-version"]),
            ("icx", ["--version"]),
            ("icx", ["-qversion"]),
            ("icx", ["-dumpversion"]),
            ("icx", ["-dumpmachine"]),
            ("icx", ["--analyze", "foo.c"]),
            ("icx", ["--precompile", "foo.hpp"]),
            ("icx", ["--preprocess", "foo.c"]),
            ("icx", ["-emit-ast", "foo.c"]),
            ("icx", ["-emit-pch", "foo.h"]),
            ("ifx", ["-help"]),
            ("ifx", ["--help-hidden"]),
            ("ifx", ["-version"]),
            ("ifx", ["--version"]),
            ("ifx", ["-dumpversion"]),
            ("ifx", ["--preprocess", "foo.F90"]),
        ]
        script = llvm_got.stdout + intel_got.stdout
        expected = []
        for tool, args in nonlinking:
            script += f"{tool} {' '.join(args)}\n"
            expected.append(f"{tool}:{' '.join(args)}")
        script += "clang -o prog a.o\nclang -v foo.o -o prog2\n"
        expected.extend([
            "clang:-o prog a.o -Wl,-rpath,/opt/mylib -Wl,--disable-new-dtags",
            "clang:-v foo.o -o prog2 -Wl,-rpath,/opt/mylib -Wl,--disable-new-dtags",
        ])

        run = subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", "-c", script],
            env={
                "PATH": f"{self.lld_bin}:{self.bin}:/usr/bin:/bin",
                "LIBRARY_PATH": "/opt/mylib",
            },
            cwd=self.root,
            capture_output=True,
            text=True,
        )
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        lines = self.log.read_text(encoding="utf-8").splitlines()
        self.assertEqual(lines, expected)
        for line in lines[:-2]:
            self.assertNotIn("-rpath", line)
            self.assertNotIn("--disable-new-dtags", line)

    def test_generated_wrappers_skip_non_linking_flags_and_accept_library_path_flag(self):
        got = self.run_cmd(["--for", "llvm"])
        self.assertEqual(got.returncode, 0, got.stderr)
        script = (
            got.stdout
            + "clang -E foo.c\n"
            + "clang -S foo.c\n"
            + "clang -M foo.c\n"
            + "clang -MM foo.c\n"
            + "clang -fsyntax-only foo.c\n"
            + "ld --relocatable a.o -o b.o\n"
            + "ld -Ur a.o -o b.o\n"
            + "ld -i a.o -o b.o\n"
            + "clang --library-path=/opt/x/lib --library-path /opt/y/lib a.o -o prog\n"
        )
        run = subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", "-c", script],
            env={"PATH": f"{self.bin}:/usr/bin:/bin"},
            cwd=self.root,
            capture_output=True,
            text=True,
        )
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        lines = self.log.read_text(encoding="utf-8").splitlines()
        self.assertEqual(
            lines,
            [
                "clang:-E foo.c",
                "clang:-S foo.c",
                "clang:-M foo.c",
                "clang:-MM foo.c",
                "clang:-fsyntax-only foo.c",
                "ld:--relocatable a.o -o b.o",
                "ld:-Ur a.o -o b.o",
                "ld:-i a.o -o b.o",
                "clang:--library-path=/opt/x/lib --library-path /opt/y/lib a.o -o prog"
                " -Wl,-rpath,/opt/x/lib -Wl,-rpath,/opt/y/lib -Wl,--disable-new-dtags",
            ],
        )

    def test_response_files_and_libraries_named_by_path_get_run_paths(self):
        got = self.run_cmd(["--for", "gcc"])
        self.assertEqual(got.returncode, 0, got.stderr)
        libs = self.root / "libs"
        (libs / "a").mkdir(parents=True)
        (libs / "b").mkdir()
        (libs / "c").mkdir()
        (libs / "b" / "libfoo.so.3").write_text("", encoding="utf-8")
        (libs / "c" / "libbar.so").write_text("", encoding="utf-8")
        # Meson and CMake put a long link line in a response file, quoted
        # as a shell would quote it.
        (self.root / "link.rsp").write_text(
            f'-L{libs}/a main.o {libs}/b/libfoo.so.3 -o "prog one"\n',
            encoding="utf-8",
        )
        (self.root / "compile.rsp").write_text("-c foo.c -o foo.o\n", encoding="utf-8")
        script = (
            got.stdout
            + "gcc @link.rsp\n"
            + "gcc @compile.rsp\n"
            + f"gcc main.o {libs}/c/libbar.so -o two\n"
            + f"gcc main.o {libs}/c/libnone.so -o three\n"
        )
        run = subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", "-c", script],
            env={"PATH": f"{self.bin}:/usr/bin:/bin"},
            cwd=self.root,
            capture_output=True,
            text=True,
        )
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        lines = self.log.read_text(encoding="utf-8").splitlines()
        self.assertEqual(
            lines,
            [
                f"gcc:@link.rsp -Wl,-rpath,{libs}/a -Wl,-rpath,{libs}/b -Wl,--disable-new-dtags",
                # A compile in a response file is not a link.
                "gcc:@compile.rsp",
                f"gcc:main.o {libs}/c/libbar.so -o two -Wl,-rpath,{libs}/c -Wl,--disable-new-dtags",
                # A path that names no file adds nothing.
                f"gcc:main.o {libs}/c/libnone.so -o three -Wl,--disable-new-dtags",
            ],
        )

    def test_hostile_wrapper_destinations_exit_two(self):
        ro_cache = self.root / "ro-cache"
        (ro_cache / "eb-local").mkdir(parents=True)
        with hostile_fs.readonly_dir(ro_cache / "eb-local"):
            ro_got = self.run_cmd(["--for", "gcc"], XDG_CACHE_HOME=str(ro_cache))
            self.assertEqual(ro_got.returncode, 2, ro_got.stdout + ro_got.stderr)
            self.assertEqual(ro_got.stdout, "")
            self.assertIn("Permission denied", ro_got.stderr)

        ok = self.run_cmd(["--for", "gcc"])
        self.assertEqual(ok.returncode, 0, ok.stderr)
        wrap_dir = Path(ok.stdout.splitlines()[1].split("=", 1)[1])

        (wrap_dir / "gcc").unlink()
        (wrap_dir / "gcc").mkdir()
        dir_got = self.run_cmd(["--for", "gcc"])
        self.assertEqual(dir_got.returncode, 2, dir_got.stdout + dir_got.stderr)
        self.assertEqual(dir_got.stdout, "")
        self.assertIn("Unsafe", dir_got.stderr)
        (wrap_dir / "gcc").rmdir()

        link, outside = hostile_fs.dangling_symlink(wrap_dir / "gcc", self.root / "outside-gcc")
        sym_got = self.run_cmd(["--for", "gcc"])
        self.assertEqual(sym_got.returncode, 2, sym_got.stdout + sym_got.stderr)
        self.assertEqual(sym_got.stdout, "")
        self.assertIn("Unsafe", sym_got.stderr)
        self.assertTrue(link.is_symlink())
        self.assertFalse(outside.exists())

    def _run_wrapper(self, setup_stdout, path, cwd):
        script = setup_stdout + "gcc -c foo.c\n"
        return subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", "-c", script],
            env={"PATH": path, "LC_ALL": "C.UTF-8", "LANG": "C.UTF-8"},
            cwd=cwd,
            capture_output=True,
            text=True,
        )

    def test_an_empty_path_entry_is_the_current_directory(self):
        got = self.run_cmd(["--for", "gcc"])
        self.assertEqual(got.returncode, 0, got.stderr)
        cwd_gcc = self.root / "gcc"
        cwd_gcc.write_text("#!/bin/sh\nprintf 'from-cwd\\n'\n", encoding="utf-8")
        cwd_gcc.chmod(0o755)

        # A trailing colon is an empty entry after every other directory.
        trailing = self._run_wrapper(got.stdout, "", self.root)
        self.assertEqual(trailing.returncode, 0, trailing.stdout + trailing.stderr)
        self.assertEqual(trailing.stdout, "from-cwd\n")
        self.assertEqual(trailing.stderr, "")

        # An empty entry in the middle is the current directory, and it wins
        # over a later directory that also has gcc.
        self.log.write_text("", encoding="utf-8")
        middle = self._run_wrapper(got.stdout, f":{self.bin}", self.root)
        self.assertEqual(middle.returncode, 0, middle.stdout + middle.stderr)
        self.assertEqual(middle.stdout, "from-cwd\n")
        self.assertEqual(middle.stderr, "")
        self.assertEqual(self.log.read_text(encoding="utf-8"), "")

    def test_tmpfs_enospc_exits_two_and_cleans_wrapper_tree(self):
        mnt = hostile_fs.enter_full_tmpfs(self)
        if mnt is None:
            return
        got = self.run_cmd(["--for", "gcc"], XDG_CACHE_HOME=str(mnt))
        self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
        self.assertEqual(got.stdout, "")
        self.assertIn("cannot write RPATH wrappers", got.stderr)


if __name__ == "__main__":
    unittest.main()
