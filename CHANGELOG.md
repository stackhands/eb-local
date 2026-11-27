# Changelog

<!-- towncrier release notes start -->

## 3.6.0 (2026-11-27)

### Features

- The internal helper `eb-local __vm-run --mode kvm|tcg --cpu-target TARGET -- COMMAND` runs COMMAND inside a QEMU virtual CPU that presents an EESSI target, as the caller, in the caller's working directory, and refuses, before COMMAND starts, when EESSI archdetect, archspec, `gcc -march=native`, the CPU vendor or `/dev/fd` do not name the target.
- `--cpu-target TARGET` builds an easyconfig for another CPU target than the build host's, with `--mask auto|cpuid|kvm|tcg` choosing the route. The `cpuid` route runs the build with CPUID faulting and a target `/proc/cpuinfo` in an unprivileged namespace, refuses to build unless EESSI archdetect, archspec, gcc and the CPUID vendor name the target, pins the GROMACS SIMD level to the target, audits the installed tree and records the route in `easybuild/eb-local-build-mode.json`; `doctor --cpu-target` reports what the host can present.
- `--mask kvm` and `--mask tcg` run the build through `eb-local __vm-run`, and report its statuses 2, 125 and 126 as a refused request, a virtual machine that did not run and a guest CPU that did not read as the target. `--mask-allow-archspec-mismatch` passes `--allow-archspec-mismatch` to the helper and lets the build's preflight accept an archspec name other than the target's, which an aarch64 `--mask tcg` build needs because archspec reads `aarch64` under qemu-user.
- `--variant perf` and `--variant debug` build the named easyconfig with debug symbols and frame pointers, or unoptimised with debug symbols, as a module whose version ends in `-perf` or `-debug`; `doctor --profiling` reports whether perf may sample and debuggers attach, and finds perf, valgrind and gdb.
- `eb-local audit-isa PATH --target TARGET` runs `objdump` on the ELF files under PATH. It reports each instruction that needs a CPU feature the EESSI target lacks, per file with counts. It covers x86-64 (AVX-512, AMX) and aarch64 (SVE, SVE2, BF16, I8MM). Packages that choose their instruction set at run time print as dispatch and do not fail the audit; `--allow FILE` replaces that list. Exit 0 means clean, 1 means an instruction exceeds the target, and 2 means a usage or tool error.
- `eb-local dev` prints the Cargo linker lines that `eb-local eb` already runs. They live in `src/cargo-linker.sh`: a host `CARGO_TARGET_*_LINKER`, `RUSTFLAGS` and the rustc wrappers are dropped, and when `rustc -vV` prints a host, `CARGO_TARGET_<target>_LINKER` is `${CC:-gcc}`. The Zig program embeds that file.

### Fixes

- A `--cpu-target aarch64/neoverse_v1` or `aarch64/a64fx` build under `--mask tcg` stopped before `eb` started with `no mask profile`. The preflight in the virtual machine now takes the vendor and compiler names of a target that has no `cpuid` profile from the `__vm-run` target table.
- A failed sync or close while writing `eb-local.lock` leaves the previous lock in place. A new lock is published only after its bytes are durable, and a failed write removes its temporary file.
- A failed sync or close while writing a submit script is an error, and that script is not handed to sbatch.
- A signalled build keeps killing and reaping descendants until none remain or ten seconds pass, and if one remains it reports that, exits 1, and does not clean the logs.
- Avoid reloading the EESSI stack and extension modules when applying a development lock while preserving extension loading for locks written before the install prefix exists.
- Emit `drop_rpath_wrappers` and `rpath-wrappers` after loading locked modules in `eb-local dev --locked`, covering compiler families without a `buildenv` module such as `llvm-compilers` on EESSI 2026.06. Each `rpath-wrappers` command is checked, and `EB_LOCAL_DEV_PREFIX` is exported only after those commands succeed.
- The scheduler read an apostrophe in a `#SBATCH` `--output` or
  `--chdir` path as an opening quote, stopped on the unmatched quote
  and never submitted the job. `eb-local submit` now double-quotes
  such a path.
- `--profile` now selects the profile for `eb-local profiles`. It wins
  over `EB_LOCAL_PROFILE` and `default_profile`, and an unknown name is
  refused.
- `--variant` now works only with a recipe build or `submit`. Other commands refuse it instead of running as if it were absent.
- `audit-isa` stops with `cannot resolve PATH` when the working directory is gone and PATH is relative, and `__vm-run` reports `cannot resolve the read-only share PATH` and exits 125 in that case, where each reported out of memory or gave no reason.
- `doctor.approved_prefixes` refuses a path with a parent component or a spelling of the root directory, so `eb-local doctor` and a build with `build.clear_foreign_prefixes` do not treat that spelling as an approved prefix.
- `eb-local __vm-run --mode kvm --cpu-target x86_64/amd/zen3` refused with status 126 because the guest read as `x86_64/amd/zen2`: QEMU's EPYC-Milan model has no `vaes`, which EESSI archdetect requires. The zen3 guest now adds `vaes` and `vpclmulqdq`.
- `eb-local submit` keeps every job script, prints the path it submits, and writes the new script beside one whose path is already taken.

### Documentation

- Document in `docs/howto/compile.md` that the European Environment for Scientific Software Installations (EESSI) 2026.06 includes `buildenv/default-foss-2026.1` and has no `default-lfoss` or `default-intel` build environment.
- Document in the command reference that `--variant` is accepted before an easyconfig and before `submit`. `submit` keeps the option and puts it on the batch command. Another command refuses it.
- The README lists the check, rpath-wrappers, lmod-cache, modulerc, overlay and site commands and doctor --cvmfs and --mpi, says clean refuses without rtrash unless --delete is given, and says eb-local builds on a workstation as well as in a Slurm job.

### Miscellaneous

- CI builds a recipe on a GitHub-hosted runner with the EESSI mount and no Slurm, the path a user without a cluster takes.
- Discover `eb-stack` 0.8.0 or newer from `PATH` when `EB_STACK_BIN` is
  unset, isolate host `/etc/profile.d/lmod.sh` and `/etc/eb-local` site
  files in a mount namespace with a user-namespace probe and bounded
  timeouts, and run the full Python suite with zero skips in the `zig` CI
  job.
- Extract the compiler family detection snippet used by `buildenvLines` into a shared helper with no behavior change.
- Guard the remaining doctor tests that require no site file from host
  configuration, and cover them in the zero-skip isolation check.
- Require `zsh`, `eb-stack`, and `unshare` in `ZeroPythonSkips` when `EB_LOCAL_REQUIRE_TOOLS` is set, and skip with a reason otherwise.
- Run the live EESSI 2026.06 checks in `tests/site/test_dev_locked_eessi.py`
  outside `python3 -m unittest discover -s tests`. `tests/site` is not a
  package, so the zero-skip `zig` job does not collect them. Running the
  file fails when the Zig build or the EESSI init file is absent.
- The `arm-mask` workflow runs the aarch64 mask on a real Neoverse core (`ubuntu-24.04-arm`): `getauxval`, `/proc/cpuinfo` and `gcc -mcpu=native` name the target under `__mask-run`, and a recipe builds for `aarch64/neoverse_n1` with EESSI mounted, the preflight and the ISA audit on.
- The `live-eessi` job in the `zig` workflow runs `tests/site/test_dev_locked_eessi.py` on an EESSI 2026.06 mount.


## 3.5.0 (2026-11-26)

### Features

- Build managed EasyBuild recipes automatically when Slurm is absent, or explicitly with `--workstation`/`storage.mode = "local"`, using securely opened private local workspace roots that `clean --workspaces` can find after `$TMPDIR` changes.
- Recipe overlays can add typed top-level easyconfig assignments without a Python hook.
- `EB_LOCAL_PIN_BUILDENV_PYTHON=1` puts only the compatibility-layer `python3` before a foreign interpreter when `dev` loads a build environment.
- `eb-local dev` sets `JULIA_DEPOT_PATH` and `R_LIBS_USER` under `EB_LOCAL_DEV_PREFIX` when the caller has not set them. Julia's depot keeps the bundled depots after it. R's library uses R's `%p-library/%v` layout. An empty value is left as the caller set it.
- `eb-local dev` sets `PYTHONUSERBASE` under `EB_LOCAL_DEV_PREFIX` when the caller has not set it, so pip's user install stays on that CPU target. An empty value is left as the caller set it.
- `eb-local dev` sets matching Go paths under `EB_LOCAL_DEV_PREFIX` only when the caller has not set them, preserves empty and custom values, and records language directory state in the backward-compatible dev-v3 lifecycle record.
- `eb-local env` and a build unset install locations from `install_vars`, the same names in the same order as `share/env-scrub.json`.

### Fixes

- A lock that cannot be released at the end of a successful `clean`,
  `uninstall`, `restore`, build or `lmod-cache` is reported as
  `eb-local: cannot release the lock on PATH: [Errno N] text`, and the
  command exits 1. After an earlier failure, including a failed write to
  standard output, the release error is dropped and the first failure's
  message and exit status stand. A signal that stops the command, such as
  one received while a build cleans its logs, drops it too. The
  descriptor is closed either way.
- Check diagnostics name each installed binary or library and the NEEDED entry it cannot resolve.
- Compiler wrappers record the directories of shared libraries linked by absolute path as run paths.
- Development environments preserve wrapper run paths across CMake and Meson installs.
- Five eb-local writers report a failed close or `fsync` as an error
  where they used to drop it. `dev --envrc` and `dev --lock` exit 2 with
  `eb-local: cannot write NAME ([Errno N] text)` when the close of a new
  `.envrc` or `eb-local.lock` fails. A build on a workstation stops with
  `cannot record workstation workspace root` when that record cannot be
  synced or closed. `doctor --workspace` fails its probe when the close
  of the probe fails, where it used to report the probe as written. If
  the directory of the `timestamp` cannot be synced after the rename,
  `lmod-cache` exits 1 and puts the cache back. The Network File
  System (NFS) and some quota setups report a lost write only at these
  calls.
- If `clean` cannot write its list to standard output, it stops before it removes anything or makes the prefix lock.
  When there is nothing to clean, `clean` forgets a recorded workstation workspace root that has no workspace only after it has written that, so a failed write changes nothing.
- If `restore` cannot write its list to standard output, it stops before it restores anything or makes the prefix lock.
- If `uninstall` cannot write its list to standard output, it stops before it removes anything or makes the prefix lock.
  If a module file or link for what it listed appears while it waits for the prefix lock, `uninstall` removes nothing, so it leaves no dangling link behind.
- Isolate command-line tests in `tests/test_dev_cli_modes.py`, `tests/test_env_strict.py`, and `tests/test_list_doctor_cli.py` from a host `/cvmfs/software.eessi.io` mount using the shared helper in `tests/support.py`.
- Keep the compiler-family scratch variables local when `rpath-wrappers` fails during `eb-local dev`.
- Move held lock descriptors out of standard-stream slots 0, 1, and 2 via
  `zig-common` `sys.keepAboveStdio` so `clean`, `uninstall`, `restore`,
  `build`, and `lmod-cache` do not write standard output into `.lock`
  files when invoked with standard output closed.
- Name every job `submit` sends on standard output before it makes a directory or runs `sbatch`, and submit nothing when that fails.
- Report standard output write errors on standard error and return exit
  status 1 across human-readable and shell-evaluation subcommands when
  standard output is full or closed.
- Roll back newly created parent directories when recursive directory creation fails partway through in `lmod-cache`, `modulerc`, `overlay materialize`, and `rpath-wrappers`.
- Stop dev-shell evaluation when the architecture guard fails, including in
  conditional callers and JSON or lock evaluation.
- Warn in `eb-local doctor` when an explicitly exported install variable for the shared software stack selects a different mode or path from the configured user or project destination.
- Write the `clean --json` document before `clean` removes anything, and stop with nothing removed when it cannot be written.
  When that document is a refusal or says there is nothing to clean and cannot be written, `clean` keeps the recorded workstation workspace roots it would have forgotten.
- `build` says what it runs before it makes the install prefix. It keeps the build workspace when it cannot write the report of redacted secrets.
- `eb-local --explain eb` now emits `export` lines for the configured `EESSI_USER_INSTALL` or `EESSI_PROJECT_INSTALL`, `[eessi]` variables, `EBLOCAL_EB_SITE_TOOLCHAINS`, and `EBLOCAL_EB_SOURCEPATH` so replaying the printed script in a clean shell matches `eb-local eb`.
- `eb-local dev` now stops with the status of `rpath-wrappers` when that command fails, before it sets `EB_LOCAL_DEV_PREFIX`.
- `eb-local eb` now uses the configured user prefix or project, exports configured hook settings without replacing shell overrides, and keeps downloaded sources below the install prefix.
- `eb-local env` and `eb-local dev` now return failure before they change the shell when it has no `module` command.
- `lmod-cache` reports a failed close of the new `timestamp` and keeps
  the old one. When the directory of the `timestamp` cannot be written
  and the file is rewritten in place, a failed truncate, `fsync` or close
  of it is reported, and a file put in its place after it was checked is
  refused and not changed. If a failed update already changed the file,
  `lmod-cache` writes its previous bytes and times back through a
  duplicate of the descriptor that changed it, so a file renamed into
  its place is left alone. With `--verify`, a failed write or close of
  the candidate `spiderT.lua` or `lmodrc.lua`, or a failed close of the
  candidate `timestamp`, is reported and the cache is not changed. Each
  of these exits 1 with `eb-local: cannot write PATH: [Errno N] text`. A
  previous `spiderT.lua` that cannot be read, or is larger than 64 MiB,
  is not replaced: `lmod-cache` exits 1 with
  `eb-local: cannot read PATH: REASON; the cache was not changed`. A
  cache that was already replaced is put back through a new file that is
  renamed over it once it is written, synced and closed, and a cache with
  no previous one is removed. Each restore is tried once, and one that
  fails is reported after the error that started it, as
  `eb-local: cannot restore PATH: REASON` or
  `eb-local: cannot remove PATH: REASON`. A workstation build whose
  workspace-root record cannot be written, or whose registry or existing
  entry cannot be used, removes the workspace of the build before it
  exits 2. The record is written to a temporary file that is renamed over
  it only after the write, `fsync` and close succeed, so a failure before
  the rename removes only the temporary file and `clean --workspaces`
  still finds older workspaces under that root. A failed sync of the
  registry after the rename keeps the new entry, which names the same
  root as any entry it replaced.
- `settleGroup` keeps waiting while `wait4` reports a child in the signalled process group, so a child the `/proc` scan misses is reaped instead of being orphaned when `stop` re-raises the signal.

### Documentation

- The README describes builds on a workstation, laptop or CI runner without Slurm, and no longer says the shim passes an eb-local.conf.

### Miscellaneous

- A unit test pins that `eb-local lmod-cache`, updating `--timestamp` in place with standard input, output and error closed, keeps the duplicate it restores the timestamp through off descriptors 0, 1 and 2.
- Add shared Bash and zsh helpers for dev-shell lifecycle tests.
- Drop the unreachable no-install-variable branch from `explainExtend`, because configured defaults always populate the selected install variable.
- Let the test build fail standard output after the number of writes in `EB_LOCAL_TEST_STDOUT_WRITES`.
- Pin `zig-common` to 3119105, the `develop` merge of the checked stdout writer that adds `cli.Stdout` and `cli.writeOut`.
- Pin `zig-common` to `3c3b1720`, the `main` commit that merges
  `sys.keepAboveStdio`, so it is available for lock descriptor placement.
- Pin `zig-common` to `a45142a`, the `develop` merge of `zig-common` #89,
  where `state.RootLock.release` returns `sys.Error!void`. eb-local takes no
  `RootLock`, so no call site changes. A failed write in `lmod-cache`,
  `modulerc` and `overlay materialize` reports Python's `[Errno N] ...`
  text, with the file it names, where it used to print the error name such
  as `NoSpace` or `AccessDenied`; `site`, `submit` and
  `doctor` add that file name to the errno text they already printed.
- Run the tests that need the Zig build in the run through the shell shim as well, so `python3 -m unittest discover -s tests` without `EB_LOCAL_BIN` skips almost nothing.
- The SBOM test accepts a zig-common dependency pinned to a full
  commit as well as to a release tag.
- The cooperative reap test records the worker's `getppid` in `worker.reparented` only after a pidfd reports that the leader has exited, and keeps the worker blocked on a fifo until that parent id is the eb-local process.
- Write `main.zig` standard output through `cli.Stdout` and keep a failed heap allocation in `say` a fatal out of memory exit.
- `tests/hostile_fs.py` adds an `oversized_file` helper that creates sparse or byte-filled files with mode `0o600` for oversized CLI input checks.
- `tests/test_config_cli_modes.py` verifies that `eb-local` configuration loading rejects directory and FIFO inputs under a bounded timeout as well as dangling symlinks and malformed byte or oversized files.
- `tests/test_dev_shell_lifecycle.py` checks that `eb-local dev` keeps non-wrapper `PATH` entries in order when dropping a recorded `EB_LOCAL_RPATH_WRAPPERS` directory.
- `tests/test_hardening_cli.py` verifies that `file:` secret resolution rejects directory and FIFO paths under a bounded timeout as well as dangling symlinks and oversized inputs, and that log redaction leaves special files untouched while scrubbing byte-order mark and non-UTF-8 logs.
- `tests/test_site_cli_modes.py` verifies that `eb-local site` input subcommands reject directory and FIFO paths under a bounded timeout alongside dangling symlinks and malformed byte or oversized files.


## 3.4.0 (2026-11-22)

### Features

- Add opt-in development environment replacement and leaving to the Zig front end.
- The repository's `eb-local` POSIX shell shim delegates every command
  to the Zig program, avoids delegating to shim copies and preserves an
  adjacent `eb-local.conf`. For Bash users, the default prefix moves from
  `~/.local/eessi` to `~/eessi` while retaining an existing legacy
  install. User installs change from umask 022 to 077, so other users can
  no longer read them. An untrusted adjacent config is rejected instead
  of skipped, and child signals are re-raised rather than translated to
  status 128 plus the signal number.

### Fixes

- A build, `eb-local eb` and `eb-local doctor` no longer refuse an installation prefix or a workspace on btrfs with `no space left on device (... 0 free inodes)`. btrfs has no inode table and reports zero total and zero free inodes; such a file system is full only when it has no free bytes. `doctor --workspace` says that the file system does not count inodes.
- Add the `init/modules` directory of `EESSI` for builds, `eb-local env` and `eb-local dev` when a distribution's Lmod has no `EESSI` module on MODULEPATH, and say so in `eb-local doctor` instead of failing.
- Avoid leaking open pipe descriptor `fd 3` into child processes or stalling on background children when `env --json`, `dev --json`, `dev --lock`, or `dev --locked --json` evaluates shell setup lines.
- Build the Zig CLI before the shell test suite exercises the delegation shim.
- Cancel contended `.eb-local/.lock` waits on `SIGINT`, `SIGTERM`, `SIGHUP`, and `SIGQUIT` via `common.state.lockExclusiveCancel`, removing unused build workspaces before re-raising.
- Discover `config.toml` and `eb-local.conf` in `<checkout>` directly from the Zig binary when running out of `<checkout>/zig-out/bin/eb-local`, without relying on `EB_LOCAL_CONFIG` from the shell shim.
- Doctor fails when a readable Lmod initializer does not define the module command a build requires.
- Doctor refuses an install prefix that lies under a symbolic link naming shared scratch or the node-local root.
- Doctor treats a workspace under a shared scratch root as shared when that root is a symbolic link.
- Format filesystem diagnostics with `[Errno N] ...` via `storage.describeError` across `build`, `check`, `dev`, `clean`, and `doctor` to match `COMPAT` notes and `docs/reference/refusals.md`.
- Forward `SIGINT`, `SIGTERM`, `SIGHUP`, and `SIGQUIT` to `lmod-cache` child process groups and remove temporary verification and uncommitted cache directories before re-raising.
- Forward `SIGINT`, `SIGTERM`, and `SIGHUP` from `Guard.run` to the child process group across `build`, `eb`, `submit`, and `clean`, isolating non-TTY children in a dedicated process group while preserving single-signal terminal `Ctrl-C` delivery.
- Hold the signal guard across `submit` targets and unlink unsubmitted batch scripts when interrupted by `SIGINT`, `SIGTERM`, `SIGHUP`, or `SIGQUIT`.
- Initialize Lmod for the shell that evaluates eb-local env or eb-local dev, including clean zsh sessions.
- Keep the delegation shim valid POSIX shell when it skips shim copies on PATH.
- Preserve the loading executable's compatibility-layer loader root and inherited `DT_RPATH` across transitive shared-library checks in `eb-local check --recursive`, preventing false host-`libc` reports on EESSI binaries. The inherited run paths are searched before `LD_LIBRARY_PATH`, as the loader does.
- Publish Lmod cache `timestamp` files atomically with pre-backdated `mtime` so concurrent readers never observe `timestamp.mtime >= spiderT.lua.mtime`.
- Refuse non-regular FIFO inputs and outputs without blocking in `overlay materialize`, and validate output targets with exit code 2 in `--dry-run`.
- Reject dev locks whose CPU target contains empty, `.` or `..` path components.
- Reject malformed module names passed as `list` filters.
- Remove `EB_LOCAL_CONFIG` injection from the repository `eb-local` shell shim so it strictly locates and `exec`s the Zig binary without mutating the environment.
- Report OS errno diagnostics and exit `1` whenever `eb-local lmod-cache` (`--dry-run`, `--prefix`, or `--modulepath`) fails to write standard output to `/dev/full` or a closed descriptor.
- Report OS errno diagnostics and exit `1` whenever `eb-local modulerc` (`--check`, `--dry-run`, or write mode) fails to write standard output to `/dev/full` or a closed descriptor.
- Serialize concurrent `lmod-cache` writers across cache and timestamp directories via `common.state.lockExclusiveCancel`, canceling contended waits cleanly on termination signals.
- Stage and lock `.eb-local.lock` before publishing `eb-local.XXXXXXXX` build workspaces so `clean --workspaces` cannot delete a build workspace waiting on `.eb-local/.lock`.
- Submit refuses an install prefix or working directory containing a newline that would split an #SBATCH directive.
- Terminate `build_script` and `extend.script` immediately on `SIGINT` during module and target setup instead of letting GNU Bash wait-and-cooperative-exit drop `SIGINT` when a foreground setup helper catches `SIGINT` and exits normally.
- The RPATH wrappers that `dev` and `rpath-wrappers` put first read the arguments in a response file, `@FILE`, and add a run path for the directory of a shared library named by its full path. Meson and CMake put a long link line in a response file, and CMake and pkg-config often name a library by its path, so such a link recorded no run path for those libraries outside `LIBRARY_PATH`; a compile in a response file, which the wrapper took for a link, no longer gets run path options.
- Try later Lmod initializers when an earlier readable initializer defines no `module` command.
- Use `common.proc.run` instead of `std.process.run` in `storage.probeWorkspace` so `doctor --workspace` never opens and retains an un-`CLOEXEC` `/dev/null` descriptor via `std.Io.Threaded`.
- Wait on reparented child-group `SIGCHLD` events via `PR_SET_CHILD_SUBREAPER` and `signalfd` with a 500 ms deadline before escalating to `SIGKILL` in `Guard.run`, ensuring descendants flush logs and exit before secret redaction and lock release.
- `eb-local dev --locked` now skips the modules in `eb-local.lock` when that file records an EESSI version and the shell's `EESSI_VERSION` is different.
- `eb-local dev` uses nounset-safe expansions for an EESSI software target, so shells using `set -u` do not abort when a module omits either target variable.

### Documentation

- A how-to guide, *Build CUDA software against a site's GPU modules*, covers building on the GPU node a site module is visible on, giving programs a run path into a Python package's library directory that its module leaves off `LIBRARY_PATH`, checking the installation with `eb-local check`, and libraries an install step copies with the build's run path.
- A new guide, `docs/howto/install-your-own-recipe.md`, covers what a build of a recipe file of your own needs beyond a recipe EasyBuild ships: naming the file and the directory of its dependencies with `--robot=DIR`, giving sources with `--sourcepath`, a recipe for software published only as prebuilt libraries (`Tarball`, the system toolchain and when `check_readelf_rpath = False` is right), what `is already installed (module found), skipping` means when the module is not in your prefix, the lock that makes two builds into one prefix run one after the other and `EB_LOCAL_LOCK_TIMEOUT_MS` for the one that waits, and `--ignore-locks` after a build that was killed.
- Document the opt-in development environment replacement and restoration model.

### Miscellaneous

- Tests pin that `eb-local doctor` reports no finding for a path-list variable such as `PYTHONPATH` or `R_LIBS_USER` whose whole value is empty, which the tools that read it treat as unset, while an empty entry inside a non-empty list, as in `:`, `:DIR` or `DIR:`, is still named.
- The execve-block builders over a std process environment map build through
  zig-common `env.Builder`, whose set order and block shape they now use,
  instead of hand-rolled line assembly.
- Update the pinned `zig-common` dependency from `v0.10.0` to `v0.12.0`. The
  ELF scan warning for a path it cannot open now names `IsDir` or
  `NotRegularFile` instead of `InvalidArgument` for a directory or a FIFO.


## 3.3.0 (2026-11-19)

### Features

- The site tasks for a setuptools, meson-python, and scikit-build-core
  extension read the built module with `readelf` and pass when it has a
  `DT_RPATH` entry naming the stack library and no `DT_RUNPATH` entry.
  The task then imports the module with no modules loaded.
- `dev` tries the build environment at the compiler's own toolchain level, `buildenv/default-NVHPC-VERSION`, `buildenv/default-intel-compilers-VERSION` or `buildenv/default-llvm-compilers-VERSION`, when the family's configured one is not installed, before it falls back to its own RPATH wrappers. A site that installs such a module needs no `dev.buildenv_for` setting. A family set to none still goes to the wrappers without asking Lmod.
- `eb-local doctor` names a host `CARGO_TARGET_*_LINKER`, `CARGO_BUILD_RUSTC_WRAPPER`, `RUSTC_WORKSPACE_WRAPPER`, `R_MAKEVARS_USER`, `R_MAKEVARS_SITE`, and a host entry of `JULIA_LOAD_PATH`, `JULIA_DEPOT_PATH` or `NODE_PATH`. `build.clear_foreign_prefixes` drops those when it is set, and stays off by default. `RUSTFLAGS` is a flag string, so it is not treated as a path.

### Fixes

- A site file may write a decimal integer with a single "_" between two
  digits, so `1_000` is one thousand. A leading zero, a doubled "_" or a
  "_" at either end of the digits stays invalid.
- Ignore Zig `//` line comments when parsing `build.zig.zon` dependencies and fields in `tools/sbom.py`.
- Site template placeholder errors in `src/sites.zig` now report the 1-based line number alongside the template name.
- Split whitespace-separated patterns on `include` lines inside `elfcheck.parseLdSoConf` so multi-pattern `ld.so.conf` directives are not skipped.
- The release workflow publishes the shell completions and man pages as `eb-local-X.Y.Z-share.tar.gz`. For 3.2.0 the `share` directory made the upload step fail after the binaries, their software bills of materials and `SHA256SUMS` were attached, so that release has no completions archive.
- Treat `fuse` mounts backed by `cvmfs2` (and `fuse.cvmfs`) as valid CernVM File System (CVMFS) mounts in `eb-local-readiness`, avoiding false warnings on hosts running `cvmfs-fuse3`.
- `acquireBoundedLock`, `acquireOptionalLock`, and `tryLockFree` in `src/storage.zig` now check `fstat` and refuse non-regular lockfiles such as FIFOs instead of locking or treating them as free.
- `cvmfs.readFile` now uses `fsx.openRegular` when reading CernVM-FS client configuration files so non-regular entries such as a FIFO are skipped instead of blocking `eb-local doctor --cvmfs`.
- `eb-local check` (`elfcheck.expandOrigin`) now requires a non-word boundary after unbraced `$ORIGIN` (matching `ld.so`), leaving tokens such as `$ORIGIN_extra` unexpanded while still expanding `$ORIGIN`, `$ORIGIN-extra`, and `${ORIGIN}_extra`.
- `eb-local config --get` now rejects invalid `build.node_types.<NAME>` and `secrets.<NAME>` names with exit 2 and `unknown configuration key` instead of exiting 1 as unset.
- `eb-local doctor` and `build.clear_foreign_prefixes` treat every
  relative path-list entry and every empty one as outside the approved
  prefixes. An empty entry is reported as `''`. Julia's own entries are kept: an empty entry of
  `JULIA_LOAD_PATH` or `JULIA_DEPOT_PATH`, and a load-path entry starting
  with `@`.
- `eb-local eb` now refuses a non-directory or uncreatable `EESSI_USER_INSTALL` path with an `eb-local:` message and exit status 2 instead of failing in `mkdir -p` with exit status 1.
- `eb-local` RPATH wrappers now search an empty `PATH` entry as the current directory, including a trailing colon, as `execvp` does.
- `legacyToToml` now rejects a leading UTF-8 BOM and validates every line (including comments) for NUL and non-UTF-8 bytes with its line number before stripping comments.

### Documentation

- Add `gfortran -O2 -fopenmp` and `mpifort` build rows to `docs/howto/compile.md`.
- Expanded the EESSI compilation how-to with Python, uv, R, Rust, Julia, and Node.js package build commands that keep native links under the build environment wrappers.
- Extend `docs/howto/install-what-eessi-lacks.md` to show `eb-local eb -- "$recipe" --robot` for installing missing modules where there is no site file or Slurm job.
- Switch the CMake and configure prefix flag examples in `docs/howto/compile.md` to Org tilde code spans so the exported Markdown renders valid inline code.
- The how-to "Compile with Nix inside the dev shell" links a stack
  library from `nix-shell` with `DT_RPATH`. On Nix 2.35.6 that entry
  stays, including under `nix-shell --pure`, and a sandboxed
  `nix-build` fails with `cannot find -lanswer`.
- The run-paths page no longer says a program loses its run paths only when `gcc` and `ld` are both bypassed. On x86_64, rustc 1.90 and later links with rust-lld, which those wrappers never see. The page says how `eb-local eb` points Cargo at the wrapped compiler, and what a `dev` shell still has to set for Julia's depot, a host `NODE_PATH`, R's Makevars and a Python virtual environment. `tests/site/lang-dev-tasks.sh` runs each of those and then runs the program with no modules loaded.
- Update the `README.md` EasyBuild example from `GSL-2.8-GCC-15.2.0.eb` (already provided by EESSI 2026.06) to `pigz-2.8-GCCcore-15.2.0.eb`, matching `docs/howto/install-software.md`.
- Updated the `eb-without-a-site-file` how-to guide so `eb-local doctor` without a site file shows the `info no site file sets storage.node_local_root` line that the built binary prints rather than the older `FAIL` line.
- Updated the `load-eessi` and `install` how-to guides so the strict-mode example evaluates `eval "$(eb-local env --strict)"` in the shell (which emits the missing-init error and exits 2) instead of invoking `eb-local env --strict` directly.

### Miscellaneous

- Added a CLI test verifying `eb-local check --prefix` and `eb-local check --dev` exit 2 when the target path is not a directory.
- Switch `lmodcache.installVerified` in `eb-local` to create its verification directory with `zig-common` `fsx.mkdtemp`.
- The Zig workflow runs overlay bump and overlay plan against the eb-stack 0.8.0 release.


## 3.2.0 (2026-11-19)

### Features

- Add opt-in `--json` to `list`, `check`, `doctor`, `config`, `profiles`, and `site list`, printing one line of JSON with `schema_version` 1 for scripts and automation.
- Adds `doctor --workspace PATH` to exercise a build directory and report its file system, storage class, free capacity, mount execution policy and cache isolation without starting a build.
- Adds `eb-local overlay materialize`, plus `overlay bump` and `overlay plan` that forward to `eb-stack package` by subprocess only. Overlays pin an upstream easyconfig digest and apply only declarative parameter, patch, and dependency edits.
- Adds `lmod-cache --verify` to compare a temporary candidate cache with uncached Lmod discovery and leave the installed cache unchanged when inventories differ or cannot be parsed.
- The new standalone `eb-local-readiness` command checks the EESSI mount and verifies that local modules precede upstream modules on `MODULEPATH`.
- `build.secrets`, in a configuration file or a profile, and `EB_LOCAL_BUILD_SECRETS`, for one build, name the secrets a build gets: the build reads only those, so a secret it does not get never reaches `eb`, and one that cannot be read no longer stops it. Without either, every build gets every secret, as before. A name that no secret in force has is an error saying where it was set. `eb-local config` shows the setting, `config --env` carries it, `--explain` says which secrets reach `eb`, and `doctor` says FAIL only for a secret builds get, and otherwise warns. The documentation has a how-to page.
- `eb-local --explain RECIPE` prints the script a build runs, after the variables eb-local sets for it and a `set --` line with its arguments. It printed a separate rendering of that script, which could differ from it: its guard line did not stop when the guard failed. A build's first line names the command: `eb-local: what this runs: eb-local --explain RECIPE ...`.
- `eb-local --explain RECIPE`, and a build started outside a Slurm job, print an `sbatch` line for each node type the site file lists, which runs the same build as a batch job on that node type. The job runs what a job of `eb-local submit` runs, in the directory eb-local ran in, and writes its output there.
- `eb-local check --module NAME/VERSION`, `--dev` and `--prefix DIR` audit every ELF file in those installations, the dev tree or a directory. A file that is not ELF is skipped. `--quiet` prints a file only when it has a problem.
- `eb-local check --recursive` audits resolved `DT_NEEDED` shared libraries transitively alongside the target ELF files.
- `eb-local clean --json` prints a structured summary of cleaned logs, sources, and build workspaces.
- `eb-local config --get KEY` prints the resolved value of one configuration key for scripts and hooks.
- `eb-local dev --envrc MODULE...` writes the line that evaluates that `dev` to `.envrc` in the working directory, between marker lines it owns, and updates it on a later run without touching other lines. With direnv the build environment then follows the directory, in every shell direnv has a hook for.
- `eb-local dev --lock MODULE...` writes `eb-local.lock`: the stack, the EESSI version, the CPU and accelerator target and every loaded module with its version, in load order. `eb-local dev --locked` loads exactly that list from a purged shell, refuses a lock of another stack, and loads none of it on a different CPU target. Node types that share a CPU target share a lock.
- `eb-local dev --pure` runs `module purge` and unsets `LD_LIBRARY_PATH`, `LD_PRELOAD` and `LD_AUDIT` before the stack loads, so modules and loader variables the shell already had do not reach the build environment.
- `eb-local dev --strict` checks that the EESSI init file exists before loading modules and build environments.
- `eb-local dev` names the host's CA bundle in `SSL_CERT_FILE` and `CARGO_HTTP_CAINFO` when the host has none at `/etc/ssl/certs/ca-certificates.crt`, so `cargo` and `curl` from EESSI reach HTTPS servers on RHEL-family hosts. A value the shell already set is kept.
- `eb-local doctor --cvmfs` checks the CernVM-FS repository this shell would read. It reports whether the mount is present, stale, or returning an input/output error, the HTTP proxy in force and whether that value came from the process environment, and the result of `cvmfs_config probe` and `cvmfs_config chksetup` when that program is on `PATH`. `--cvmfs-parallel N` or `doctor.cvmfs_parallel` reads repository metadata from N tasks inside an allocation, through `srun` when it is on `PATH`. A build does not run these checks.
- `eb-local doctor --mpi` reports whether `fi_info` and `ucx_info` are on `PATH`, and any Slurm CPU or memory bind. Inside an allocation it compiles and runs a two-rank hello for each transport named by `doctor.mpi_transports` (`ofi` or `ucx`) and reports the `OMPI_MCA_pml` and `OMPI_MCA_mtl` values used for that run only. A build does not set those values.
- `eb-local doctor --strict` exits 1 whenever diagnostic checks emit `warn` lines as well as `FAIL`.
- `eb-local doctor` reports `PERL5LIB`, `PYTHONPATH`, `R_LIBS*`, `CMAKE_PREFIX_PATH`, `PKG_CONFIG_PATH` and compiler-wrapper variables that resolve outside the EESSI repository, the install prefix and `doctor.approved_prefixes`. It also reports the timezone `/etc/localtime` resolves to, a bind of that file, and a host library directory a container runtime injected. `build.clear_foreign_prefixes` and `EB_LOCAL_BUILD_CLEAR_FOREIGN_PREFIXES` drop those entries from a build; both stay off unless set.
- `eb-local doctor` says whether eessi-arch-guard is on `PATH` and, inside a job with EESSI loaded, which CPU target it selects, which builds, `env` and `dev` then use. It asks the guard as a build does, with `--strict --shell` and a private directory that it removes after; a guard that cannot select a target is a `warn`.
- `eb-local env --json` and `eb-local dev --json` print the change their lines make to the environment (`set` and `unset`, as one line of JSON) in place of the lines, so a shell that cannot evaluate POSIX text, such as nushell, can apply it. The reference has a nushell wrapper.
- `eb-local env --strict` and `EB_LOCAL_ENV_STRICT=1` prepend a check that the EESSI init file exists before the load lines. The load-eessi how-to names it for hosts where CVMFS is not mounted yet.
- `eb-local list --missing` prints the sorted `NAME/VERSION` modules absent from the loaded CPU target.
- `eb-local lmod-cache --prefix` walks every CPU target's `modules/all` tree (and nested accelerator module trees), then runs Lmod's `update_lmod_system_cache_files` for each, matching EESSI's publisher cache refresh. `--dry-run` lists the targets; single-target `--modulepath` mode is unchanged.
- `eb-local lmod-cache` writes Lmod's `spiderT.lua` for the module directories it is given, and a timestamp one second older, so Lmod trusts the cache. A `spider` that fails leaves both files unchanged.
- `eb-local modulerc --check` reports whether requested directives would update `.modulerc.lua`.
- `eb-local modulerc --json` prints structured JSON describing directives, target file, and drift status.
- `eb-local modulerc` idempotently writes operator-selected Lmod defaults, aliases and hidden versions, with a `--dry-run` preview.
- `eb-local overlay materialize --check` compares generated outputs against disk and exits 1 on drift without writing.
- `eb-local overlay materialize --dry-run` validates an overlay and lists its output paths without creating them.
- `eb-local site check` validates a site configuration file as a site layer without installing it.
- `eb-local uninstall --target` limits removal and dependent checks to one CPU target tree.
- `eb-local uninstall --usage-log FILE` asks `eb-keep-logs used --prefix PREFIX --require-none FILE` and removes nothing when that command exits 2. Without `--usage-log`, uninstall is unchanged.
- eb-local now generates bash, zsh and fish completion scripts and a man page from the live command help in CI and release builds, so shell integration and command docs are shipped from one source of truth.

### Fixes

- A SIGTERM sent to eb-local alone, as `kill PID` sends it, now stops the build: eb-local passes it on to EasyBuild, as it does SIGINT, SIGHUP and SIGQUIT, and `eb-local eb` does the same. eb-local cleans the logs once EasyBuild has exited, so a secret in the lines EasyBuild writes as it stops is removed too; before, a SIGTERM to the whole process group could leave one there. A build stopped with Ctrl-C now ends with eb-local dying of SIGINT, like one stopped with SIGTERM.
- A build and `eb-local eb` check where EESSI-extend will install once it has loaded, and stop with exit 2, before `eb` runs, when `EASYBUILD_INSTALLPATH` is outside the tree the install variable selects, `<prefix>/versions` for a build, or when `EASYBUILD_INSTALLPATH_SOFTWARE` or `EASYBUILD_INSTALLPATH_MODULES` is set. Before, a site Lmod hook that set an install path, or an `EESSI_CVMFS_REPO` with a character such as `-`, which EESSI-extend matches as a Lua pattern, sent the install and its logs outside the prefix eb-local had checked and cleans of secrets while eb-local said it was installing into that prefix, and `eb-local eb` passed a leftover `EASYBUILD_INSTALLPATH_MODULES` on to EasyBuild, splitting an install between two trees. Both now say when loading EESSI-extend sets or unsets an install variable, as a site load hook does too late for its own load. A build names each install variable it clears from the caller's shell, and the refusal of more than one install variable by `eb-local eb` names each with its value and what EESSI-extend would do with them: with a user and a project variable, a private user install.
- A build that cannot load the stack module or EESSI-extend shows Lmod's reason, such as an unknown module, under `eb-local: could not load <module>:`. A build dropped everything a load wrote to stderr, so a module missing from `MODULEPATH` and a load hook that failed both read only `could not load`. A load that works stays quiet.
- A build that does not get a secret no longer gets the variable its `env:` source names. Before, the secret stayed out of `eb`'s environment, but its value reached `eb` and the programs it runs under the source's name, and the logs were not cleaned of it. `eb-local --explain` says that the variable stays out too. A variable a secret may not set, such as `PATH`, stays, since the build needs it.
- A build, `env` and `dev` in a shell without a module command source EESSI's own Lmod, from the init `eb-local eb` sources, when the host has no Lmod init of its own. On a host whose only Lmod is EESSI's, a build stopped with `eb-local: no module command found` and `eval "$(eb-local env)"` printed `module: command not found`, while `eb-local doctor` said that nothing stopped a build. `doctor` now names the init a build sources, and with a site file fails when none of the three can be read; the build's message names them too.
- A refused secret source says what is wrong with it: `env:` takes a variable name, `file:` an absolute or `~/` path, and a `nimvault:` entry may not be empty or start with `-`. Before, each of these drew the message for a value written in place of a source, which `file:token` and `nimvault:-x` are not.
- A site-wide XALT preload (`LD_PRELOAD` naming only `libxalt_init.so`) is an `info` line in `doctor`, not a `warn`, and a build drops it without a warning, so `doctor --strict` no longer fails for every user of such a site.
- An empty `~/.local/eessi` no longer replaces the default prefix `~/eessi`; only one that holds an install (`versions/` or `.eb-local/`) stays in use, so a user with an empty old directory no longer sees the pre-3.0 notice on every command.
- Enforce `max_depth` before descending into an installation `easybuild` directory in `secrets.redactTree`.
- Escape leading `.` and `'` characters in `esc_roff` so roff control lines inside manpage help text are preserved literally.
- Fall back to `/cvmfs/software.eessi.io` in `eb-local-readiness` when `EESSI_CVMFS_REPO` is empty while still rejecting `--repo ""`.
- Fall back to `main` when `DOCS_SOURCE_REF` or `GITHUB_SHA` is empty in `docs/tools/zig_api.zig`.
- Honor `EESSI_CVMFS_REPO` in `eessi_runpath` and `from_eessi` inside `tests/site/dev-tasks.sh` instead of hardcoding `/cvmfs`.
- Ignore negative CPU identifiers in `mpi.sharedCpu` so failed `sched_getcpu` results are not reported as shared CPU bindings.
- JSON output emits one U+FFFD per maximal ill-formed UTF-8 subpart via `zig-common`'s `pytext.decodeReplace`.
- Lmod init discovery in `eb-local` and `eb-local doctor` now requires a readable regular file so a directory at an earlier init path is skipped instead of sourced.
- Parse `build.zig.zon` dependency blocks independently of indentation and field order in `tools/sbom.py`.
- RPATH wrappers now collapse repeated slashes in `EESSI_EPREFIX` and library search directories before filtering `/lib`, `/lib64`, `/usr`, and compat paths.
- Reap child probes in batches in `cvmfs.parallelProbe` so `tasks` above 8 does not overflow `pids`.
- Refuse empty `--prefix` or `--repo` arguments with exit status `2` in `eb-local-readiness` instead of resolving `""` to the working directory.
- Refuse empty `--project=` and `dev --buildenv=` operands with exit code 2 in `eb-local`, matching `--project ""` and `--buildenv ""`.
- Reject non-regular `.modulerc.lua` entries such as FIFOs before reading in `modulerc.run` instead of blocking.
- Reject reopening a dotted-key table with a `[table]` header or extending an explicit `[table]` via dotted keys in `toml.parse`.
- Require a terminating NUL byte in `PT_INTERP` segments during `elfcheck.parse` instead of returning an unterminated string.
- Require three strict ASCII octal digits for `\ooo` escapes in `storage.unescape` instead of accepting `+`, `-`, or `_` via `parseInt`.
- Require valid UTF-8 in `sites.validValue` so non-UTF-8 `--set` values and placeholder defaults are rejected before writing TOML.
- Resolve `pigz` installation and module paths with `find` in `tests/site/rtrash-job.sh` so two-component and three-component EESSI CPU targets both match.
- Return exit status `2` instead of `1` when `eb-local modulerc` fails to read an existing `.modulerc.lua`, distinguishing I/O refusals from `--check` drift (`1`).
- Return exit status `2` instead of `1` when `eb-local overlay materialize --check` fails to read an existing materialized recipe or `provenance.toml`.
- Return exit status `2` instead of `1` when `eb-local overlay materialize` cannot read `--overlay` or `--base`, avoiding collision with `--check` drift status `1` and matching `check` and `site check`.
- Sanitize fixed-size arrays recursively in `jsonout.utf8Safe` so non-UTF-8 string elements encode as JSON strings rather than byte arrays.
- Sanitize non-identifier characters in the Bash completion function name generated by `tools/cli_assets.py` so scripts load cleanly in POSIX mode.
- Scope `eb-local overlay materialize` `[dependencies.replace]` edits to actual dependency tuples inside `dependencies = [...]` rather than matching arbitrary substrings inside prose or comments.
- Skip run-path and `--disable-new-dtags` injection when `ld` wrappers run an incremental `-i` link.
- Strip optional surrounding quotes from values read by `setting` in `tests/site/build-job.sh` so TOML and legacy site files both parse cleanly.
- Strip trailing slashes from `EESSI_CVMFS_REPO` in the `extend` launcher script so error messages and `PATH` match `extend.initPath`.
- Support TOML 1.0 `"""` multi-line basic strings (opening newline trimming and line-ending backslashes) in `src/toml.zig` so multi-line `rationale` fields parse without changing overlay examples.
- TOML `\u` and `\U` escapes now require strict ASCII hexadecimal digits, rejecting `+` signs and `_` separators.
- The command reference names its `--explain` and `--explain eb` sections as code; Org's exporter wrote their `--` as an en dash. A test fails on any character reference Org writes into a page.
- The frozen 1.x Bash script now handles `--version` before any Slurm checks, so `eb-local --version` and `eb-local --help` both exit successfully outside a job allocation.
- The header line of `eb-local list` no longer ends in two spaces; its rows already did not.
- The refusals of a build's node-local mount and install prefix, by a build, `eb-local clean` and `eb-local doctor`, now say what was refused and why, what the command then did not do, and, on the next line, what to change: the setting, with its value and where it was set as `eb-local config` shows it, or the variable, option or command. Before, most said only that the allocation's node-local root "must be an owned writable directory" or that paths "must use durable owned storage", without the path, the setting or the reason. A workspace that cannot be made in a mount that passed the checks names the error the kernel gave, and a setting in a 1.x `eb-local.conf` is shown with its own line. The documentation has a page listing each refusal.
- Track active symlink expansion bounds in `storage.canonical` so revisited non-cyclic symlinks resolve like `readlink -m`.
- Track triple-quoted strings and bracket depth in `eb-local overlay materialize` so `[replace]`, `[patches]`, and `[dependencies]` only match top-level easyconfig assignments rather than lines inside docstrings or nested expressions.
- Treat a trailing slash in an `eb-local list NAME/` filter as a package prefix match rather than requiring an extra slash after `NAME/`.
- Treat an empty `EB_LOCAL_DOCS_OUT` environment variable as unset in `docs/export.el` instead of exporting into the working directory.
- Validate `default_profile` as a string across every configuration file even when `--profile` or `EB_LOCAL_PROFILE` overrides it, instead of silently ignoring a non-string value.
- `--config=FILE` names a configuration file, as `--config FILE` does. A build passed it to `eb` and read the usual files, `env` refused it, and `eb-local --config=FILE config` ran a build of a recipe called `config`. An empty value after `=`, as in `--project=`, is refused as an empty one after a space is; an empty `--project=` made the current directory the project.
- `--json` output encodes non-UTF-8 paths and text as UTF-8 replacement strings rather than integer arrays.
- `cmdBuild` now removes the newly created build workspace directory and includes the OS errno via `storage.describeError` when creating workspace subdirectories fails.
- `config.load` now rejects empty `prefix` and `project` strings in configuration files instead of letting `prefix = ""` resolve to the current working directory.
- `config.validSecretName` now refuses `SHELLOPTS` and `BASHOPTS` alongside `BASH_ENV` and `ENV` so secret entries cannot inject shell startup options into build commands.
- `cvmfs.readProxy` now recognizes `export` followed by a tab as well as spaces before `CVMFS_HTTP_PROXY` in client configuration files.
- `cvmfs.readProxy` now treats an empty `CVMFS_HTTP_PROXY=""` or `CVMFS_HTTP_PROXY=` assignment as clearing any earlier file-configured proxy instead of preserving the previous value.
- `cvmfs.readProxy` now trims surrounding spaces and tabs inside quoted `CVMFS_HTTP_PROXY` values so `" DIRECT "` resolves as direct mode and whitespace-only values clear earlier settings.
- `dev` with the `LLVM` module no longer lets `clang` link without run paths. The module sets `EBROOTLLVM`, not the variable of `llvm-compilers`, so `dev` loads the GCC build environment, whose wrappers do not cover `clang`; a program `clang` linked failed when it started, and `dev` said nothing. Whichever build environment loads, `dev` now puts RPATH wrappers first for each `clang`, `clang++`, `flang`, `flang-new` and `ld.lld` that no wrapper covers, and says so, as the 3.0.0 note promised that a program never links without run paths. `eb-local rpath-wrappers --unwrapped` prints those lines alone.
- `doctor --workspace` reports `execute=failed` instead of aborting when a `noexec` mount blocks probe execution.
- `eb-local --explain eb [--] [eb options]` prints the script `eb-local eb` runs, after a `set --` line with its arguments, and runs nothing; it ran the launcher. `--explain` with any command other than a build or `eb` is refused with exit 2, where it was ignored and the command ran: `eb-local --explain clean --delete` deleted logs, and `eb-local --explain submit` submitted jobs.
- `eb-local --explain` and outside-job refusal messages now use ANSI-C `$'...'` single-line quoting when paths or arguments contain newlines so generated `#   sbatch ...` comment lines never spill uncommented lines.
- `eb-local --help` names `dev --buildenv MODULE` and `clean --no-logs`, which the program took without listing them, and says that `eb` takes none of `--profile`, `--project` and `--config`, which it refuses.
- `eb-local check --dev` now verifies that paths built from `EESSI_VERSION`, `EESSI_SOFTWARE_SUBDIR`, and `EESSI_ACCELERATOR_TARGET` remain strictly inside `<prefix>/dev`.
- `eb-local check --json` now suppresses human-readable stdout lines even when `--quiet` is omitted, emitting one valid JSON report line on stdout when problems or unreadable files are found.
- `eb-local check --module` now deduplicates installation roots before auditing ELF files, so repeating a module argument no longer audits files twice or doubles `problem_count` and `elf_count`.
- `eb-local check` now deduplicates positional file arguments and symlink aliases by canonical path, so repeating a file or passing a symlink to an already-checked binary no longer audits it twice or doubles `elf_count` and `problem_count`.
- `eb-local check` now expands `$ORIGIN` and `${ORIGIN}` in `DT_NEEDED` entries that contain `/`, so plain and `--recursive` checks resolve and audit those shared libraries.
- `eb-local check` now rejects repeated `--prefix` flags with exit code 2 instead of silently discarding earlier `--prefix` values.
- `eb-local check` now resolves `include` patterns and directory entries in `<root>/etc/ld.so.conf` relative to the ELF loader's compatibility-layer root instead of the host filesystem or current working directory.
- `eb-local check` now trims trailing slashes from `EESSI_SOFTWARE_SUBDIR` before checking run paths against the current target tree.
- `eb-local check` now trims trailing slashes on `EESSI_EPREFIX` before checking whether an ELF `PT_INTERP` loader sits inside the EESSI compatibility layer.
- `eb-local clean` and `eb-local uninstall` say `clean.trash is none`, with where it was set, when that setting keeps them from removing anything without `--delete`; they said `rtrash is not installed` even with rtrash on `PATH`.
- `eb-local clean` now rejects combining `--no-logs` with `--logs-older-than` and rejects repeated `--logs-older-than` flags with exit code 2.
- `eb-local clean` removes read-only directory trees and reports accurate removal counts and exit status on partial failures.
- `eb-local clean` waits on the prefix lock while cleaning logs or sources and retains workspaces locked by active builds.
- `eb-local config --get eessi.<NAME>` now exits 1 with empty stdout when the configured `[eessi]` entry is empty, matching all other scalar keys and the documented `--get` contract.
- `eb-local config` gives each `build.targets` entry the line that sets it; every entry showed the line of the `[build.targets]` header.
- `eb-local config` now rejects repeated `--get` flags with exit code 2 instead of silently discarding earlier `--get` keys.
- `eb-local doctor --cvmfs` now strips inline `#` comments and unquotes `CVMFS_HTTP_PROXY` values when trailing comments are present in CernVM-FS client configuration files.
- `eb-local doctor --mpi` now builds its two-rank hello in a private temporary workspace under `$TMPDIR` or `/tmp` instead of `.zig-cache/` in the current working directory, leaving the working directory clean and working when it is read-only.
- `eb-local doctor --mpi` now writes `hello.c` via `atomicWrite` and reports write failures as a warning instead of mapping filesystem errors to `OutOfMemory`.
- `eb-local doctor --workspace` now reports `FAIL` and exits 1 when the workspace mount has zero free bytes or zero free inodes.
- `eb-local doctor` and `build.clear_foreign_prefixes` now resolve both paths and approved prefixes through symbolic links, keeping entries inside symlinked approved prefixes while flagging and scrubbing symlinks that point outside them.
- `eb-local doctor` no longer warns about `EASYBUILD_INSTALLPATH` and `EASYBUILD_PREFIX` in a shell that ran `eval "$(eb-local env)"`. Once the prefix exists, `env` loads EESSI-extend, which sets both for that prefix, and `doctor` called them left over from an earlier session. They still draw the warning when EESSI-extend is not loaded or the install path is outside `<prefix>/versions`.
- `eb-local doctor` now canonicalizes `MODULEPATH` entries before checking whether they live under the resolved installation prefix, avoiding false warnings when the prefix is reached through a symbolic link.
- `eb-local doctor` now checks prefix free bytes and free inodes and inspects the nearest existing ancestor when a user prefix has not been created yet, reporting read-only, unwritable, and full filesystems as `FAIL`.
- `eb-local doctor` now rejects repeated `--workspace` flags with exit code 2 instead of silently discarding earlier `--workspace` values.
- `eb-local doctor` now selects the last covering `/etc/localtime` entry in `/proc/self/mountinfo` when reporting host timezone bind mounts.
- `eb-local doctor` now verifies that the EESSI init file is a readable regular file instead of reporting `ok` when the path is a directory or unreadable.
- `eb-local doctor` reads each secret as a build would, without showing its value, and says FAIL when one cannot be read: a build reads every secret before it starts, so one missing source stops every build, including builds that do not use it. Before, `doctor` ended with "Nothing above stops a build." and the next build stopped on the secret. It warns, as a build does, about a secret too short to be removed from logs.
- `eb-local doctor` says that `eb-local eb` stops when `EESSI_PROJECT_INSTALL` names no directory, since EESSI-extend then refuses to load; it said `ok` and named the variable as the project install `eb-local eb` would make. As for its other checks of `eb-local eb`, that is a `FAIL` without a site file and a `warn` with one.
- `eb-local doctor` says when the shell has a module command but no directory on `MODULEPATH` holds `stack.module`, and names the `module use` line that adds EESSI's module directory: a `FAIL` with a site file, a `warn` without one. Before, it said that nothing stops a build, and each build stopped at once with `could not load EESSI/2026.06`, since a build keeps the shell's module command and `MODULEPATH`.
- `eb-local doctor` without a site file checks what `eb-local eb` needs, the EESSI init and at most one install variable, and no longer exits 1 because builds in a job need a site file. The exit status changes only in that case: with a site file, what stops only `eb-local eb` is a warning.
- `eb-local eb -- --help` runs `eb --help`: every argument after `--` goes to EasyBuild, as the help says. `--help` and `-h` printed eb-local's help instead, and `--project`, `--profile` and `--config` stopped the command, wherever they came. Before `--`, `eb-local eb --help` still prints eb-local's help.
- `eb-local eb` no longer sets `WORKING_DIR=/tmp` when it is unset, so EESSI-extend uses its own default, `/tmp/$USER`, and EasyBuild builds under `/tmp/$USER/easybuild`. With `/tmp/easybuild` shared, the first user's build made it with umask 077, and every other user's `eb-local eb` on that node failed with `Permission denied`.
- `eb-local eb` now checks that the EESSI init script is a readable regular file and exits 2 before sourcing it.
- `eb-local eb` now drops `BASH_ENV`, `ENV`, `SHELLOPTS`, and `BASHOPTS` before invoking bash, matching `eb-local <recipe>` so caller startup scripts and shell options do not run inside the launcher shell.
- `eb-local eb` now normalizes repeated and trailing slashes on the expected install root and `EASYBUILD_INSTALLPATH` before comparing them, so `EESSI_USER_INSTALL`, `EESSI_PROJECT_INSTALL`, `EESSI_SITE_SOFTWARE_PATH`, and `EESSI_SOFTWARE_PATH` values with a trailing slash match Lmod's normalized install path.
- `eb-local eb` says what to change when the EESSI init is missing, as its other refusals do: set `EESSI_CVMFS_REPO` or `EESSI_VERSION` if EESSI is elsewhere. It said only `eb-local: missing INIT`.
- `eb-local list --json` now populates `missing_on_node` and `hint` when `EESSI_SOFTWARE_SUBDIR` selects a CPU target with no installed tree yet, matching `eb-local list --missing` and the text output.
- `eb-local list --json` records `--json` as an output flag rather than a module name filter.
- `eb-local list` now trims trailing slashes from `EESSI_SOFTWARE_SUBDIR` before matching CPU target trees, so `list` and `list --missing` recognize the current node when `EESSI_SOFTWARE_SUBDIR` ends with `/`.
- `eb-local lmod-cache --prefix` now falls back to `statAt` when directory entries report `DT_UNKNOWN`, allowing CPU and accelerator target discovery on filesystems without `d_type` support.
- `eb-local lmod-cache --prefix` now validates `--eessi-version` as a single directory name and rejects `.`, `..`, and path separators with exit code 2 before walking `<prefix>/versions`.
- `eb-local lmod-cache --verify` now clears `BASH_ENV`, `ENV`, `SHELLOPTS`, and `BASHOPTS` before invoking `bash` to inspect module inventories, preventing caller shell startup hooks from corrupting verification output.
- `eb-local lmod-cache --verify` now installs the verified `spiderT.lua` via `atomicWrite` and rolls back the cache file and any newly created cache directory if updating `--timestamp` fails.
- `eb-local lmod-cache` exits 2 without updating caches when `--prefix` is combined with single-target options.
- `eb-local lmod-cache` now exits 2 when `--spider` is passed with `--prefix`, or when `--eessi-version` or `--update-cmd` is passed without `--prefix`, matching the existing validation for `--modulepath`, `--cache-dir`, `--timestamp`, `--verify`, and `--dry-run`.
- `eb-local lmod-cache` now opens the timestamp file with `O_NOFOLLOW`, refusing symbolic links without clobbering their targets and rolling back any newly written cache file.
- `eb-local lmod-cache` now writes `spiderT.lua` via `atomicWrite` and rolls back the cache file and any newly created cache directory when writing or updating the timestamp fails.
- `eb-local modulerc --check` and `--dry-run` now refuse a symbolic-link `.modulerc.lua` with exit code 2 instead of reading through it, matching the write path's symlink refusal.
- `eb-local modulerc` now refuses an existing `.modulerc.lua` containing NUL bytes with `{path}:{line}: the file holds a NUL byte` and exit status 2 instead of writing or printing NUL bytes.
- `eb-local modulerc` now refuses symbolic links at `.modulerc.lua` before opening them in write mode as well as `--check` and `--dry-run`.
- `eb-local modulerc` now trims surrounding spaces and tabs when matching existing lines, preventing duplicate directives when `.modulerc.lua` lines carry leading indentation or trailing whitespace.
- `eb-local modulerc` now validates `--default`, `--hide`, and both sides of `--alias NAME=MODULE` with `config.validModule`, rejecting invalid module names with exit code 2.
- `eb-local modulerc` now writes `.modulerc.lua` via `atomicWrite` and cleans up any newly created module tree directory on failure, refusing to replace symlinks and leaving no `.new` temporary file behind.
- `eb-local overlay materialize --check` now refuses symbolic links at `materialized-<base>` or `provenance.toml` with exit code 2 instead of reading through them.
- `eb-local overlay materialize` measures leading indentation directly so trailing spaces or carriage returns on easyconfig lines stay valid.
- `eb-local overlay materialize` no longer treats `==` comparisons in easyconfigs as parameter or array assignments.
- `eb-local overlay materialize` now consumes all continuation lines of multi-line parameter assignments when `[replace]` substitutes a parameter.
- `eb-local overlay materialize` now escapes backslashes, control characters, and consecutive or trailing quotes inside `provenance.toml` `rationale` and string fields, ensuring valid TOML output.
- `eb-local overlay materialize` now exits 2 when an overlay file contains unknown top-level keys or unknown subkeys under `[dependencies]`, catching typos instead of silently writing an unedited easyconfig.
- `eb-local overlay materialize` now includes the overlay file path and line number on every parse or schema refusal.
- `eb-local overlay materialize` now inserts commas before any trailing inline `#` comment when appending to `dependencies` or `patches`, avoiding bare leading commas in materialized easyconfigs.
- `eb-local overlay materialize` now reports stdout write errors on stderr instead of exiting `1` silently.
- `eb-local overlay materialize` now writes both outputs via `atomicWrite` and rolls back the materialized easyconfig and any newly created output directory if writing `provenance.toml` fails.
- `eb-local overlay materialize` omits duplicate commas when appending entries to easyconfig lists that already end with a comma.
- `eb-local overlay materialize` reports the failing parameter, dependency, or list diagnostic on stderr when an overlay edit fails to apply.
- `eb-local overlay materialize` skips Python string literals and comments when matching easyconfig list brackets.
- `eb-local overlay` forwards every argument after `--` directly to `eb-stack`.
- `eb-local overlay` rejects unknown options and misplaced flags before `--` with exit 2 instead of silently discarding them.
- `eb-local profiles` in text mode now counts printed profiles instead of checking `rows.items.len`, so `no profiles are defined` is printed only when zero profiles exist.
- `eb-local rpath-wrappers` now formats directory setup and wrapper write failures through `storage.describeError`, reporting OS errno descriptions alongside the failing wrapper path.
- `eb-local rpath-wrappers` now strips all trailing slashes from library directories and `EESSI_EPREFIX` before filtering compatibility-layer paths and emitting `-rpath` flags.
- `eb-local site install` now refuses a directory `--to` target before checking `--force` and suggests passing a file path such as `DIR/config.toml`.
- `eb-local site install` now refuses live and dangling symbolic link targets up front with exit 2 instead of prompting for `--force`.
- `eb-local site show` and `eb-local site install` now exit 2 when a site template contains an unclosed or invalid `{{...}}` placeholder instead of silently writing literal `{{...` into the output configuration.
- `eb-local site show` and `site install` name every placeholder that has no default, in one message, in the order the template writes them. `slurm` therefore asks for `--set node_local_root=VALUE` and `--set shared_scratch=VALUE` together.
- `eb-local site show` and `site install` name the template and its line when a rendered value does not load, as in `template slurm:10: storage.node_local_root must be one absolute path without a trailing slash`. They named the file install would write, `config.toml` beside the program by default, which is the site file in use, though neither command had written it.
- `eb-local site` now formats read and write fallback errors with `storage.describeError` so diagnostics include OS errno text alongside the target path.
- `eb-local site` now rejects repeated `--to` flags with exit code 2 instead of silently overwriting earlier `--to` targets.
- `eb-local submit --on` now deduplicates repeated node-type names, so listing the same node type more than once generates and submits one job per target.
- `eb-local submit` now double-quotes `#SBATCH --output` and `#SBATCH --chdir` directive values when the path contains spaces or quotes so `sbatch` does not split them on whitespace.
- `eb-local submit` now includes OS errno descriptions via `storage.describeError` when creating `.eb-local/jobs` or `.eb-local/logs` fails.
- `eb-local submit` now rejects unknown flags before the recipe name with exit code 2 instead of forwarding them as the recipe name, while still passing flags after the recipe to `eb`.
- `eb-local submit` now stops immediately and propagates the signal when `sbatch` or `submit` is interrupted by a signal, matching the other attached commands instead of submitting remaining targets and exiting 1.
- `eb-local uninstall --delete` now formats removal failures with `storage.describeError` so permission and filesystem errors include the OS errno description.
- `eb-local uninstall` and `eb-local restore` acquire the prefix lock when modifying installations and release it on every exit path.
- `eb-local uninstall` deduplicates repeated module arguments so installations and module files are removed cleanly on the first pass.
- `eb-local uninstall` now detects single-quoted `depends_on('...')` and `load('...')` dependency lines in Lua modulefiles alongside double-quoted calls.
- `eb-local-readiness` now checks that `--mountinfo` is a regular file and handles non-UTF-8 bytes cleanly with `FAIL` and exit status 1 instead of hanging on a FIFO or crashing with `UnicodeDecodeError`.
- `eb-local-readiness` now compares canonical mount target lengths so a covering mount at a shorter real path overrides an earlier mount entry using a longer symlink alias.
- `eb-local-readiness` now resolves symbolic links with `os.path.realpath` when comparing `--prefix`, `--repo`, mount points, and `MODULEPATH` directories.
- `eb-local-readiness` now selects the latest covering mount entry in `mountinfo` when multiple mounts share the same target path, matching `storage.mountOf` when `cvmfs` overlays `autofs`.
- `eb-local` accepts `--logs-older-than=DAYS` in `clean`, matching `--project=DIR` and `dev --buildenv=MODULE` alongside the Zig binary.
- `eb-local` accepts `=VALUE` forms for `--for`, `--set`, `--to`, and `--logs-older-than` as documented.
- `eb-local` aligns its `env` option refusal diagnostic with `src/main.zig` so invalid `env` arguments emit the same stderr line on both front ends.
- `eb-local` approves `$XDG_CACHE_HOME/eb-local` for RPATH wrappers even when `HOME` is unset.
- `eb-local` builds now check free bytes and free inodes on the install prefix filesystem before creating a job workspace and stop with exit code 2 when either is 0.
- `eb-local` checks guarded `SIGINT` and `SIGTERM` arrivals before forking child processes and removes unused pre-launch workspaces when signalled before `eb` starts.
- `eb-local` checks log directory writability before building and removes the workspace when durable directory setup fails.
- `eb-local` evaluates `valid_module`, `--logs-older-than`, `SLURM_JOB_ID`, and workspace regexes under `LC_ALL=C` via `c_match` so Unicode letters and digits under `LANG=en_US.UTF-8` are refused like `src/main.zig` and `src/config.zig`.
- `eb-local` ignores `SIGXFSZ` while replacing log files during secret redaction so `RLIMIT_FSIZE` failures report `EFBIG` and sibling logs continue redacting.
- `eb-local` names the log or installation directory and OS error reason when top-level secret redaction fails.
- `eb-local` names the target path and OS error reason when installation prefix, log, mountinfo, or submit-job file operations fail.
- `eb-local` parses `eb-local.conf` lines in a single pass before value validation by splitting on the first `=`, reporting `line N: cannot read the line` only when `=` is omitted and `line N: unknown setting` for unrecognized keys to match `legacyToToml` in `src/config.zig`.
- `eb-local` prefixes `--buildenv` validation refusals with `--buildenv: ` to match `src/config.zig`.
- `eb-local` prints its version when `--version` is the first argument (matching `src/main.zig`), refusing `--version` after subcommands or `--env` with exit `2` and forwarding it to `eb` in build mode.
- `eb-local` prints one warning and proceeds unlocked when `flock` returns `ENOLCK`, `ENOTSUP`, `EOPNOTSUPP`, or `ENOSYS`.
- `eb-local` quotes the project path in its `mkdir -p` hint for a missing project directory the way the Zig binary does.
- `eb-local` recognizes `--env` only inside the `build` branch before any positional recipe argument so non-build subcommands reject extra `--env` flags with their existing refusals matching `src/main.zig`.
- `eb-local` recognizes `env`, `dev`, and `clean` subcommands when `--project` precedes them so Bash option ordering matches the Zig binary.
- `eb-local` rejects combining `--no-logs` with `--logs-older-than` in `clean` with exit `2`, matching the Zig binary.
- `eb-local` rejects duplicate keys in `eb-local.conf` after syntax parsing and before value validation with Zig's exact `line` and TOML key diagnostic (`'<toml_key>' is set twice (first on line <N>)`).
- `eb-local` rejects repeated `--logs-older-than` options in `clean` with exit `2` (`clean takes one --logs-older-than`), while refusing empty `--logs-older-than=` first to match `joined()` before the duplicate check in `src/main.zig`.
- `eb-local` reports unreadable log directories and preserves OS error details in secret-redaction warnings while continuing to redact sibling logs.
- `eb-local` serializes concurrent builds on the same prefix through `storage.acquireBoundedLock` with a bounded `flock` wait, stderr notice, and timeout exit 2.
- `eb-local` uses one shared helper (`opt_value`) for `--project`, `--buildenv`, and `--logs-older-than` so separated and joined empty or omitted values print `<opt> needs a value` (`exit 2`), matching `src/main.zig`.
- `eb-local` validates `eb-local.conf` values grouped by TOML table in first-appearance order and formats diagnostics as `<file>:<line>: <toml_key> ...`, matching `src/config.zig`.
- `eb-local` validates legacy `eb-local.conf` paths, mount patterns, and filesystem types through `c_match` so Unicode characters under `LANG=en_US.UTF-8` are refused like `src/config.zig`.
- `elfcheck.isHostPath` now collapses repeated leading slashes before matching `/lib`, `/lib64`, and `/usr`, so `eb-local check` catches host libraries resolved through paths such as `//usr/lib64`.
- `elfcheck.parse` now uses checked integer addition when matching `DT_STRTAB` bounds against `PT_LOAD` segments so wrapping ELF headers are rejected as damaged.
- `env --strict`, `EB_LOCAL_ENV_STRICT=1`, and `dev --strict` now emit an `elif [[ ! -f $init || ! -r $init ]]` guard in the strict prelude so a non-regular or unreadable EESSI init path exits 2 instead of proceeding to `module load`.
- `extend.initPath` now trims trailing slashes from `EESSI_CVMFS_REPO` before building the `/versions/.../init/lmod/bash` path reported by `eb-local doctor` and `eb-local eb`.
- `gccBuildenv` now matches GCC toolchain names at `/` and string boundaries as `llvmToolchain` does, recognizing `buildenv/foss-...`, `foss/...`, and `GCCcore/...` build environments.
- `jsonout.emit` now checks `common.sys.writeAll` on stdout, prints `eb-local: cannot write JSON output (...)` to stderr, and exits 1 when writing fails (such as on `ENOSPC`).
- `jsonout.utf8Safe` now uses Zig 0.17 `ptr.attrs.@"const"` and sanitizes mutable and sentinel-terminated `u8` slices instead of failing comptime field lookup on `ptr.is_const`.
- `lmod-cache --verify` now accepts Lmod terse category headers, status markers and alias lines.
- `lmod-cache --verify` removes empty newly created cache directories on failure and exits 127 when `module` is missing.
- `lmodcache.moduleDirs` now deduplicates repeated directories in `--modulepath` while keeping first-seen order so `spider` receives each module tree once.
- `mpi.parseRanks` now parses `rank`, `size`, `cpu`, and `cpus` fields starting at `hello rank=` instead of from the start of the line.
- `openConfig` now formats configuration and template open failures with `storage.describeError`, reporting OS errno messages alongside the target path.
- `rpath.write` now refuses a symlinked or foreign-owned `eb-local` parent directory before creating or writing compiler RPATH wrappers.
- `rpath.write` now writes compiler wrappers before writing the `.eb-local-rpath` marker and removes any newly created wrapper directory on failure, so failed runs leave no poisoned marker directory behind.
- `secrets.resolve` now reports OS errno descriptions via `storage.describeError` when `file:` or `nimvault:` secret sources fail to open, read, or run.
- `secrets.resolve` now requires `HOME` to be non-empty and absolute when expanding `file:~/...` secret sources and `nimvault.vault` paths starting with `~/`.
- `sites.render` now validates default values in `{{name:default}}` placeholders with `validValue`, rejecting defaults that are empty or break out of TOML strings.
- `src/rpath.zig` includes `--help=*` among info-only compiler flags in its generated wrapper script so `LIBRARY_PATH` and `-L` run paths are not appended to `--help=target` queries.
- `src/rpath.zig` sets `link=0` in its generated wrapper script for LLVM and Intel info-only queries (`-help`, `--help-hidden`, `-version`, `-dumpmachine`, `-print-*`) and non-linking actions (`--analyze`, `--precompile`, `--preprocess`, `-emit-ast`, `-emit-pch`) even when combined with `--target=...`.
- `storage.lockTimeoutMs` now requires `EB_LOCAL_LOCK_TIMEOUT_MS` to consist strictly of ASCII digits, rejecting leading `+` signs and `_` separators.
- `storage.under` now treats `/` as an ancestor of any absolute path instead of returning `false` when `path` is not `"/"`.
- `toml.parse` now rejects a leading UTF-8 BOM cleanly, reports the exact line number for NUL and non-UTF-8 bytes, and reports unclosed single-line strings on CRLF endings.
- `toml.parse` now rejects unescaped `0x7f` (DEL) bytes inside basic and literal strings as control characters, matching TOML 1.0 and `sites.validValue`.
- `tools/cli_assets.py` extracts subcommands and sub-actions from `eb-local --help` without leaking description prose into generated shell completions.
- `tools/cli_assets.py` writes each completion and manpage asset through a staged temporary file that rejects symlinks and rolls back earlier writes on failure. Filesystem errors print a `cli_assets:` diagnostic on stderr and exit `1` instead of raising an unhandled traceback.

### Documentation

- "Build for every node type" in the README uses one set of node types, `cpu` and `gpu`, in its `[build.targets]` example and in its `submit --on gpu` command. The command named a target the example lacked, and exited 2.
- A build or `eb-local eb` that stops on an install path EESSI-extend moved, or on an install variable a load sets, names the page "Where EESSI-extend installs" by its address, https://stackhands.github.io/eb-local/explanation/install-variables.html, rather than a section of the README.
- Add `docs/orgmode/reference/readiness.org` to document `eb-local-readiness` options, output prefixes, and exit codes, register it in the reference index, and note the `--prefix` requirement in `find-what-is-wrong.org`.
- Add the missing doc comment for `lmodcache.Options` so the declaration lint and CI tests pass.
- Aligned the `--json` option summary and `list`/`config` JSON descriptions in `docs/orgmode/reference/cli.org` and `docs/reference/cli.md` with the JSON schemas and emitted fields.
- An inline source block in an Org page, such as `src_sh{eb-local env}`, comes out as code in the page `docs/export.el` writes. It came out empty: Org's Babel exported its results by default, and a batch export runs nothing.
- Clarify in the `doctor` section of `docs/orgmode/reference/cli.org` and `docs/reference/cli.md` that `--json` exits 1 when `failed` is `true` (either `FAIL` or a warning under `--strict`).
- Document `--strict` (and `EB_LOCAL_ENV_STRICT=1` with exit status 2) in the `env` section of `docs/orgmode/reference/cli.org` and `docs/reference/cli.md`.
- Document that `eb-local lmod-cache --verify` exits 127 when `module` is missing and 1 on inventory failures.
- Document the EESSI, Lmod, and CernVM-FS environment variables read by `eb-local` in `environment.org`.
- Document the `doctor --cvmfs`, `--cvmfs-parallel`, and `--mpi` flags in the `cli.org` synopsis, update the post-v3.1.0 additions summary, and list `lmod-cache` exit 1 cases.
- Documents the recipe overlay file format, the overlay command, and a how-to for rebasing site recipe changes.
- Every `pub` declaration in the source has a doc comment, so each entry in the API reference says what the declaration is for, and a test fails when one is added without.
- List `SHELLOPTS` and `BASHOPTS` among the refused secret variable names in the configuration reference (`docs/orgmode/reference/configuration.org` and `docs/reference/configuration.md`), matching `src/config.zig`.
- Match the exact `eb-local lmod-cache` missing-mode error message in `refresh-the-module-cache.org`.
- The CLI reference now states that it documents `main`, and it records that no flags were removed or renamed since `v3.1.0`.
- The README has a how-to for a site Lmod hook. Build, source and temporary paths from a hook work; an install path from a hook bypasses eb-local's checks and its cleaning of secrets from logs; and a default install prefix cannot come from a load hook, so a site that wants one sets it in the environment and as `prefix` in its site file. The README also says why the default prefix is `$HOME/eessi`.
- The README opens with when `module load EESSI-extend` and `eb` are enough, and the four things eb-local adds.
- The README says why `dev`'s programs get their run paths: the modules set `LIBRARY_PATH` and the build environment's `gcc` and `ld` wrappers read it when the program links, so the order the modules load in does not matter, and one real `gcc` or `ld` ahead of the wrappers does no harm. It no longer gives keeping a compiler's `gcc` or `ld` behind the wrappers as the reason the build environment loads last, and says "RPATH entries" where it said "RUNPATH": the cluster test found DT_RPATH entries.
- The README's `eb-local list` transcript is a `console` block, so the documentation builds with warnings as errors again: as an `sh` block, the apostrophe in its output stopped the highlighter, and `sphinx -W` failed.
- The configuration reference says that `eb-local doctor` reads every secret, as `eb-local config --check` does, and that a build that does not get a secret from `env:VARIABLE` runs `eb` without VARIABLE.
- The configuration reference shows a user file with profiles and what `eb-local profiles` and `eb-local --profile gpu config` print for it. It also notes that `eb-local config` shows each `[eessi]` value. The README's Configuration section points to the reference, the environment variables and the site file how-to in place of repeating them.
- The documentation has a Contributing page, with the tests, the news fragments, the site acceptance scripts in `tests/site/`, how to build the pages and how to write one, and a Changelog page that shows `CHANGELOG.md`. The README's Test section points at the Contributing page.
- The documentation has a page on where EESSI-extend installs under each install variable and each mix of them, as the module did under Lmod, on the trap a variable left from an earlier session sets, and on what eb-local checks. Pages besides the README are written in Org under `docs/orgmode` and exported to the MyST pages Sphinx builds with `emacs --batch -Q -l docs/export.el`, which needs only the Markdown backend Org has; a test checks the committed pages against a fresh export where Emacs is installed.
- The documentation has four sections, each with an index page: tutorials, how-to guides, explanation and reference. The front page is written from `docs/orgmode/index.org`, as the other pages are, and says where to read for what. The tutorial is eb-stack's, which the tutorials page links.
- The explanation "Where a build puts things, and why" holds the README's "Where things go": what goes in the workspace and what in the prefix, why the work happens on a node-local mount of the job's own, why installs, sources and logs stay in the prefix, and why the default prefix is `$HOME/eessi`, with the notice a pre-3.0 `$HOME/.local/eessi` gets.
- The explanation "eb-local and eb-stack" says what each tool does, that an eb-stack EESSI-extend target runs eb-local with `EB_LOCAL_EESSI_EXTEND=1` while eb-local never runs eb-stack, why the split falls at one build, and which tool a task needs; how eb-stack plans and finds gaps stays in its own documentation.
- The find-what-is-wrong how-to says release 3.1.0 does not ship `eb-local-readiness`, and installs the script from a pinned main commit or a checkout instead of a missing release URL.
- The generated how-to pages for install and find-what-is-wrong are refreshed from their Org sources with `docs/export.el`, so the committed Markdown matches what the documentation export test checks.
- The help, the README, the 3.0.0 release note and the refusal of `eb-local eb` say that at most one of `EESSI_USER_INSTALL`, `EESSI_PROJECT_INSTALL`, `EESSI_SITE_INSTALL` and `EESSI_CVMFS_INSTALL` may be set, where they said exactly one: with none set, the command runs and the module installs under `$HOME/eessi`.
- The how-to "Build for every node type" lists the node types in the site file, prints and runs the `sbatch` line `eb-local --explain` gives for each, checks the jobs, and covers `eb-local submit` until 4.0.0. The tests that ran the README's node types and `submit` commands now run those of the page, and check that the `sbatch` line it runs is one `--explain` prints. The README points to the page.
- The how-to "Clean up after builds, and remove what you installed" covers `eb-local clean`, the workspace a failed build keeps, `eb-local uninstall` and `eb-local restore`, with what each prints; the reference has the details the README had.
- The how-to "Compile your code against EESSI" builds a program with `eb-local dev` for one node type, checks it with `eb-local check`, runs it from a job script, and lists the other kinds of code and compilers `dev` handles; its failure table includes the unbound variable EESSI's Lmod init stops a `set -u` script on. The page "Run paths, and one build per CPU target" says why a program built so needs no `LD_LIBRARY_PATH`, why the wrappers record `RPATH`, and why each CPU target needs its own build. The reference lists each problem `eb-local check` reports. The README points to both pages.
- The how-to "Find what is wrong with a build or a module" reads `eb-local doctor` and `eb-local list`, and the CPU targets a module is built for; the reference lists what `doctor` checks. A test checks each `doctor` line the how-to guides show against the messages in the code.
- The how-to "Install eb-local" has the steps to install a release, with its checksums and attestations, or to build from source, what the main branch has that release 3.1.0 lacks, and what to do when a step fails. The README points to it, and the reference describes the frozen 1.x Bash script.
- The how-to "Install software on top of EESSI with EasyBuild" finds a recipe with `eb-local eb -- --search`, builds it in an allocation, loads it, builds into a project directory for a group, checks the result with `eb-local list`, and says what each failure means, including the reason Lmod gives when a module does not load. The reference says which Lmod init a build sources, and the page on run paths which CPU target eessi-arch-guard gives a build. The README points to the how-to.
- The how-to "Install the modules EESSI lacks, found with eb-stack" runs eb-stack's gap on a list of a site's modules against EESSI's module tree and EasyBuild's easyconfigs, and installs the recipes it names with one `eb-local` build each, pointing to eb-stack's guides for what the gap means.
- The how-to "Load EESSI and the software you installed" loads EESSI and EESSI-extend with `eb-local env` in a shell and in a job script, for a user prefix or a project, carries the settings into a job or a container with `eb-local config --env`, and checks the result with `eb-local doctor`. The README's section on the configuration as variables points to it.
- The how-to "Run EasyBuild through EESSI-extend without a site file" installs with `eb-local eb` into your home, another directory or a project, and from a program that passes only eb's arguments; the reference has the install modes and the details the README had, and says that the printed build script runs with `W` set to a workspace a build made.
- The how-to "Set a site's EasyBuild defaults and default prefix" holds the README's site Lmod hook, with checks of the paths it gives EESSI-extend loaded by hand, `eb-local eb` and a build, and a login script that sets another default prefix and creates it, since EESSI-extend refuses a user directory that does not exist; a test runs that script and checks that `doctor` accepts the prefix it sets.
- The how-to "Write the site file for a cluster" renders the `slurm` template with a site's values, installs it beside the program, adds what the template has no placeholder for, keeps a site's own template, checks the result with `eb-local config` and with `eb-local doctor` in a job, and says what each refusal on the way means. A test runs the `site list`, `site show` and `site install` commands it shows and compares their output with the page. The README points to it.
- The new explanation page "What happens to a secret" says when a build reads a secret, which builds get it, where its value goes and how the logs are cleaned of it. It also covers what a stopped build and a kept workspace leave behind, and how nimvault runs. The README's Secrets section points to it.
- The no-site-file how-to now shows the `doctor` output that release 3.1.0 and main print (`FAIL no site file sets storage.node_local_root, so builds cannot run`) and explains that this is expected while `eb-local eb` still works without a site file; install docs now also say that `./eb-local --version` in a checkout is the frozen Bash compatibility script, not the installed Zig binary.
- The reference describes the `eb-local` command: its synopsis, the usage `eb-local --help` prints, its options, each command with its own options, and the exit statuses. A test fails when the page's copy of the usage differs from what the program prints, or when the page leaves out an option or a command.
- The reference describes the configuration files: where eb-local looks for them, which owners and permissions it accepts, the order of the layers, how a profile is chosen, and each setting with its value, default and meaning. A test fails when a setting `eb-local config` shows has no row on the page, or when the page's default differs from what it prints.
- The reference has the API of each component, written from the doc comments as the site is built: a page for each source file, with each `pub` declaration linked to its source line, and the Zig autodoc site at `api/`, which `zig build docs` makes. Building the documentation now needs Zig 0.17.1 on `PATH`. "Edit this page" opens a page's Org source.
- The reference lists the environment variables eb-local reads, with the setting each one replaces, and the variables `eb-local env`, `eb-local dev` and a build set or clear. A test fails when the page leaves out an `EB_LOCAL_*` variable the program reads, names one it does not, or leaves out a variable a build sets or `env` unsets.
- The reference says that `env --strict` and `dev --strict` end the shell that evaluates their lines when the EESSI init file is absent, and that `EESSI_VERSION` and `EESSI_CVMFS_REPO` choose only the Lmod init file for `env` and `dev`: the stack those lines load is `stack.module`.
- Updated `docs/orgmode/reference/refusals.org` and `docs/reference/refusals.md` so the workspace creation failure example shows `([Errno 28] No space left on device)` as printed by the built binary.
- Updated the `write-a-site-file` how-to page so its symlink refusal row matches the message `eb-local site install` prints (`FILE is a symbolic link; pass a regular file path`).
- `docs/export.el` writes no blank at the end of a line. Org's Markdown indented the empty lines of a list item, such as those around a code block in a numbered step, and the whitespace hook then changed the written page, which no longer matched its Org source.

### Removals

- A user build no longer passes `--umask=022` to eb. It runs with the umask EESSI-extend sets for a user install, 077, and the sticky bit, as `eb-local eb` does, so the modules in `$HOME/eessi` have the same permissions whichever of the two built them. Installs made before keep their modes. To share installs, use `--project`; where others must read a user install, pass `--umask=022` among eb's options.
- The Bash script `eb-local`, 1.x, is frozen: it gains no commands, and it is removed in 4.0.0, as is the test suite's default run against it. Its help says so. The eb-local program has its commands and reads the same `eb-local.conf`.
- The `nimvault:` secret source is deprecated, warns on each build that uses it, and is removed in 4.0.0; `file:` and `env:` serve any vault.
- The worked example of a real site's file is gone from `examples/sites/`; a site keeps its own site file in a repository of its own, and installs it with `eb-local site install FILE` as before. `examples/sites/example.toml` is a worked example for a site that does not exist. The release notes of earlier releases no longer name the site.
- `[build.targets]` in the site file is now `[build.node_types]`, as the documentation calls its entries; a target is already a CPU target in `eb-local list` and `eb-local check`. eb-local reads the old name until 4.0.0 and warns where it does, and refuses a file that has both. `eb-local config` shows the entries as `build.node_types.NAME`.
- `eb-local submit` is deprecated and is removed in 4.0.0; it says so when it runs, and otherwise works as before. `eb-local --explain RECIPE` prints the `sbatch` line for each node type the site lists; `[build.node_types]` stays.

### Miscellaneous

- A test checks each `eb-local:` line the how-to guides show against the messages in the code, so a reworded message fails until the guides show the new words.
- Add black-box CLI tests for `eb-local check` flag and refusal parity in `tests/test_check_cli_flags.py`.
- Add black-box CLI tests for `eb-local clean` filters, age bounds, and refusals in `tests/test_clean_cli_modes.py`.
- Add black-box CLI tests for `eb-local config` modes, `--get`, `--env`, and `--check` in `tests/test_config_cli_modes.py`.
- Add black-box CLI tests for `eb-local dev` module validation and warnings in `tests/test_dev_cli_modes.py`.
- Add black-box CLI tests for `eb-local doctor` option validation, environment warnings, and init checks in `tests/test_doctor_cli_modes.py`.
- Add black-box CLI tests for `eb-local eb` and `EB_LOCAL_EESSI_EXTEND` in `tests/test_eb_cli_modes.py`.
- Add black-box CLI tests for `eb-local env` and `--env` in `tests/test_env_cli_modes.py`.
- Add black-box CLI tests for `eb-local list` filters, multi-version labels, and refusals in `tests/test_list_cli_modes.py`.
- Add black-box CLI tests for `eb-local lmod-cache` modes and path validation in `tests/test_lmod_cache_cli_modes.py`.
- Add black-box CLI tests for `eb-local modulerc` error handling and JSON idempotency in `tests/test_modulerc_cli_errors.py`.
- Add black-box CLI tests for `eb-local overlay` action dispatch and `eb-stack` forwarding in `tests/test_overlay_eb_stack_cli.py`.
- Add black-box CLI tests for `eb-local profiles` in `tests/test_profiles_cli.py`.
- Add black-box CLI tests for `eb-local restore` in `tests/test_restore_cli.py`.
- Add black-box CLI tests for `eb-local rpath-wrappers` in `tests/test_rpath_wrappers_cli.py`.
- Add black-box CLI tests for `eb-local site` subactions, template rendering, and refusals in `tests/test_site_cli_modes.py`.
- Add black-box CLI tests for `eb-local submit` modes and partial failures in `tests/test_submit_cli_modes.py`.
- Add black-box CLI tests for `eb-local uninstall` options, `--delete`, and refusals in `tests/test_uninstall_cli_modes.py`.
- Add black-box CLI tests for default recipe build refusals, `--explain`, `help`, and `--version` in `tests/test_build_cli_modes.py`.
- Added CLI regression tests in `tests/test_lmod_cache_cli_modes.py` using `tests/hostile_fs.py` to verify that `eb-local lmod-cache` refuses read-only cache directories, directory or dangling-symlink collisions at output paths, and `ENOSPC` on a full tmpfs cleanly.
- Added CLI regression tests in `tests/test_modulerc_cli.py` using `tests/hostile_fs.py` to verify that `eb-local modulerc` refuses read-only trees, directory or dangling-symlink collisions at `.modulerc.lua`, and `ENOSPC` on a full tmpfs cleanly.
- Added CLI regression tests in `tests/test_rpath_wrappers_cli.py` using `tests/hostile_fs.py` to verify that `eb-local rpath-wrappers` refuses read-only parents, directory or dangling-symlink collisions at wrapper paths, and `ENOSPC` on a full tmpfs cleanly.
- Added a CLI test covering `eb-local restore` when `rtrash list --json` contains duplicate entries for the same path.
- Added a CLI test in `RefusalWording` covering symlink, non-directory, and absent-mountinfo refusals for the node-local mount.
- Added a CLI test verifying `[eessi]` rejects reserved `EESSI_*` install and site-toolchain variable names with exit status 2.
- Added a CLI test verifying `eb-local clean` exits 2 with the `rtrash put exited` message and leaves targets intact when `rtrash put` fails.
- Added shared hostile-destination test helpers in `tests/hostile_fs.py` (`enter_full_tmpfs`, `readonly_dir`, and `dangling_symlink`) with unit coverage in `tests/test_hostile_fs.py`.
- Adds an example OpenMPI site overlay template under `examples/overlays/`.
- Adds command-line tests for digest-pinned materialization and the default byte-identical path when an overlay has no edits.
- Prove that disabling foreign-prefix clearing produces byte-identical default build output.
- The `eb-local eb` tests check that no default prefix is made in `$HOME/eessi`, the directory EESSI-extend installs into, as well as in `$HOME/EESSI`, the one its help text names. Four of them looked only at `$HOME/EESSI`, and passed with a launcher that made `$HOME/eessi`.
- The test that each Org source has its page in a table of contents compares both lists in one order, so a page whose name extends another's, such as `install-software` beside `install`, no longer fails it.
- The tests use the example site's node types, and CI looks for every name on the documentation's list.
- `eb-local` delegates shell word quoting to `zig-common`'s `pytext.shellQuote`.
- `eb-local` pins `zig-common` `v0.10.0` in `build.zig.zon`, adding `fsx.mkdtemp` alongside `fsx.normPath` and `fsx.absPath`.
- `prek run --all-files` runs the hooks in `prek.toml`: whitespace and end-of-file fixes, YAML and TOML checks, `zig fmt --check`, shellcheck and codespell; `prek install` runs them on each commit.
- `storage.describeError` maps system errors to kernel errno text for shared diagnostics.
- `tests/site/build-job.sh` ages the log directory its `clean` check makes, as well as the log in it. `clean` takes a directory among the logs once neither it nor anything in it is newer than the cutoff, so the check found nothing to clean and failed twice. The command reference and the clean-up guide say that a directory's own time counts.
- `tests/test_overlay_cli.py` verifies that `eb-local overlay materialize` refuses read-only output directories and dangling symlinks while rolling back partial outputs on symlink or out-of-space tmpfs failures.
- `tests/test_rpath_wrappers_cli.py` extends `test_wrappers_bypass_llvm_intel_nonlinking_flags` to run every LLVM and Intel non-linking flag through the generated wrapper and confirm forwarded `argv` lines omit `-rpath` and `--disable-new-dtags`.
- `tests/test_rpath_wrappers_cli.py` moves the `--help=*` RPATH wrapper check onto its shared fake-compiler fixture.
- `tests/test_sites_cli.py` verifies that `eb-local site install` exits `2` with an out-of-space diagnostic and keeps the destination directory free of partial files when writing to a full tmpfs.
- `zig build test` runs the command-line suite without `-Dtest-ops=true`: the suite gets a debug build of its own with the test seams, where it failed 33 tests against a binary without them. `zig build -Dtest-ops=true test`, as CI runs it, still runs the suite against the binary it builds.
- eb-local builds on zig-common 0.9.0, as eessi-arch-guard does. Cleaning secrets from a log now keeps a GPFS NFSv4 ACL on the file, which the rewrite dropped, and a program eb-local runs and reads, such as nimvault, gets `/dev/null` or its pipe on a standard stream eb-local was started without, so its errors no longer land in what eb-local reads from it.


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
- `eb-local eb` sources the EESSI init, loads `EESSI-extend` and runs `eb`, with no site file and no Slurm job. At most one of `EESSI_USER_INSTALL`, `EESSI_PROJECT_INSTALL`, `EESSI_SITE_INSTALL` and `EESSI_CVMFS_INSTALL` may be set, and a present empty value counts as set. A non-empty user prefix is created; a project, site or cvmfs prefix is not. With none of the four set, nothing is exported: the module installs under `$HOME/eessi` (its help text says `$HOME/EESSI`). The process umask is 077, 002 or 022 for those modes, and EasyBuild keeps the umask, the sticky bit and the hooks the module sets. `EB_LOCAL_EESSI_EXTEND=1` selects the same launcher when every argument belongs to `eb`.
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

- The site template written for one particular site is no longer built into eb-local, whose built-in templates are for no particular site; it is now a worked example under `examples/sites/`, with the same settings. `eb-local site install NAME` for it becomes `eb-local site install examples/sites/FILE`, run from a checkout of eb-local. A site file already installed needs no change.

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
  built into the program, `slurm` and one for a particular site, with
  placeholders filled by `--set KEY=VALUE`. `install` writes `config.toml`
  beside the program (or `--to FILE`), mode 644, only after the rendered
  file loads as a site file; it replaces a file only with `--force` and
  never writes through a symbolic link.
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
  against rtrash 0.1.4 on a production cluster; the test double now
  refuses a directory without `-r` as rtrash does.

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
  build programs that run without `LD_LIBRARY_PATH`. Checked on a
  production cluster for C with FFTW and OpenMP, MPI, CMake against GSL, a
  Python venv with a compiled package, and an R package.
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
