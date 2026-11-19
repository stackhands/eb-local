`cvmfs.readFile` now uses `fsx.openRegular` when reading CernVM-FS client configuration files so non-regular entries such as a FIFO are skipped instead of blocking `eb-local doctor --cvmfs`.
