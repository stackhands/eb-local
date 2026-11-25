Five eb-local writers report a failed close or `fsync` as an error
where they used to drop it. `dev --envrc` and `dev --lock` exit 2 with
`eb-local: cannot write NAME ([Errno N] text)` when the close of a new
`.envrc` or `eb-local.lock` fails. A build on a workstation stops with
`cannot record workstation workspace root` when that record cannot be
synced or closed. `doctor --workspace` fails its probe when the close
of the probe fails, where it used to report the probe as written. If
the directory of the `timestamp` cannot be synced after the rename,
`lmod-cache` exits 1 and puts the cache back. The Network File
System (NFS) and some quota setups report a lost write only at these
calls.
