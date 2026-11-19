`eb-local` validates legacy `eb-local.conf` paths, mount patterns, and filesystem types through `c_match` so Unicode characters under `LANG=en_US.UTF-8` are refused like `src/config.zig`.
