`eb-local doctor --mpi` now writes `hello.c` via `atomicWrite` and reports write failures as a warning instead of mapping filesystem errors to `OutOfMemory`.
