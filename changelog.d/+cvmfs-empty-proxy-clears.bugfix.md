`cvmfs.readProxy` now treats an empty `CVMFS_HTTP_PROXY=""` or `CVMFS_HTTP_PROXY=` assignment as clearing any earlier file-configured proxy instead of preserving the previous value.
