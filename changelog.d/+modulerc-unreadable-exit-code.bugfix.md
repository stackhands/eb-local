Return exit status `2` instead of `1` when `eb-local modulerc` fails to read an existing `.modulerc.lua`, distinguishing I/O refusals from `--check` drift (`1`).
