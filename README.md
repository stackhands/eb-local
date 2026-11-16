<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="branding/logo/logo-dark.svg">
    <img src="branding/logo/logo-light.svg" alt="eb-local" width="420">
  </picture>
</p>

# eb-local

<!-- docs:start -->
Build your own code and install software on top of [EESSI](https://www.eessi.io) (the European Environment for Scientific Software Installations) 2026.06, without knowing EasyBuild's RPATH wrappers, `buildenv` or `LD_LIBRARY_PATH`.

Documentation: <https://stackhands.github.io/eb-local/>

## Compile your own code

```sh
eval "$(eb-local dev FFTW/3.3.10-GCC-15.2.0)"
gcc -O2 -fopenmp prog.c -lfftw3 -o prog
./prog                      # runs in a new shell or a job, with no modules loaded
```

`eb-local dev` loads EESSI, the modules you name, and a build environment last, so `gcc`, `mpicc`, `make`, CMake and meson record where each library lives.
The program then runs without `LD_LIBRARY_PATH`; do not set it, because it can mix the host's libraries into EESSI's.
The build environment has to be loaded; when, relative to the libraries, does not matter, because the modules set `LIBRARY_PATH` and the wrappers read it when you link.
On a cluster with EESSI 2026.06, GSL loaded before and after `buildenv/default-foss-2026.1` gives the same RPATH entries, and both programs run with no modules loaded; without the build environment the program cannot find `libgsl.so.28`.
Its `gcc` and `ld` wrappers each record the run paths, so one real `gcc` or one real `ld` ahead of them on `PATH` does no harm.
A program loses its run paths only when both are bypassed, or when its compiler has no wrapper, such as `clang` from the `LLVM` module loaded by hand; `dev` gives such a compiler a wrapper (see [Other compilers](#other-compilers)).
The link still succeeds and the program fails when it starts; `eb-local check PROGRAM` shows this first.
`dev` chooses the build environment from the compilers loaded when it runs, so name every module you link against on the `dev` line, not after it.
EESSI 2026.06 ships one build environment, `buildenv/default-foss-2026.1`, whose wrappers cover the GCC compilers; see [Other compilers](#other-compilers) for clang, flang and the rest.

`tests/site/dev-tasks.sh` checks these on a cluster with EESSI 2026.06, each program then run with no modules at all:

| task | the line before building |
|---|---|
| C with FFTW and OpenMP | `eval "$(eb-local dev FFTW/3.3.10-GCC-15.2.0)"` |
| MPI | `eval "$(eb-local dev)"`, then `mpicc` |
| CMake against GSL | `eval "$(eb-local dev GSL/2.8-GCC-15.2.0 CMake/3.31.11-GCCcore-15.2.0)"` |
| a Python venv, with packages that compile C | `eval "$(eb-local dev Python/3.14.2-GCCcore-15.2.0)"`, then `python -m venv` and `pip install` |
| R packages into your own library | `eval "$(eb-local dev R/4.6.1-gfbf-2026.1)"`, then `install.packages(..., lib=...)` and `R_LIBS` |

Load EESSI on the node type that will run the program: it picks the binaries for the CPU it finds when it loads.
A program built with `dev` belongs to that one CPU target, because the wrappers record run paths into `$EESSI_SOFTWARE_SUBDIR`; a binary linked on zen4 loads zen4 libraries wherever it runs and can stop with an illegal instruction on zen2.
The build environment also puts `-march=native` in `CFLAGS`, `CXXFLAGS` and `FFLAGS`, so `make` and CMake compile the program for that CPU too.
So build once per node type, inside an allocation on that node type, and install into a path that names the target.
`dev` sets `EB_LOCAL_DEV_PREFIX` to one: `<install-prefix>/dev/<EESSI version>/<CPU target>`, with the GPU target appended when EESSI found one.

```sh
salloc -p <partition> -n 4 -t 00:30:00      # one allocation per node type
eval "$(eb-local dev FFTW/3.3.10-GCC-15.2.0)"
mkdir -p "$EB_LOCAL_DEV_PREFIX/bin"
gcc -O2 -fopenmp prog.c -lfftw3 -o "$EB_LOCAL_DEV_PREFIX/bin/prog"
eb-local check "$EB_LOCAL_DEV_PREFIX/bin/prog"
```

CMake takes `-DCMAKE_INSTALL_PREFIX="$EB_LOCAL_DEV_PREFIX"`, autotools `--prefix="$EB_LOCAL_DEV_PREFIX"`.
A job script finds the build for the node it lands on by loading EESSI first:

```sh
eval "$(eb-local env)"
"$HOME/eessi/dev/$EESSI_VERSION/$EESSI_SOFTWARE_SUBDIR/bin/prog"   # with the default prefix
```

### Other compilers

The build environment `dev` loads depends on the compilers the named modules bring in:

| modules from | build environment |
|---|---|
| GCC (the default) | `buildenv/default-foss-2026.1` |
| CUDA | `buildenv/default-foss-2026.1-CUDA-13.3.0`, else the GCC one |
| `llvm-compilers` (lfoss) | `buildenv/default-lfoss-2026.1` |
| `intel-compilers` | `buildenv/default-intel-2026.1` |
| NVHPC | none |

When Lmod has no such module, `dev` writes small RPATH wrappers for the compilers and linkers on `PATH` into `~/.cache/eb-local` and puts them first, and says so.
Like EasyBuild's own wrappers, they add a run path for each library directory a link names with `-L` or finds through `LIBRARY_PATH`, leaving out system and compatibility-layer directories.
Whichever build environment loads, `dev` then puts these wrappers first for each `clang`, `clang++`, `flang`, `flang-new` or `ld.lld` on `PATH` that no wrapper covers, and says so.
Those find their linker themselves, so an `ld` wrapper never sees what they link.
The `LLVM` module, which other modules also load, ships `clang` but is not `llvm-compilers`: with it, `dev` loads the GCC build environment, which wraps `gcc` and `ld` but not `clang`.
`eb-local rpath-wrappers` prints the same lines on their own; with `--unwrapped`, only those for the compilers no wrapper covers.

A site that installs its own build environments names them per family; an empty name means none:

```toml
[dev.buildenv_for]
nvhpc = "buildenv/site-nvhpc-26.7"
llvm = ""
```

Setting `dev.buildenv` (or `--buildenv`) loads that module whatever the compilers.

### Check a program

`eb-local check FILE...` reads a program or library and says whether it runs here without `LD_LIBRARY_PATH`.
It prints the loader, the run paths and where each needed library resolves, ignoring the shell's `LD_LIBRARY_PATH`, and it reports these problems:

- the file is built for another architecture;
- with EESSI loaded, the loader or a library comes from the host rather than the compatibility layer;
- the file records `RUNPATH`, which `LD_LIBRARY_PATH` overrides and the libraries' own dependencies ignore, rather than `RPATH`;
- a run path points into the software tree of another CPU target than `$EESSI_SOFTWARE_SUBDIR`;
- a library is not found, or is found only through `LD_LIBRARY_PATH`.

It exits 0 with no problems, 1 with problems and 2 when a file cannot be read.
It checks the libraries the file names itself; run it on a library to check that one's.

## Install software with EasyBuild

Build inside a Slurm allocation on the node type that will run the software, because EasyBuild targets the CPU of the node it runs on:

```sh
salloc -p <partition> -n 16 -t 02:00:00   # on nodes with a node-local disk
eb-local GSL-2.8-GCC-15.2.0.eb --robot
```

To use what you installed in a new shell or job:

```sh
eval "$(eb-local env)"
module avail
```

Where the site runs [eessi-arch-guard](https://github.com/stackhands/eessi-arch-guard) and `eessi-arch-guard` is on `PATH`, a build, `env` and `dev` load EESSI for the CPU target the guard selects, which is the target Slurm tasks get.
On a CPU without a flag GCC enables for the target EESSI detects, such as a Sapphire Rapids without `waitpkg`, that is the next target down (`x86_64/intel/icelake`).
A build stops when the guard cannot select a target; `EESSI_ARCH_GUARD=0` turns the guard off.

For a group install, the project owner creates the directory once with the project group and the setgid bit:

```sh
mkdir -p /path/to/project/eessi && chgrp myproj /path/to/project/eessi && chmod 2770 /path/to/project/eessi
eb-local --project /path/to/project/eessi GSL-2.8-GCC-15.2.0.eb --robot
```

eb-local refuses a project directory that others can write to, since anyone could then add module files the group loads, and warns when the setgid bit is missing, since each member's installs would then keep that member's own group.
`eb-local config` still prints every setting when the project directory is missing or refused, and warns; `config --check` then exits 1.

A project build runs with the umask EESSI-extend sets for a project install, 002, so that each member can write the directories the others' builds made: `software/`, `modules/`, EasyBuild's locks and `.eb-local/`. EasyBuild still leaves each installation read-only. A user build runs with the umask EESSI-extend sets for a user install, 077, and EasyBuild adds the sticky bit the module asks for, so an install is yours alone, as one `eb-local eb` makes. Installs made before eb-local 3.2 keep their modes. To share installs, use `--project`; where others must read a user install, as Lmod running as uid 0 in a user-namespace build must, pass `--umask=022` among eb's options.

A successful build removes its workspace, unless `EB_LOCAL_KEEP_WORK=1` is set; a failed one keeps it for inspection until the allocation ends.
The build does not pass `LD_LIBRARY_PATH`, `LD_PRELOAD` or `LD_AUDIT` through to `eb`, and it does not run `BASH_ENV` or honour `SHELLOPTS`, so a startup file or a trace cannot see the build or its secrets.

## EESSI-extend, without a site file

`eb-local eb` is the way to run EasyBuild where there is no site file and no Slurm job: inside `eessi_container.sh`, on a laptop with the CernVM File System (CVMFS) mount, or anywhere else the EESSI init can be sourced. It sources that init, loads `EESSI-extend`, and execs `eb`. The module keeps EESSI's hooks, RPATH and compat layer. Host Cargo and CMake wrappers are unset first, and the compat-layer linker is put on `PATH` even when `rustc` is not installed.
EasyBuild builds under `$WORKING_DIR/easybuild`, as the module sets it. This command leaves `WORKING_DIR` as you set it; unset, the module uses `/tmp/$USER`, so two users on one node do not share a build directory.

Set at most one install variable before it. A variable that is present and empty counts as set, which is how EESSI-extend reads them. With none set, this command exports nothing and creates nothing. The loaded module then installs under `$HOME/eessi`. Its help text says `$HOME/EESSI`; on EESSI 2026.06 the module uses the lowercase directory, and does not require it to exist before the load.

| variable | mode | prefix | process umask |
|---|---|---|---|
| `EESSI_USER_INSTALL` | user | created when the value is non-empty | 077 |
| `EESSI_PROJECT_INSTALL` | project | not created; the owner sets the group and the setgid bit | 002 |
| `EESSI_SITE_INSTALL` | site | the init's site software path | 022 |
| `EESSI_CVMFS_INSTALL` | cvmfs | the EESSI software path | 022 |

The module sets `EASYBUILD_UMASK` to the same end (and the sticky bit for a user prefix, the setgid bit for a project). This command does not pass `--umask`, so that value stands. An argument of eb's still overrides it: `--umask=022` is what a user-namespace build needs when Lmod, running as uid 0, skips a directory that others cannot search.

```sh
eb-local eb -- example.eb --robot          # the module's default, $HOME/eessi
export EESSI_USER_INSTALL=$HOME/eessi      # a named user prefix; it is created
eb-local eb -- example.eb --robot
```

`eb-local --explain eb -- example.eb --robot` prints the script this command runs, after a `set --` line with its arguments, and runs nothing; `bash` runs the printed text as this command would.

`--profile`, `--project` and `--config` are not this command's options. The project, site and cvmfs modes are the variables above. A caller that can pass only a program name, and then eb's own arguments, sets `EB_LOCAL_EESSI_EXTEND=1`. Every argument is then eb's, which is how an eb-stack EESSI target runs this command. The 1.x Bash script has no `eb` command.

### What a build runs

`eb-local --explain` prints the script a build runs, and creates and runs nothing.
The checks eb-local makes first are comments, then come the variables it sets for the script, a `set --` line with the script's arguments, and the script itself.
A build names this command in its first line, as in `eb-local: what this runs: eb-local --explain GSL-2.8-GCC-15.2.0.eb --robot`:

```sh
eb-local --explain GSL-2.8-GCC-15.2.0.eb --robot
```

The script does what you would type to use EESSI-extend by hand: clear the install variables a login shell may carry, set one of `EESSI_USER_INSTALL` or `EESSI_PROJECT_INSTALL`, load `EESSI/2026.06`, then `EESSI-extend`, which reads that variable as it loads, and run `eb`.
`$W` stands for the workspace a build makes in the allocation's node-local mount. With `W` set to a directory, `bash` runs the printed text as a build runs its script; the checks before it and the cleaning of logs after it are eb-local's own.

## Where things go

| what | where |
|---|---|
| installs | `$HOME/eessi`, the `prefix` setting, or `--project DIR` |
| build, temporary, cache and EESSI setup directories | a unique workspace in the allocation's node-local mount |
| downloaded source archives | `<install-prefix>/.eb-local/sources` |
| build logs | `<install-prefix>/.eb-local/logs` |

The default prefix, `$HOME/eessi`, is EESSI-extend's own, so modules installed with `eb-local`, with `eb-local eb` and with EESSI-extend loaded by hand are in one tree, with the same permissions.
That is why the default is not `$HOME/.local/eessi`: EESSI-extend, loaded with no install variable set, installs under `$HOME/eessi`, so any other default would split one user's modules into two trees, of which `eb-local env` shows one.
Before 3.0 the default was `$HOME/.local/eessi`; where that exists and `$HOME/eessi` does not, eb-local keeps using it and says so. Set `prefix` to choose either for good.
A site that wants another default for everyone sets it where EESSI-extend reads it too, as the next section shows; an Lmod hook cannot.

## A site Lmod hook

A site can set EasyBuild defaults of its own when `EESSI-extend` loads, with an Lmod hook, and needs no eb-local setting for it.
EESSI's `SitePackage.lua` registers EESSI's load hook and then runs the site's file, `/cvmfs/software.eessi.io/host_injections/2026.06/.lmod/SitePackage.lua`, so a load hook there calls EESSI's first:

```lua
local hook = require("Hook")

-- EasyBuild's source and build paths, set as EESSI-extend loads.
local function site_load_hook(t)
    if t.modFullName:find("^EESSI%-extend/") then
        local home, user = os.getenv("HOME"), os.getenv("USER")
        setenv("EASYBUILD_SOURCEPATH", pathJoin(home, ".local/easybuild/sources"))
        setenv("EASYBUILD_BUILDPATH", pathJoin("/tmp", user, "easybuild-build"))
    end
end

hook.register("load", function(t)
    eessi_load_hook(t)
    site_load_hook(t)
end)
```

Build, source and temporary paths from a hook work.
They apply when EESSI-extend is loaded by hand and under `eb-local eb`.
An eb-local build puts its own workspace and `.eb-local/sources` back after EESSI-extend loads, so the build uses those, and the two do not conflict.
Lmod undoes only what a module file sets, so the hook's values stay set after `module unload EESSI-extend`.

An install path from a hook bypasses eb-local's checks.
`EASYBUILD_INSTALLPATH`, `EASYBUILD_INSTALLPATH_SOFTWARE` or `EASYBUILD_INSTALLPATH_MODULES` set in a hook replaces the install path EESSI-extend chose, while the `MODULEPATH` the module set still names its own tree.
In an eb-local build, EasyBuild then installs, and writes its logs, outside the prefix eb-local checked: `eb-local env` and `list` do not show what it installed, and eb-local does not remove secret values from those logs.
A hook sets no install path.

A default install prefix cannot come from a load hook.
EESSI-extend reads `EESSI_USER_INSTALL` and the other install variables as its module file runs, and Lmod runs the load hook after that.
A hook that sets `EESSI_USER_INSTALL=$HOME/.local/eessi` when no install variable is set is too late for that load, which installs under `$HOME/eessi`.
The value stays after `module unload`, so the next load in the same shell installs under `$HOME/.local/eessi`, and which tree a user gets depends on what their shell did before.
A hook for the `EESSI` module itself does not run: that module sets `LMOD_PACKAGE_PATH`, through which Lmod finds EESSI's `SitePackage.lua` and so the site's, and neither is in effect for the command that loads it.

So another default goes into the environment before EESSI-extend loads, for example `EESSI_USER_INSTALL` set by a login script in `/etc/profile.d`, and into eb-local's site file as `prefix`, before the file's first table, so that eb-local builds there too:

```toml
prefix = "~/.local/eessi"
```

`eb-local doctor` then says that `EESSI_USER_INSTALL` names your prefix.

A build needs a Slurm allocation whose node-local directory, `<node_local_root>/<node_local_mount>`, is its own mount, of the configured file system type, owned by you.
Shared parallel-file-system paths, tmpfs, enclosing mounts and symbolic-link aliases are refused before anything is created.

## Build for every node type

A module is built for the CPU target of the node that built it, so a site with several node types needs one build on each.
The site file lists them in `[build.node_types]`, each as the sbatch options that place a job there; only the site file may:

```toml
[build.node_types]
cpu = "-p cpu -n 16 -t 02:00:00"
gpu = "-p gpu -n 16 -t 02:00:00 --gpus=1"
```

`eb-local --explain`, and a build started outside a job, then print an `sbatch` line for each, which runs the same build as a batch job on that node type:

```console
$ eb-local --explain GSL-2.8-GCC-15.2.0.eb --robot
# On each node type the site file lists in [build.node_types], the same build as a batch job:
#   sbatch -p cpu -n 16 -t 02:00:00 --job-name=eb-local-cpu-GSL-2.8-GCC-15.2.0.eb --chdir=/home/alice --output=%x-%j.out --wrap='exec /usr/local/bin/eb-local GSL-2.8-GCC-15.2.0.eb --robot'
#   sbatch -p gpu -n 16 -t 02:00:00 --gpus=1 --job-name=eb-local-gpu-GSL-2.8-GCC-15.2.0.eb --chdir=/home/alice --output=%x-%j.out --wrap='exec /usr/local/bin/eb-local GSL-2.8-GCC-15.2.0.eb --robot'
```

Only those lines of the explanation are shown here. Each job runs this eb-local with the same recipe, options and configuration, in the directory `--explain` ran in, and writes its output there; `eb-local list` then shows the module on each CPU target.
Before eb-local 3.2 the table was `[build.targets]`; eb-local reads that name, and warns, until 4.0.0.

`eb-local submit` sends those jobs itself. It is deprecated, and is removed in 4.0.0:

```sh
eb-local submit GSL-2.8-GCC-15.2.0.eb --robot             # every node type
eb-local submit --on gpu GSL-2.8-GCC-15.2.0.eb --robot    # only these
eb-local submit --print GSL-2.8-GCC-15.2.0.eb               # show the jobs, submit nothing
```

`--on` and `--print` come before the recipe; options after it are eb's.
The batch scripts go to `<install-prefix>/.eb-local/jobs`, and each job's output to `<install-prefix>/.eb-local/logs/submit-NODETYPE-JOBID.out`.

## What you have, and what is wrong

Each CPU target has its own tree, so a module built on one node type is not there on another.
`eb-local list` shows every module you installed, with a column per CPU target, and, with EESSI loaded, which of them this node's target lacks:

```console
$ eval "$(eb-local env)"
$ eb-local list
/home/u/eessi: 2 module(s) for 2 CPU target(s)
MODULE                   zen2  zen4*
GSL/2.8-GCC-15.2.0       x     x
pigz/2.8-GCCcore-15.2.0  x     -
Not built for this node's target, x86_64/amd/zen4 (*): pigz/2.8-GCCcore-15.2.0.
Build them in an allocation on this node type; each target needs its own build.
```

`eb-local list GSL` or `eb-local list GSL/2.8-GCC-15.2.0` narrows it.

`eb-local doctor` checks, one line each, what would stop a build, `eb-local eb` or a module load: the site file, the secrets a build reads (never their values), the prefix and its permissions, install variables and `LD_LIBRARY_PATH` left in the shell, the EESSI init `eb-local eb` sources, the allocation's node-local mount, whether EESSI is loaded and your modules are on `MODULEPATH`, eessi-arch-guard, and rtrash.
Inside a job with EESSI loaded, it asks eessi-arch-guard, where that is on `PATH`, as a build asks it, and shows the target it selects; a guard that cannot select one is a `warn`, since a build's own run of it decides.
Each line says `ok`, `info`, `warn` or `FAIL`; it exits 1 when one says `FAIL`, and changes nothing.
With a site file, what stops a build is a `FAIL`, and what stops only `eb-local eb` is a `warn`.
Without one, builds cannot run and `eb-local eb` can, so what stops `eb-local eb` is the `FAIL`.
Paste its output when asking for help.

## Clean up

```sh
eb-local clean --dry-run            # what would go
eb-local clean                      # logs older than 30 days, to the trash with rtrash
eb-local clean --sources            # downloaded archives too
eb-local clean --workspaces --no-logs   # inside an allocation: its leftover workspaces
```

With [rtrash](https://github.com/HaoZeke/rtrash) on `PATH`, files go to the trash (`rtrash list`, `rtrash restore`); without it, nothing is deleted unless you pass `--delete`.
A directory among the logs, such as the `reprod_*` copies of a failed build's easyconfig, easyblocks and hooks, goes whole once nothing in it is newer than the cutoff: the copies keep their originals' older times.
`clean` never follows a symbolic link out of the installation directory.

To remove something you installed, for every CPU target you built it for:

```sh
eb-local uninstall pigz/2.8-GCCcore-15.2.0 --dry-run
eb-local uninstall pigz/2.8-GCCcore-15.2.0      # to the trash with rtrash, or --delete
eb-local restore pigz/2.8-GCCcore-15.2.0        # back from the trash, read-only again
```

EasyBuild leaves installations read-only, so `rm -rf` fails on them; `uninstall` makes their directories writable first, and removes the module files with them, along with the links EasyBuild makes to each from `modules/<class>/`.
If another module you installed loads the one you name, `uninstall` lists it and removes nothing, because that module would then fail to load; name both in the same command to remove both.
`restore` brings back what `uninstall` moved to the trash, for every CPU target, with `rtrash restore`, and takes write permission away again, as EasyBuild does.
`rtrash restore` on one path brings back read-only files in writable directories: rtrash moves a directory, and empties the trash, only when its directories are writable.

## Configuration

Settings come from, lowest first: built-in defaults, the site file, a site profile, your file, your profile, `EB_LOCAL_*` variables, options.
`eb-local config` prints every setting and where it came from; `eb-local profiles` lists the profiles.
`--config FILE`, or `EB_LOCAL_CONFIG=FILE` without it, is read in place of the site file when root or the program's owner owns it, otherwise in place of your file when you own it.
The other file is still read, so a named site file keeps your profiles and secrets, and a file of yours cannot set the storage settings.

```toml
# ~/.config/eb-local/config.toml
default_profile = "mine"

[profile.mine]
dev.modules = ["FFTW/3.3.10-GCC-15.2.0"]

[profile.group]
project = "/path/to/project/eessi"

[profile.gpu]
dev.modules = ["CUDA/13.3.0"]
```

`eb-local --profile gpu dev` or `EB_LOCAL_PROFILE=gpu` selects a profile; without either, `default_profile` does, from your file if it sets one, else from the site file.
The keys are `default_profile` (outside any profile), `prefix`, `project`, `stack.module`, `stack.extend`, `dev.buildenv`, `dev.buildenv_for.{cuda,llvm,intel,nvhpc}`, `dev.modules`, `build.allocation_hint`, `build.site_toolchains` and `build.node_types` (site file only), `clean.trash` (`auto`, `rtrash` or `none`), `clean.logs_older_than_days`, `nimvault.program`, `nimvault.vault`, `[eessi]` and `[secrets]`; the variables are `EB_LOCAL_PREFIX`, `EB_LOCAL_PROJECT`, `EB_LOCAL_STACK_MODULE`, `EB_LOCAL_STACK_EXTEND`, `EB_LOCAL_DEV_BUILDENV`, `EB_LOCAL_DEV_BUILDENV_FOR_{CUDA,LLVM,INTEL,NVHPC}` (`none` for the RPATH wrappers), `EB_LOCAL_DEV_MODULES`, `EB_LOCAL_BUILD_ALLOCATION_HINT`, `EB_LOCAL_CLEAN_TRASH`, `EB_LOCAL_CLEAN_LOGS_OLDER_THAN_DAYS`, `EB_LOCAL_NIMVAULT_PROGRAM`, `EB_LOCAL_NIMVAULT_VAULT` and `EB_LOCAL_SECRET_<NAME>`.
An unknown key, a wrong type, a duplicate key or an unsafe module name is an error naming its file and line, in every profile, selected or not.

The site file is the first that exists of `config.toml` beside the program, `/etc/eb-local/config.toml`, and a 1.x `eb-local.conf` beside the program or in `/etc`.
It also holds the storage settings, which only it may set:

```toml
[storage]
node_local_root = "/local"               # where allocation mounts are
node_local_mount = "%u.%j"               # each allocation's mount below it: %u the user, %j the job id
node_local_fstype = "xfs"
shared_scratch = ["/scratch", "/work"]

[build]
allocation_hint = "salloc -p cpu -n 16 -t 02:00:00"
site_toolchains = ["intel/2026.1"]       # toolchains EESSI's hooks accept besides foss and lfoss
```

`site_toolchains` reaches EasyBuild as `EESSI_SITE_TOP_LEVEL_TOOLCHAINS_<EESSI version>`, so users build recipes on those toolchains without setting the variable; `eb-local config` shows it.
`env` and `dev` print it too, after the stack loads, for `eb` run by hand.

Other settings for the EESSI module and its EasyBuild hooks go in `[eessi]`, in the site file, your file or a profile; `env`, `dev` and builds export them before the stack loads:

```toml
[eessi]
EESSI_IGNORE_LMOD_ERROR_ZEN4_GCC1220 = "1"
```

`[eessi]` takes `EESSI_*` names other than the install and target variables eb-local sets itself (`EESSI_USER_INSTALL`, `EESSI_PROJECT_INSTALL`, `EESSI_SITE_INSTALL`, `EESSI_CVMFS_INSTALL`, `EESSI_SITE_SOFTWARE_PREFIX`, `EESSI_SOFTWARE_SUBDIR_OVERRIDE`, `EESSI_ACCELERATOR_TARGET_OVERRIDE`, `EESSI_OVERRIDE_GPU_CHECK`) and the `EESSI_SITE_TOP_LEVEL_TOOLCHAINS_*` ones `site_toolchains` sets. `eb-local eb` reads the four install variables from the environment instead.
`eb-local config` shows each value; a credential belongs in `[secrets]`, not here.

### Site files from a template

eb-local carries one site file template, `slurm`, for any Slurm cluster whose jobs get a node-local disk.
A site can keep its own template in a file, named with a slash, in a repository of its own; `examples/sites/example.toml` is a worked example of such a file, for a site that does not exist.

```sh
eb-local site list                                  # the built-in templates and their placeholders
eb-local site show slurm --set node_local_root=/local --set shared_scratch=/scratch   # rendered and checked
eb-local site install ./site.toml --set partition=gpu   # a template file of the site's own
```

`install` writes `config.toml` beside the program (or `--to FILE`), mode 644, only after the rendered file loads as a site file; it never replaces an existing file without `--force`, and never through a symbolic link.
A `--set` value cannot hold a quote, a backslash or a control character.
A template file is read only when it is a regular file, not a symbolic link, not writable by group or others.

### The configuration as variables

`eb-local config --env` prints the settings in force as `export EB_LOCAL_...` lines, secrets as `EB_LOCAL_SECRET_<NAME>=<source>`, so a job script, a container or CI carries the same configuration without the files. `EB_LOCAL_PREFIX` and `EB_LOCAL_PROJECT` are the absolute path `env` uses, with `~/` expanded and symbolic links resolved:

```sh
eb-local --profile gpu config --env > eb-local.env   # sources only, never values
. ./eb-local.env && eb-local config                  # each setting now says [environment ...]
```

Empty settings are printed too, and `EB_LOCAL_PROFILE` is printed empty, which selects no profile, not even `default_profile`: the lines already hold every setting of the profile in force, and they work where that profile is not defined.
An empty `EB_LOCAL_DEV_MODULES`, `EB_LOCAL_BUILD_ALLOCATION_HINT`, `EB_LOCAL_NIMVAULT_PROGRAM` or `EB_LOCAL_NIMVAULT_VAULT` empties its setting; any other empty `EB_LOCAL_*` variable is ignored.
`EB_LOCAL_SECRET_<NAME>` is checked as a `[secrets]` entry is. `[eessi]` settings come out as the `EESSI_*` variables themselves, which reach EESSI as they are. The storage settings and `build.site_toolchains` have no variable: only the site file sets them.

A configuration file is used only when it is a regular file, not a symbolic link, not writable by group or others, and owned by root or the program's owner (a site file) or by you (your file); otherwise eb-local stops.
A site file you own is refused unless you own the program too, since only the site file sets the storage settings and `build.site_toolchains`.
A 1.x `eb-local.conf` is read as before.

## Secrets

A build that needs a credential, such as a licence server or a token for a private source mirror, names where it comes from; the value is never written in a configuration file:

```toml
[secrets]
LM_LICENSE_FILE = "nimvault:licences/flexlm"   # nimvault get licences/flexlm
SOURCE_TOKEN = "file:~/.secrets/source-token"   # your file, mode 600
MIRROR_PASSWORD = "env:MY_MIRROR_PASSWORD"
```

- Values are read only for a build, after every other check, and go only into the environment of `eb` and what it runs.
- `eb-local config --check` reads each secret and reports `ok` or why not, never the value.
- After the build, the logs written during it (in `.eb-local/logs` and each installation's `easybuild/`) have each value, its base64 form and its percent-encoded form (either hex case) replaced. The usual replacement is `<secret NAME removed by eb-local>`; a value that those words contain is replaced with `<redacted:N>` instead, so the marker does not put the value back. Where one value is a prefix of another, the longer one is removed whole. The log directory is private meanwhile. EasyBuild compresses the copy in an installation (with `bzip2` under EESSI-extend): a log ending in `.bz2`, `.gz`, `.xz` or `.zst` is decompressed and compressed again with `bzip2`, `gzip`, `xz` or `zstd` from `PATH`. A value shorter than 4 bytes, or a log that is too large or too deep to check or that cannot be decompressed, is reported instead, including an installation log nested too deep to reach. A secret reaches every program the build runs. A build stopped with a signal is cleaned up, including those logs, and eb-local then dies from that same signal, so a cancelled job does not continue; a build killed with SIGKILL leaves its logs unchecked. eb-local passes SIGINT, SIGTERM, SIGHUP and SIGQUIT on to EasyBuild, except one from the terminal, such as Ctrl-C, which reaches EasyBuild directly, and cleans the logs only once EasyBuild has exited, so the lines it writes as it stops are cleaned too. An ignored signal, as SIGHUP is under `nohup`, stays ignored. `eb-local eb` passes signals on in the same way.
- A secret cannot set `PATH`, `LD_*`, `EESSI_*`, `EASYBUILD_*` or another variable the build depends on.
- [nimvault](https://github.com/HaoZeke/nimvault) runs with a 30-second deadline; on failure eb-local shows its error output, never what it printed as the value.
- nimvault finds its vault from `NIMVAULT_VAULT_REPO` or the current git repository, so a build started inside another repository reads that one. Name the vault, and the program if it is not on `PATH`:

  ```toml
  # ~/.config/eb-local/config.toml
  [nimvault]
  vault = "~/vault"                     # passed as nimvault get ENTRY --vault ~/vault
  program = "/opt/nimvault/bin/nimvault"
  ```

  A profile may name its own vault. An entry starting with `-` is refused, since nimvault would read it as an option.

## Install

On a cluster whose site installs eb-local, load its module and skip the rest of this section.

Otherwise, download the static binary, one file per architecture, from a [release](https://github.com/stackhands/eb-local/releases):

```sh
v=3.1.0; f=eb-local-$v-$(uname -m)-linux-musl
mkdir -p ~/.local/bin && cd ~/.local/bin
curl -fLO "https://github.com/stackhands/eb-local/releases/download/v$v/$f"
curl -fL "https://github.com/stackhands/eb-local/releases/download/v$v/SHA256SUMS" | sha256sum -c --ignore-missing
mv "$f" eb-local && chmod 755 eb-local
eb-local --version
```

`env` and `dev` work once `~/.local/bin` is on `PATH`.
Building with EasyBuild also needs a site file beside the program: `eb-local site install slurm` with your cluster's paths, or the site's own template file.
To build from source: `zig build --release=safe` with Zig 0.17.1.

Each release binary has a build provenance attestation and, from 2.4.0, a CycloneDX SBOM (`$f.cdx.json` beside it) with its own attestation.
With the GitHub CLI, check both before the `mv`:

```sh
gh attestation verify "$f" --repo stackhands/eb-local
gh attestation verify "$f" --repo stackhands/eb-local --predicate-type https://cyclonedx.org/bom
```

The Bash script (`eb-local`, 1.x) is frozen: it gains no commands, and it is removed in 4.0.0, when the suite's default run against it ends too.
It needs GNU coreutils, util-linux `findmnt`, Lmod and an EESSI 2026.06 mount, and has no profiles or secrets.
It reads one site file, `eb-local.conf`: the file `EB_LOCAL_CONFIG` names, else the one beside the script, else `/etc/eb-local.conf`, used only when it is a regular file, not a symbolic link, not writable by group or others, and owned by root, the script's owner or you.
Its `key = value` lines set `node_local_root`, `node_local_mount`, `node_local_fstype`, `shared_scratch`, `allocation_hint`, `stack_module`, `extend_module`, `dev_buildenv` and `trash`.
A site's easyconfig installs the program and its site configuration.

## Test

```sh
python3 -m unittest discover -s tests                    # the Bash script, until 4.0.0
zig build unit && zig build test                          # the Zig build: unit tests, then the same suite
```

`zig build test` runs the suite against a debug build with the test seams; with `-Dtest-ops=true`, as CI runs it, against the binary it builds.

A change adds a news fragment, `changelog.d/<pull request>.<type>.md` with type `feature`, `bugfix`, `doc`, `removal` or `misc`; `towncrier build --draft --version 2.1.2` shows the release notes it makes.

`tests/site/` holds the site acceptance scripts: the development tasks above, and a build inside an allocation, which takes the site's partition and node-local disk feature on its `sbatch` line and finds the allocation's mount from the site file.

## License

MIT, see [LICENSE](https://github.com/stackhands/eb-local/blob/main/LICENSE).

<!-- stackhands:begin -->
## Part of stackhands

eb-local is one of the [stackhands](https://github.com/stackhands) tools for building, installing and maintaining an HPC software stack with EasyBuild on top of EESSI.

| Tool | Job | Docs |
|---|---|---|
| [eb-stack](https://github.com/stackhands/eb-stack) | Solve, shard and plan an EasyBuild build list; admit builds under a scratch inode budget | [docs](https://eb-stack.rgoswami.me/) |
| [eb-staged-rebuild](https://github.com/stackhands/eb-staged-rebuild) | Rebuild an installation in a staged tree and swap it in, so running jobs keep their paths | [docs](https://stackhands.github.io/eb-staged-rebuild/) |
| [eessi-arch-guard](https://github.com/stackhands/eessi-arch-guard) | Reload EESSI in a Slurm task that inherited it for another CPU or GPU | [docs](https://stackhands.github.io/eessi-arch-guard/) |
| **eb-local** | Install software with EasyBuild on top of EESSI into a directory a user or project owns | [docs](https://stackhands.github.io/eb-local/) |
| [eb-keep-logs](https://github.com/stackhands/eb-keep-logs) | Keep a failed build's EasyBuild log and command output; rotate a pipeline's log tree | [docs](https://stackhands.github.io/eb-keep-logs/) |
| [eb-pipeline](https://github.com/stackhands/eb-pipeline) | Run a build list through a site's EasyBuild pipeline, described in one per-site TOML file | [docs](https://github.com/stackhands/eb-pipeline#readme) |
| [rfc9162](https://github.com/stackhands/rfc9162) | Append-only Merkle logs hashed as RFC 9162, with tiled storage and signed checkpoints | [docs](https://stackhands.github.io/rfc9162/) |
| [zig-common](https://github.com/stackhands/zig-common) | The shared Zig library under the Zig tools: system calls, checked files, child processes | [docs](https://stackhands.github.io/zig-common/) |
<!-- stackhands:end -->
