`lmod-cache` reports a failed close of the new `timestamp` and keeps
the old one. When the directory of the `timestamp` cannot be written
and the file is rewritten in place, a failed truncate, `fsync` or close
of it is reported, and a file put in its place after it was checked is
refused and not changed. If a failed update already changed the file,
`lmod-cache` writes its previous bytes and times back through a
duplicate of the descriptor that changed it, so a file renamed into
its place is left alone. With `--verify`, a failed write or close of
the candidate `spiderT.lua` or `lmodrc.lua`, or a failed close of the
candidate `timestamp`, is reported and the cache is not changed. Each
of these exits 1 with `eb-local: cannot write PATH: [Errno N] text`. A
previous `spiderT.lua` that cannot be read, or is larger than 64 MiB,
is not replaced: `lmod-cache` exits 1 with
`eb-local: cannot read PATH: REASON; the cache was not changed`. A
cache that was already replaced is put back through a new file that is
renamed over it once it is written, synced and closed, and a cache with
no previous one is removed. Each restore is tried once, and one that
fails is reported after the error that started it, as
`eb-local: cannot restore PATH: REASON` or
`eb-local: cannot remove PATH: REASON`. A workstation build whose
workspace-root record cannot be written, or whose registry or existing
entry cannot be used, removes the workspace of the build before it
exits 2. The record is written to a temporary file that is renamed over
it only after the write, `fsync` and close succeed, so a failure before
the rename removes only the temporary file and `clean --workspaces`
still finds older workspaces under that root. A failed sync of the
registry after the rename keeps the new entry, which names the same
root as any entry it replaced.
