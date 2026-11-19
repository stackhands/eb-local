`jsonout.emit` now checks `common.sys.writeAll` on stdout, prints `eb-local: cannot write JSON output (...)` to stderr, and exits 1 when writing fails (such as on `ENOSPC`).
