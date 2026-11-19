`src/rpath.zig` includes `--help=*` among info-only compiler flags in its generated wrapper script so `LIBRARY_PATH` and `-L` run paths are not appended to `--help=target` queries.
