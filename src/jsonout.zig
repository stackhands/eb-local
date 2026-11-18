//! One-line JSON for `--json`; schema_version 1, stable keys.
const std = @import("std");
const common = @import("zig_common");
const cli = common.cli;

/// Dropping or renaming a key, or changing what one means, needs a new version.
pub const schema_version: u32 = 1;

fn oom() noreturn {
    cli.die("eb-local", "out of memory", .{});
}

fn lossyUtf8(a: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < bytes.len) {
        if (std.unicode.utf8ByteSequenceLength(bytes[i])) |len| {
            if (i + len <= bytes.len) {
                if (std.unicode.utf8Decode(bytes[i..][0..len])) |_| {
                    try out.appendSlice(a, bytes[i..][0..len]);
                    i += len;
                    continue;
                } else |_| {}
            }
        } else |_| {}
        try out.appendSlice(a, "\u{FFFD}");
        i += 1;
    }
    return out.toOwnedSlice(a);
}

fn utf8Safe(a: std.mem.Allocator, value: anytype) std.mem.Allocator.Error!@TypeOf(value) {
    const T = @TypeOf(value);
    if (T == []const u8) return try lossyUtf8(a, value);
    return switch (@typeInfo(T)) {
        .optional => |opt| if (value) |inner| @as(?opt.child, try utf8Safe(a, inner)) else null,
        .pointer => |ptr| switch (ptr.size) {
            .slice => blk: {
                if (ptr.child == u8 and ptr.is_const) {
                    break :blk try lossyUtf8(a, value);
                }
                const items = try a.alloc(ptr.child, value.len);
                for (value, 0..) |item, idx| items[idx] = try utf8Safe(a, item);
                break :blk items;
            },
            else => value,
        },
        .@"struct" => |st| blk: {
            var copy = value;
            inline for (st.field_names) |name| {
                @field(copy, name) = try utf8Safe(a, @field(value, name));
            }
            break :blk copy;
        },
        else => value,
    };
}

/// Render `value` as one minified JSON line (ending with `\n`), replacing
/// any non-UTF-8 byte sequences in string slices with U+FFFD so `std.json.Stringify`
/// never falls back to emitting byte arrays.
pub fn renderLine(a: std.mem.Allocator, value: anytype) std.mem.Allocator.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const safe = try utf8Safe(arena.allocator(), value);
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    std.json.Stringify.value(safe, .{}, &out.writer) catch return error.OutOfMemory;
    out.writer.writeAll("\n") catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Print one JSON document on stdout and a newline; minified.
pub fn emit(a: std.mem.Allocator, value: anytype) void {
    const slice = renderLine(a, value) catch oom();
    defer a.free(slice);
    cli.put(1, slice);
}

test "renderLine replaces non-UTF-8 bytes in nested strings without emitting byte arrays" {
    const Item = struct { path: []const u8 };
    const Doc = struct {
        path: []const u8,
        items: []const Item,
        tags: []const []const u8,
        note: ?[]const u8,
    };
    const items = [_]Item{.{ .path = "/tmp/bad-\xff-0.log" }};
    const tags = [_][]const u8{ "ok", "bad-\xc3\x28" };
    const line = try renderLine(std.testing.allocator, Doc{
        .path = "/tmp/tree-\x80",
        .items = &items,
        .tags = &tags,
        .note = "hi-\xfe",
    });
    defer std.testing.allocator.free(line);
    try std.testing.expect(std.unicode.utf8ValidateSlice(line));
    try std.testing.expectEqualStrings(
        "{\"path\":\"/tmp/tree-\u{FFFD}\",\"items\":[{\"path\":\"/tmp/bad-\u{FFFD}-0.log\"}],\"tags\":[\"ok\",\"bad-\u{FFFD}(\"],\"note\":\"hi-\u{FFFD}\"}\n",
        line,
    );
}
