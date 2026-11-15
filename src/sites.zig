//! Site file templates, built into the program: `eb-local site` lists,
//! renders and installs them. A template is TOML with {{name}} placeholders,
//! which --set name=value must fill, and {{name:default}} ones, which take
//! the default unless set. Values go inside TOML strings, so a value with a
//! quote, a backslash or a control character is refused.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Template = struct { name: []const u8, text: []const u8 };

pub const all = [_]Template{
    .{ .name = "snellius", .text = @embedFile("sites/snellius.toml") },
    .{ .name = "slurm", .text = @embedFile("sites/slurm.toml") },
};

pub fn find(name: []const u8) ?Template {
    for (all) |t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

pub const Set = struct { name: []const u8, value: []const u8 };

pub const Diagnostic = struct { message: []const u8 = "" };

pub const Error = error{Invalid} || Allocator.Error;

fn fail(a: Allocator, d: *Diagnostic, comptime fmt: []const u8, args: anytype) Error {
    d.message = try std.fmt.allocPrint(a, fmt, args);
    return error.Invalid;
}

fn validName(n: []const u8) bool {
    if (n.len == 0) return false;
    for (n) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return false;
    return true;
}

/// A value that stays one TOML string: printable, no quote or backslash.
pub fn validValue(v: []const u8) bool {
    if (v.len == 0) return false;
    for (v) |c| if (c < 0x20 or c == 0x7f or c == '"' or c == '\\') return false;
    return true;
}

/// Parse NAME=VALUE.
pub fn parseSet(a: Allocator, arg: []const u8, d: *Diagnostic) Error!Set {
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return fail(a, d, "--set takes NAME=VALUE, got '{s}'", .{arg});
    const name = arg[0..eq];
    const value = arg[eq + 1 ..];
    if (!validName(name)) return fail(a, d, "--set: '{s}' is not a placeholder name", .{name});
    if (!validValue(value)) return fail(a, d, "--set {s}: the value must be non-empty, without quotes, backslashes or control characters", .{name});
    return .{ .name = name, .value = value };
}

/// The names a template's placeholders use, each once, in order.
pub fn placeholders(a: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "{{")) |open| {
        const close = std.mem.indexOfPos(u8, text, open, "}}") orelse break;
        const inner = text[open + 2 .. close];
        const name = inner[0 .. std.mem.indexOfScalar(u8, inner, ':') orelse inner.len];
        for (out.items) |seen| {
            if (std.mem.eql(u8, seen, name)) break;
        } else try out.append(a, name);
        i = close + 2;
    }
    return out.items;
}

/// The template with every placeholder filled. A --set naming no
/// placeholder, or a required placeholder left unset, is an error.
pub fn render(a: Allocator, t: Template, sets: []const Set, d: *Diagnostic) Error![]const u8 {
    const names = try placeholders(a, t.text);
    for (sets) |s| {
        for (names) |n| {
            if (std.mem.eql(u8, n, s.name)) break;
        } else return fail(a, d, "template {s} has no placeholder {s} (it has: {s})", .{ t.name, s.name, if (names.len == 0) "none" else try std.mem.join(a, ", ", names) });
    }
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, t.text, i, "{{")) |open| {
        const close = std.mem.indexOfPos(u8, t.text, open, "}}") orelse break;
        try out.appendSlice(a, t.text[i..open]);
        const inner = t.text[open + 2 .. close];
        const colon = std.mem.indexOfScalar(u8, inner, ':');
        const name = inner[0 .. colon orelse inner.len];
        var value: ?[]const u8 = if (colon) |c| inner[c + 1 ..] else null;
        for (sets) |s| if (std.mem.eql(u8, s.name, name)) {
            value = s.value;
        };
        try out.appendSlice(a, value orelse return fail(a, d, "template {s} needs --set {s}=VALUE", .{ t.name, name }));
        i = close + 2;
    }
    try out.appendSlice(a, t.text[i..]);
    return out.items;
}

const testing = std.testing;

test "every template renders with its required placeholders set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diagnostic = .{};
    const snel = try render(a, find("snellius").?, &.{}, &d);
    try testing.expect(std.mem.indexOf(u8, snel, "salloc -p rome ") != null);
    try testing.expect(std.mem.indexOf(u8, snel, "{{") == null);
    const genoa = try render(a, find("snellius").?, &.{.{ .name = "partition", .value = "genoa" }}, &d);
    try testing.expect(std.mem.indexOf(u8, genoa, "salloc -p genoa ") != null);
    try testing.expectError(error.Invalid, render(a, find("slurm").?, &.{}, &d));
    try testing.expect(std.mem.indexOf(u8, d.message, "--set node_local_root=VALUE") != null);
    const slurm = try render(a, find("slurm").?, &.{
        .{ .name = "node_local_root", .value = "/local" },
        .{ .name = "shared_scratch", .value = "/scratch" },
    }, &d);
    try testing.expect(std.mem.indexOf(u8, slurm, "node_local_root = \"/local\"") != null);
    try testing.expect(std.mem.indexOf(u8, slurm, "node_local_fstype = \"xfs\"") != null);
    try testing.expectError(error.Invalid, render(a, find("snellius").?, &.{.{ .name = "nope", .value = "x" }}, &d));
}

test "a value cannot leave its TOML string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    for ([_][]const u8{ "p=a\"b", "p=a\\b", "p=a\nb", "p=", "P=x", "nop" }) |bad|
        try testing.expectError(error.Invalid, parseSet(arena.allocator(), bad, &d));
    const s = try parseSet(arena.allocator(), "partition=genoa", &d);
    try testing.expectEqualStrings("genoa", s.value);
}

test "every rendered template loads as a site file" {
    const config = @import("config.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    for (all) |t| {
        var sets: std.ArrayList(Set) = .empty;
        for (try placeholders(a, t.text)) |n| try sets.append(a, .{ .name = n, .value = "/srv/x" });
        var d: Diagnostic = .{};
        const text = try render(a, t, sets.items, &d);
        var cd: config.Diagnostic = .{};
        const s = config.load(a, &.{.{ .path = t.name, .text = text, .layer = .site }}, &env, .{}, &cd) catch |e| {
            std.debug.print("template {s}: {s}\n", .{ t.name, cd.message });
            return e;
        };
        try testing.expect(s.node_local_root.value.len > 0);
    }
}
