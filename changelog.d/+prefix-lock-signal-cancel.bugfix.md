Cancel contended `.eb-local/.lock` waits on `SIGINT`, `SIGTERM`, `SIGHUP`, and `SIGQUIT` via `common.state.lockExclusiveCancel`, removing unused build workspaces before re-raising.
