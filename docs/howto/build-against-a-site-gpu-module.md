<!-- Generated from docs/orgmode/howto/build-against-a-site-gpu-module.org by docs/export.el; edit that file. -->

# Build CUDA software against a site's GPU modules

Some sites install modules of their own on top of EESSI for their GPU nodes, such as a CUDA build of PyTorch.
A recipe of yours can depend on one, and then builds against it on the node type that has it.
These steps build such a recipe, give its programs a run path into a library directory that the site's module does not announce, and check the result before you use it.

## Before you start

-   A recipe that depends on the site's module by name and version, such as `('PyTorch', '2.10.0', '-CUDA-13.3.0')`, and on the `CUDA` module of the same version, as [Install a recipe of your own, and prebuilt software](install-your-own-recipe.md) describes.
-   A site file whose node types include the GPU node, as [Build for every node type](build-for-every-node-type.md) shows.

## Build on the GPU node

The site's GPU modules are visible only on the node type they were built for, so build there, in a job with one GPU:

```bash
sbatch -p gpu --gpus-per-node=1 --cpus-per-task=16 -t 03:00:00 \
  --wrap='eb-local ~/recipes/mycode-1.0-foss-2026.1-CUDA-13.3.0.eb --robot=$HOME/recipes'
```

EasyBuild finds the site's module and uses it, and builds nothing for it:

```text
== PyTorch/2.10.0-foss-2026.1-CUDA-13.3.0 is already installed (module found), skipping
```

## Give the programs a run path into the module's libraries

A program built by EasyBuild finds its libraries through run paths that EasyBuild's compiler wrappers record when it links: one for each directory named with `-L` and for each entry of `LIBRARY_PATH`.
A module of a C or C++ library puts its library directory on `LIBRARY_PATH`.
A module of a Python package often does not: PyTorch keeps its libraries in `lib/pythonX.Y/site-packages/torch/lib` of its installation, and its module leaves that directory off `LIBRARY_PATH`.

A program that links those libraries through a full path still runs.
A library that one of them opens later by name does not, such as `libtorch.so` when torch loads a compiled model:

```text
Error in dlopen: libtorch.so: cannot open shared object file: No such file or directory
```

Put the directory on `LIBRARY_PATH` in the recipe, for every step that links:

```python
local_torch_lib = ('export LIBRARY_PATH="$(ls -d "$EBROOTPYTORCH"'
                   '/lib/python*/site-packages/torch/lib)${LIBRARY_PATH:+:$LIBRARY_PATH}"; ')
prebuildopts = local_torch_lib + prebuildopts
preinstallopts = local_torch_lib + preinstallopts
```

Every program and library the build links then records that directory as a run path.

A library opened at run time by another library that carries a `RUNPATH` of its own is searched for through that run path, not the program's, as can happen when torch loads a compiled model.
If the error stays after the change above, the program has to load the library by its full path before that happens, and no recipe option does that.

## Check the installation

Run `eb-local check` on the installed programs, with the module loaded:

```bash
eval "$(eb-local env)"
module load mycode/1.0-foss-2026.1-CUDA-13.3.0
eb-local check "$EBROOTMYCODE"/bin/* "$EBROOTMYCODE"/lib/*.so
```

It lists, for each file, where every library it needs resolves, ignoring `LD_LIBRARY_PATH`, and reports a `RUNPATH` and a library found only through `LD_LIBRARY_PATH` as problems.
It cannot see what a library opens at run time, so also run one real calculation in a GPU job before you depend on the module.

## Libraries an install step copies

A recipe or a build system that copies a library into the installation, instead of linking it there, keeps the run path the library had in the build directory.
Those entries name a directory that is gone after the build, and the library's own dependencies are then found only by chance.
`eb-local check` on the installed library shows its run path; one with a directory under the build tree needs the copy step to rewrite it, for example with `patchelf --force-rpath --set-rpath '$ORIGIN:...'`.

## Related

-   [Install a recipe of your own, and prebuilt software](install-your-own-recipe.md)
-   [Build for every node type](build-for-every-node-type.md)
-   [Find what is wrong with a build or a module](find-what-is-wrong.md)
-   [Run paths](../explanation/run-paths.md)
