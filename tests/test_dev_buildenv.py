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


@unittest.skipUnless(binary.ZIG, "compiler-family selection is a feature of the Zig build")
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

    def test_opt_in_pin_uses_only_the_compatibility_python(self):
        compat = self.root / "compat"
        python = compat / "usr" / "bin" / "python3"
        python.parent.mkdir(parents=True)
        python.write_text('#!/bin/sh\nprintf compat > "$CONTROL_ROOT/python"\n')
        python.chmod(0o755)
        for name, text in {
            "python3": '#!/bin/sh\nprintf foreign > "$CONTROL_ROOT/python"\nexit 1\n',
            "gcc": "#!/bin/sh\npython3\n",
            "as": "#!/bin/sh\nexit 0\n",
        }.items():
            path = self.bin / name
            path.write_text(text)
            path.chmod(0o755)

        base = self.run_wrapper(["dev", "GSL/2.8-GCC-15.2.0"])
        self.assertEqual(base.returncode, 0, base.stderr)
        failed = subprocess.run(
            [
                BASH,
                "-c",
                MODULE
                + base.stdout
                + 'printf "%s\\n" "$(command -v ld)" "$(command -v gcc)" '
                + '"$(command -v as)" > "$CONTROL_ROOT/paths-base"\n'
                + "gcc\n",
            ],
            env=dict(self.env, EESSI_EPREFIX=str(compat), EPREFIX=str(compat)),
            cwd=self.root,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual((self.root / "python").read_text(), "foreign")

        pinned = self.run_wrapper(["dev", "GSL/2.8-GCC-15.2.0"])
        pinned_again = self.run_wrapper(["dev", "GSL/2.8-GCC-15.2.0"])
        runtime = self.root / "runtime"
        script = (
            MODULE
            + pinned.stdout
            + "gcc\n"
            + 'printf "%s\\n" "$(command -v ld)" "$(command -v gcc)" '
            + '"$(command -v as)" > "$CONTROL_ROOT/paths-pinned"\n'
            + pinned_again.stdout
            + 'printf "%s" "$PATH" > "$CONTROL_ROOT/path-after-second-dev"\n'
        )
        replay = subprocess.run(
            [BASH, "-c", script],
            env=dict(
                self.env,
                EESSI_EPREFIX=str(compat),
                EPREFIX=str(compat),
                EB_LOCAL_PIN_BUILDENV_PYTHON="1",
                XDG_RUNTIME_DIR=str(runtime),
                PATH=f"{self.bin}:/usr/bin:/bin",
            ),
            cwd=self.root,
            text=True,
            capture_output=True,
        )
        self.assertEqual(replay.returncode, 0, replay.stdout + replay.stderr)
        pin = runtime / "eb-local" / "python-pin"
        self.assertEqual(sorted(p.relative_to(runtime) for p in runtime.rglob("*")), [
            Path("eb-local"),
            Path("eb-local/python-pin"),
            Path("eb-local/python-pin/python3"),
        ])
        self.assertEqual(
            (self.root / "path-after-second-dev").read_text().split(":").count(str(pin)),
            1,
        )
        self.assertEqual((self.root / "python").read_text(), "compat")
        self.assertEqual(
            (self.root / "paths-base").read_text(),
            (self.root / "paths-pinned").read_text(),
        )

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

    def test_rpath_wrappers_ignore_repeated_slashes_in_host_and_eprefix_dirs(self):
        after = 'clang a.o -o prog -L//usr/lib64 -L/compat//usr/lib64 -L/opt//foo/lib\n'
        self.dev(
            "llvm-compilers/21.1.8",
            after=after,
            LIBRARY_PATH="/compat//usr/lib64://lib64:/eessi//fftw/lib",
            EESSI_EPREFIX="/compat//",
        )
        self.assertEqual((self.root / "cc-calls").read_text().splitlines(), [
            "a.o -o prog -L//usr/lib64 -L/compat//usr/lib64 -L/opt//foo/lib"
            " -Wl,-rpath,/opt/foo/lib -Wl,-rpath,/eessi/fftw/lib -Wl,--disable-new-dtags",
        ])

    def test_nvhpc_has_no_default_buildenv_and_asks_lmod_nothing(self):
        calls, replay = self.dev("NVHPC/26.7")
        self.assertEqual(calls[-1], "load NVHPC/26.7")
        self.assertIn("RPATH wrappers for clang ld", replay.stderr)

    def test_the_compilers_own_level_buildenv_when_the_site_installed_it(self):
        # NVHPC has no build environment by default. A site that installs one
        # at the compiler's toolchain level gets it without a site file.
        calls, replay = self.dev("NVHPC/26.9", EBVERSIONNVHPC="26.9",
                                 CONTROL_AVAILABLE="buildenv/default-NVHPC-26.9")
        self.assertEqual(calls[-2:], ["is-avail buildenv/default-NVHPC-26.9", "load buildenv/default-NVHPC-26.9"])
        self.assertNotIn("no build environment module", replay.stderr)

    def test_the_level_buildenv_comes_after_the_familys_own(self):
        # intel-compilers without the full intel toolchain installed: the
        # family's build environment is missing, the compiler's own is there.
        calls, _ = self.dev("intel-compilers/2025.3.3", EBVERSIONINTELMINCOMPILERS="2025.3.3",
                            CONTROL_AVAILABLE="buildenv/default-intel-compilers-2025.3.3")
        self.assertEqual(calls[-3:], ["is-avail buildenv/default-intel-2026.1",
                                      "is-avail buildenv/default-intel-compilers-2025.3.3",
                                      "load buildenv/default-intel-compilers-2025.3.3"])
        both, _ = self.dev("intel-compilers/2025.3.3", EBVERSIONINTELMINCOMPILERS="2025.3.3",
                           CONTROL_AVAILABLE="buildenv/default-intel-2026.1 buildenv/default-intel-compilers-2025.3.3")
        self.assertEqual(both[-2:], ["is-avail buildenv/default-intel-2026.1", "load buildenv/default-intel-2026.1"])

    def test_a_missing_level_buildenv_still_gets_rpath_wrappers(self):
        calls, replay = self.dev("NVHPC/26.9", EBVERSIONNVHPC="26.9")
        self.assertEqual(calls[-1], "is-avail buildenv/default-NVHPC-26.9")
        self.assertIn("RPATH wrappers for clang ld", replay.stderr)

    def test_a_family_set_to_none_asks_lmod_for_no_level_buildenv(self):
        calls, replay = self.dev("NVHPC/26.9", EBVERSIONNVHPC="26.9", EB_LOCAL_DEV_BUILDENV_FOR_NVHPC="none",
                                 CONTROL_AVAILABLE="buildenv/default-NVHPC-26.9")
        self.assertEqual(calls[-1], "load NVHPC/26.9")
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

    def test_a_full_path_shared_library_records_its_directory(self):
        lib = self.root / "dep" / "lib"
        lib.mkdir(parents=True)
        versioned = lib / "libfoo.so.3"
        unversioned = lib / "libbar.so"
        static = lib / "libfoo.so.a"
        (self.root / "foo.c").write_text("int foo(void) { return 42; }\n")
        (self.root / "main.c").write_text(
            "int foo(void);\nint main(void) { return foo() == 42 ? 0 : 1; }\n"
        )
        env = dict(os.environ, XDG_CACHE_HOME=str(self.root / "cache"))
        env.pop("LD_LIBRARY_PATH", None)
        env.pop("LIBRARY_PATH", None)
        subprocess.run(
            ["gcc", "-shared", "-fPIC", "-Wl,-soname,libfoo.so.3", "-o", versioned, self.root / "foo.c"],
            check=True,
            cwd=self.root,
        )
        subprocess.run(
            ["gcc", "-shared", "-fPIC", "-Wl,-soname,libbar.so", "-o", unversioned, self.root / "foo.c"],
            check=True,
            cwd=self.root,
        )
        subprocess.run(["gcc", "-c", "-o", self.root / "foo.o", self.root / "foo.c"], check=True, cwd=self.root)
        subprocess.run(["ar", "rcs", static, self.root / "foo.o"], check=True, cwd=self.root)
        argv, env = binary.command(self.script, ["rpath-wrappers"], env)
        setup = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(setup.returncode, 0, setup.stderr)
        relative = unversioned.relative_to(self.root)
        build = subprocess.run(
            [
                "bash",
                "-c",
                setup.stdout
                + f'''
set -e
gcc main.c "{versioned}" -o prog-versioned
env -u LD_LIBRARY_PATH ./prog-versioned
gcc main.c "{unversioned}" -o prog-unversioned
gcc main.c "{static}" -o prog-static
gcc main.c "{relative}" -o prog-relative
gcc main.c -L"{lib}" "{versioned}" -o prog-duplicate
''',
            ],
            env=env,
            cwd=self.root,
            capture_output=True,
            text=True,
        )
        self.assertEqual(build.returncode, 0, build.stdout + build.stderr)

        def dynamic(name):
            return subprocess.run(
                ["readelf", "-d", self.root / name],
                check=True,
                capture_output=True,
                text=True,
            ).stdout

        for name in ("prog-versioned", "prog-unversioned"):
            with self.subTest(name=name):
                dyn = dynamic(name)
                self.assertIn(f"Library rpath: [{lib}]", dyn)
                self.assertNotIn("RUNPATH", dyn)
        for name in ("prog-static", "prog-relative"):
            with self.subTest(name=name):
                dyn = dynamic(name)
                self.assertNotIn("RPATH", dyn)
                self.assertNotIn("RUNPATH", dyn)
        duplicate = dynamic("prog-duplicate")
        self.assertIn(f"Library rpath: [{lib}]", duplicate)
        self.assertEqual(duplicate.count(str(lib)), 1)

    def test_cmake_install_keeps_the_wrapper_rpath(self):
        lib = self.root / "dep" / "lib"
        search = self.root / "search" / "lib"
        source = self.root / "project"
        install = self.root / "install"
        lib.mkdir(parents=True)
        search.mkdir(parents=True)
        source.mkdir()
        shared = lib / "libfoo.so.3"
        (self.root / "foo.c").write_text("int foo(void) { return 42; }\n")
        (source / "main.c").write_text(
            "int foo(void);\nint main(void) { return foo() == 42 ? 0 : 1; }\n"
        )
        subprocess.run(
            ["gcc", "-shared", "-fPIC", "-Wl,-soname,libfoo.so.3", "-o", shared, self.root / "foo.c"],
            check=True,
        )
        (source / "CMakeLists.txt").write_text(
            "cmake_minimum_required(VERSION 3.20)\n"
            "project(wrapper_rpath C)\n"
            "add_library(foo SHARED IMPORTED)\n"
            f'set_target_properties(foo PROPERTIES IMPORTED_LOCATION "{shared}")\n'
            "add_executable(app main.c)\n"
            "target_link_libraries(app PRIVATE foo)\n"
            "install(TARGETS app)\n"
        )
        after = (
            "set -e\n"
            f'cmake $CMAKE_ARGS -S "{source}" -B build -DCMAKE_INSTALL_PREFIX="{install}"\n'
            "cmake --build build\n"
            "cmake --install build\n"
            f'env -u LD_LIBRARY_PATH "{install}/bin/app"\n'
            f'readelf -d "{install}/bin/app" > "$CONTROL_ROOT/installed.dynamic"\n'
            'printf %s "$EB_LOCAL_MESON_INSTALL_RPATH" > "$CONTROL_ROOT/meson-rpath"\n'
        )
        _, replay = self.dev(
            "NVHPC/26.7",
            after=after,
            PATH=os.environ["PATH"],
            LIBRARY_PATH=str(search),
            LD_LIBRARY_PATH="",
        )
        self.assertEqual(replay.returncode, 0, replay.stdout + replay.stderr)
        dynamic = (self.root / "installed.dynamic").read_text()
        self.assertIn("Library rpath:", dynamic)
        self.assertIn(str(lib), dynamic)
        self.assertNotIn("RUNPATH", dynamic)
        self.assertEqual((self.root / "meson-rpath").read_text(), str(search))

    def test_meson_install_rpath_filters_library_path(self):
        keep = self.root / "keep" / "lib"
        other = self.root / "other" / "lib64"
        compat = self.root / "compat"
        after = 'printf %s "$EB_LOCAL_MESON_INSTALL_RPATH" > "$CONTROL_ROOT/meson-rpath"\n'
        self.dev(
            "NVHPC/26.7",
            after=after,
            LIBRARY_PATH=(
                f":relative:{keep}//:{keep}/:{compat}/lib:/lib:/lib64/sub:"
                f"/usr/lib:{other}:/opt/lib,comma"
            ),
            EESSI_EPREFIX=f"{compat}//",
        )
        self.assertEqual(
            (self.root / "meson-rpath").read_text(),
            f"{keep}:{other}",
        )


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
