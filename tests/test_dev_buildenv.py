#!/usr/bin/env python3
"""dev picks the build environment for the compilers the modules bring in,
and falls back to RPATH wrappers when none is installed. Zig build only.

The module double records each call, sets the EBROOT variable a compiler
module would set, and answers is-avail from CONTROL_AVAILABLE. The fake
compiler records its arguments; one test links with the host's gcc and
reads the result with readelf.
"""
import os
from pathlib import Path
import shutil
import subprocess
import unittest

import binary
from test_storage import StorageFixture

MODULE = r'''
module() {
    printf '%s\n' "$*" >> "$CONTROL_ROOT/module-calls"
    case "$1" in
        load)
            shift
            for m in "$@"; do
                case $m in
                    llvm-compilers/*) export EBROOTLLVMMINCOMPILERS=/eessi/llvm ;;
                    intel-compilers/*) export EBROOTINTELMINCOMPILERS=/eessi/intel ;;
                    CUDA/*) export EBROOTCUDA=/eessi/cuda ;;
                    NVHPC/*) export EBROOTNVHPC=/eessi/nvhpc ;;
                esac
            done ;;
        is-avail) case " ${CONTROL_AVAILABLE-} " in *" $2 "*) return 0 ;; esac; return 1 ;;
    esac
}
'''

BASH = shutil.which("bash")

FAKE_CC = r'''#!/bin/sh
printf '%s\n' "$*" >> "$CONTROL_ROOT/cc-calls"
'''


@unittest.skipUnless(binary.BIN, "compiler-family selection is a feature of the Zig build")
class DevBuildenv(StorageFixture):
    def setUp(self):
        super().setUp()
        self.prefix.mkdir(parents=True)
        self.bin = self.root / "compilers"
        self.bin.mkdir()
        for name in ("clang", "ld"):
            (self.bin / name).write_text(FAKE_CC)
            (self.bin / name).chmod(0o755)
        # Only the fake compilers, so the host's are not wrapped too.
        self.env.update(XDG_CACHE_HOME=str(self.root / "cache"), SLURM_JOB_ID="", PATH=str(self.bin))
        self.env.pop("LIBRARY_PATH", None)
        self.env.pop("EESSI_EPREFIX", None)

    def dev(self, *modules, after="", **extra):
        run = self.run_wrapper(["dev", *modules], **extra)
        self.assertEqual(run.returncode, 0, run.stderr)
        script = self.root / "replay.sh"
        script.write_text(MODULE + run.stdout + after)
        replay = subprocess.run([BASH, str(script)], env=dict(self.env, **extra), cwd=self.root,
                                text=True, capture_output=True)
        self.assertEqual(replay.returncode, 0, replay.stdout + replay.stderr)
        calls = (self.root / "module-calls").read_text().splitlines()
        return calls, replay

    def test_gcc_modules_load_the_configured_buildenv_as_before(self):
        calls, _ = self.dev("GSL/2.8-GCC-15.2.0")
        self.assertEqual(calls[-2:], ["load GSL/2.8-GCC-15.2.0", "load buildenv/default-foss-2026.1"])

    def test_the_family_buildenv_when_lmod_has_it(self):
        calls, _ = self.dev("llvm-compilers/21.1.8", CONTROL_AVAILABLE="buildenv/default-lfoss-2026.1")
        self.assertEqual(calls[-2:], ["is-avail buildenv/default-lfoss-2026.1", "load buildenv/default-lfoss-2026.1"])

    def test_cuda_without_its_buildenv_uses_the_gcc_one(self):
        calls, _ = self.dev("CUDA/13.3.0")
        self.assertEqual(calls[-2:], ["is-avail buildenv/default-foss-2026.1-CUDA-13.3.0",
                                      "load buildenv/default-foss-2026.1"])

    def test_a_family_without_a_buildenv_gets_rpath_wrappers(self):
        after = ('printf "%s" "$EB_LOCAL_RPATH_WRAPPERS" > "$CONTROL_ROOT/wrappers"\n'
                 'clang -c a.c -o a.o\n'
                 'clang a.o -o prog -L/opt/foo/lib -L/usr/lib64 -Lrelative\n'
                 'ld -r a.o -o b.o\n'
                 'ld a.o -L /opt/bar/lib -o prog\n'
                 'clang --version\n')
        calls, replay = self.dev("llvm-compilers/21.1.8", after=after,
                                 LIBRARY_PATH="/eessi/fftw/lib:/compat/usr/lib64:/opt/foo/lib:",
                                 EESSI_EPREFIX="/compat")
        self.assertEqual(calls[-1], "is-avail buildenv/default-lfoss-2026.1")
        self.assertIn("no build environment module for the llvm compilers", replay.stderr)
        wrappers = Path((self.root / "wrappers").read_text())
        self.assertEqual(wrappers.parent, self.root / "cache" / "eb-local")
        self.assertEqual(oct(wrappers.stat().st_mode & 0o777), "0o700")
        self.assertEqual(sorted(p.name for p in wrappers.iterdir()), [".eb-local-rpath", "clang", "ld"])
        self.assertEqual((self.root / "cc-calls").read_text().splitlines(), [
            "-c a.c -o a.o",
            "a.o -o prog -L/opt/foo/lib -L/usr/lib64 -Lrelative"
            " -Wl,-rpath,/opt/foo/lib -Wl,-rpath,/eessi/fftw/lib -Wl,--disable-new-dtags",
            "-r a.o -o b.o",
            "a.o -L /opt/bar/lib -o prog -rpath /opt/bar/lib --disable-new-dtags",
            "--version",
        ])

    def test_nvhpc_has_no_default_buildenv_and_asks_lmod_nothing(self):
        calls, replay = self.dev("NVHPC/26.7")
        self.assertEqual(calls[-1], "load NVHPC/26.7")
        self.assertIn("RPATH wrappers for clang ld", replay.stderr)

    def test_a_later_dev_drops_the_previous_rpath_wrappers(self):
        first = self.run_wrapper(["dev", "NVHPC/26.7"])
        self.assertEqual(first.returncode, 0, first.stderr)
        second = self.run_wrapper(["dev", "GSL/2.8-GCC-15.2.0"])
        self.assertEqual(second.returncode, 0, second.stderr)
        script = self.root / "replay.sh"
        script.write_text(
            MODULE + first.stdout
            + 'printf %s "$EB_LOCAL_RPATH_WRAPPERS" > "$CONTROL_ROOT/wrap1"\n'
            + 'printf %s "$PATH" > "$CONTROL_ROOT/path1"\n'
            # The NVHPC module left EBROOTNVHPC set. Unloading it, as a later
            # dev of a GCC module does in a real Lmod session, must not leave
            # the wrappers in front of the build environment.
            + 'unset EBROOTNVHPC\n'
            + second.stdout
            + 'printf %s "${EB_LOCAL_RPATH_WRAPPERS-unset}" > "$CONTROL_ROOT/wrap2"\n'
            + 'printf %s "$PATH" > "$CONTROL_ROOT/path2"\n'
            + 'command -v ld > "$CONTROL_ROOT/ld"\n'
        )
        replay = subprocess.run([BASH, str(script)], env=self.env, cwd=self.root, text=True, capture_output=True)
        self.assertEqual(replay.returncode, 0, replay.stdout + replay.stderr)
        wrap = Path((self.root / "wrap1").read_text())
        self.assertTrue(wrap.is_dir(), wrap)
        self.assertTrue((self.root / "path1").read_text().startswith(str(wrap) + ":"))
        path2 = (self.root / "path2").read_text()
        self.assertNotIn(str(wrap), path2)
        self.assertEqual((self.root / "ld").read_text().strip(), str(self.bin / "ld"))
        # The GCC build environment does not wrap clang, so it alone gets a wrapper.
        wrap2 = Path((self.root / "wrap2").read_text())
        self.assertEqual(sorted(p.name for p in wrap2.iterdir()), [".eb-local-rpath", "clang"])

    def test_the_llvm_modules_clang_gets_a_wrapper_beside_the_gcc_buildenv(self):
        # The LLVM module sets EBROOTLLVM, not EBROOTLLVMMINCOMPILERS, so dev
        # loads the GCC build environment, which wraps gcc and ld, not clang.
        after = ('printf "%s" "$EB_LOCAL_RPATH_WRAPPERS" > "$CONTROL_ROOT/wrappers"\n'
                 'clang a.o -o prog -lgsl\n'
                 'ld a.o -o prog\n')
        calls, replay = self.dev("GSL/2.8-GCC-15.2.0", "LLVM/21.1.8-GCCcore-15.2.0", after=after,
                                 LIBRARY_PATH="/eessi/gsl/lib")
        self.assertEqual(calls[-2:], ["load GSL/2.8-GCC-15.2.0 LLVM/21.1.8-GCCcore-15.2.0",
                                      "load buildenv/default-foss-2026.1"])
        self.assertIn("eb-local: the build environment does not wrap clang;\n"
                      "  RPATH wrappers for it come first", replay.stderr)
        wrappers = Path((self.root / "wrappers").read_text())
        self.assertEqual(sorted(p.name for p in wrappers.iterdir()), [".eb-local-rpath", "clang"])
        self.assertEqual((self.root / "cc-calls").read_text().splitlines(), [
            "a.o -o prog -lgsl -Wl,-rpath,/eessi/gsl/lib -Wl,--disable-new-dtags",
            "a.o -o prog",
        ])

    def test_a_compiler_the_build_environment_wraps_is_left_to_it(self):
        ours = self.root / "buildenv" / "bin" / "rpath_wrappers" / "clang_wrapper"
        ours.mkdir(parents=True)
        (ours / "clang").write_text(FAKE_CC)
        (ours / "clang").chmod(0o755)
        after = 'printf "%s" "${EB_LOCAL_RPATH_WRAPPERS-unset}" > "$CONTROL_ROOT/wrappers"\n'
        _, replay = self.dev("llvm-compilers/21.1.8", after=after, PATH=f"{ours}:{self.bin}",
                             CONTROL_AVAILABLE="buildenv/default-lfoss-2026.1")
        self.assertEqual((self.root / "wrappers").read_text(), "unset")
        self.assertEqual(replay.stderr, "")

    def test_without_clang_a_gcc_dev_adds_no_wrappers(self):
        gcc_only = self.root / "gcc-only"
        gcc_only.mkdir()
        for name in ("gcc", "ld"):
            (gcc_only / name).write_text(FAKE_CC)
            (gcc_only / name).chmod(0o755)
        after = 'printf "%s" "${EB_LOCAL_RPATH_WRAPPERS-unset}" > "$CONTROL_ROOT/wrappers"\n'
        calls, replay = self.dev("GSL/2.8-GCC-15.2.0", after=after, PATH=str(gcc_only))
        self.assertEqual(calls[-1], "load buildenv/default-foss-2026.1")
        self.assertEqual((self.root / "wrappers").read_text(), "unset")
        self.assertEqual(replay.stderr, "")

    def test_a_chosen_buildenv_is_loaded_whatever_the_compilers(self):
        calls, _ = self.dev("llvm-compilers/21.1.8", "--buildenv", "buildenv/site-llvm")
        self.assertEqual(calls[-1], "load buildenv/site-llvm")

    def test_a_buildenv_named_among_the_modules_stays_there(self):
        # Only a chosen build environment is sure to come last; the GCC one
        # is not loaded for LLVM compilers unless it stays among the modules.
        calls, _ = self.dev("buildenv/default-foss-2026.1", "llvm-compilers/21.1.8",
                            CONTROL_AVAILABLE="buildenv/default-lfoss-2026.1")
        self.assertEqual(calls[-3:], ["load buildenv/default-foss-2026.1 llvm-compilers/21.1.8",
                                      "is-avail buildenv/default-lfoss-2026.1",
                                      "load buildenv/default-lfoss-2026.1"])

    def test_a_site_buildenv_for_a_family(self):
        toml = self.root / "site.toml"
        toml.write_text('[storage]\nnode_local_root = "%s"\n[dev.buildenv_for]\nnvhpc = "buildenv/site-nvhpc"\n'
                        % self.nodes)
        toml.chmod(0o600)
        calls, _ = self.dev("NVHPC/26.7", EB_LOCAL_CONFIG=str(toml), CONTROL_AVAILABLE="buildenv/site-nvhpc")
        self.assertEqual(calls[-1], "load buildenv/site-nvhpc")
        run = self.run_wrapper(["config"], EB_LOCAL_CONFIG=str(toml))
        self.assertRegex(run.stdout, r"dev\.buildenv_for\.nvhpc\s+buildenv/site-nvhpc\s+\[site ")
        self.assertRegex(run.stdout, r"dev\.buildenv_for\.llvm\s+buildenv/default-lfoss-2026\.1\s+\[default\]")

    @unittest.skipUnless(shutil.which("gcc") and shutil.which("readelf"), "needs gcc and readelf")
    def test_a_real_link_through_the_wrappers_records_rpath(self):
        lib = self.root / "dep" / "lib"
        lib.mkdir(parents=True)
        (self.root / "foo.c").write_text("int foo(void) { return 42; }\n")
        (self.root / "main.c").write_text("int foo(void);\nint main(void) { return foo() == 42 ? 0 : 1; }\n")
        env = dict(os.environ, XDG_CACHE_HOME=str(self.root / "cache"))
        env.pop("LD_LIBRARY_PATH", None)
        env.pop("LIBRARY_PATH", None)
        subprocess.run(["gcc", "-shared", "-fPIC", "-o", str(lib / "libfoo.so"), str(self.root / "foo.c")],
                       check=True, cwd=self.root)
        argv, env = binary.command(self.script, ["rpath-wrappers"], env)
        run = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        build = subprocess.run(["bash", "-c", run.stdout + f'gcc main.c -L{lib} -lfoo -o prog && ./prog'],
                               env=env, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
        dyn = subprocess.run(["readelf", "-d", str(self.root / "prog")], capture_output=True, text=True).stdout
        self.assertIn(f"Library rpath: [{lib}]", dyn)
        self.assertNotIn("RUNPATH", dyn)

        compat = self.root / "compat"
        (compat / "lib").mkdir(parents=True)
        env["EESSI_EPREFIX"] = f"{compat}/"
        build2 = subprocess.run(
            ["bash", "-c", run.stdout + f'gcc main.c -L{lib}// -L{compat}/lib -lfoo -o prog2 && ./prog2'],
            env=env,
            cwd=self.root,
            capture_output=True,
            text=True,
        )
        self.assertEqual(build2.returncode, 0, build2.stdout + build2.stderr)
        dyn2 = subprocess.run(["readelf", "-d", str(self.root / "prog2")], capture_output=True, text=True).stdout
        self.assertIn(f"Library rpath: [{lib}]", dyn2)
        self.assertNotIn(str(compat), dyn2)


    def test_config_env_keeps_the_choice_by_family(self):
        run = self.run_wrapper(["config", "--env"])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertNotIn("EB_LOCAL_DEV_BUILDENV", run.stdout)
        run = self.run_wrapper(["config", "--env"], EB_LOCAL_DEV_BUILDENV_FOR_CUDA="none",
                               EB_LOCAL_DEV_BUILDENV_FOR_NVHPC="buildenv/site-nvhpc-26.7")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("export EB_LOCAL_DEV_BUILDENV_FOR_CUDA=none\n", run.stdout)
        self.assertIn("export EB_LOCAL_DEV_BUILDENV_FOR_NVHPC=buildenv/site-nvhpc-26.7\n", run.stdout)
        self.assertNotIn("EB_LOCAL_DEV_BUILDENV=", run.stdout)

if __name__ == "__main__":
    unittest.main()
