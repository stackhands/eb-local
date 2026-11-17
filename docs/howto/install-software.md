<!-- Generated from docs/orgmode/howto/install-software.org by docs/export.el; edit that file. -->

# Install software on top of EESSI with EasyBuild

A build installs an EasyBuild recipe, and the dependencies EESSI lacks, into your install prefix or a project's directory, for the CPU target of the node that builds it.
These steps build `pigz` for one node type, use it, and build for a group.

## Before you start

-   eb-local with a site file, as [Write the site file for a cluster](write-a-site-file.md) describes; `eb-local doctor` names the site file on its second line.
-   The file name of the recipe.
    `eb-local eb -- --search NAME` lists those in the EasyBuild that EESSI ships; EESSI 2026.06 builds on the toolchains of 2026.1, such as `GCCcore-15.2.0`:

    ```bash
    eb-local eb -- --search pigz-2.8
    ```

## Build it

1.  Start an allocation on the node type that will run the software, on nodes with a node-local disk:

    ```bash
    salloc -p cpu -n 16 -t 02:00:00
    ```

    EasyBuild builds for the CPU of the node it runs on.
    `eb-local config` shows the line the site suggests, as `build.allocation_hint`.

2.  Build the recipe, with `--robot` for its dependencies:

    ```bash
    eb-local pigz-2.8-GCCcore-15.2.0.eb --robot
    ```

    eb-local's own lines come first and last, around EasyBuild's output:

    ```text
    eb-local: what this runs: eb-local --explain pigz-2.8-GCCcore-15.2.0.eb --robot
    eb-local: installing into /home/alice/eessi (user)
    eb-local: target x86_64/intel/sapphirerapids, build space /local/alice.16/eb-local.MMgKwXBi
    == Temporary log file in case of crash /home/alice/eessi/.eb-local/logs/easybuild-jonti74m.log
    ...
    == Build succeeded for 1 out of 1 (total: 26 secs)
    ...
    eb-local: done. To use the modules in a new shell or job:
      eval "$(eb-local env)"
    ```

    The options after the recipe are EasyBuild's.
    The build works in a new workspace in the allocation's node-local mount, and removes it when the build succeeds.

3.  Load the module, in this shell or a new one:

    ```bash
    eval "$(eb-local env)"
    module load pigz/2.8-GCCcore-15.2.0
    ```

4.  Repeat steps 1 to 3 on each other node type that will run the software, or have a batch job build it on each, as [Build for every node type](build-for-every-node-type.md) describes.

`eb-local --explain pigz-2.8-GCCcore-15.2.0.eb --robot` prints the script the build runs, and the checks before it, and creates and runs nothing.

## Build for a group

A project directory holds the installs of a group, who all load them.
The project's owner creates it once, with the project's group and the setgid bit:

```bash
mkdir -p /path/to/project/eessi && chgrp myproj /path/to/project/eessi && chmod 2770 /path/to/project/eessi
```

Each member then builds into it:

```bash
eb-local --project /path/to/project/eessi pigz-2.8-GCCcore-15.2.0.eb --robot
```

A project build runs with umask 002, as EESSI-extend sets it for a project install, so that each member can write the directories the others' builds made; EasyBuild still leaves each installation read-only.
A user build runs with umask 077, and EasyBuild adds the sticky bit, so an install in your prefix is yours alone.
Where others must read a user install, pass `--umask=022` among EasyBuild's options.

## Check that it worked

With EESSI loaded, list what you installed:

```bash
eb-local list
```

```text
/home/alice/eessi: 1 module(s) for 1 CPU target(s)
MODULE                   sapphirerapids*
pigz/2.8-GCCcore-15.2.0  x
Every module listed is built for this node's target, x86_64/intel/sapphirerapids (*).
```

The column marked `*` is this node's CPU target.

## If it fails

| Message | Cause | What to do |
|---|---|---|
| `eb-local: not inside a Slurm job: SLURM_JOB_ID is unset or empty; nothing was built.` | The shell is not in an allocation. | Start one with the line the message suggests, on the node type that will run the software. |
| `eb-local: no site file sets storage.node_local_root, the directory that holds each job's node-local mount; ...` | eb-local has no site file. | Ask the site to install one, or use `eb-local eb`, which needs none. |
| `eb-local: could not load EESSI/2099.01:`, then Lmod's reason, indented | `stack.module` or `stack.extend` names a module Lmod cannot load here. | Correct the setting that `eb-local config` shows, or load the module by hand to see why it fails. |
| `eb-local: project directory DIR is writable by others and is not used; chmod o-w it` | Anyone could add module files that the group loads. | Run `chmod o-w DIR`. |
| `eb-local: project directory DIR has no setgid bit, so installs keep the installer's group; chmod g+s it` | A warning: each member's installs would keep that member's group. | Run `chmod g+s DIR`. |
| `eb-local: build workspace kept at WORKSPACE; it goes when the allocation ends,` | The build failed, and eb-local keeps its workspace for you to look into. | Read EasyBuild's log, which EasyBuild names, then run `eb-local clean --workspaces --no-logs` in the allocation. |

[Refusals](../reference/refusals.md) lists every check a build makes before it starts.

## Related

-   [Load EESSI and the software you installed](load-eessi.md)
-   [Build for every node type](build-for-every-node-type.md)
-   [Find what is wrong with a build or a module](find-what-is-wrong.md)
-   [Where EESSI-extend installs](../explanation/install-variables.md)
-   [Refusals](../reference/refusals.md)
