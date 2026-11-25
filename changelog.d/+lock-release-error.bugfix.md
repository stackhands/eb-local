A lock that cannot be released at the end of a successful `clean`,
`uninstall`, `restore`, build or `lmod-cache` is reported as
`eb-local: cannot release the lock on PATH: [Errno N] text`, and the
command exits 1. After an earlier failure, including a failed write to
standard output, the release error is dropped and the first failure's
message and exit status stand. A signal that stops the command, such as
one received while a build cleans its logs, drops it too. The
descriptor is closed either way.
