`eb-local` serializes concurrent builds on the same prefix through `storage.acquireBoundedLock` with a bounded `flock` wait, stderr notice, and timeout exit 2.
