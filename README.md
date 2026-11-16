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
Load the modules you link against on the `dev` line, not after it.
EESSI 2026.06 ships one build environment, `buildenv/default-foss-2026.1`, whose wrappers cover the GCC compilers; see [Other compilers](#other-compilers) for clang, flang and the rest.

These were checked on Snellius with EESSI 2026.06, each program then run with no modules at all:

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
"$HOME/.local/eessi/dev/$EESSI_VERSION/$EESSI_SOFTWARE_SUBDIR/bin/prog"   # with the default prefix
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
`eb-local rpath-wrappers` prints the same lines on their own.

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

For a group install, the project owner creates the directory once with the project group and the setgid bit:

```sh
mkdir -p /path/to/project/eessi && chgrp myproj /path/to/project/eessi && chmod 2770 /path/to/project/eessi
eb-local --project /path/to/project/eessi GSL-2.8-GCC-15.2.0.eb --robot
```

eb-local refuses a project directory that others can write to, since anyone could then add module files the group loads, and warns when the setgid bit is missing, since each member's installs would then keep that member's own group.

A successful build removes its workspace; a failed one keeps it for inspection until the allocation ends.
The build does not pass `LD_LIBRARY_PATH`, `LD_PRELOAD` or `LD_AUDIT` through to `eb`, and it does not run `BASH_ENV` or honour `SHELLOPTS`, so a startup file or a trace cannot see the build or its secrets.

## EESSI-extend, without a site file

`eb-local eb` is the way to run EasyBuild where there is no site file and no Slurm job: inside `eessi_container.sh`, on a laptop with the CernVM File System (CVMFS) mount, or anywhere else the EESSI init can be sourced. It sources that init, loads `EESSI-extend`, and execs `eb`. The module keeps EESSI's hooks, RPATH and compat layer. Host Cargo and CMake wrappers are unset first, and the compat-layer linker is put on `PATH` even when `rustc` is not installed.

Set exactly one install variable before it. A variable that is present and empty counts as set, which is how EESSI-extend reads them. With none set, the mode is a user install at `$HOME/EESSI`, and that directory is created.

| variable | mode | prefix | process umask |
|---|---|---|---|
| `EESSI_USER_INSTALL` | user | created when the value is non-empty | 077 |
| `EESSI_PROJECT_INSTALL` | project | not created; the owner sets the group and the setgid bit | 002 |
| `EESSI_SITE_INSTALL` | site | the init's site software path | 022 |
| `EESSI_CVMFS_INSTALL` | cvmfs | the EESSI software path | 022 |

The module sets `EASYBUILD_UMASK` to the same end (and the sticky bit for a user prefix, the setgid bit for a project). This command does not pass `--umask`, so that value stands. An argument of eb's still overrides it: `--umask=022` is what a user-namespace build needs when Lmod, running as uid 0, skips a directory that others cannot search.

```sh
export EESSI_USER_INSTALL=$HOME/EESSI
eb-local eb -- example.eb --robot
```

`--profile`, `--project` and `--config` are not this command's options. The project, site and cvmfs modes are the variables above. A caller that can pass only a program name, and then eb's own arguments, sets `EB_LOCAL_EESSI_EXTEND=1`. Every argument is then eb's, which is how an eb-stack EESSI target runs this command. The 1.x Bash script has no `eb` command.

## Where things go

| what | where |
|---|---|
| installs | `$HOME/.local/eessi`, the `prefix` setting, or `--project DIR` |
| build, temporary, cache and EESSI setup directories | a unique workspace in the allocation's node-local mount |
| downloaded source archives | `<install-prefix>/.eb-local/sources` |
| build logs | `<install-prefix>/.eb-local/logs` |

A build needs a Slurm allocation whose node-local directory is its own mount, of the configured file system type, owned by you.
Shared parallel-file-system paths, tmpfs, enclosing mounts and symbolic-link aliases are refused before anything is created.

## Clean up

```sh
eb-local clean --dry-run            # what would go
eb-local clean                      # logs older than 30 days, to the trash with rtrash
eb-local clean --sources            # downloaded archives too
eb-local clean --workspaces --no-logs   # inside an allocation: its leftover workspaces
```

With [rtrash](https://github.com/HaoZeke/rtrash) on `PATH`, files go to the trash (`rtrash list`, `rtrash restore`); without it, nothing is deleted unless you pass `--delete`.
`clean` never follows a symbolic link out of the installation directory.

To remove something you installed, for every CPU target you built it for:

```sh
eb-local uninstall pigz/2.8-GCCcore-15.2.0 --dry-run
eb-local uninstall pigz/2.8-GCCcore-15.2.0      # to the trash with rtrash, or --delete
```

EasyBuild leaves installations read-only, so `rm -rf` fails on them; `uninstall` makes them writable first, and removes the module files with them, along with the links EasyBuild makes to each from `modules/<class>/`.
If another module you installed loads the one you name, `uninstall` lists it and removes nothing, because that module would then fail to load; name both in the same command to remove both.

## Configuration

Settings come from, lowest first: built-in defaults, the site file, a site profile, your file, your profile, `EB_LOCAL_*` variables, options.
`eb-local config` prints every setting and where it came from; `eb-local profiles` lists the profiles.

```toml
# ~/.config/eb-local/config.toml
default_profile = "mine"

[profile.mine]
dev.modules = ["FFTW/3.3.10-GCC-15.2.0"]

[profile.group]
project = "/projects/0/myproj/eessi"

[profile.gpu]
dev.modules = ["CUDA/13.3.0"]
```

`eb-local --profile gpu dev` or `EB_LOCAL_PROFILE=gpu` selects a profile.
The keys are `prefix`, `project`, `stack.module`, `stack.extend`, `dev.buildenv`, `dev.buildenv_for.{cuda,llvm,intel,nvhpc}`, `dev.modules`, `build.allocation_hint`, `build.site_toolchains` (site file only), `clean.trash` (`auto`, `rtrash` or `none`), `clean.logs_older_than_days`, `nimvault.program`, `nimvault.vault`, `[eessi]` and `[secrets]`; the variables are `EB_LOCAL_PREFIX`, `EB_LOCAL_PROJECT`, `EB_LOCAL_STACK_MODULE`, `EB_LOCAL_STACK_EXTEND`, `EB_LOCAL_DEV_BUILDENV`, `EB_LOCAL_DEV_BUILDENV_FOR_{CUDA,LLVM,INTEL,NVHPC}` (`none` for the RPATH wrappers), `EB_LOCAL_DEV_MODULES`, `EB_LOCAL_BUILD_ALLOCATION_HINT`, `EB_LOCAL_CLEAN_TRASH`, `EB_LOCAL_CLEAN_LOGS_OLDER_THAN_DAYS`, `EB_LOCAL_NIMVAULT_PROGRAM`, `EB_LOCAL_NIMVAULT_VAULT` and `EB_LOCAL_SECRET_<NAME>`.
An unknown key, a wrong type, a duplicate key or an unsafe module name is an error naming its file and line, in every profile, selected or not.

The site file (`/etc/eb-local/config.toml`, or `config.toml` beside the program) also holds the storage settings, which only it may set:

```toml
[storage]
node_local_root = "/scratch-node"        # allocation mounts are <root>/<user>.<job id>
node_local_fstype = "xfs"
shared_scratch = ["/scratch-shared", "/gpfs/scratch1"]

[build]
allocation_hint = "salloc -p rome -n 16 -t 02:00:00 --constraint=scratch-node"
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

eb-local carries site file templates: `snellius`, and `slurm` for any Slurm cluster whose jobs get a node-local disk.

```sh
eb-local site list                                  # templates and their placeholders
eb-local site show snellius --set partition=genoa   # the file, rendered and checked
eb-local site install slurm --set node_local_root=/local --set shared_scratch=/scratch
```

`install` writes `config.toml` beside the program (or `--to FILE`), mode 644, only after the rendered file loads as a site file; it never replaces an existing file without `--force`, and never through a symbolic link.
A `--set` value cannot hold a quote, a backslash or a control character.

### The configuration as variables

`eb-local config --env` prints the settings in force as `export EB_LOCAL_...` lines, secrets as `EB_LOCAL_SECRET_<NAME>=<source>`, so a job script, a container or CI carries the same configuration without the files. `EB_LOCAL_PREFIX` and `EB_LOCAL_PROJECT` are the absolute path `env` uses, with `~/` expanded and symbolic links resolved:

```sh
eb-local --profile gpu config --env > eb-local.env   # sources only, never values
. ./eb-local.env && eb-local config                  # each setting now says [environment ...]
```

`EB_LOCAL_SECRET_<NAME>` is checked as a `[secrets]` entry is. `[eessi]` settings come out as the `EESSI_*` variables themselves, which reach EESSI as they are. The storage settings and `build.site_toolchains` have no variable: only the site file sets them.

A configuration file is used only when it is a regular file, not a symbolic link, not writable by group or others, and owned by root, the program's owner or you (a site file) or by you (your file); otherwise eb-local stops.
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
- After the build, the logs written during it (in `.eb-local/logs` and each installation's `easybuild/`) have each value, its base64 form and its percent-encoded form (either hex case) replaced. The usual replacement is `<secret NAME removed by eb-local>`; a value that those words contain is replaced with `<redacted:N>` instead, so the marker does not put the value back. Where one value is a prefix of another, the longer one is removed whole. The log directory is private meanwhile. A value shorter than 4 bytes, or a log that is too large or too deep to check, is reported instead, including an installation log nested too deep to reach. A secret reaches every program the build runs. A build stopped with a signal is cleaned up, including those logs, and eb-local then dies from that same signal, so a cancelled job does not continue; a build killed with SIGKILL leaves its logs unchecked.
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
v=2.4.0; f=eb-local-$v-$(uname -m)-linux-musl
mkdir -p ~/.local/bin && cd ~/.local/bin
curl -fLO "https://github.com/stackhands/eb-local/releases/download/v$v/$f"
curl -fL "https://github.com/stackhands/eb-local/releases/download/v$v/SHA256SUMS" | sha256sum -c --ignore-missing
mv "$f" eb-local && chmod 755 eb-local
eb-local --version
```

`env` and `dev` work once `~/.local/bin` is on `PATH`.
Building with EasyBuild also needs a site file beside the program: `eb-local site install snellius`, or the `slurm` template with your cluster's paths.
To build from source: `zig build --release=safe` with Zig 0.17.1.

Each release binary has a build provenance attestation and, from 2.4.0, a CycloneDX SBOM (`$f.cdx.json` beside it) with its own attestation.
With the GitHub CLI, check both before the `mv`:

```sh
gh attestation verify "$f" --repo stackhands/eb-local
gh attestation verify "$f" --repo stackhands/eb-local --predicate-type https://cyclonedx.org/bom
```

The Bash script (`eb-local`, 1.x) needs GNU coreutils, util-linux `findmnt`, Lmod and an EESSI 2026.06 mount, and has no configuration files, profiles or secrets.
A site's easyconfig installs the program and its site configuration.

## Test

```sh
python3 -m unittest discover -s tests                    # the Bash script
zig build unit && zig build -Dtest-ops=true test          # the Zig build: unit tests, then the same suite
```

A change adds a news fragment, `changelog.d/<pull request>.<type>.md` with type `feature`, `bugfix`, `doc`, `removal` or `misc`; `towncrier build --draft --version 2.1.2` shows the release notes it makes.

`tests/site/` holds the acceptance scripts run on Snellius: the development tasks above, and a build inside an allocation.

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
| [rfc9162](https://github.com/stackhands/rfc9162) | Append-only Merkle logs hashed as RFC 9162, with tiled storage and signed checkpoints | [docs](https://stackhands.github.io/rfc9162/) |
| [zig-common](https://github.com/stackhands/zig-common) | The shared Zig library under the Zig tools: system calls, checked files, child processes | [docs](https://stackhands.github.io/zig-common/) |
<!-- stackhands:end -->
