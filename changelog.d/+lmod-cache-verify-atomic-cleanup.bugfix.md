`eb-local lmod-cache --verify` now installs the verified `spiderT.lua` via `atomicWrite` and rolls back the cache file and any newly created cache directory if updating `--timestamp` fails.
