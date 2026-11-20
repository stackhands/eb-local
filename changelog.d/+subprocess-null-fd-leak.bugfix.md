Use `common.proc.run` instead of `std.process.run` in `storage.probeWorkspace` so `doctor --workspace` never opens and retains an un-`CLOEXEC` `/dev/null` descriptor via `std.Io.Threaded`.
