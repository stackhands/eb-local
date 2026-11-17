<!-- Generated from docs/orgmode/explanation/eb-local-and-eb-stack.org by docs/export.el; edit that file. -->

# eb-local and eb-stack

eb-local and [eb-stack](https://eb-stack.rgoswami.me/) are stackhands tools that both end in an EasyBuild run on top of EESSI.
They split the work at that run: eb-stack works out what a stack should build, and eb-local runs one build.
This page says what each does, where they meet, and why the line falls there.

## What eb-local does

eb-local runs one EasyBuild build at a time, for you or for a project, on the node it runs on.
Before `eb` starts, it checks the Slurm job, the job's node-local mount and the install prefix, as [Refusals](../reference/refusals.md) lists; then it loads EESSI and EESSI-extend and runs `eb` with the recipe and the options you give.
Its other commands serve the same person: `env` loads what you installed, `dev` compiles your own code against EESSI, `doctor`, `list` and `check` find what is wrong, and `clean` and `uninstall` remove what builds leave.
What it builds is the recipe you name, with the dependencies that EasyBuild's `--robot` finds EESSI lacks.

## What eb-stack does

eb-stack works on lists of packages and on whole stacks.
It reads recipes from several ecosystems into a plan, finds which of a site's modules a stack lacks, splits build lists, and drives builds as a campaign on the targets it is configured with.
How it does each of these is its own, and its documentation has it: [Route the modules a stack does not have](https://eb-stack.rgoswami.me/howto/module-gap.html) for what a stack lacks, [Dependency closure](https://eb-stack.rgoswami.me/explanation/sbom-blast-radius.html) for what a change reaches, and [From recipe to verified package](https://eb-stack.rgoswami.me/explanation/lifecycle.html) for the way from a recipe to an installed package.

## Where they meet

eb-stack runs EasyBuild through a target, and a target's EasyBuild command is one executable.
eb-stack's [example of an EESSI-extend target](https://github.com/stackhands/eb-stack/blob/main/examples/targets/eessi-extend.toml) names `/usr/local/bin/eb-local` as that command and sets `EB_LOCAL_EESSI_EXTEND=1` for it.
With that variable set, every argument eb-local gets goes to `eb`, as after `eb-local eb --`: eb-local sources the EESSI init, loads EESSI-extend and runs `eb` with eb-stack's options, as [Run EasyBuild through EESSI-extend without a site file](../howto/eb-without-a-site-file.md) shows.
In that mode eb-local reads no site file and checks no Slurm job; the variables the target sets, such as `EESSI_USER_INSTALL` and `WORKING_DIR`, choose where it installs and where it works.
eb-stack does not build eb-local: it runs the eb-local installed where the target runs, which has to be 3.0.0 or later for that variable.

Nothing goes the other way.
eb-local starts no eb-stack command and reads no file eb-stack writes.
A list from eb-stack, such as the recipes for the modules EESSI lacks, reaches eb-local through you, one build per recipe, as [Install the modules EESSI lacks, found with eb-stack](../howto/install-what-eessi-lacks.md) shows.

## Why the line falls at one build

eb-local's checks are about one build: the job it runs in, that job's node-local mount, the CPU target of that node, and the prefix it writes.
They hold only where and when the build runs.
What a stack should contain depends on every package at once, and on inputs eb-local never reads, such as a site's module list, trees of recipes, open pull requests and a toolchain generation.
So each tool keeps the inputs it can check.
A user without eb-stack builds what they need with eb-local, and eb-stack drives an EasyBuild command of its target's choosing, eb-local among them.

## Which one to use

| To | Use |
|---|---|
| Install a recipe and the dependencies EESSI lacks, for yourself or a project | eb-local: [Install software on top of EESSI with EasyBuild](../howto/install-software.md) |
| Compile your own code against EESSI | eb-local: [Compile your code against EESSI](../howto/compile.md) |
| Find which of a site's modules EESSI lacks, and install them | eb-stack, then eb-local: [Install the modules EESSI lacks, found with eb-stack](../howto/install-what-eessi-lacks.md) |
| Turn a recipe from PyPI, CRAN or conda-forge into an EasyBuild package | eb-stack: [Tutorial: foreign recipe to verified EasyBuild package](https://eb-stack.rgoswami.me/tutorial.html) |
| Build a list of recipes as one campaign | eb-stack: [Build target configuration](https://eb-stack.rgoswami.me/reference/targets.html) |

## Related

-   [Install the modules EESSI lacks, found with eb-stack](../howto/install-what-eessi-lacks.md)
-   [Run EasyBuild through EESSI-extend without a site file](../howto/eb-without-a-site-file.md)
-   [Environment variables](../reference/environment.md), for `EB_LOCAL_EESSI_EXTEND`
-   eb-stack's [Tutorial: foreign recipe to verified EasyBuild package](https://eb-stack.rgoswami.me/tutorial.html)
