<!-- Generated from docs/orgmode/explanation/run-paths.org by docs/export.el; edit that file. -->

# Run paths, and one build per CPU target

A program built against EESSI needs EESSI's libraries when it runs.
It finds them through the run paths its link recorded, not through `LD_LIBRARY_PATH`, and those run paths name the libraries of one CPU target.
This page says how `eb-local dev` gets them recorded, why `LD_LIBRARY_PATH` stays unset, and why each CPU target needs a build of its own.
[Compile your code against EESSI](../howto/compile.md) has the steps.

## Where the run paths come from

`eb-local dev` loads EESSI, the modules you name, and a build environment last, so `gcc`, `mpicc`, `make`, CMake and meson record where each library lives.
The build environment has to be loaded; when, relative to the libraries, does not matter, because the modules set `LIBRARY_PATH` and the wrappers read it when you link.
On a cluster with EESSI 2026.06, GSL loaded before and after `buildenv/default-foss-2026.1` gives the same RPATH entries, and both programs run with no modules loaded; without the build environment the program cannot find `libgsl.so.28`.
Its `gcc` and `ld` wrappers each record the run paths, so one real `gcc` or one real `ld` ahead of them on `PATH` does no harm.
A program loses its run paths when the link never goes through either wrapper. A compiler that finds its own linker does that on its own, and so does a linker that is neither of those two programs.
The link still succeeds, and the program fails when it starts; `eb-local check PROGRAM` shows this first.
`check --dev`, `check --module NAME/VERSION` and `check --prefix DIR` apply that audit to every ELF file in the dev tree, an installed module or a directory, and skip a file that is not ELF.
`dev` chooses the build environment from the compilers loaded when it runs, so the modules you link against go on the `dev` line, not after it.

## Why not LD\_LIBRARY\_PATH

A program with its run paths needs no `LD_LIBRARY_PATH`, and setting one can mix the host's libraries into EESSI's.
`dev` warns when the shell has it set, and a build with EasyBuild does not pass it on to `eb`.
The wrappers record `RPATH`, not `RUNPATH`: `LD_LIBRARY_PATH` overrides `RUNPATH`, and the loader does not use a program's `RUNPATH` for the dependencies of its libraries.
`eb-local check` reports a file with `RUNPATH` as a problem, as it does a library found only through `LD_LIBRARY_PATH`.

## Compilers without a wrapper

`clang`, `clang++`, `flang`, `flang-new` and `ld.lld` find their linker themselves, so an `ld` wrapper never sees what they link.
The `LLVM` module, which other modules also load, ships `clang` but is not `llvm-compilers`: with it, `dev` loads the GCC build environment, which wraps `gcc` and `ld` but not `clang`.
So `dev` puts RPATH wrappers of its own first for each of those compilers on `PATH` that no wrapper covers, and does the same for every compiler and linker when Lmod has no build environment for the compilers loaded.
Like EasyBuild's wrappers, they add a run path for each library directory a link names with `-L` or finds through `LIBRARY_PATH`, and leave out the system's and the compatibility layer's directories.

## Linkers the wrappers never see

The wrappers cover `gcc`, `ld` and the compilers `dev` wraps because they find their own linker.
Cargo, Julia, Node.js, R and a Python virtual environment can still link without them, or pick up a host compiler or a host library tree.
`dev` leaves the variables named below as the shell had them. `eb-local eb` resets Cargo's.

On x86\_64, `rustc` 1.90 and later links with `rust-lld`.
That linker is not `gcc`, `ld` or `ld.lld`, so the build environment's wrappers never see the link and the program has no run path into EESSI's libraries.
`eb-local eb` drops a host `RUSTC_WRAPPER`, `CARGO_BUILD_RUSTC_WRAPPER`, `RUSTC_WORKSPACE_WRAPPER`, `RUSTFLAGS` and `CARGO_ENCODED_RUSTFLAGS`, drops every `CARGO_TARGET_*_LINKER` and `CARGO_TARGET_*_RUSTFLAGS`, and, when `rustc -vV` prints a host, sets `CARGO_TARGET_<target>_LINKER` to the shell's `CC`, or to `gcc` when `CC` is unset.
Load `Rust/1.94.1-GCCcore-15.2.0` on the `dev` line.
Its toolchain is GCCcore 15.2.0, so `dev` loads `buildenv/default-foss-2026.1`.
The same assignment then points Cargo at that `gcc`.
Leave a host `RUSTFLAGS` unset. It can name another linker.

`Julia/1.13.2` is a tarball on the system toolchain.
The `julia` command puts `$EBROOTJULIA/lib` and `$EBROOTJULIA/lib/julia` on `LD_LIBRARY_PATH` and runs `julia.bin`.
A library you compile for it is still linked by the build environment.
The module sets none of the compiler-family variables, so `dev` loads the GCC build environment and `gcc` records the run paths.
Julia's depot defaults to `~/.julia`, one directory for every CPU target.
Set `JULIA_DEPOT_PATH` under `EB_LOCAL_DEV_PREFIX` when it is unset.
`JULIA_LOAD_PATH` names code Julia loads. A host entry there is a host tree.

`nodejs/24.16.0-GCCcore-15.2.0` is the module name, with `nodejs` in lower case.
A native addon is compiled with the build environment's `CC` and `CXX` when those are `gcc` and `g++`.
Unset a host `NODE_PATH` before that build. It names a host module tree.

R's Makeconf calls `gcc` unless `R_MAKEVARS_USER` or `R_MAKEVARS_SITE` names another file.
Unset both when they point outside your prefix.
`R/4.6.1-gfbf-2026.1` belongs to the gfbf toolchain, so `dev` loads the foss build environment for it.

A virtual environment from `Python/3.14.2-GCCcore-15.2.0` compiles an extension with that `gcc` unless `CC` or `PYTHONPATH` still names the host.
`dev` leaves both as the shell had them.

`tests/site/lang-dev-tasks.sh` runs each of these, then runs the built program with no modules loaded.

## One build per CPU target

EESSI chooses the binaries for the CPU it finds when it loads.
A program built with `dev` belongs to that one CPU target, because the wrappers record run paths into `$EESSI_SOFTWARE_SUBDIR`: a binary linked on zen4 loads zen4 libraries wherever it runs, and can stop with an illegal instruction on zen2.
The build environment also puts `-march=native` in `CFLAGS`, `CXXFLAGS` and `FFLAGS`, so `make` and CMake compile the program for that CPU too; with `buildenv/default-foss-2026.1`, `CFLAGS` is `-O2 -ftree-vectorize -march=native -fno-math-errno`.
So a program is built once per node type, in an allocation on that node type, and installed into a path that names the target, which `dev` sets as `EB_LOCAL_DEV_PREFIX`.
A job script that loads EESSI first then finds the build for the node it lands on.
Software built with EasyBuild is the same: each CPU target has a tree of its own below the install prefix.

Where the site runs [eessi-arch-guard](https://github.com/stackhands/eessi-arch-guard) and `eessi-arch-guard` is on `PATH`, a build, `env` and `dev` load EESSI for the CPU target the guard selects, which is the target Slurm tasks get.
On a CPU without a flag that GCC enables for the target EESSI detects, such as a Sapphire Rapids without `waitpkg`, that is the next target down, `x86_64/intel/icelake`.
A build stops when the guard cannot select a target; `EESSI_ARCH_GUARD=0` turns the guard off.

## Related

-   [Compile your code against EESSI](../howto/compile.md)
-   [The eb-local command](../reference/cli.md): `dev`, `check` and `rpath-wrappers`
