`acquireBoundedLock`, `acquireOptionalLock`, and `tryLockFree` in `src/storage.zig` now check `fstat` and refuse non-regular lockfiles such as FIFOs instead of locking or treating them as free.
