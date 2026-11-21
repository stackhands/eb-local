`settleGroup` keeps waiting while `wait4` reports a child in the signalled process group, so a child the `/proc` scan misses is reaped instead of being orphaned when `stop` re-raises the signal.
