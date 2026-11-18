#!/usr/bin/env python3
"""Black-box CLI behavior tests for `eb-local rpath-wrappers`."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary


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
        self.log = self.root / "calls.log"
        for tool in ("gcc", "clang", "ld"):
            p = self.bin / tool
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


if __name__ == "__main__":
    unittest.main()
