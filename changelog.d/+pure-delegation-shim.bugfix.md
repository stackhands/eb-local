Remove `EB_LOCAL_CONFIG` injection from the repository `eb-local` shell shim so it strictly locates and `exec`s the Zig binary without mutating the environment.
