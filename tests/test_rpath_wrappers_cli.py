#!/usr/bin/env python3
"""Black-box CLI behavior tests for `eb-local rpath-wrappers`."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary
import hostile_fs


@unittest.skipUnless(binary.BIN, "rpath-wrappers is a feature of the Zig build")
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
            [binary.BIN, "rpath-wrappers", *args],
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

        script = (
            llvm_got.stdout
            + "clang --help-hidden\n"
            + "clang --target=x86_64-linux-gnu -dumpmachine\n"
            + "clang --target=x86_64-linux-gnu --print-resource-dir\n"
            + "clang --analyze foo.c\n"
            + "clang --precompile foo.hpp\n"
            + "ld.lld -version\n"
            + "ld.lld --help-hidden\n"
            + intel_got.stdout
            + "icx -help\n"
            + "ifx -help\n"
            + "clang -o prog a.o\n"
        )
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
        self.assertEqual(
            self.log.read_text(encoding="utf-8").splitlines(),
            [
                "clang:--help-hidden",
                "clang:--target=x86_64-linux-gnu -dumpmachine",
                "clang:--target=x86_64-linux-gnu --print-resource-dir",
                "clang:--analyze foo.c",
                "clang:--precompile foo.hpp",
                "ld.lld:-version",
                "ld.lld:--help-hidden",
                "icx:-help",
                "ifx:-help",
                "clang:-o prog a.o -Wl,-rpath,/opt/mylib -Wl,--disable-new-dtags",
            ],
        )

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
