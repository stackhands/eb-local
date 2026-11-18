<!-- Generated from docs/orgmode/reference/readiness.org by docs/export.el; edit that file. -->

# Readiness probe

`eb-local-readiness` checks the EESSI client mount and local-module precedence on `MODULEPATH` without changing files or the environment.
It lives at the root of the repository on `main` (outside the `eb-local` binary release archive).

## Synopsis

```text
eb-local-readiness [--repo PATH] [--prefix PATH] [--mountinfo FILE]
```

## Options

| Option | Default | Meaning |
|---|---|---|
| `--repo PATH` | `EESSI_CVMFS_REPO`, else `/cvmfs/software.eessi.io` | EESSI repository directory whose mount and `MODULEPATH` position are checked. |
| `--prefix PATH` | `EB_LOCAL_PREFIX`, `EESSI_SITE_SOFTWARE_PREFIX`, `EESSI_PROJECT_INSTALL`, `EESSI_USER_INSTALL` | Local installation prefix to look for on `MODULEPATH`; when unset, skips precedence check. |
| `--mountinfo FILE` | `/proc/self/mountinfo` | Linux mount table file to inspect. |

## Output lines

`ok`
: the EESSI repository is mounted with `cvmfs`, or a module directory under `--prefix` precedes upstream EESSI on `MODULEPATH`.

`warn`
: the EESSI repository exists without a mount entry or on another filesystem (for example a bind mount), or no upstream module directory is on `MODULEPATH`.

`info`
: no local prefix is selected, so the `MODULEPATH` precedence check did not run.

`FAIL`
: the EESSI repository directory is missing, no module directory under `--prefix` is on `MODULEPATH`, upstream EESSI modules precede local modules, or `--mountinfo` cannot be read.

## Exit status

| Status | Meaning |
|---|---|
| 0 | No `FAIL` line was printed (warnings or `info` lines alone still exit 0). |
| 1 | At least one `FAIL` line was printed, or `--mountinfo` could not be read. |
| 2 | `--repo` or `--prefix` was passed as an empty string, or the command line could not be parsed. |
