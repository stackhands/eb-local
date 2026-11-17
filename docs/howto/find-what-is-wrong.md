<!-- Generated from docs/orgmode/howto/find-what-is-wrong.org by docs/export.el; edit that file. -->

# Find what is wrong with a build or a module

When a build stops before it starts, or a module you installed does not load, two commands say why.
`eb-local doctor` checks, one line each, what would stop a build, `eb-local eb` or a module load, and `eb-local list` shows the CPU targets each module is built for.
These steps run them and read what they say.

## Before you start

-   A shell where the problem happens: inside the allocation for a build, and on the node type where it does not load for a module.

## Find what stops a build or a load

1.  Run `doctor` in that shell.
    In this one, an earlier session left `EESSI_PROJECT_INSTALL` and `LD_LIBRARY_PATH` set:

    ```bash
    eb-local doctor
    ```

    ```text
    ok   eb-local 3.1.0
    ok   site file /usr/local/bin/config.toml
    ok   builds use the allocation's own xfs mount /local/%u.%j
    ok   installs go to /home/alice/eessi: a user install, prefix from default
    warn EESSI_PROJECT_INSTALL=/path/to/project/eessi is set in this shell; eb-local builds clear it, but EESSI-extend or eb run by hand would use it
    ok   `eb-local eb` sources /cvmfs/software.eessi.io/versions/2026.06/init/lmod/bash
    warn EESSI_PROJECT_INSTALL=/path/to/project/eessi is not a directory, so EESSI-extend refuses to load and `eb-local eb` stops; the project owner creates it with the project group and chmod 2770
    warn LD_LIBRARY_PATH is set; programs built with eb-local dev do not need it, and it can mix host libraries into EESSI's
    ok   Slurm job 21: build space /local/alice.21
    info EESSI is not loaded in this shell; eval "$(eb-local env)" loads it with your modules
    info eessi-arch-guard is not on PATH; builds, env and dev load EESSI for the target EESSI detects
    warn your modules are not on MODULEPATH in this shell; eval "$(eb-local env)"
    info no module command in this shell; builds, env and dev source /cvmfs/software.eessi.io/versions/2026.06/init/lmod/bash
    ok   rtrash is on PATH: clean and uninstall move files to the trash

    Nothing above stops a build.
    ```

    Each line says `ok`, `info`, `warn` or `FAIL`, and a `warn` or `FAIL` line says what to change.
    `doctor` changes nothing, and exits 1 when a line says `FAIL`.
    With a site file, what stops a build is a `FAIL`, and what stops only `eb-local eb` is a `warn`; without one, builds cannot run, so what stops `eb-local eb` is the `FAIL`.
    Here `EESSI_PROJECT_INSTALL` would send EESSI-extend, loaded by hand or by `eb-local eb`, to a project directory that is not there; `unset EESSI_PROJECT_INSTALL LD_LIBRARY_PATH` clears both warnings.

2.  With EESSI loaded, see which CPU targets the module is built for:

    ```bash
    eval "$(eb-local env)"
    eb-local list pigz
    ```

    ```text
    /home/alice/eessi: 1 module(s) for 1 CPU target(s)
    MODULE                   sapphirerapids*
    pigz/2.8-GCCcore-15.2.0  x
    Every module listed is built for this node's target, x86_64/intel/sapphirerapids (*).
    ```

    Each CPU target has its own tree, so a module built on one node type is not there on another.
    Each tree has a column, `x` where the module is built for it, and `*` marks this node's target.
    When this node's target lacks modules, the last lines name them:

    ```text
    Not built for this node's target, TARGET (*): MODULES.
    Build them in an allocation on this node type; each target needs its own build.
    ```

    When nothing is built for it, the last line is `Nothing is built for this node's target, TARGET, yet; build in an allocation on this node type.`
    `eb-local list` alone shows every module you installed.

3.  Load the module by hand, with its full name, to see the reason Lmod gives:

    ```bash
    module load pigz/2.8-GCCcore-15.2.0
    ```

    For a module that is not on `MODULEPATH`, here `pigz/9.9`, Lmod says:

    ```text
    Lmod has detected the following error: The following module(s) are unknown:
    "pigz/9.9"
    ```

    A build that cannot load a module prints Lmod's reason itself, indented below the module's name, keeps its workspace, and exits 1:

    ```text
    eb-local: could not load EESSI/2099.01:
      Lmod has detected the following error: The following module(s) are unknown:
      "EESSI/2099.01"
    ```

    Here `EB_LOCAL_STACK_MODULE` named an EESSI version this host does not have; `eb-local config` shows each setting and where it was set.

    Where the shell has Lmod's `module` command but no directory on `MODULEPATH` holds the EESSI module, a build cannot load `EESSI/2026.06` either; with nothing on `MODULEPATH`, Lmod's reason starts `Lmod Warning: MODULEPATH is undefined.`
    `eb-local doctor` names the directory to add:

    ```bash
    eb-local doctor
    ```

    ```text
    FAIL no directory on MODULEPATH in this shell holds stack.module, EESSI/2026.06 [default], so builds, env and dev cannot load it; module use /cvmfs/software.eessi.io/init/modules adds EESSI's module directory
    ```

4.  For a build that stops before it starts, read its refusal: the first line says what was refused and why, and the next what to change, with the setting and where it was set.
    [Refusals](../reference/refusals.md) lists each one.
    `eb-local --explain RECIPE` prints the checks a build makes, and the script it runs.

When you ask the site for help, include the output of `eb-local doctor` and of `eb-local config`; neither shows the value of a secret.

## Check the EESSI client and module order

Before a site build, run the standalone, non-mutating readiness probe `eb-local-readiness`.
Release 3.1.0 ships the `eb-local` binary only; the script is in the repository on `main`, not in the release archive.

From a checkout, run it from the repository root:

```bash
./eb-local-readiness --prefix /opt/site/eessi
```

Without a checkout, copy the script from `main` onto `PATH`.
The commit pinned here matches published `main`:

```bash
curl -fsSL -o ~/.local/bin/eb-local-readiness \
  https://raw.githubusercontent.com/stackhands/eb-local/8cc1d02b38c163accd7973d1ac8e8ab12e013427/eb-local-readiness
chmod 0755 ~/.local/bin/eb-local-readiness
eb-local-readiness --prefix /opt/site/eessi
```

The repository defaults to `EESSI_CVMFS_REPO`, or `/cvmfs/software.eessi.io`.
The prefix defaults to `EB_LOCAL_PREFIX`, `EESSI_SITE_SOFTWARE_PREFIX`, `EESSI_PROJECT_INSTALL` or `EESSI_USER_INSTALL`, in that order.
A ready shell reports that the repository is mounted with CVMFS and that local modules precede EESSI on `MODULEPATH`.

The probe exits 1 when the repository is missing, no local module directory is on `MODULEPATH`, or upstream EESSI modules occur first.
It warns but exits 0 for another filesystem because a site may deliberately expose CVMFS through a bind mount.
Use `--mountinfo FILE` to check a saved node mount table or a container's view.

## Check that it worked

`eb-local doctor` in the same shell ends with this line, and exits 0:

```text
Nothing above stops a build.
```

Without a site file, it ends with ``Nothing above stops `eb-local eb`; `eb-local RECIPE` needs a site file.`` instead.

## If it fails

| Message | Cause | What to do |
|---|---|---|
| `Something above says FAIL; builds stop there.` | A line says `FAIL`. | Do what that line says, then run `eb-local doctor` again. |
| `Lmod has detected the following error: The following module(s) are unknown:` | The module is not on `MODULEPATH` in this shell. | Run `eval "$(eb-local env)"` with the options the build had, and check its CPU targets with `eb-local list`. |
| `Nothing that matches is installed in PREFIX.` from `eb-local list` | No module under this prefix matches the name. | Check the prefix with `eb-local config`; for a project's modules, run `eb-local list --project DIR`. |

## Related

-   [Refusals](../reference/refusals.md)
-   [The eb-local command](../reference/cli.md): `doctor` and `list`
-   [Where EESSI-extend installs](../explanation/install-variables.md)
