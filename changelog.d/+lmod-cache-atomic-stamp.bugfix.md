Publish Lmod cache `timestamp` files atomically with pre-backdated `mtime` so concurrent readers never observe `timestamp.mtime >= spiderT.lua.mtime`.
