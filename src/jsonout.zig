//! One-line JSON for `--json`; schema_version 1, stable keys.
const std = @import("std");
const common = @import("zig_common");
const cli = common.cli;

/// Dropping or renaming a key, or changing what one means, needs a new version.
pub const schema_version: u32 = 1;

fn oom() noreturn {
    cli.die("eb-local", "out of memory", .{});
}

/// Print one JSON document on stdout and a newline; minified.
pub fn emit(a: std.mem.Allocator, value: anytype) void {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    std.json.Stringify.value(value, .{}, &out.writer) catch oom();
    out.writer.writeAll("\n") catch oom();
    const slice = out.toOwnedSlice() catch oom();
    defer a.free(slice);
    cli.put(1, slice);
}
