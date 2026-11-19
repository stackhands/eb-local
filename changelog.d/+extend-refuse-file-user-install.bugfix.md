`eb-local eb` now refuses a non-directory or uncreatable `EESSI_USER_INSTALL` path with an `eb-local:` message and exit status 2 instead of failing in `mkdir -p` with exit status 1.
