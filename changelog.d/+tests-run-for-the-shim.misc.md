Run the tests that need the Zig build in the run through the shell shim as well, so `python3 -m unittest discover -s tests` without `EB_LOCAL_BIN` skips almost nothing.
