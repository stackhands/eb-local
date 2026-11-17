<!-- Generated from docs/orgmode/index.org by docs/export.el; edit that file. -->

# eb-local

```{image} _static/logo-light.svg
:alt: eb-local
:width: 420px
:class: light-only
```

```{image} _static/logo-dark.svg
:alt: eb-local
:width: 420px
:class: dark-only
```

eb-local builds your own code and installs software on top of the European Environment for Scientific Software Installations (EESSI) 2026.06, into a directory you or your project own.
`eval "$(eb-local dev MODULE...)"` sets up a shell in which `gcc`, `make` and CMake link against EESSI's libraries, so the programs run without `LD_LIBRARY_PATH`.
`eb-local RECIPE.eb` installs a recipe with EasyBuild and EESSI-extend, inside a Slurm allocation, and builds on the allocation's node-local disk.
`eval "$(eb-local env)"` makes what you installed visible in a new shell or job.
eb-local is one static binary.
It needs EESSI 2026.06 from the CernVM File System (CVMFS); a build also needs a site file and a Slurm allocation.

| You want to | Read |
|---|---|
| learn by doing, start to finish | [Tutorials](tutorials/index.md) |
| get one task done | [How-to guides](howto/index.md) |
| understand why it works this way | [Explanation](explanation/index.md) |
| look up a command, setting or API | [Reference](reference/index.md) |

```{include} ../README.md
:start-after: <!-- docs:start -->
:end-before: <!-- stackhands:begin -->
:relative-docs: docs/
```

```{toctree}
:hidden:
:caption: Tutorials

tutorials/index
```

```{toctree}
:hidden:
:caption: How-to guides

howto/index
```

```{toctree}
:hidden:
:caption: Explanation

explanation/index
```

```{toctree}
:hidden:
:caption: Reference

reference/index
```
