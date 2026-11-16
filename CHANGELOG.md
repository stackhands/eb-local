# Changelog

<!-- towncrier release notes start -->

## 3.1.0 (2026-11-16)

### Features

- `eb-local doctor` reports, one line each, what would stop a build or a module load: the site file, the prefix and its permissions, install variables and loader variables left in the shell, the allocation's node-local mount, EESSI and `MODULEPATH`, and rtrash. It exits 1 when a line says FAIL and changes nothing.
- `eb-local list [NAME[/VERSION]...]` shows the modules installed in the prefix with a column per CPU target, and, with EESSI loaded, the ones this node's target lacks.
- `eb-local submit [--on NAME,...] [--print] RECIPE [eb options]` sends one batch job per node type the site file lists in `[build.targets]` (a name and its sbatch options, site file only), each running this eb-local with the same recipe and configuration, so a module is built for every CPU target. `eb-local config` shows the targets.


## 3.0.0 (2026-11-16)

### Features

- The default install prefix is `$HOME/eessi`, EESSI-extend's own default, so `eb-local`, `eb-local eb` and EESSI-extend loaded by hand share one tree. An existing `$HOME/.local/eessi`, the earlier default, stays in use while `$HOME/eessi` does not exist, with a warning; `prefix` chooses either for good.
- `[eessi]` in the site file, your file or a profile sets `EESSI_*` variables for the EESSI module and its hooks; `env`, `dev` and builds export them before the stack loads, `eb-local config` shows them, and `config --env` prints them as themselves. The install and target variables eb-local sets itself, and the toolchain list `build.site_toolchains` sets, are refused.
- `dev` picks the build environment for the compilers the modules bring in: GCC, CUDA, `llvm-compilers` (lfoss), `intel-compilers` or NVHPC. When Lmod has none for that family, RPATH wrappers for the compilers and linkers on `PATH` stand in, so a program never links without run paths. `dev.buildenv_for` or `EB_LOCAL_DEV_BUILDENV_FOR_<FAMILY>` names a site's own build environment per family, `config --env` leaves the default `dev.buildenv` out so the choice survives the round trip, and `eb-local rpath-wrappers` prints the wrapper lines on their own.
- `eb-local --explain RECIPE [eb options]` prints the commands a build runs, as shell lines with its checks as comments, and creates and runs nothing; it works outside an allocation.
- `eb-local check FILE...` reads a program or library and reports what stops it running on this node without `LD_LIBRARY_PATH`: another architecture, the host's loader or libraries under EESSI, `RUNPATH` instead of `RPATH`, run paths into another CPU target's tree, and libraries not found or found only through `LD_LIBRARY_PATH`.
- `eb-local dev` sets `EB_LOCAL_DEV_PREFIX` to `<install-prefix>/dev/<EESSI version>/<CPU target>`, with the GPU target appended when EESSI found one, so hand builds install per target by default.
- `eb-local eb` sources the EESSI init, loads `EESSI-extend` and runs `eb`, with no site file and no Slurm job. Exactly one of `EESSI_USER_INSTALL`, `EESSI_PROJECT_INSTALL`, `EESSI_SITE_INSTALL` and `EESSI_CVMFS_INSTALL` may be set, and a present empty value counts as set. A non-empty user prefix is created; a project, site or cvmfs prefix is not. With none of the four set, nothing is exported: the module installs under `$HOME/eessi` (its help text says `$HOME/EESSI`). The process umask is 077, 002 or 022 for those modes, and EasyBuild keeps the umask, the sticky bit and the hooks the module sets. `EB_LOCAL_EESSI_EXTEND=1` selects the same launcher when every argument belongs to `eb`.
- `eb-local site show` and `eb-local site install` take a site's own template file as well as a built-in template: a NAME with a slash, such as `./site.toml`, is read as a template, with the same placeholders and checks. The file is read only when it is a regular file, not a symbolic link, not writable by group or others.
- `storage.node_local_mount` (`node_local_mount` in a 1.x `eb-local.conf`) names each allocation's mount below `storage.node_local_root`: one file name, with `%u` for the user and `%j`, which it must hold, for the job id. The default, `%u.%j`, is the layout eb-local required until now, so a site file without the key works as before; `eb-local config` shows the setting, and the `slurm` template takes it as a placeholder.

### Fixes

- A `shared_scratch` path is taken literally. A glob character in it is no longer expanded, so the named tree is what a build refuses and a neighbour that happens to match is not.
- A build does not pass `BASH_ENV`, `ENV`, `SHELLOPTS`, `BASHOPTS`, `LD_LIBRARY_PATH`, `LD_PRELOAD` or `LD_AUDIT` to `eb`. A startup file cannot run in the build, a trace cannot print it, and host libraries cannot be selected ahead of the toolchain.
- A build stopped by a signal is cleaned up, including its logs, and eb-local then dies from that signal. A shell or Slurm sees the signal instead of exit 128+n and does not continue the job. An ignored signal, as with nohup, stays ignored.
- A build workspace is mode 0700 even when the process umask would clear those bits. mkdir was applying the umask, and a umask of 0777 left a directory this process could not enter.
- A build, `env` and `dev` run `eessi-arch-guard` when it is on `PATH`, after loading EESSI and before EESSI-extend, in the Zig build and the Bash script, so software installs for the CPU target Slurm tasks get. On a Sapphire Rapids CPU without `waitpkg`, EESSI detects `x86_64/intel/sapphirerapids` and the guard selects `x86_64/intel/icelake`; a build from `salloc` installed into the sapphirerapids tree, and an `srun` task on the same node could not load the module. A build stops when the guard cannot select a target.
- A file named with `--config` or `EB_LOCAL_CONFIG` that root or the program's owner owns replaces only the site file; your file was not read either, so its profiles, default profile and secrets were lost. `eb-local help` and the README now say what a named file replaces.
- A later `dev` removes the RPATH wrapper directory a previous `dev` put first on `PATH`, so a build environment loaded afterwards is the one that compiles.
- A project install (`--project`, `project`) keeps the umask EESSI-extend sets for one, 002. eb-local passed `eb --umask=022` and made `.eb-local/` with the caller's umask, so a second member's build failed with EACCES on EasyBuild's lock, the logs or the sources. It now makes what it creates in a project directory with umask 002 and passes no `--umask`; a user install keeps `--umask=022`.
- A site file must be owned by root or by the program's owner, as the code already required; the README and the code's comment said one you own was used too. A refused configuration file now says who may own it.
- A symbolic link whose target does not exist yet is resolved the way `readlink -m` does, so a dangling link from the installation prefix onto shared scratch is refused before a workspace is made.
- Removing a build workspace, and the empty directories clean leaves behind, stays on that file system. A mount point inside the tree is left in place, as `rm --one-file-system` does.
- Secret redaction removes the longer of two overlapping values whole, matches percent-encoding in either hex case, and uses a marker that does not contain the value. An installation log nested too deep to search is reported for the easybuild tree as well as the log tree.
- Secret values are removed from the copy of the log EasyBuild keeps in an installation, which it compresses (`easybuild/*.log.bz2` under EESSI-extend): a log ending in `.bz2`, `.gz`, `.xz` or `.zst` is decompressed with `bzip2`, `gzip`, `xz` or `zstd` from `PATH`, cleaned and compressed again. The read-only `easybuild/` EasyBuild leaves no longer stops the check, and a log that cannot be checked or rewritten is named.
- The lfoss warning no longer fires for a site build environment whose name has no LLVM toolchain in it; it covers a chosen GCC build environment only, and knows lmpflf.
- The lines that say how to eval `env` or `dev` repeat the config file, profile, project and buildenv that produced them, shell-quoted, so the hint is the environment that was printed.
- The shell conditions shellcheck SC2015 flagged are `if` statements, and the build cleanup function is called on the way out as well as from the EXIT trap, so SC2317 is not silenced with a disable comment.
- `clean` ages each file and directory at the top of the logs as a whole, by the newest time in it, in both the binary and the Bash script. EasyBuild copies a build's easyconfig, easyblocks and hooks into `reprod_<time>_<pid>/` keeping their own older times, so `clean` removed those copies from a build made the same day and left the rest of the directory. A directory goes to the trash with `rtrash put -r`, and the counts say items rather than files.
- `config --env` exports an empty `[eessi]` value, which is how a profile clears a setting from the site file.
- `config --env` prints empty settings too, and `EB_LOCAL_PROFILE` empty, so the lines select no profile. A job that sourced them where the files are still in place got the default profile back beneath them, with its modules and secrets, and a value the chosen profile cleared, such as the allocation hint, came back from the file that set it. An empty `EB_LOCAL_DEV_MODULES`, `EB_LOCAL_BUILD_ALLOCATION_HINT`, `EB_LOCAL_NIMVAULT_PROGRAM` or `EB_LOCAL_NIMVAULT_VAULT` now empties its setting instead of being ignored.
- `config` prints every setting when the project directory is missing, not a directory or writable by others, and then warns; it stopped before printing anything, so the profile that named the directory could not be read. `config --check` reads the secrets too and exits 1. Every other command still stops.
- `dev` loads each module once, where it is first named in `dev.modules` or on the command line, and a chosen build environment (`dev.buildenv` or `--buildenv`) only last: a module named in both, or twice, was printed twice. Lmod loads a repeated module once, so this changes the printed lines, not what is loaded.
- `dev` recognises an lfoss or intel module by the `EBROOT` name EasyBuild writes, where a hyphen in the software name becomes `min`.
- `eb-local config --env` prints `EB_LOCAL_PREFIX` and `EB_LOCAL_PROJECT` as the absolute path `env` uses, with `~/` expanded and symbolic links resolved, so sourcing the lines from another directory follows the same tree.
- `eb-local restore NAME/VERSION` brings back from the trash what `uninstall` moved there, for every CPU target, and takes write permission away again, as EasyBuild leaves an installation. A link EasyBuild made to the module file from `modules/<class>/` comes back after the file. `uninstall` made every file writable before `rtrash put`, so `rtrash restore` brought an installation back writable; it now makes only the directories writable, which rtrash needs to move a directory and to empty the trash, and the files keep their read-only modes.
- `env` and `dev` now export `build.site_toolchains` after the stack loads, as a build does, so `eb` run by hand accepts those toolchains too.
- `env`, `dev` and a build load the stack and EESSI-extend in two `module load` calls, in the Zig build and the Bash script. Lmod 9.4.5 finds every module of a load before it loads any, and EESSI-extend is on `MODULEPATH` only once EESSI is loaded, so the single call exited 1 and loaded nothing unless EESSI was already loaded.
- `uninstall` removes the links EasyBuild makes to a module file from `modules/<class>/NAME/VERSION.lua`, with the module file, and the `NAME` directories they leave empty. It left them dangling; naming the module again now removes a link an earlier `uninstall` left.
- `zig build -Dtest-ops=true test` no longer shows a passing command-line suite as a failed command: the suite step inherits stdio, so unittest's report reaches the terminal as it is, and the step runs every time instead of being skipped while the binary is unchanged, which left an edited test unrun.
- `zig build -Dtest-ops=true test` started in a subdirectory such as `src/` runs the command-line suite: the suite step runs in the build root, where `-s tests` finds it, instead of where `zig build` was started, where unittest stopped with `Start directory is not importable: 'tests'`.

### Documentation

- The README and the help give the order in which the site file is found, `default_profile`, `EB_LOCAL_KEEP_WORK=1`, why the modules go on the `dev` line, and the `eb-local.conf` the 1.x script reads; the stackhands table lists eb-pipeline, and `.gitignore` the Zig build and package directories.
- The README says what a cluster test showed: loading the build environment before or after the libraries gives the same run paths; it has to be loaded, and `dev` loads it last only so that no other compiler's `gcc` or `ld` comes ahead of its wrappers.
- The README's per-target build example names a partition placeholder rather than a site's partition, and says the build environment compiles with `-march=native`.
- The README, the help and `eb-local.conf.example` describe no particular site: their examples use a neutral one (node-local mounts under `/local`, shared scratch `/scratch` and `/work`, partition `cpu`, a project under `/path/to/project`), and the help no longer names the tool eb-local replaced at one site.

### Removals

- The `snellius` site template is no longer built into eb-local, whose built-in templates are for no particular site; it is now the worked example `examples/sites/snellius.toml`, with the same settings. `eb-local site install snellius [--set partition=genoa]` becomes `eb-local site install examples/sites/snellius.toml [--set partition=genoa]`, run from a checkout of eb-local. A site file already installed needs no change.

### Miscellaneous

- News fragments in `changelog.d/`, assembled into `CHANGELOG.md` by towncrier at release, as in the other stackhands repositories.
- The acceptance scripts in `tests/site/` name no partition or node feature, which go on the `sbatch` line, and find the allocation's mount from `node_local_root` and `node_local_mount` in the site file, so they run at any site.


## 2.4.0

* `eb-local uninstall` keeps a module that another installed module
  loads (`depends_on` or `load` in its Lua module file) and lists the
  dependents; naming them in the same command removes them all.
* A project directory (`--project`, `project`) writable by others is
  refused, and one without the setgid bit gets a warning naming
  `chmod g+s`.
* Releases carry a CycloneDX 1.6 SBOM per binary
  (`eb-local-VERSION-ARCH-linux-musl.cdx.json`), written by
  `tools/sbom.py` from `build.zig.zon` and attested with
  `actions/attest-sbom`.

## 2.3.0

* `eb-local site list | show NAME | install NAME`: site file templates
  built into the program, `snellius` and `slurm`, with placeholders filled
  by `--set KEY=VALUE`. `install` writes `config.toml` beside the program
  (or `--to FILE`), mode 644, only after the rendered file loads as a site
  file; it replaces a file only with `--force` and never writes through a
  symbolic link.
* `eb-local config --env` prints the settings in force as `export
  EB_LOCAL_...` lines; `EB_LOCAL_SECRET_<NAME>=SOURCE` sets a secret's
  source and is checked as the `[secrets]` table is.
* `[nimvault] program` and `vault` (`EB_LOCAL_NIMVAULT_PROGRAM`,
  `EB_LOCAL_NIMVAULT_VAULT`): nimvault runs as `get ENTRY --vault DIR`, so a
  build started inside another git repository does not read that
  repository's vault. A nimvault entry starting with `-` is refused.

## 2.2.0

* `build.site_toolchains` in the site file lists NAME/VERSION toolchains
  that EESSI's hooks accept besides foss and lfoss; a build exports them as
  `EESSI_SITE_TOP_LEVEL_TOOLCHAINS_<EESSI version>`, replacing a value the
  caller exported. A user file or a profile cannot set it (#3).
* `dev` warns when a named module belongs to the lfoss hierarchy
  (`llvm-compilers`, `lompi`, `lfbf`, `lfoss`) and the build environment
  wraps only the GCC compilers, and points at `--buildenv` (#2).
* Global options may come before the command: `eb-local --profile gpu dev`
  ran as a build of an easyconfig named `dev`.
* README: a program built with `dev` belongs to one CPU target (#4); a
  copy-paste install of the release binary with its checksum.
* CI: every action pinned to a commit SHA, read-only tokens, dependabot.

## 2.1.2

* `uninstall` with rtrash passes `-r`: `rtrash put` follows rm(1) and
  refused the installation directories, so 2.1.1 trashed the module files
  and left the installations. Installations now go first, in their own
  call, so a refusal leaves every module file in place. Found by running
  against rtrash 0.1.4 on Snellius; the test double now refuses a
  directory without `-r` as rtrash does.

## 2.1.1

Fixes from an adversarial review of 2.1.0:

* Only a site file (owned by root or by the account that installed
  eb-local) may set `[storage]`; a file of your own named with `--config`
  or `EB_LOCAL_CONFIG` is a user file, and the site file is always read.
  Shared scratch and node-local trees are compared after resolving symbolic
  links, and the installation's `versions` and `.eb-local` trees must not
  lead onto them.
* Secrets: the log directory is made private (0700) for a build that has
  them; the copy of the log EasyBuild keeps in an installation's
  `easybuild/` is cleaned too; base64 and percent-encoded forms of a value
  are removed with it; a value too short to remove, and a log too large or
  too deep to check, is reported.
* `uninstall` looks only at installations (beside their module files, per
  CPU target), never descends into installed software, and refuses any
  path through a symbolic link.
* The build command keeps the signal dispositions it was started with, so
  `nohup eb-local ...` survives a hangup.
* `clean` checks for rtrash or `--delete` before it removes anything, and
  says how many workspaces it removed.
* Paths are made canonical as `readlink -m` does (`link/..` is the parent
  of the link's target).
* The TOML reader refuses arrays nested more than 32 deep and files of more
  than 10000 keys and items.

## 2.1.0

* `eb-local uninstall NAME/VERSION...`: an installation and its module file,
  for every CPU target under the installation directory, made writable (an
  EasyBuild installation is read-only, so `rm -rf` fails on it) and moved to
  the trash with rtrash, or deleted with `--delete`; `--dry-run` lists them.
  A symbolic link is never followed.

## 2.0.0

eb-local in Zig, one static binary per architecture; the Bash script stays
in the repository as the reference implementation, and the command-line
suite runs against both.

* `eb-local dev [MODULE...]`: the lines that load EESSI, the named modules
  and a build environment last, so `gcc`, `mpicc`, `make`, CMake and meson
  build programs that run without `LD_LIBRARY_PATH`. Checked on Snellius
  for C with FFTW and OpenMP, MPI, CMake against GSL, a Python venv with a
  compiled package, and an R package.
* `eb-local env`: the lines that make your installed modules visible;
  `--env` keeps working. Before the first install the stack is loaded
  alone, because EESSI-extend refuses a missing install directory and Lmod
  then undoes the whole load.
* Layered TOML configuration: the site file, a site profile, your file, your
  profile, `EB_LOCAL_*` variables and options, with `eb-local config`
  showing where each setting came from and `eb-local profiles` listing the
  profiles. Storage settings come only from the site file. Every key, type
  and module name is checked, in every profile, with file and line. A 1.x
  `eb-local.conf` is read as before.
* Secrets from the environment, owner-only files or nimvault, named in the
  configuration and never written in it; read only for a build, passed only
  to `eb`, never printed (`eb-local config --check` reports `ok` or why
  not), and removed from the logs written during the build.
* A successful build removes its node-local workspace; a failed one keeps it
  and says where. `eb-local clean` moves old logs (and, asked, sources) to
  the trash with rtrash, deletes only with `--delete` without it, removes
  an allocation's leftover workspaces, and never follows a symbolic link out
  of the installation directory.
* Output for `eval` is shell-quoted and module names are checked, so it
  means the same whatever the input.
* Documentation: <https://stackhands.github.io/eb-local/>.

## 1.3

* The node-local root and the shared scratch trees come from
  `eb-local.conf`; without a node-local root, a build stops before it
  creates anything.

## 1.2

* The workspace is bound to the current user and allocation.

## 1.1

* The node-local allocation requirement is shown in the build hint; the
  owned installation environment is selected after EESSI-extend is unloaded.

## 1.0

* The first release: build and install with EasyBuild on top of EESSI
  2026.06 into a directory you own, with a project mode and `--env`.
