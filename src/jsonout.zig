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
    return try common.pytext.decodeReplace(a, bytes);
}

fn utf8Safe(a: std.mem.Allocator, value: anytype) std.mem.Allocator.Error!@TypeOf(value) {
    const T = @TypeOf(value);
    if (T == []const u8) return try lossyUtf8(a, value);
    return switch (@typeInfo(T)) {
        .optional => |opt| if (value) |inner| @as(?opt.child, try utf8Safe(a, inner)) else null,
        .pointer => |ptr| switch (ptr.size) {
            .slice => blk: {
                if (ptr.child == u8) {
                    const clean = try lossyUtf8(a, value);
                    if (comptime ptr.sentinel() != null) {
                        const z = try a.dupeZ(u8, clean);
                        break :blk @as(T, z);
                    }
                    break :blk if (ptr.attrs.@"const") clean else try a.dupe(u8, clean);
                }
                const items = try a.alloc(ptr.child, value.len);
                for (value, 0..) |item, idx| items[idx] = try utf8Safe(a, item);
                break :blk items;
            },
            else => value,
        },
        .array => blk: {
            var copy = value;
            for (value, 0..) |item, idx| copy[idx] = try utf8Safe(a, item);
            break :blk copy;
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
    common.sys.writeAll(1, slice) catch |e| {
        cli.err("eb-local: cannot write JSON output ({s})\n", .{common.sys.describe(e)});
        std.process.exit(1);
    };
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

test "renderLine replaces truncated multi-byte UTF-8 sequences with one U+FFFD per maximal subpart" {
    const Doc = struct { path: []const u8 };
    const line = try renderLine(std.testing.allocator, Doc{ .path = "a\xe2\x82b\xff\xf0\x9f\x98" });
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("{\"path\":\"a\u{FFFD}b\u{FFFD}\u{FFFD}\"}\n", line);
}

test "renderLine encodes mutable u8 slices as JSON strings rather than byte arrays" {
    var mut_buf = [_]u8{ '/', 't', 'm', 'p', '/', 0xff };
    const Doc = struct { path: []u8 };
    const line = try renderLine(std.testing.allocator, Doc{ .path = &mut_buf });
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("{\"path\":\"/tmp/\u{FFFD}\"}\n", line);
}

test "renderLine replaces non-UTF-8 bytes in fixed-size arrays" {
    const Doc = struct { tags: [2][]const u8 };
    const line = try renderLine(std.testing.allocator, Doc{ .tags = .{ "ok", "bad-\xff" } });
    defer std.testing.allocator.free(line);
    try std.testing.expect(std.unicode.utf8ValidateSlice(line));
    try std.testing.expectEqualStrings("{\"tags\":[\"ok\",\"bad-\u{FFFD}\"]}\n", line);
}
