<!-- Generated from docs/orgmode/howto/install-your-own-recipe.org by docs/export.el; edit that file. -->

# Install a recipe of your own, and prebuilt software

EasyBuild ships recipes for thousands of packages, and [Install software on top of EESSI with EasyBuild](install-software.md) builds one of those by its file name.
A package it has no recipe for, or a version it does not have yet, needs a recipe file of your own.
These steps build such a file, give it sources you already hold, install software that its authors publish only as prebuilt libraries, and run two builds into one prefix.

## Before you start

-   eb-local with a site file, as [Write the site file for a cluster](write-a-site-file.md) describes.
-   An allocation on the node type that will run the software, as step 1 of [Install software on top of EESSI with EasyBuild](install-software.md) starts one.
-   The recipe: a file whose name ends in `.eb`. EasyBuild's documentation on [writing easyconfig files](https://docs.easybuild.io/writing-easyconfig-files/) describes its contents.

## Build a recipe file

Name the file by its path, with `--robot` for its dependencies:

```bash
eb-local ~/recipes/CapnProto-1.4.0-GCCcore-15.2.0.eb --robot
```

A recipe that depends on other recipes of yours finds them when `--robot` names their directory:

```bash
eb-local ~/recipes/mycode-1.0-foss-2026.1.eb --robot=$HOME/recipes
```

EasyBuild looks in that directory first, and then among the recipes it ships.

## Give it the sources

EasyBuild downloads what the recipe's `source_urls` name, and keeps the files under `.eb-local/sources` in your install prefix, so a second build does not download them again.
A source that cannot be downloaded, such as an archive of your own code, goes in a directory that `--sourcepath` names:

```bash
eb-local ~/recipes/mycode-1.0-foss-2026.1.eb --robot=$HOME/recipes --sourcepath=$HOME/recipes
```

EasyBuild then looks for each source file in that directory, and puts what it downloads there too, in a directory named for the first letter of the package and the package itself, such as `m/mycode`.
The recipe's `checksums` are checked either way.

## Install prebuilt software

Some software is published only as libraries that its authors built, with no source release that builds the same thing.
A recipe for it unpacks the archive and writes a module, and compiles nothing.
This one installs the C++ distribution of PyTorch:

```python
easyblock = 'Tarball'

name = 'libtorch'
version = '2.8.0'
versionsuffix = '-cpu'

homepage = 'https://pytorch.org'
description = 'The C++ distribution of PyTorch, as the PyTorch project publishes it.'

toolchain = SYSTEM

source_urls = ['https://download.pytorch.org/libtorch/cpu']
sources = [{
    'download_filename': 'libtorch-shared-with-deps-2.8.0%2Bcpu.zip',
    'filename': 'libtorch-shared-with-deps-2.8.0-cpu.zip',
}]
checksums = ['8dea5bcfed4b53ca0f6852517bea4b4d1f3ff1cc0c21da662e834d34af1ec824']

check_readelf_rpath = False

sanity_check_paths = {
    'files': ['build-version', 'lib/libtorch.so'],
    'dirs': ['include', 'lib'],
}

moduleclass = 'lib'
```

-   `easyblock = 'Tarball'` unpacks the archive into the installation directory.
-   `toolchain = SYSTEM` says that no compiler of the stack built it.
-   `download_filename` is the name on the server, and `filename` the name the file is kept under; they differ here because the server's name has a `+` in it.
-   `check_readelf_rpath = False` tells EasyBuild not to look for a run path into the stack in each library. These libraries find the libraries they ship with through a run path of their own. Leave the check on for anything a compiler of the stack built: without it, a build that lost its run paths installs a module that fails only when it is used.

Build it as any other recipe:

```bash
eb-local ~/recipes/libtorch-2.8.0-cpu.eb
```

```text
== COMPLETED: Installation ended successfully (took 26 secs)
...
eb-local: done. To use the modules in a new shell or job:
  eval "$(eb-local env)"
```

The install is filed under the CPU target of the node that ran it, like one that was compiled:

```text
/home/alice/eessi: 1 module(s) for 1 CPU target(s)
MODULE              sapphirerapids*
libtorch/2.8.0-cpu  x
```

So run the same command on each node type that will load the module, although the files it installs are the same on each.

## When EasyBuild says the module is already installed

```text
== CapnProto/1.4.0-GCCcore-15.2.0 is already installed (module found), skipping
```

A module of that name and version is visible, and EasyBuild builds nothing and installs nothing into your prefix.
It need not be one of yours: the stack, or the site on top of it, may provide it.
`eb-local list` shows what is in your prefix, and Lmod shows where the one it found is:

```bash
eval "$(eb-local env)"
module -t show CapnProto/1.4.0-GCCcore-15.2.0 2>&1 | head -1
```

A recipe that depends on it then uses that module.

## Run two builds into one prefix

A build holds a lock on its install prefix for as long as it runs, so two builds into one prefix run one after the other.
The second prints, while it waits:

```text
eb-local: waiting for lock /home/alice/eessi/.eb-local/.lock; another eb-local run holds it
```

It waits five minutes, and then stops:

```text
eb-local: timed out after 300000 ms waiting for lock /home/alice/eessi/.eb-local/.lock
```

A build that takes longer than that needs the second job to wait longer, in milliseconds; this is three hours:

```bash
export EB_LOCAL_LOCK_TIMEOUT_MS=10800000
eb-local ~/recipes/mycode-1.0-foss-2026.1.eb --robot=$HOME/recipes
```

Jobs on two node types, each building the same recipe for its own CPU target, wait for each other in the same way.
Submitting the second with `sbatch --dependency=afterany:JOBID` has it start when the first has ended, and it then spends none of its allocation waiting.

## After a build that was killed

EasyBuild keeps a lock of its own for each installation it is building, and a build that the scheduler killed leaves it behind.
The next build of that recipe stops at once, with a line such as:

```text
ERROR: Lock /home/alice/eessi/versions/2026.06/software/linux/x86_64/intel/sapphirerapids/software/.locks/_home_alice_eessi_..._mycode_1.0-foss-2026.1.lock already exists, aborting!
```

When no other build of that recipe is running, `--ignore-locks` among EasyBuild's options builds over it:

```bash
eb-local ~/recipes/mycode-1.0-foss-2026.1.eb --robot=$HOME/recipes --ignore-locks
```

It skips EasyBuild's lock only; the lock on the prefix, in the section above, still holds.

## Related

-   [Install software on top of EESSI with EasyBuild](install-software.md)
-   [Build for every node type](build-for-every-node-type.md)
-   [Overlay a site recipe](overlay-a-recipe.md)
-   [Find what is wrong with a build or a module](find-what-is-wrong.md)
-   [Environment variables](../reference/environment.md)
