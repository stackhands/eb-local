Serialize concurrent `lmod-cache` writers across cache and timestamp directories via `common.state.lockExclusiveCancel`, canceling contended waits cleanly on termination signals.
