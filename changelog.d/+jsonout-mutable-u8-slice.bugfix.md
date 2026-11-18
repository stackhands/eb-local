`jsonout.utf8Safe` now uses Zig 0.17 `ptr.attrs.@"const"` and sanitizes mutable and sentinel-terminated `u8` slices instead of failing comptime field lookup on `ptr.is_const`.
