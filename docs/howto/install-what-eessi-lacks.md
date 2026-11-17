<!-- Generated from docs/orgmode/howto/install-what-eessi-lacks.org by docs/export.el; edit that file. -->

# Install the modules EESSI lacks, found with eb-stack

A site that moves its users to EESSI has a list of the modules they load.
[eb-stack](https://eb-stack.rgoswami.me/), another stackhands tool, compares that list with the modules EESSI provides and names an EasyBuild recipe for each one EESSI lacks; eb-local installs those recipes on top of EESSI.
These steps take a list of four modules, find the two that EESSI 2026.06 lacks, and install them.
How eb-stack decides, and what its other answers mean, is in its guide [Route the modules a stack does not have](https://eb-stack.rgoswami.me/howto/module-gap.html); this page does not repeat it.

## Before you start

-   eb-local with a site file, as [Write the site file for a cluster](write-a-site-file.md) describes.
-   eb-stack, from its [Installation](https://eb-stack.rgoswami.me/install.html) page; these steps use eb-stack 0.7.4.
-   The modules your users load, in a file with one `Name/version` per line, here `site-modules.txt`:

    ```text
    FFTW/3.3.10-GCC-12.3.0
    GSL/2.7-GCC-12.3.0
    jq/1.6-GCCcore-12.3.0
    pigz/2.7-GCCcore-12.3.0
    ```

    `eb-stack stack gap --help` lists the other forms it reads, such as a module tree or what `module -t avail` prints.

## Find what EESSI lacks

1.  Load EESSI, and the EasyBuild it ships:

    ```bash
    eval "$(eb-local env)"
    module load EasyBuild/5.4.2
    ```

2.  Find the toolchain generation of your EESSI version, which is the version of its `foss` module:

    ```bash
    module -t avail foss/
    ```

    ```text
    /cvmfs/software.eessi.io/versions/2026.06/software/linux/x86_64/intel/sapphirerapids/modules/all:
    foss/2026.1
    lfoss/2026.1
    ```

    EESSI 2026.06 builds on generation `2026.1`.

3.  Compare the list with the modules EESSI provides for this node's CPU target, and look for recipes among the easyconfigs of EESSI's EasyBuild:

    ```bash
    eb-stack stack gap --site site-modules.txt \
      --installed "$EESSI_SOFTWARE_PATH/modules/all" \
      --easyconfigs "$EBROOTEASYBUILD/easybuild/easyconfigs" \
      --generation 2026.1 --out-dir gap
    ```

    ```text
    site=4 in-stack=2 filtered=0 open-layer=0 recipe=2 open-easyconfigs=0 no-recipe=0 excluded=0 out=gap
    ```

    On a node whose CVMFS cache does not hold the easyconfigs yet, this takes minutes.

4.  Read the recipes to install:

    ```bash
    cat gap/roots.txt
    ```

    ```text
    jq-1.8.1-GCCcore-15.2.0.eb
    pigz-2.8-GCCcore-15.2.0.eb
    ```

    `gap/gap.tsv` has a line for each module of the list, with its route.
    eb-stack's guide says what each route means, and what to do for a module that has no recipe to install.

## Install them

1.  In the same shell, start an allocation on the node type that will run the software; `eb-local config` shows the line your site suggests, as `build.allocation_hint`:

    ```bash
    salloc -p cpu -n 8 -t 02:00:00
    ```

2.  Install each recipe with its dependencies, and stop at the first that fails:

    ```bash
    mapfile -t recipes < gap/roots.txt
    for recipe in "${recipes[@]}"; do eb-local "$recipe" --robot || break; done
    ```

    ```text
    eb-local: what this runs: eb-local --explain jq-1.8.1-GCCcore-15.2.0.eb --robot
    eb-local: installing into /home/alice/eessi (user)
    eb-local: target x86_64/intel/sapphirerapids, build space /local/alice.34/eb-local.cWtPMNFE
    ...
    == Summary:
       * [SUCCESS] jq/1.8.1-GCCcore-15.2.0
    ...
    eb-local: done. To use the modules in a new shell or job:
      eval "$(eb-local env)"
    eb-local: what this runs: eb-local --explain pigz-2.8-GCCcore-15.2.0.eb --robot
    ...
    == pigz/2.8-GCCcore-15.2.0 is already installed (module found), skipping
    ...
    ```

    Each `eb-local` call is one build, with the checks and the workspace that [Install software on top of EESSI with EasyBuild](install-software.md) describes.
    A recipe that is already installed is skipped, so the loop can run again after a failure.

3.  Repeat steps 1 and 2 on each other node type that will run the software.

To have eb-stack run the builds instead, as a campaign on a target, give the target eb-local as its EasyBuild command.
eb-stack's [eOn on EESSI with EESSI-extend and `eb --robot`](https://eb-stack.rgoswami.me/howto/eon-eessi-extend.html) and [Build target configuration](https://eb-stack.rgoswami.me/reference/targets.html) have such a target, and [Run EasyBuild through EESSI-extend without a site file](eb-without-a-site-file.md) says what eb-local does in it.

## Check that it worked

In a new shell, list the modules and run one:

```bash
eval "$(eb-local env)"
eb-local list jq pigz
module load jq/1.8.1-GCCcore-15.2.0
jq --version
```

```text
/home/alice/eessi: 2 module(s) for 1 CPU target(s)
MODULE                   sapphirerapids*
jq/1.8.1-GCCcore-15.2.0  x
pigz/2.8-GCCcore-15.2.0  x
Every module listed is built for this node's target, x86_64/intel/sapphirerapids (*).
jq-1.8.1
```

## If it fails

| Message | Cause | What to do |
|---|---|---|
| `eb-local: not inside a Slurm job: SLURM_JOB_ID is unset or empty; nothing was built.` | The loop ran outside an allocation. | Start one, and run the loop again. |
| `ERROR: One or more files not found: RECIPE (search paths: DIR)` | EasyBuild does not find the recipe in the easyconfigs of EESSI's EasyBuild, as when `--easyconfigs` named another tree. | Give eb-local the recipe's path, such as `eb-local recipes/pigz-2.8-GCCcore-15.2.0.eb --robot`. |
| `eb-local: build workspace kept at WORKSPACE; it goes when the allocation ends,` | A build failed, and the loop stopped there. | Follow [Find what is wrong with a build or a module](find-what-is-wrong.md), then run the loop again. |
| A module of the list is in `gap/gap.tsv` and not in `gap/roots.txt` | eb-stack gave it a route other than `recipe`. | Look the route up in eb-stack's [Route the modules a stack does not have](https://eb-stack.rgoswami.me/howto/module-gap.html). |

## Related

-   [Install software on top of EESSI with EasyBuild](install-software.md)
-   [Build for every node type](build-for-every-node-type.md)
-   [eb-local and eb-stack](../explanation/eb-local-and-eb-stack.md)
-   eb-stack's [Classify a site module list](https://eb-stack.rgoswami.me/howto/stack-gap.html)
-   eb-stack's [Tutorial: foreign recipe to verified EasyBuild package](https://eb-stack.rgoswami.me/tutorial.html)
