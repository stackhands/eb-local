<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="branding/logo/logo-dark.svg">
    <img src="branding/logo/logo-light.svg" alt="eb-local" width="420">
  </picture>
</p>

# eb-local

Build your own code and install software on top of [EESSI](https://www.eessi.io) (the European Environment for Scientific Software Installations) 2026.06, without knowing EasyBuild's RPATH wrappers, `buildenv` or `LD_LIBRARY_PATH`.

Documentation: <https://stackhands.github.io/eb-local/>

<!-- docs:start -->
## Compile your own code

```sh
eval "$(eb-local dev FFTW/3.3.10-GCC-15.2.0)"
gcc -O2 -fopenmp prog.c -lfftw3 -o prog
./prog                      # runs in a new shell or a job, with no modules loaded
```

[Compile your code against EESSI](docs/howto/compile.md) has the steps for each node type, other compilers and the checks; [Run paths, and one build per CPU target](docs/explanation/run-paths.md) says why the program needs no `LD_LIBRARY_PATH`.

## Install software with EasyBuild

```sh
salloc -p <partition> -n 16 -t 02:00:00   # on nodes with a node-local disk
eb-local GSL-2.8-GCC-15.2.0.eb --robot
```

[Install software on top of EESSI with EasyBuild](docs/howto/install-software.md) has the steps, a build for a group, and what each failure means; [Load EESSI and the software you installed](docs/howto/load-eessi.md) loads the modules in a new shell or job.

## EESSI-extend, without a site file

```sh
eb-local eb -- pigz-2.8-GCCcore-15.2.0.eb --robot   # no site file or Slurm job; installs into $HOME/eessi
```

`eb-local eb` sources the EESSI init, loads `EESSI-extend`, and runs `eb`, where there is no site file and no Slurm job: inside `eessi_container.sh`, on a laptop with the CernVM File System (CVMFS) mount, or anywhere else the EESSI init can be sourced.
[Run EasyBuild through EESSI-extend without a site file](docs/howto/eb-without-a-site-file.md) has the steps, and [Where EESSI-extend installs](docs/explanation/install-variables.md) says where each install variable sends an install and what eb-local checks.
`eb-local --explain RECIPE` prints the script a build runs, and `eb-local --explain eb -- ARGS` the one `eb-local eb` runs; [The eb-local command](docs/reference/cli.md) says what each holds.

## Where things go

Installs go into `$HOME/eessi`, EESSI-extend's own default, the `prefix` setting or `--project DIR`; a build works in a new workspace in its allocation's node-local mount, and keeps source archives and logs in `<install-prefix>/.eb-local`.
[Where a build puts things, and why](docs/explanation/where-things-go.md) says why, and [Refusals](docs/reference/refusals.md) lists what a build refuses before it makes anything.

## A site's defaults

A site sets EasyBuild paths for every user with an Lmod hook that runs as `EESSI-extend` loads, and another default prefix with a login script and `prefix` in the site file.
[Set a site's EasyBuild defaults and default prefix](docs/howto/set-site-defaults.md) has the steps, and [Where EESSI-extend installs](docs/explanation/install-variables.md) says why a hook can set neither an install path nor the prefix.

## Build for every node type

A module is built for the CPU target of the node that built it; where the site file lists the node types in `[build.node_types]`, `eb-local --explain` prints an `sbatch` line for each that runs the same build there.
[Build for every node type](docs/howto/build-for-every-node-type.md) has the steps, and `eb-local submit`, deprecated until 4.0.0.

## What you have, and what is wrong

Each CPU target has its own tree, so a module built on one node type is not there on another.
`eb-local list` shows the modules you installed, with a column per CPU target, and `eb-local doctor` checks, one line each, what would stop a build, `eb-local eb` or a module load.
[Find what is wrong with a build or a module](docs/howto/find-what-is-wrong.md) has the steps, and [The eb-local command](docs/reference/cli.md) lists what `doctor` checks.

## Clean up

```sh
eb-local clean --dry-run                        # what would go
eb-local clean                                  # logs older than 30 days, to the trash with rtrash
eb-local clean --sources                        # downloaded archives too
eb-local clean --workspaces --no-logs           # inside an allocation: its leftover workspaces
eb-local uninstall pigz/2.8-GCCcore-15.2.0      # for every CPU target, to the trash with rtrash
eb-local restore pigz/2.8-GCCcore-15.2.0        # back from the trash, read-only again
```

[Clean up after builds, and remove what you installed](docs/howto/clean-up.md) has the steps, and [The eb-local command](docs/reference/cli.md) the options.

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
The keys are `default_profile` (outside any profile), `prefix`, `project`, `stack.module`, `stack.extend`, `dev.buildenv`, `dev.buildenv_for.{cuda,llvm,intel,nvhpc}`, `dev.modules`, `build.allocation_hint`, `build.secrets`, `build.site_toolchains` and `build.node_types` (site file only), `clean.trash` (`auto`, `rtrash` or `none`), `clean.logs_older_than_days`, `nimvault.program`, `nimvault.vault`, `[eessi]` and `[secrets]`; the variables are `EB_LOCAL_PREFIX`, `EB_LOCAL_PROJECT`, `EB_LOCAL_STACK_MODULE`, `EB_LOCAL_STACK_EXTEND`, `EB_LOCAL_DEV_BUILDENV`, `EB_LOCAL_DEV_BUILDENV_FOR_{CUDA,LLVM,INTEL,NVHPC}` (`none` for the RPATH wrappers), `EB_LOCAL_DEV_MODULES`, `EB_LOCAL_BUILD_ALLOCATION_HINT`, `EB_LOCAL_BUILD_SECRETS`, `EB_LOCAL_CLEAN_TRASH`, `EB_LOCAL_CLEAN_LOGS_OLDER_THAN_DAYS`, `EB_LOCAL_NIMVAULT_PROGRAM`, `EB_LOCAL_NIMVAULT_VAULT` and `EB_LOCAL_SECRET_<NAME>`.
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

eb-local carries one site file template, `slurm`, for any Slurm cluster whose jobs get a node-local disk; a site can keep its own in a repository of its own.
[Write the site file for a cluster](docs/howto/write-a-site-file.md) renders, installs and checks one.

### The configuration as variables

`eb-local config --env` prints the settings in force as `export EB_LOCAL_...` lines, secrets as `EB_LOCAL_SECRET_<NAME>=<source>`, so a job script, a container or CI carries the same configuration without the files; [Load EESSI and the software you installed](docs/howto/load-eessi.md) shows how, and [The environment variables](docs/reference/environment.md) lists them.

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

A build gets every secret unless `build.secrets` names the ones it gets, and then only those: set it to `[]` in your file and name the secrets in the profile of the builds that need them, or for one build with `EB_LOCAL_BUILD_SECRETS`, names separated by spaces:

```toml
# ~/.config/eb-local/config.toml
[build]
secrets = []                              # no build gets a secret it does not name

[profile.licensed]
build.secrets = ["LM_LICENSE_FILE"]       # eb-local --profile licensed MATLAB-2026a.eb
```

```sh
EB_LOCAL_BUILD_SECRETS=SOURCE_TOKEN eb-local Private-1.0-GCC-15.2.0.eb
```

A secret a build does not get is not read, so it cannot stop that build. A name no secret has is an error that says where it was set. `eb-local config` shows `build.secrets`, and `eb-local --explain RECIPE` which secrets reach `eb`. [Give a secret only to the builds that need it](docs/howto/scope-secrets.md) has the steps.

- Values are read only for a build, after every other check, and go only into the environment of `eb` and what it runs.
- `eb-local config --check` reads each secret and reports `ok` or why not, never the value.
- After the build, the logs written during it (in `.eb-local/logs` and each installation's `easybuild/`) have each value, its base64 form and its percent-encoded form (either hex case) replaced. The usual replacement is `<secret NAME removed by eb-local>`; a value that those words contain is replaced with `<redacted:N>` instead, so the marker does not put the value back. Where one value is a prefix of another, the longer one is removed whole. The log directory is private meanwhile. EasyBuild compresses the copy in an installation (with `bzip2` under EESSI-extend): a log ending in `.bz2`, `.gz`, `.xz` or `.zst` is decompressed and compressed again with `bzip2`, `gzip`, `xz` or `zstd` from `PATH`. A value shorter than 4 bytes, or a log that is too large or too deep to check or that cannot be decompressed, is reported instead, including an installation log nested too deep to reach. A secret a build gets reaches every program the build runs. A build stopped with a signal is cleaned up, including those logs, and eb-local then dies from that same signal, so a cancelled job does not continue; a build killed with SIGKILL leaves its logs unchecked. eb-local passes SIGINT, SIGTERM, SIGHUP and SIGQUIT on to EasyBuild, except one from the terminal, such as Ctrl-C, which reaches EasyBuild directly, and cleans the logs only once EasyBuild has exited, so the lines it writes as it stops are cleaned too. An ignored signal, as SIGHUP is under `nohup`, stays ignored. `eb-local eb` passes signals on in the same way.
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

On a cluster whose site installs eb-local, load its module.
Otherwise, download the static binary for your architecture from a [release](https://github.com/stackhands/eb-local/releases), or build it from source with Zig 0.17.1: [Install eb-local](docs/howto/install.md) has the steps and the checks.

## Test

```sh
python3 -m unittest discover -s tests                    # the Bash script, until 4.0.0
zig build unit && zig build test                          # the Zig build: unit tests, then the same suite
```

`zig build test` runs the suite against a debug build with the test seams; with `-Dtest-ops=true`, as CI runs it, against the binary it builds.

A change adds a news fragment, `changelog.d/<pull request>.<type>.md` with type `feature`, `bugfix`, `doc`, `removal` or `misc`; `towncrier build --draft --version 2.1.2` shows the release notes it makes.

`prek run --all-files` runs the hooks in `prek.toml`, and `prek install` runs them on each commit: whitespace and end-of-file fixes, YAML and TOML checks, `zig fmt --check`, shellcheck and codespell.

The documentation is this README and the pages under `docs/`. A page with an Org source in `docs/orgmode/` is written from it, so edit the Org file and run `emacs --batch -Q -l docs/export.el`; `tests/test_docs.py` checks that the two agree where Emacs is installed. `python -m sphinx -W -b html docs docs/_build/html` builds the site, as CI does; it needs Zig 0.17.1 on `PATH`, to write the API reference from the code.

`tests/site/` holds the site acceptance scripts: the development tasks of [Compile your code against EESSI](docs/howto/compile.md), and a build inside an allocation, which takes the site's partition and node-local disk feature on its `sbatch` line and finds the allocation's mount from the site file.

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
