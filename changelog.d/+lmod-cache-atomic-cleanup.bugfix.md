`eb-local lmod-cache` now writes `spiderT.lua` via `atomicWrite` and rolls back the cache file and any newly created cache directory when writing or updating the timestamp fails.
