<!-- Generated from docs/orgmode/howto/compile.org by docs/export.el; edit that file. -->

# Compile your code against EESSI

`eb-local dev` loads EESSI, the modules you name, and a build environment whose compiler wrappers record where each library lives.
The program then runs with no modules loaded and without `LD_LIBRARY_PATH`.
These steps build a C program that uses FFTW and OpenMP for one node type, check it, and run it from a job script.
[Run paths, and one build per CPU target](../explanation/run-paths.md) says why each step is there.

## Before you start

-   eb-local on `PATH`, as [Install eb-local](install.md) describes, and EESSI 2026.06 under `/cvmfs/software.eessi.io`.
    `dev` needs no site file.
-   The node type that will run the program, and a Slurm partition with that node type.
-   The modules your code links against, as `module avail` names them once EESSI is loaded.

## Build the program

1.  Start an allocation on the node type that will run the program:

    ```bash
    salloc -p cpu -n 4 -t 00:30:00
    ```

    EESSI chooses the binaries for the CPU it finds when it loads, so a program built here belongs to this node type.

2.  Load EESSI, the modules your code links against, and the build environment:

    ```bash
    eval "$(eb-local dev FFTW/3.3.10-GCC-15.2.0)"
    ```

    Name every module you link against on this line, not after it: `dev` chooses the build environment from the compilers those modules bring in.
    Add `--strict` (or set `EB_LOCAL_ENV_STRICT=1`) to verify that the EESSI init file exists before loading modules.
    The EESSI and EESSI-extend modules print lines of their own as they load.

3.  Compile into the directory that `dev` names in `EB_LOCAL_DEV_PREFIX`:

    ```bash
    mkdir -p "$EB_LOCAL_DEV_PREFIX/bin"
    gcc -O2 -fopenmp prog.c -lfftw3 -o "$EB_LOCAL_DEV_PREFIX/bin/prog"
    ```

    `EB_LOCAL_DEV_PREFIX` is `<install prefix>/dev/<EESSI version>/<CPU target>`, with the GPU target appended when EESSI found one, such as `/home/alice/eessi/dev/2026.06/x86_64/intel/sapphirerapids`.
    CMake takes `-DCMAKE_INSTALL_PREFIX`"$EB\_LOCAL\_DEV\_PREFIX"`, and a =configure` script `--prefix`"$EB\_LOCAL\_DEV\_PREFIX"=.

4.  Check that the program finds its libraries without `LD_LIBRARY_PATH`:

    ```bash
    eb-local check "$EB_LOCAL_DEV_PREFIX/bin/prog"
    ```

    ```text
    /home/alice/eessi/dev/2026.06/x86_64/intel/sapphirerapids/bin/prog: x86_64
      loader   /cvmfs/software.eessi.io/versions/2026.06/compat/linux/x86_64/lib64/ld-linux-x86-64.so.2
      RPATH    /cvmfs/software.eessi.io/host_injections/2026.06/software/linux/x86_64/intel/sapphirerapids/rpath_overrides/OpenMPI/system-GCC/lib:...
      needs    libfftw3.so.3 => /cvmfs/software.eessi.io/versions/2026.06/software/linux/x86_64/intel/sapphirerapids/software/FFTW.MPI/3.3.10-gompi-2026.1/lib/../lib64/libfftw3.so.3   [RPATH]
      needs    libgomp.so.1 => /cvmfs/software.eessi.io/versions/2026.06/software/linux/x86_64/intel/sapphirerapids/software/GCCcore/15.2.0/lib64/../lib64/libgomp.so.1   [RPATH]
      needs    libc.so.6 => /cvmfs/software.eessi.io/versions/2026.06/compat/linux/x86_64/lib/../lib64/libc.so.6   [RPATH]
    eb-local check: no problems
    ```

    The `RPATH` line, one directory for each library directory the link could use, is cut short here.

    To audit every ELF file in the dev tree, rather than the one program:

    ```bash
    eb-local check --dev --quiet
    ```

    `--quiet` prints a file only when it has a problem. A file that is not ELF is skipped.

5.  Repeat steps 1 to 4 on each other node type that will run the program.
    Each build goes into the directory for its own CPU target.

## Run it from a job script

A job script loads EESSI first, so that `EESSI_SOFTWARE_SUBDIR` names the CPU target of the node it lands on, and runs the build for that target:

```bash
#!/bin/bash
#SBATCH -p cpu -n 1 -t 00:10:00
eval "$(eb-local env)"
"$HOME/eessi/dev/$EESSI_VERSION/$EESSI_SOFTWARE_SUBDIR/bin/prog"
```

The path is for the default install prefix, `$HOME/eessi`; `eb-local config` shows the prefix in force.
The program runs without the FFTW module, and without `LD_LIBRARY_PATH`.

## Other kinds of code

`tests/site/dev-tasks.sh` in eb-local's repository does each of these with EESSI 2026.06, and runs each program with no modules loaded:

| Code | The line before building |
|---|---|
| C with FFTW and OpenMP | `eval "$(eb-local dev FFTW/3.3.10-GCC-15.2.0)"` |
| MPI | `eval "$(eb-local dev)"`, then `mpicc` |
| CMake against GSL | `eval "$(eb-local dev GSL/2.8-GCC-15.2.0 CMake/3.31.11-GCCcore-15.2.0)"` |
| A Python virtual environment, with packages that compile C | `eval "$(eb-local dev Python/3.14.2-GCCcore-15.2.0)"`, then `python -m venv` and `pip install` |
| R packages, into a library of your own | `eval "$(eb-local dev R/4.6.1-gfbf-2026.1)"`, then `install.packages()` into your library, which `R_LIBS` names |

## Other compilers

The modules on the `dev` line choose the build environment:

| Modules from | Build environment |
|---|---|
| GCC, the default | `buildenv/default-foss-2026.1` |
| CUDA | `buildenv/default-foss-2026.1-CUDA-13.3.0`, else the GCC one |
| `llvm-compilers` (lfoss) | `buildenv/default-lfoss-2026.1` |
| `intel-compilers` | `buildenv/default-intel-2026.1` |
| NVHPC | none |

When Lmod has no such module, `dev` writes RPATH wrappers for the compilers and linkers on `PATH` into `~/.cache/eb-local`, puts them first, and says so.
It does the same for each `clang`, `clang++`, `flang`, `flang-new` or `ld.lld` on `PATH` that no wrapper covers, whichever build environment loads:

```text
eb-local: the build environment does not wrap clang clang++;
  RPATH wrappers for it come first (/home/alice/.cache/eb-local/rpath-742e62ed18c960d2), so what it links has run paths.
```

A site that installs build environments of its own names them in `dev.buildenv_for`, and `dev.buildenv` or `--buildenv MODULE` loads one module whatever the compilers; [The configuration files](../reference/configuration.md) has both.

## Check that it worked

Run the program as a job script runs it, with no modules and an empty environment:

```bash
env -i HOME="$HOME" PATH=/usr/bin:/bin "$EB_LOCAL_DEV_PREFIX/bin/prog"
```

```text
28
```

`eb-local check` on the program exits 0 and ends in `eb-local check: no problems`.

## If it fails

| Message | Cause | What to do |
|---|---|---|
| `problem: libfftw3.so.3 is not found` from `eb-local check`, and `error while loading shared libraries` when the program starts | The program was linked without the build environment, as after `module load` by hand. | Load the modules with `eval "$(eb-local dev MODULE...)"`, and link again. |
| `.../init/lmod/bash: line 89: EESSI_NO_MODULE_PURGE_ON_INIT: unbound variable` | The script runs with `set -u`, and the shell has no module command, so the lines source EESSI's Lmod init, which reads unset variables. | Put `set -u` after the `eval` line. |
| `Illegal instruction` on another node type | The program was built for another CPU target. | Build it on that node type too, and run the build for `$EESSI_SOFTWARE_SUBDIR`. |
| `problem: RUNPATH, which LD_LIBRARY_PATH overrides and the libraries' own dependencies ignore; link with --disable-new-dtags for RPATH` | A compiler and a linker that no wrapper covers linked the program with `--enable-new-dtags`. | Link again after `eval "$(eb-local dev MODULE...)"`, whose wrappers record `RPATH`. |

## Related

-   [Load EESSI and the software you installed](load-eessi.md)
-   [Run paths, and one build per CPU target](../explanation/run-paths.md)
-   [The eb-local command](../reference/cli.md): `dev`, `check` and `rpath-wrappers`
-   [The configuration files](../reference/configuration.md): `dev.modules`, `dev.buildenv` and `dev.buildenv_for`
