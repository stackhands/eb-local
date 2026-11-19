<!-- Generated from docs/orgmode/howto/eb-without-a-site-file.org by docs/export.el; edit that file. -->

# Run EasyBuild through EESSI-extend without a site file

`eb-local eb` runs EasyBuild with EESSI-extend loaded where there is no site file and no Slurm job: on a login node, inside `eessi_container.sh`, or on a machine with the CernVM File System (CVMFS) mount of EESSI.
It sources the EESSI init, loads `EESSI-extend`, and runs `eb` with the arguments after `--`.
EESSI-extend keeps EESSI's hooks, RPATH and compatibility layer, and installs where its install variables say; with none set, into `$HOME/eessi`, the prefix eb-local builds use too.

## Before you start

-   EESSI 2026.06 mounted at `/cvmfs/software.eessi.io`; where it is elsewhere, set `EESSI_CVMFS_REPO` or `EESSI_VERSION`.
-   eb-local on `PATH`, as [Install eb-local](install.md) describes.
-   At most one of the install variables `EESSI_USER_INSTALL`, `EESSI_PROJECT_INSTALL`, `EESSI_SITE_INSTALL` and `EESSI_CVMFS_INSTALL` in your shell, and only one you mean to use.

## Install into your home

1.  Check that nothing stops `eb-local eb`:

    ```bash
    eb-local doctor
    ```

    ```text
    ok   eb-local 3.2.0
    FAIL no site file sets storage.node_local_root, so builds cannot run
    ok   installs go to /home/alice/eessi: a user install, prefix from default
    ok   no other EESSI or EasyBuild install variable is set in this shell
    ok   `eb-local eb` sources /cvmfs/software.eessi.io/versions/2026.06/init/lmod/bash
    ok   `eb-local eb` makes a user install into the module's default, $HOME/eessi
    info not in a Slurm job; builds need one on the node type that will run the software
    info EESSI is not loaded in this shell; eval "$(eb-local env)" loads it with your modules
    info eessi-arch-guard is not on PATH; builds, env and dev load EESSI for the target EESSI detects
    warn your modules are not on MODULEPATH in this shell; eval "$(eb-local env)"
    info no module command in this shell; builds source /cvmfs/software.eessi.io/versions/2026.06/init/lmod/bash
    ok   rtrash is on PATH: clean and uninstall move files to the trash

    Nothing above stops `eb-local eb`; `eb-local RECIPE` needs a site file.
    ```

    Without a site file, this one `FAIL` line is expected while the rest are for `eb-local eb`.

2.  Run EasyBuild with the easyconfig:

    ```bash
    eb-local eb -- pigz-2.8-GCCcore-15.2.0.eb --robot
    ```

    EESSI and EESSI-extend say what they selected as they load, then EasyBuild runs and ends with:

    ```text
    == COMPLETED: Installation ended successfully (took 24 secs)
    == Results of the build can be found in the log file(s)
    /home/alice/eessi/versions/2026.06/software/linux/x86_64/intel/sapphirerapids/so
    ftware/pigz/2.8-GCCcore-15.2.0/easybuild/easybuild-pigz-2.8-20261117.091725.log.
    bz2
    == Running post-easyblock hook...
    == Build succeeded for 1 out of 1 (total: 24 secs)
    == Summary:
       * [SUCCESS] pigz/2.8-GCCcore-15.2.0
    ```

    It builds on the machine you run it on, for the CPU target EESSI selects there, here `x86_64/intel/sapphirerapids`; a login node's target can differ from the compute nodes', as [Run paths, and one build per CPU target](../explanation/run-paths.md) explains.
    EasyBuild builds under `$WORKING_DIR/easybuild`; EESSI-extend sets `WORKING_DIR` to `/tmp/$USER` when you have not set it, and `eb-local eb` leaves it as you set it.

3.  Load the module, in this shell or in a job:

    ```bash
    eval "$(eb-local env)"
    module load pigz/2.8-GCCcore-15.2.0
    ```

    `eb-local env` loads EESSI with the modules under `$HOME/eessi`, those `eb-local eb` installed among them; [Load EESSI and the software you installed](load-eessi.md) has the rest.

## Install into another directory

Set `EESSI_USER_INSTALL` to the directory; `eb-local eb` creates it, private to you, before EESSI-extend loads:

```bash
EESSI_USER_INSTALL=$HOME/eessi-b eb-local eb -- pigz-2.8-GCCcore-15.2.0.eb --robot
```

The other commands of eb-local take that directory from `EB_LOCAL_PREFIX`, or from the `prefix` setting:

```bash
eval "$(EB_LOCAL_PREFIX=$HOME/eessi-b eb-local env)"
module load pigz/2.8-GCCcore-15.2.0
```

For a project, set `EESSI_PROJECT_INSTALL` to the project's directory, which its owner creates once with the project group and the setgid bit, as [Install software on top of EESSI with EasyBuild](install-software.md) shows.
`eb-local --explain eb` says on its second line which install the variables select, and runs nothing:

```bash
EESSI_PROJECT_INSTALL=/project/climate/eessi eb-local --explain eb -- pigz-2.8-GCCcore-15.2.0.eb --robot | head -2
```

```text
# eb-local --explain eb: the script eb-local eb runs, with its arguments. Nothing was run.
# EESSI_PROJECT_INSTALL=/project/climate/eessi selects a project install; the process umask is 002.
```

The rest of its output is the script `eb-local eb` runs, which `bash` runs as `eb-local eb` would.
[Where EESSI-extend installs](../explanation/install-variables.md) says where each variable, and each mix of them, sends an install.

## From a program that passes only eb's arguments

A program that runs one command with `eb`'s own arguments, as an eb-stack EESSI target does, sets `EB_LOCAL_EESSI_EXTEND=1`; every argument of `eb-local` then goes to `eb`:

```bash
EB_LOCAL_EESSI_EXTEND=1 eb-local --version
```

After what EESSI and EESSI-extend say as they load, the last line is EasyBuild's:

```text
This is EasyBuild 5.4.2 (framework: 5.4.2, easyblocks: 5.4.2) on host node001.
```

eb-stack's [targets reference](https://eb-stack.rgoswami.me/reference/targets.html) has the target that runs `eb-local` this way.

## Check that it worked

```bash
eb-local list pigz
```

```text
/home/alice/eessi: 1 module(s) for 1 CPU target(s)
MODULE                   sapphirerapids
pigz/2.8-GCCcore-15.2.0  x
Load EESSI (eval "$(eb-local env)") to see what this node's CPU target lacks.
```

## If it fails

| Message | Cause | What to do |
|---|---|---|
| `eb-local: missing /cvmfs/nosuch.eessi.io/versions/2026.06/init/lmod/bash, the EESSI init; eb was not run.` | EESSI is not mounted there, or that version is not. | Set `EESSI_CVMFS_REPO` or `EESSI_VERSION` to where EESSI is. |
| `eb-local: EESSI_USER_INSTALL=/home/alice/eessi and EESSI_PROJECT_INSTALL=/project/climate/eessi are both set;`, exit 3 | Two install variables are set, one of them left from an earlier session. | Unset the one you do not mean; `eb-local doctor` lists every one your shell has. |
| `Lmod has detected the following error: The location of EESSI_PROJECT_INSTALL (/path/to/project/eessi) does not exist or is not a folder` | The project directory is not there. | Its owner creates it with the project group and `chmod 2770`; `eb-local doctor` says so too. |
| `eb-local: EASYBUILD_INSTALLPATH_SOFTWARE=/tmp/sw is set in this shell and would put part of this install outside /home/alice/eessi; nothing was built.` | A variable in your shell moves part of the install out of the tree EESSI-extend chose. | Unset it. |

## Related

-   [Where EESSI-extend installs](../explanation/install-variables.md)
-   [The eb-local command](../reference/cli.md): `eb` and `--explain eb`
-   [Load EESSI and the software you installed](load-eessi.md)
-   [Install software on top of EESSI with EasyBuild](install-software.md), for builds in a Slurm job with a site file
