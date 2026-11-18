//! `eb-local modulerc`: add operator-selected defaults, aliases and hides.
const std = @import("std");
const common = @import("zig_common");
const jsonout = @import("jsonout.zig");

/// One `module_alias` directive.
pub const Alias = struct {
    name: []const u8,
    target: []const u8,
};

/// The module tree and operator-selected directives for `modulerc`.
pub const Options = struct {
    tree: []const u8 = "",
    defaults: []const []const u8 = &.{},
    aliases: []const Alias = &.{},
    hidden: []const []const u8 = &.{},
    dry_run: bool = false,
    check: bool = false,
    json: bool = false,
};

const JsonReport = struct {
    schema_version: u32 = jsonout.schema_version,
    kind: []const u8 = "modulerc",
    module_tree: []const u8,
    file: []const u8,
    mode: []const u8,
    changed: bool,
    defaults: []const []const u8,
    aliases: []const Alias,
    hidden: []const []const u8,
    content: ?[]const u8 = null,
};

fn fail(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("eb-local: " ++ fmt ++ "\n", args);
}

fn quoted(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '"');
    for (value) |ch| switch (ch) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        '\t' => try out.appendSlice(a, "\\t"),
        0...8, 11...12, 14...31, 127 => try out.print(a, "\\{d:0>3}", .{ch}),
        else => try out.append(a, ch),
    };
    try out.append(a, '"');
    return out.toOwnedSlice(a);
}

fn hasLine(text: []const u8, wanted: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r"), wanted)) return true;
    }
    return false;
}

fn addLine(a: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    if (hasLine(out.items, line)) return;
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(a, '\n');
    try out.appendSlice(a, line);
    try out.append(a, '\n');
}

/// Add every requested directive to `previous`, without duplicating a line.
pub fn render(a: std.mem.Allocator, previous: []const u8, opts: Options) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, previous);
    for (opts.defaults) |module| {
        const q = try quoted(a, module);
        try addLine(a, &out, try std.fmt.allocPrint(a, "module_version({s}, \"default\")", .{q}));
    }
    for (opts.aliases) |alias| {
        const name = try quoted(a, alias.name);
        const target = try quoted(a, alias.target);
        try addLine(a, &out, try std.fmt.allocPrint(a, "module_alias({s}, {s})", .{ name, target }));
    }
    for (opts.hidden) |module| {
        const q = try quoted(a, module);
        try addLine(a, &out, try std.fmt.allocPrint(a, "hide_version({s})", .{q}));
    }
    return out.toOwnedSlice(a);
}

/// Write, print, or check the resulting `.modulerc.lua`.
pub fn run(io: std.Io, a: std.mem.Allocator, opts: Options) u8 {
    if (opts.tree.len == 0) {
        fail("modulerc needs --module-tree DIR", .{});
        return 2;
    }
    if (!std.fs.path.isAbsolute(opts.tree)) {
        fail("--module-tree {s} is not an absolute path", .{opts.tree});
        return 2;
    }
    if (opts.defaults.len == 0 and opts.aliases.len == 0 and opts.hidden.len == 0) {
        fail("modulerc needs at least one --default, --alias or --hide", .{});
        return 2;
    }
    const path = std.fs.path.join(a, &.{ opts.tree, ".modulerc.lua" }) catch return 1;
    const cwd = std.Io.Dir.cwd();
    const previous = cwd.readFileAlloc(io, path, a, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => {
            fail("cannot read {s}: {s}", .{ path, @errorName(err) });
            return 2;
        },
    };
    const text = render(a, previous, opts) catch return 1;
    const changed = !std.mem.eql(u8, previous, text);
    if (opts.check) {
        if (opts.json) {
            jsonout.emit(a, JsonReport{
                .module_tree = opts.tree,
                .file = path,
                .mode = "check",
                .changed = changed,
                .defaults = opts.defaults,
                .aliases = opts.aliases,
                .hidden = opts.hidden,
            });
        } else {
            var stdout = std.Io.File.stdout();
            const message = std.fmt.allocPrint(a, "{s} {s}\n", .{ if (changed) "would update" else "up to date", path }) catch return 1;
            stdout.writeStreamingAll(io, message) catch {
                fail("cannot print {s}", .{path});
                return 1;
            };
        }
        return if (changed) 1 else 0;
    }
    if (opts.dry_run) {
        if (opts.json) {
            jsonout.emit(a, JsonReport{
                .module_tree = opts.tree,
                .file = path,
                .mode = "dry-run",
                .changed = changed,
                .defaults = opts.defaults,
                .aliases = opts.aliases,
                .hidden = opts.hidden,
                .content = text,
            });
        } else {
            var stdout = std.Io.File.stdout();
            stdout.writeStreamingAll(io, text) catch {
                fail("cannot print {s}", .{path});
                return 1;
            };
        }
        return 0;
    }
    var first_missing: ?[]const u8 = null;
    {
        var probe: []const u8 = opts.tree;
        while (probe.len > 1) {
            if (common.fsx.statAt(common.fsx.cwd, probe, true)) |st| {
                if (st.isDir()) break;
                break;
            } else |_| {}
            first_missing = probe;
            probe = std.fs.path.dirname(probe) orelse break;
        }
    }
    common.atomic.makedirs(opts.tree) catch |err| {
        fail("cannot create {s}: {s}", .{ opts.tree, @errorName(err) });
        return 1;
    };
    var why: common.atomic.Why = .{};
    defer why.deinit(a);
    common.atomic.atomicWrite(a, path, text, .{ .mode = 0o644 }, &why) catch |err| {
        fail("cannot write {s}: {s}", .{ path, if (why.msg.len > 0) why.msg else @errorName(err) });
        if (first_missing) |dir| common.fsx.deleteTree(a, common.fsx.cwd, dir) catch {};
        return 1;
    };
    if (opts.json) {
        jsonout.emit(a, JsonReport{
            .module_tree = opts.tree,
            .file = path,
            .mode = "write",
            .changed = changed,
            .defaults = opts.defaults,
            .aliases = opts.aliases,
            .hidden = opts.hidden,
        });
    } else {
        var stdout = std.Io.File.stdout();
        const message = std.fmt.allocPrint(a, "wrote {s}\n", .{path}) catch return 1;
        stdout.writeStreamingAll(io, message) catch return 1;
    }
    return 0;
}

test "rendering named directives is idempotent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const aliases = [_]Alias{.{ .name = "latest", .target = "Example/2.0" }};
    const opts: Options = .{
        .tree = "/modules",
        .defaults = &.{"Example/2.0"},
        .aliases = &aliases,
        .hidden = &.{"Example/1.0"},
    };
    const once = try render(a, "-- keep this\n", opts);
    const twice = try render(a, once, opts);
    try std.testing.expectEqualStrings(once, twice);
    try std.testing.expectEqualStrings(
        "-- keep this\nmodule_version(\"Example/2.0\", \"default\")\nmodule_alias(\"latest\", \"Example/2.0\")\nhide_version(\"Example/1.0\")\n",
        once,
    );
}
