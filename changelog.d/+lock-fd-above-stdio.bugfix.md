Move held lock descriptors out of standard-stream slots 0, 1, and 2 via
`zig-common` `sys.keepAboveStdio` so `clean`, `uninstall`, `restore`,
`build`, and `lmod-cache` do not write standard output into `.lock`
files when invoked with standard output closed.
