`tests/test_sites_cli.py` verifies that `eb-local site install` exits `2` with an out-of-space diagnostic and keeps the destination directory free of partial files when writing to a full tmpfs.
