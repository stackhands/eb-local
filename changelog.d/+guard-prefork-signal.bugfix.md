`eb-local` checks guarded `SIGINT` and `SIGTERM` arrivals before forking child processes and removes unused pre-launch workspaces when signalled before `eb` starts.
