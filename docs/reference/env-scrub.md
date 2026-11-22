<!-- Generated from docs/orgmode/reference/env-scrub.org by docs/export.el; edit that file. -->

# Install variables cleared for a child

`share/env-scrub.json` is a JSON array of the install-location names a child command must not inherit.
It is the same names, in the same order, as `install_vars`, and the same bytes as zig-common's env-scrub policy.
`eb-local env` prints those names in four `unset` lines, in that order.
A build unsets the same names before it loads the stack.

| Name |
|---|
| `EESSI_CVMFS_INSTALL` |
| `EESSI_SITE_INSTALL` |
| `EESSI_USER_INSTALL` |
| `EESSI_PROJECT_INSTALL` |
| `EESSI_SITE_SOFTWARE_PREFIX` |
| `EESSI_SOFTWARE_SUBDIR_OVERRIDE` |
| `EESSI_ACCELERATOR_TARGET_OVERRIDE` |
| `EESSI_OVERRIDE_GPU_CHECK` |
| `EASYBUILD_INSTALLPATH` |
| `EASYBUILD_INSTALLPATH_SOFTWARE` |
| `EASYBUILD_INSTALLPATH_MODULES` |
| `EASYBUILD_PREFIX` |

[Environment variables](environment.md) says what each name selects.
