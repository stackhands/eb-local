<!-- Generated from docs/orgmode/contributing.org by docs/export.el; edit that file. -->

# Contributing

Changes come as pull requests to [stackhands/eb-local](https://github.com/stackhands/eb-local).
A change to behaviour changes the page that describes it in the same pull request.

## Record the change

Every change adds a news fragment to `changelog.d/`: `PR.TYPE.md`, with the pull request's number, which the release notes link to, or `+SLUG.TYPE.md`, with a short slug for the change.
TYPE is one of the types `towncrier.toml` configures:

| Type | Section of the release notes |
|---|---|
| `feature` | Features |
| `bugfix` | Fixes |
| `doc` | Documentation |
| `removal` | Removals |
| `misc` | Miscellaneous |

A fragment is one paragraph in the present tense that names the commands, options, settings and files it is about in backticks, as the entries in the [Changelog](changelog.md) do.
With towncrier 26.9.0 installed, this prints the release notes the fragments make, for the version in `build.zig.zon`:

```bash
towncrier build --draft --version 3.1.0
```

The `changelog` workflow runs the same draft, and fails on a fragment whose name has no such type.

## Run the tests

With Zig 0.17.1 and Python 3.12, from the top of the repository:

```bash
zig fmt --check src build.zig
zig build unit
zig build -Dtest-ops=true test
```

`zig build unit` runs the unit tests in `src/`.
`zig build test` runs them, and then the command-line suite in `tests/` against a debug binary that reads the mount table the tests give it.
With `-Dtest-ops=true`, as the `zig` workflow runs it, that binary is the one the build installs; without, it is a build of its own.
`python3 -m unittest discover -s tests` runs the same suite against the Bash script `eb-local` at the top of the repository, the 1.x command, until 4.0.0 removes it.

A release build carries no test seam, which the `zig` workflow checks on the binary this builds:

```bash
zig build --release=safe --prefix out
out/bin/eb-local --version
```

`prek run --all-files` runs the hooks in `prek.toml`, and `prek install` runs them on each commit: whitespace and end-of-file fixes, YAML and TOML checks, `zig fmt --check`, shellcheck and codespell.

## Run the site acceptance scripts

The scripts in `tests/site/` run eb-local on a cluster with EESSI 2026.06, Lmod and Slurm.
Each takes a directory, `EB_LOCAL_TEST_ROOT`, that holds the configuration as `eb-local.conf` and gets the installs in `eessi/`; remove it afterwards.
`EB_LOCAL_BIN` names the eb-local under test; without it, `build-job.sh` and `dev-tasks.sh` test the Bash script, and `rtrash-job.sh` stops, as it does without `RTRASH`, the rtrash under test.

| Script | What it checks |
|---|---|
| `dev-tasks.sh` | The tasks of [Compile your code against EESSI](howto/compile.md), each program then run with no modules and no `LD_LIBRARY_PATH`. It needs network access for pip and CRAN. |
| `build-job.sh` | In a batch job: a build that leaves no workspace, its module used through `env` and its program with no modules, a failed build that keeps its workspace until `clean` removes it, `clean` of old logs without rtrash, and `dev-tasks.sh`. |
| `rtrash-job.sh` | In a batch job: `clean` and `uninstall` with the real rtrash, and `restore`, which brings an installation back read-only. |

```bash
EB_LOCAL_TEST_ROOT=DIR EB_LOCAL_BIN=/path/eb-local bash tests/site/dev-tasks.sh
EB_LOCAL_TEST_ROOT=DIR EB_LOCAL_BIN=/path/eb-local sbatch -p PARTITION --output=DIR/job-%j.out --export=ALL tests/site/build-job.sh
sbatch -p PARTITION --output=DIR/job-%j.out --export=ALL,EB_LOCAL_TEST_ROOT=DIR,EB_LOCAL_BIN=/path/eb-local,RTRASH=/path/rtrash tests/site/rtrash-job.sh
```

Submit the batch jobs from the top of the repository, with the options that place them on a node with a node-local disk.
They start with `module purge`, so submit them from a shell with Lmod's `module` command and the EESSI module on `MODULEPATH`, where `eb-local doctor` finds nothing that stops a build; `--export=ALL` passes both to the job.
`build-job.sh` counts the workspaces in the job's directory, which it works out from `node_local_root` and `node_local_mount` in `DIR/eb-local.conf`.
eb-local reads that file in place of the site file only when root or the owner of the eb-local under test owns it, so give it one of those owners.
Each script ends with a line that counts the checks that passed and failed, and exits 1 when one failed.

## Build the documentation

The pages are Org files under `docs/orgmode/`.
`docs/export.el` writes each as the MyST Markdown page that Sphinx builds: `docs/orgmode/PART/NAME.org` as `docs/PART/NAME.md`.
Edit the Org file, then run, from the top of the repository, with Emacs 29 or newer:

```bash
emacs --batch -Q -l docs/export.el
```

Commit the Org file with the page it writes.
`tests/test_docs.py` fails when a page has no Org source, when an Org source has no place in a table of contents, and on a character reference or a blank at the end of a line.
Where Emacs is installed, it also fails when a page is not what its Org source exports to.

To build the site, with Python 3.12, and Zig 0.17.1 on `PATH` to write the API reference from the code:

```bash
python -m pip install -r docs/requirements.txt
python -m sphinx -W -b html docs docs/_build/html
```

The site is in `docs/_build/html/`.
The build fails on any Sphinx warning, and the `pages` workflow builds it the same way and publishes it.

## Where things are

| Path | What it holds |
|---|---|
| `src/` | the Zig source of eb-local |
| `tests/` | the command-line suite, the tests of the pages, and `tests/site/` |
| `docs/orgmode/` | the pages, in Org: edit these |
| `docs/export.el` | the Org to MyST Markdown export |
| `docs/conf.py` | the Sphinx configuration |
| `docs/_ext/` | the Sphinx domain for Zig declarations |
| `docs/tools/zig_api.zig` | writes the Zig API pages from the doc comments |
| `examples/sites/` | a worked site file, for a site that does not exist |
| `tools/sbom.py` | writes the CycloneDX SBOM of a release binary |
| `changelog.d/` | the news fragments of the next release |
| `eb-local` | the Bash script, the 1.x command, until 4.0.0 |

The pages under `docs/reference/api/` are written as the site builds, and are not committed.

## Write a page

A page belongs to one quadrant: a tutorial teaches by doing, a how-to guide gets one task done, an explanation says why, and a reference page lists what there is.
The stackhands tutorial is eb-stack's, which the tutorials page here links to; eb-local has none of its own.
Add a page to the `toctree` of its quadrant's `index.org`.

Write in the present tense, one sentence per line, and name commands, options and files as eb-local prints them.
A how-to guide has an introduction, then Before you start, Steps, Check that it worked, If it fails and Related, as the guides here do.
Examples use the user `alice`, paths such as `/home/alice`, and sites that do not exist; a real site's names stay out of the pages and the code, which the `shellcheck` workflow checks.

Every command a page shows was run against a built eb-local, and the output under it is what that printed.
Tests hold the pages to the program:

| Test | What it checks |
|---|---|
| `tests/test_cli_docs.py` | the `--help` block of [The eb-local command](reference/cli.md) is what eb-local prints, and the page names every option and command |
| `tests/test_config_docs.py` | each setting `eb-local config` shows has its row and default in [The configuration files](reference/configuration.md) |
| `tests/test_environment_docs.py` | [The environment variables](reference/environment.md) names every variable the program reads, sets for a build or unsets |
| `tests/test_messages_docs.py` | each `eb-local:` line in a how-to guide's example block is a message eb-local can print |
| `tests/test_doctor_docs.py` | each `eb-local doctor` line in a how-to guide is a line `doctor` can print |

API documentation is written in the code: a `//!` comment at the top of each file in `src/`, and a `///` comment above each `pub` declaration, whose first sentence is the summary shown in lists.
`tests/test_doc_comments.py` fails when one is missing.
