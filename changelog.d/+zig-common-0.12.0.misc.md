Update the pinned `zig-common` dependency from `v0.10.0` to `v0.12.0`. The
ELF scan warning for a path it cannot open now names `IsDir` or
`NotRegularFile` instead of `InvalidArgument` for a directory or a FIFO.
