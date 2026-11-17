<!-- Generated from docs/orgmode/reference/cli.org by docs/export.el; edit that file. -->

# The eb-local command

`eb-local` builds and installs software with EasyBuild on top of EESSI 2026.06, into a directory you or your project own, and prints the shell lines that load EESSI and what you installed.
This page describes the static binary on this branch's `main`.
The 1.x Bash script, frozen until it is removed in 4.0.0, has a build, `env`, `dev` and `clean` only.

## Synopsis

```text
eb-local [OPTION]... <easyconfig> [eb options]
eb-local [OPTION]... --explain <easyconfig> [eb options]
eb-local eb [--] [eb options]
eb-local --explain eb [--] [eb options]
eb-local [OPTION]... env
eb-local [OPTION]... dev [--buildenv MODULE] [MODULE...]
eb-local rpath-wrappers [--for FAMILY | --unwrapped]
eb-local check FILE...
eb-local check (--module NAME/VERSION... | --dev | --prefix DIR) [--quiet]
eb-local [OPTION]... submit [--on NAME,...] [--print] <easyconfig> [eb options]
eb-local [OPTION]... list [NAME[/VERSION]...]
eb-local [OPTION]... doctor
eb-local lmod-cache --modulepath DIR[:DIR] --cache-dir DIR --timestamp FILE [--spider CMD]
eb-local lmod-cache --prefix DIR [--eessi-version VER] [--update-cmd CMD] [--dry-run]
eb-local modulerc --module-tree DIR [--default MODULE]...
                   [--alias NAME=MODULE]... [--hide MODULE]... [--dry-run]
eb-local [OPTION]... clean [--logs-older-than DAYS] [--no-logs] [--sources] [--workspaces]
                           [--dry-run] [--delete]
eb-local [OPTION]... config [--check | --env]
eb-local [OPTION]... profiles
eb-local [OPTION]... uninstall NAME/VERSION... [--dry-run] [--delete] [--usage-log FILE]
eb-local [OPTION]... restore NAME/VERSION... [--dry-run]
eb-local site [list | show NAME | install NAME] [--set KEY=VALUE]... [--to FILE] [--force]
eb-local help | -h | --help | --version
```

`OPTION` is one of `--profile NAME`, `--project DIR` and `--config FILE`, which the options below describe.

`eb-local --help` prints:

```text
eb-local: install and build software on top of EESSI 2026.06, into a
directory you own.

  eb-local <easyconfig> [eb options]   build and install with EasyBuild
  eb-local --explain <easyconfig> [eb options]
                                       the commands that build runs, as shell lines,
                                       its checks as comments; creates and runs nothing
  eb-local eb [--] [eb options]        load EESSI-extend and run eb; no site file, no Slurm job.
                                       At most one of EESSI_USER_INSTALL, EESSI_PROJECT_INSTALL,
                                       EESSI_SITE_INSTALL, EESSI_CVMFS_INSTALL may be set, and a
                                       present empty value counts as set; with none set, the
                                       module uses $HOME/eessi and nothing is exported.
                                       eb runs only if the module's install path is in the
                                       tree that variable selects
  eb-local --explain eb [--] [eb options]
                                       the script eb runs, with its arguments; runs nothing
  eb-local env [--strict]                lines that make your installed modules visible;
                                       --strict exits when the EESSI init file is missing
                                       (also when EB_LOCAL_ENV_STRICT=1)
  eb-local dev [--buildenv MODULE] [MODULE...]
                                       the same, plus MODULEs and a build environment,
                                       so gcc, make, cmake and meson just work;
                                       --buildenv names the build environment to load
  eb-local rpath-wrappers [--for FAMILY | --unwrapped]
                                       lines that put RPATH wrappers for the compilers
                                       on PATH first; dev uses them when no build
                                       environment exists for the loaded compilers.
                                       --unwrapped: only clang, clang++, flang,
                                       flang-new and ld.lld, where no wrapper comes
                                       first; dev adds them after a build environment
  eb-local check FILE...               whether a program or library built here runs here:
                                       its architecture, loader, run paths and libraries
  eb-local check (--module NAME/VERSION... | --dev | --prefix DIR) [--quiet]
                                       the same for every ELF file in those installations,
                                       the dev tree, or DIR; a file that is not ELF is skipped.
                                       --quiet prints a file only when it has a problem
  eb-local submit [--on NAME,...] [--print] <easyconfig> [eb options]
                                       one batch job per node type the site file lists
                                       in build.node_types, each building the recipe for
                                       its CPU target; --print shows the jobs instead.
                                       Deprecated, and removed in 4.0.0: --explain
                                       prints an sbatch line for each node type
  eb-local list [NAME[/VERSION]...]    what you installed, for which CPU targets, and
                                       what this node's target lacks
  eb-local doctor [--cvmfs] [--cvmfs-parallel N] [--mpi]
                                       what in this shell, node or configuration would
                                       stop a build or a module load; changes nothing.
                                       --cvmfs checks the CernVM-FS client.
                                       --cvmfs-parallel N (1 to 8) reads repository
                                       metadata from N tasks inside an allocation.
                                       --mpi reports libfabric and UCX, and inside an
                                       allocation runs a two-rank hello per approved transport
  eb-local lmod-cache --modulepath DIR[:DIR] --cache-dir DIR
                      --timestamp FILE [--spider CMD]
                                       write Lmod's spiderT.lua for those module
                                       directories, and a timestamp one second
                                       older, so Lmod trusts the cache. A spider
                                       that fails leaves both files unchanged.
                                       --spider names the spider program;
                                       default: spider. Does not read the site file
  eb-local lmod-cache --prefix DIR [--eessi-version VER] [--update-cmd CMD]
                      [--dry-run]
                                       for every CPU target under DIR, refresh
                                       .lmod/cache with Lmod's cache updater
                                       (like EESSI's update_lmod_caches.sh).
                                       --dry-run lists targets; existing
                                       --modulepath mode is unchanged
  eb-local modulerc --module-tree DIR [--default MODULE]...
                     [--alias NAME=MODULE]... [--hide MODULE]... [--dry-run]
                                       write DIR/.modulerc.lua with the
                                       defaults, aliases and hidden versions named;
                                       preserve other lines. --dry-run prints the file
  eb-local clean [--logs-older-than DAYS] [--no-logs] [--sources] [--workspaces]
                 [--dry-run] [--delete]
                                       remove what eb-local left behind; --no-logs
                                       leaves the logs
  eb-local config [--check | --env]    the settings in force and where each came from;
                                       --check also reads every secret (values not shown);
                                       --env prints them as EB_LOCAL_* lines for export
  eb-local profiles                    the profiles the configuration defines
  eb-local uninstall NAME/VERSION... [--dry-run] [--delete] [--usage-log FILE]
                                       remove an installation and its module file, for
                                       every CPU target, to the trash with rtrash.
                                       --usage-log asks eb-keep-logs whether the prefix
                                       is in FILE, and removes nothing when that exits 2
  eb-local restore NAME/VERSION... [--dry-run]
                                       bring them back from the trash, read-only again
  eb-local site [list | show NAME | install NAME] [--set KEY=VALUE]... [--to FILE] [--force]
                                       a site file from a template built in, or from a
                                       template file (a NAME with a slash); install
                                       writes config.toml beside this program, mode 644
  eb-local help | --version

Every command but eb takes --profile NAME, --project DIR (a shared project
directory instead of $HOME/eessi) and --config FILE. Use env and dev with eval:

  eval "$(eb-local env)"
  eval "$(eb-local dev FFTW/3.3.10-GCC-15.2.0)"

Configuration: the site file (the first of config.toml beside this program,
/etc/eb-local/config.toml, eb-local.conf beside this program and
/etc/eb-local.conf), then ~/.config/eb-local/config.toml,
then EB_LOCAL_* variables (EB_LOCAL_SECRET_NAME=SOURCE for a secret),
then options. Builds use the allocation's own
node-local mount; a successful build removes its workspace unless
EB_LOCAL_KEEP_WORK=1. Secrets reach eb's environment only, and logs
written during a build are cleaned of them. A build gets every secret,
unless build.secrets or EB_LOCAL_BUILD_SECRETS names the ones it gets.

--config FILE, or EB_LOCAL_CONFIG=FILE without it, is read in place of the
site file when root or this program's owner owns it, otherwise in place of
your ~/.config/eb-local/config.toml when you own it; the other file is
still read, and only a site file may set the storage settings.
```

## Arguments

The first word names the command.
Without a command, the words go to `eb` in the order given, the easyconfig and `eb`'s own options, and eb-local builds.
`--profile`, `--project`, `--config`, `-h` and `--help` are eb-local's wherever they come, and `--explain` is eb-local's before the first word that goes to `eb`.
After `eb`, every word goes to `eb` except `-h` and `--help`; after `eb --`, every word does, so `eb-local eb -- --help` prints `eb`'s help.
`--env` as the first word is `env`, as in the 1.x script.

## Options

| Option | Meaning |
|---|---|
| `--profile NAME` | Use the profile NAME, in place of `EB_LOCAL_PROFILE` and `default_profile`. |
| `--project DIR` | Install into, and load from, the project directory DIR instead of the prefix, as the `project` setting does. |
| `--config FILE` | Read FILE in place of the site file when root or the owner of this program owns it; otherwise in place of `~/.config/eb-local/config.toml`, when you own it. The other file is still read. |
| `--explain` | Before an easyconfig, or before `eb`: print what would run, and create and run nothing. |
| `-h`, `--help`, `help` | Print the usage on stdout and exit 0. |
| `--version` | Print the version line on stdout and exit 0. |

Each option that takes a value also takes it after an equals sign, as in `--profile=gpu`.
An empty value is refused either way, with `OPTION needs a value`.
`eb` refuses `--profile`, `--project` and `--config`, since it reads the install mode from the environment; `site`, `check` and `rpath-wrappers` take them and do not use them.

The version line names the program, its version, the target and optimize mode of the build, the Zig version, and the commit given to `zig build` as `-Dcommit`, or `unknown`.
Built with `zig build --release=safe -Dcommit=0123abc`, it prints:

```text
eb-local 3.1.0 (x86_64-linux-musl, safe, zig 0.17.1, 0123abc)
```

Since `v3.1.0`, no CLI flag was removed or renamed on `main`.
The command line added `--strict` on `env`, `--unwrapped` on `rpath-wrappers`, and `lmod-cache` with `--modulepath`, `--cache-dir`, `--timestamp` and `--spider`.

## Commands

### A build

Build `<easyconfig>` with EasyBuild through EESSI-extend, for the CPU target of this node, and install it into the prefix, or into the project directory with `--project`.
A build runs only inside a Slurm job, in a workspace of its own in the job's node-local mount, `<storage.node_local_root>/<storage.node_local_mount>`.
Outside a job it builds nothing: it names the allocation the site suggests, and an `sbatch` line for each node type in `build.node_types`, and exits 2.
Its first line names the command that prints what it runs:

```text
eb-local: what this runs: eb-local --explain pigz-2.8-GCCcore-15.2.0.eb --robot
```

A build that succeeds removes its workspace, unless `EB_LOCAL_KEEP_WORK` is `1`, and ends with the line that makes what it installed visible:

```text
eb-local: done. To use the modules in a new shell or job:
  eval "$(eb-local env)"
```

A failed build keeps its workspace until the job ends.
A build exits with `eb`'s status.
In a shell without a module command, a build, `env` and `dev` source the first Lmod init they can read: `$LMOD_PKG/init/bash`, or `/usr/share/lmod/lmod/init/bash` with `LMOD_PKG` unset, then `/etc/profile.d/lmod.sh`, then EESSI's own, the one `eb-local eb` sources; `eb-local doctor` names the one a build would source.
Stopped by a signal, it removes the secret values from the logs and then stops with the same signal.

### `--explain`

Print the script a build runs, and create and run nothing, inside a Slurm job or outside one.
The output is, in order: comments that say where the build installs, the checks it makes first, and whether each secret reaches `eb`; the variables it sets for the script, with `W` standing for its workspace; a `set --` line with the script's arguments; and the script itself.
With `build.node_types` in the site file, the comments also hold an `sbatch` line for each node type, which runs the same build as a batch job there.

The script does what you would type to use EESSI-extend by hand: clear the install variables a login shell may carry, set one of `EESSI_USER_INSTALL` or `EESSI_PROJECT_INSTALL`, load `EESSI/2026.06`, then `EESSI-extend`, which reads that variable as it loads, check that the install path EESSI-extend set is in `<prefix>/versions`, and run `eb`.
With `W` set to a workspace a build made, which holds `build`, `cache`, `cargo`, `source-index` and `tmp`, such as one a failed build kept or one kept with `EB_LOCAL_KEEP_WORK=1`, `bash` runs the printed text as a build runs its script; the checks before it and the cleaning of logs after it are eb-local's own.

### eb

Load EESSI and EESSI-extend in a bash with no profile and no rc file, and run `eb` with the arguments, with no site file and no Slurm job.
EESSI-extend takes the install mode from the install variables, of which at most one of `EESSI_USER_INSTALL`, `EESSI_PROJECT_INSTALL`, `EESSI_SITE_INSTALL` and `EESSI_CVMFS_INSTALL` may be set; a present, empty one counts.
With more than one set, `eb` runs nothing and the command exits 3.

| Variable | Mode | Prefix | Process umask |
|---|---|---|---|
| `EESSI_USER_INSTALL` | user | created when the value is not empty | 077 |
| `EESSI_PROJECT_INSTALL` | project | not created; its owner sets the group and the setgid bit | 002 |
| `EESSI_SITE_INSTALL` | site | the init's site software path | 022 |
| `EESSI_CVMFS_INSTALL` | cvmfs | the EESSI software path | 022 |
| none | user | `$HOME/eessi`, which need not exist before the module loads | 077 |

The module sets `EASYBUILD_UMASK` to the same end, with the sticky bit for a user prefix and the setgid bit for a project, and `eb` gets no `--umask`, so that value stands.
An argument of `eb`'s still overrides it: `--umask=022` is what a user-namespace build needs when Lmod, running as uid 0, skips a directory that others cannot search.
The module's help text says `$HOME/EESSI`; on EESSI 2026.06 it uses `$HOME/eessi`.
Before EESSI-extend loads, the script unsets host Rust and CMake wrappers, such as `RUSTC_WRAPPER` and `CMAKE_C_COMPILER_LAUNCHER`, and puts the compatibility layer's `usr/bin`, with its `ld`, first on `PATH`, even when `rustc` is not installed.
EasyBuild builds under `$WORKING_DIR/easybuild`; the module sets `WORKING_DIR` to `/tmp/$USER` when it is not set, and `eb` leaves it as you set it.
`--profile`, `--project` and `--config` are not options of `eb`, which stops with exit 2 when given one; the 1.x Bash script has no `eb` command.

Once EESSI-extend has loaded, the script exits 2 before `eb` runs when the install path the module set is outside the tree the install variable selects, or when `EASYBUILD_INSTALLPATH_SOFTWARE` or `EASYBUILD_INSTALLPATH_MODULES` is set.
Otherwise the command exits with `eb`'s status.

With `EB_LOCAL_EESSI_EXTEND` set, not empty and not `0`, every argument of `eb-local` goes to `eb`, as after `eb-local eb --`.

### `--explain eb`

Print the script `eb` runs, after a `set --` line with its arguments, and run nothing.
With more than one install variable set, it prints nothing on stdout and exits 3.

### env

Print the shell lines that load EESSI and then EESSI-extend for the prefix, or the project directory, which puts the modules installed there on `MODULEPATH`.
Run them with `eval "$(eb-local env)"`.
When stdout is a terminal, it also says on stderr that the lines change nothing until the shell runs them.

### dev

Print the lines `env` prints, then the lines that load the modules `dev.modules` names and those named on the line, then a build environment, and that set `EB_LOCAL_DEV_PREFIX` to `<prefix>/dev/<EESSI version>/<CPU target>`, with the GPU target appended when EESSI found one.

| Option | Meaning |
|---|---|
| `--buildenv MODULE` | Load MODULE as the build environment whatever the compilers, as `dev.buildenv` does. |

A `MODULE` starts with a letter or digit and holds letters, digits, `.`, `_`, `+`, `-` and single slashes, with none at the end.
With `LD_LIBRARY_PATH` set in the shell, `dev` warns on stderr.

### rpath-wrappers

Write RPATH wrappers for the compilers and linkers on `PATH` into a directory below `$XDG_CACHE_HOME/eb-local`, or `$HOME/.cache/eb-local` without it, and print the lines that put that directory first on `PATH` and name it in `EB_LOCAL_RPATH_WRAPPERS`.
The names it wraps are `gcc`, `g++`, `c++`, `cc`, `gfortran`, `clang`, `clang++`, `flang`, `flang-new`, `icx`, `icpx`, `ifx`, `nvc`, `nvc++`, `nvfortran`, `ld`, `ld.bfd`, `ld.gold` and `ld.lld`.

| Option | Meaning |
|---|---|
| `--for FAMILY` | Say on stderr that no build environment for the FAMILY compilers is available, as `dev` does. |
| `--unwrapped` | Wrap only the `clang`, `clang++`, `flang`, `flang-new` and `ld.lld` on `PATH` that no other wrapper comes before, and print nothing when there are none. |

Without `--unwrapped`, finding nothing to wrap is exit 1.

### check

For each `FILE`, print its machine, its program interpreter (the loader), its `RPATH` or `RUNPATH`, and where each library it needs resolves, ignoring `LD_LIBRARY_PATH`, then one line for all of them:

```text
eb-local check: no problems
```

A problem is a line of its own, after `problem:`, below the line it concerns:

| Problem | When |
|---|---|
| `built for MACHINE; this node is MACHINE` | The file is for another architecture. |
| `the loader is the host's, not the compatibility layer's under DIR` | EESSI is loaded, and the file names a loader outside its compatibility layer. |
| `RUNPATH, which LD_LIBRARY_PATH overrides and the libraries' own dependencies ignore; link with --disable-new-dtags for RPATH` | The file records `RUNPATH` rather than `RPATH`. |
| `run paths into the TARGET software tree; this shell is TARGET: build it again on this node type` | A run path, or a directory in `LD_LIBRARY_PATH`, leads into the tree of a CPU target other than `$EESSI_SOFTWARE_SUBDIR`. |
| `LIBRARY does not exist` | The file names a library by its path, and there is none. |
| `LIBRARY is not found` | No run path, no directory in `LD_LIBRARY_PATH` and none of the loader's directories holds the library. |
| `LIBRARY is found only through LD_LIBRARY_PATH` | The same, but a directory in `LD_LIBRARY_PATH` holds it. |
| `LIBRARY comes from the host, not from EESSI` | EESSI is loaded, and the library resolves outside it. |

`check` follows the libraries the file names, not theirs; run it on a library to check that one's.

`--module NAME/VERSION`, `--dev` and `--prefix DIR` audit every ELF file in place of the files named on the line.
A file that is not ELF is skipped, and a symbolic link is not followed, so a link cannot point the audit outside the tree.
`--module` may be repeated, and further `NAME/VERSION` words after it name more modules.
Each must be installed. Every CPU target's installation is audited, and the module files are not: they are not ELF.
`--dev` reads `EB_LOCAL_DEV_PREFIX` when it is set, and otherwise `<prefix>/dev/$EESSI_VERSION/$EESSI_SOFTWARE_SUBDIR`, with `$EESSI_ACCELERATOR_TARGET` appended when that is set.
`--prefix` is any directory and does not read the site file.
The three are alternatives to naming files, and to each other.
`--quiet` prints a file only when it has a problem, and still ends with the summary line.
With no ELF file in the tree, and without `--quiet`, `check` says `eb-local check: no ELF files` and then `eb-local check: no problems`.

It exits 0 when there are no problems, 1 when there are, and 2 when a named file cannot be read or is not ELF, or when a file in a tree cannot be read.
A file that is not ELF is not a failure of a tree audit.

### submit

Send one batch job for each node type in `build.node_types`, each running this eb-local with the same easyconfig, options and configuration.
`submit` is deprecated, and is removed in 4.0.0; `--explain` prints the same jobs as `sbatch` lines.

| Option | Meaning |
|---|---|
| `--on NAME,...` | Only the node types named. |
| `--print` | Print the jobs, and submit nothing. |

`--on` and `--print` come before the easyconfig; the words after it go to `eb`.
It exits 1 when `sbatch` refuses a job, and 2 when the site file has no `build.node_types`.

### list

Print each module installed in the prefix, or the project directory, with a column for each CPU target it has a tree for, `x` where the module is built for that target and `-` where it is not.
With EESSI loaded, the column of this node's target is marked `*`, and the modules it lacks are named.
A `NAME` keeps the modules of that name, and a `NAME/VERSION` that module.

### doctor

Print one line for each check of what would stop a build, `eb-local eb` or a module load, each starting `ok`, `info`, `warn` or `FAIL`, then a line that says whether anything stops a build.
It checks the site file, the secrets a build reads (never their values), the prefix and its permissions, install variables and `LD_LIBRARY_PATH` left in the shell, the EESSI init `eb-local eb` sources, the allocation's node-local mount, whether EESSI is loaded and your modules are on `MODULEPATH`, the Lmod init a build sources where the shell has no module command, eessi-arch-guard, and rtrash.
It names an entry of `PERL5LIB`, `PYTHONPATH`, `R_LIBS*`, `CMAKE_PREFIX_PATH` or `PKG_CONFIG_PATH`, and a compiler-wrapper variable (`CC`, `CXX`, `FC`, `F77`, `F90`, `F95`, `CPP`, the `OMPI_`, `MPICH_` and `I_MPI_` forms, `RUSTC_WRAPPER`, `CCACHE_*`, `SCCACHE_*` and `CMAKE_*_COMPILER_LAUNCHER`), that resolves outside the approved prefixes.
A build keeps that entry unless `build.clear_foreign_prefixes` is set.
It reports the path `/etc/localtime` resolves to, warns when that file is its own bind mount, and warns about a host library directory a container runtime injected, including `/.singularity.d/libs` and a directory named by `APPTAINER_CONTAINLIBS` or `SINGULARITY_CONTAINLIBS`.
With `--cvmfs`, it also checks the CernVM-FS repository named by `EESSI_CVMFS_REPO`, or `/cvmfs/software.eessi.io`.
It reports whether that mount is present, a stale FUSE mount, or returning an input/output error.
It reports the HTTP proxy in force: `CVMFS_HTTP_PROXY` in the environment wins over `/etc/cvmfs/default.conf`, `default.local`, `domain.d` and `config.d`, and a value taken from the environment is named as one a host can inject.
`DIRECT` is direct mode.
When `cvmfs_config` is on `PATH`, it runs `cvmfs_config probe` and `cvmfs_config chksetup`; a stale mount skips the probe.
`--cvmfs-parallel N`, or `doctor.cvmfs_parallel` when the flag is omitted, reads repository metadata from N tasks, and only inside an allocation.
It uses `srun -n N stat` when `srun` is on `PATH`, and otherwise reads from N processes of its own.
A build does not run these checks and does not set a CernVM-FS variable.
With `--mpi`, it reports whether `fi_info` and `ucx_info` are on `PATH`, and any Slurm CPU or memory bind in `SLURM_CPU_BIND`, `SLURM_CPU_BIND_LIST` and `SLURM_MEM_BIND`.
Inside an allocation it compiles a two-rank hello with `mpicc` and runs it with `mpirun -np 2` for each transport in `doctor.mpi_transports`.
The hello for `ofi` is run with `OMPI_MCA_pml` set to cm and `OMPI_MCA_mtl` set to ofi.
The hello for `ucx` is run with `OMPI_MCA_pml` set to ucx and `OMPI_MCA_mtl` set to ^ofi.
Those variables are set only on that hello. A build does not set them, and it does not set `FI_PROVIDER`.
Outside an allocation the hello is not compiled.
Where the shell has a module command, a build keeps it and its `MODULEPATH`, so doctor checks that a directory on `MODULEPATH` holds `stack.module`.
Inside a job with EESSI loaded, it asks eessi-arch-guard, where that is on `PATH`, as a build asks it, and shows the target it selects; a guard that cannot select one is a `warn`, since a build's own run of it decides.
With a site file, what stops a build is a `FAIL`, and what stops only `eb-local eb` is a `warn`; without one, builds cannot run, so what stops `eb-local eb` is the `FAIL`.
It changes nothing, and exits 1 when a line says `FAIL`.

| Option | Meaning |
|---|---|
| `--cvmfs` | Check the CernVM-FS client. Off unless this flag, or `--cvmfs-parallel`, is given. |
| `--cvmfs-parallel N` | Also read repository metadata from N tasks, 1 to 8, inside an allocation. Implies `--cvmfs`. |
| `--mpi` | Report libfabric, UCX and Slurm binding, and run a two-rank hello per site-approved transport inside an allocation. Off unless this flag is given. |

### lmod-cache

Write `spiderT.lua` in `--cache-dir` from Lmod's `spider -o spiderT`, for every directory in `--modulepath`, then set `--timestamp` one second older than that file.
Lmod treats a newer timestamp as a stale cache and does not show the modules the cache names.
A `spider` that cannot start, exits non-zero, or writes nothing leaves the cache and the timestamp as they were.

With `--prefix`, the command walks every CPU target under the prefix (`versions/*/software/…` or `software/…`), prepends each accelerator's `modules/all` directory on that CPU (as EESSI's filesystem-layer `update_lmod_caches.sh` does), and runs Lmod's `update_lmod_system_cache_files` into `<cpu>/.lmod/cache`.
`--dry-run` lists each target, cache directory and colon-separated `MODULEPATH`; it changes no file.

It does not read the site file. `--profile`, `--project` and `--config` are accepted and ignored.

| Option | Meaning |
|---|---|
| `--modulepath DIR[:DIR]` | The module directories, separated by colons. Absolute. Required without `--prefix`. |
| `--cache-dir DIR` | The directory that receives `spiderT.lua`. Absolute. Required without `--prefix`. Created if it is missing. |
| `--timestamp FILE` | The timestamp file Lmod compares with the cache. Absolute. Required without `--prefix`. |
| `--spider CMD` | The `spider` program for single-target mode. Default: `spider` on `PATH`. |
| `--prefix DIR` | Walk `DIR` for CPU targets and refresh each `.lmod/cache` with Lmod's cache updater. Absolute. |
| `--eessi-version VER` | With `--prefix`, only `DIR/versions/VER/software`; default is every `versions/*/software`. |
| `--update-cmd CMD` | Lmod's `update_lmod_system_cache_files` program. Default: `DIR/compat/linux/$(uname -m)/usr/share/Lmod/libexec/update_lmod_system_cache_files`. |
| `--dry-run` | With `--prefix`, list targets only. |

Exit 0 means both files were written or every prefix target was updated. Exit 2 is a missing or relative path. Exit 127 means `spider` or the cache updater could not be started. Any other exit is the child program's, and caches are left as they were on failure.

### modulerc

Write or update `.modulerc.lua` at the root of `--module-tree`.
The command adds only the defaults, aliases and hidden versions named explicitly; it never examines the tree to select a default.
Existing lines are preserved, and a line already present is not duplicated.

| Option | Meaning |
|---|---|
| `--module-tree DIR` | The absolute module tree containing `.modulerc.lua`. Required. |
| `--default MODULE` | Add `module_version("MODULE", "default")`. Repeatable. |
| `--alias NAME=MODULE` | Add `module_alias("NAME", "MODULE")`. Repeatable. |
| `--hide MODULE` | Add `hide_version("MODULE")`. Repeatable. |
| `--dry-run` | Print the complete resulting file and leave the tree unchanged. |

At least one directive option is required.
Running the same command again produces identical file contents.
This command does not read the site file; `--profile`, `--project` and `--config` are accepted and ignored.

### clean

Remove what eb-local left in the prefix, or the project directory: by default the build logs in `.eb-local/logs` older than `clean.logs_older_than_days`.

| Option | Meaning |
|---|---|
| `--logs-older-than DAYS` | The logs more than DAYS whole days old, in place of `clean.logs_older_than_days`; DAYS is at most 99999. |
| `--no-logs` | No logs. |
| `--sources` | The downloaded source archives in `.eb-local/sources` too. |
| `--workspaces` | Your build workspaces in the job's node-local mount too; only inside the Slurm job that made them. |
| `--dry-run` | Print what would be removed, and remove nothing. |
| `--delete` | Delete for good when `clean.trash` does not move files to the trash. |

Files go to the trash with `rtrash` as `clean.trash` says; workspaces are deleted.
A directory among the logs, such as the `reprod_*` copies of a failed build's easyconfig, easyblocks and hooks, goes whole once neither it nor anything in it is newer than the cutoff: the copies keep their originals' older times, and a file added to a directory makes the directory new.
`clean` never follows a symbolic link out of the installation directory.
With `clean.trash` `none`, or `auto` and no rtrash on `PATH`, it removes nothing without `--delete`, and exits 1.

### config

Print every setting in force, with where its value came from: `default`, a file and line with its layer and profile, a variable, or an option.
[The configuration files](configuration.md) lists the settings.

| Option | Meaning |
|---|---|
| `--check` | Also read each secret, and print `ok`, or `FAILED:` and why, where the file that set it would be; never the value. |
| `--env` | Print the settings as `export EB_LOCAL_...` lines for a shell, with each secret's source and never its value. |

It exits 1 with `--check` when a secret cannot be read or the project directory cannot be used.

### profiles

Print each profile the configuration files define, with the layer and the file that define it, or `no profiles are defined`.

### uninstall

Remove each installation `NAME/VERSION` names, for every CPU target, with its module files and the links EasyBuild makes to them from `modules/CLASS/`, and print what it removes.
EasyBuild leaves an installation read-only; `uninstall` makes its directories writable first.

| Option | Meaning |
|---|---|
| `--dry-run` | Print what would be removed, and remove nothing. |
| `--delete` | Delete for good when `clean.trash` does not move files to the trash. |
| `--usage-log FILE` | Ask `eb-keep-logs` whether the install prefix is named in FILE, and remove nothing when that command exits 2. |

It removes nothing, and exits 2, when another module installed in the prefix loads one named and is not named too.
With `clean.trash` `none`, or `auto` and no rtrash on `PATH`, it removes nothing without `--delete`, and exits 1.

`--usage-log FILE` runs `eb-keep-logs used --prefix PREFIX --require-none FILE` after that dependents check and before anything is listed or removed.
PREFIX is the install prefix.
eb-local does not read FILE.
When that command exits 0, uninstall goes on as it would without the option, including a dry run.
When it exits 2, or any other status, or `eb-keep-logs` is not on `PATH` or cannot be run, uninstall removes nothing, exits 2, and prints what `eb-keep-logs` wrote.
Without `--usage-log`, uninstall does not run `eb-keep-logs`.
`restore` does not take the option, and uninstall takes it once.

### restore

Bring each `NAME/VERSION` that `uninstall` moved to the trash back, for every CPU target, with `rtrash restore`, and make it read-only again.

| Option | Meaning |
|---|---|
| `--dry-run` | Print what would come back, and restore nothing. |

One that is not in the trash for the prefix is exit 2, and so is a path in the trash more than once, as after two `uninstall` runs: it restores nothing, and names the `rtrash restore` command for that path.
`rtrash restore` on one path brings back read-only files in writable directories: rtrash moves a directory, and empties the trash, only when its directories are writable.

### site

Print or write a site file from a template: `slurm`, built in, or a template file of the site's own, named with a slash.

| Word or option | Meaning |
|---|---|
| `list` | Print each built-in template and its placeholders; `site` alone does the same. |
| `show NAME` | Print the site file the template NAME makes. |
| `install NAME` | Write that site file to `config.toml` beside this program, mode 644. |
| `--set KEY=VALUE` | Fill the placeholder KEY; may be given more than once. |
| `--to FILE` | With `install`: write FILE instead. |
| `--force` | With `install`: replace a file that exists. |

`show` and `install` check that the file loads as a site file first.
A value with a quote, a backslash or a control character is refused.

## Exit status

| Status | Meaning |
|---|---|
| 0 | Done, or nothing to do. |
| 1 | `check` found a problem; `doctor` printed a `FAIL`; `config --check` could not read a secret or use the project directory; `clean` or `uninstall` had something to remove and no way to; `rpath-wrappers` found nothing to wrap; `submit`: `sbatch` refused a job. |
| 2 | Refused, with the reason on stderr after `eb-local:`, or the command line was wrong; a build outside a Slurm job; `check` could not read a file. |
| 3 | `eb` or `--explain eb`: more than one install variable is set. |
| N | A build or `eb`: `eb` exited N. |

## The 1.x Bash script

The Bash script `eb-local`, 1.x, is frozen: it gains no commands, and it is removed in 4.0.0, when the test suite's default run against it ends too.
It needs GNU coreutils, util-linux `findmnt`, Lmod and an EESSI 2026.06 mount, and has no profiles or secrets.
It reads one site file, `eb-local.conf`: the file `EB_LOCAL_CONFIG` names, else the one beside the script, else `/etc/eb-local.conf`, used only when it is a regular file, not a symbolic link, not writable by group or others, and owned by root, the script's owner or you.
Its `key = value` lines are the 1.x keys [The configuration files](configuration.md) lists.

## See also

-   [The configuration files](configuration.md), for each setting.
-   [Refusals](refusals.md), for what each refusal means.
-   [Give a secret only to the builds that need it](../howto/scope-secrets.md).
-   [Where EESSI-extend installs](../explanation/install-variables.md).
-   [The API](api.md), for the code of each component.
