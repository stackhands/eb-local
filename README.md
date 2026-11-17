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
## When EESSI-extend alone is enough

eb-local loads EESSI's own `EESSI-extend` module unchanged and runs `eb`; the install goes where EESSI-extend puts it, with EESSI's hooks.
If you build on one node type, interactively, and need nothing below, `module load EESSI-extend` and `eb` is the same install ([Building on top of EESSI](https://www.eessi.io/docs/using_eessi/building_on_eessi/)).
eb-local adds what that leaves to each user:

- `eb-local dev` puts EasyBuild's RPATH compiler wrappers in front of your own `gcc` or `mpicc`, so a program you compile runs later with no modules loaded;
- a build runs only inside a Slurm job, in the job's node-local disk, and refuses shared scratch as a work or install directory, before it creates anything;
- `eb-local list` shows which CPU targets each module you installed was built for, since EESSI-extend keeps one tree per target;
- `eb-local uninstall` removes an install and its module file for every target, which EasyBuild leaves read-only and neither EasyBuild nor Lmod removes.

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
`eb-local config` prints every setting and where it came from, and `eb-local profiles` the profiles; `eb-local config --env` prints the settings as variables for a job script, a container or CI.
[The configuration files](docs/reference/configuration.md) lists the files, the profiles and every setting, [The environment variables](docs/reference/environment.md) the variables, and [Write the site file for a cluster](docs/howto/write-a-site-file.md) has the steps for a site file.

## Secrets

A build that needs a credential, such as a licence server or a token for a private source mirror, names in `[secrets]` where its value comes from, `env:VARIABLE`, `file:PATH` or `nimvault:ENTRY`, and never the value.
A build gets every secret unless `build.secrets` names the ones it gets, and the logs written during it are cleaned of each value it gets.
[Give a secret only to the builds that need it](docs/howto/scope-secrets.md) has the steps, and [What happens to a secret](docs/explanation/secrets.md) says when a value is read, where it goes and what is cleaned.

## Install

On a cluster whose site installs eb-local, load its module.
Otherwise, download the static binary for your architecture from a [release](https://github.com/stackhands/eb-local/releases), or build it from source with Zig 0.17.1: [Install eb-local](docs/howto/install.md) has the steps and the checks.
In a source checkout, `./eb-local --version` is the frozen Bash 1.x compatibility script; the installed Zig binary is the `eb-local` command this README and the docs describe.

## Contributing

[Contributing](docs/contributing.md) has the tests, the news fragment each change adds, the site acceptance scripts in `tests/site/`, and how to build these pages.

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
