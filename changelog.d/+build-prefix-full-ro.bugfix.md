`eb-local` builds now check free bytes and free inodes on the install prefix filesystem before creating a job workspace and stop with exit code 2 when either is 0.
