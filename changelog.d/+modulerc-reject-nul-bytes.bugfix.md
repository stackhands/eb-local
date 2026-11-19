`eb-local modulerc` now refuses an existing `.modulerc.lua` containing NUL bytes with `{path}:{line}: the file holds a NUL byte` and exit status 2 instead of writing or printing NUL bytes.
