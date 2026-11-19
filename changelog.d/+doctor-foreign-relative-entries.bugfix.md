`eb-local doctor` and `build.clear_foreign_prefixes` treat every
relative path-list entry and every empty one as outside the approved
prefixes. An empty entry is reported as `''`. Julia's own entries are kept: an empty entry of
`JULIA_LOAD_PATH` or `JULIA_DEPOT_PATH`, and a load-path entry starting
with `@`.
