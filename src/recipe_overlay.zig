//! Declarative site overlays for upstream easyconfigs: parameter replacements,
//! patch additions, dependency variants, keyed by the base file digest.
const std = @import("std");
const toml = @import("toml.zig");
const Allocator = std.mem.Allocator;

/// One parameter assignment to replace in the upstream easyconfig.
pub const Parameter = struct {
    name: []const u8,
    value: []const u8,
};

/// One patch tuple to append to `patches`.
pub const Patch = struct {
    name: []const u8,
    file: []const u8,
};

/// One dependency variant to add or replace.
pub const Dependency = struct {
    action: []const u8,
    name: []const u8,
    spec: []const u8,
};

/// A parsed overlay description; only the fields the format allows.
pub const Spec = struct {
    overlay_version: i64 = 1,
    base_easyconfig: []const u8 = "",
    base_digest: []const u8 = "",
    rationale: []const u8 = "",
    parameters: []const Parameter = &.{},
    patches: []const Patch = &.{},
    dependencies: []const Dependency = &.{},
};

/// Where an overlay file or materialization was refused.
pub const Diagnostic = struct {
    line: usize = 0,
    message: []const u8 = "",
};

/// Refusal reasons while parsing or materializing an overlay.
pub const Error = error{ Invalid, DigestMismatch, OutOfMemory };

fn fail(a: Allocator, d: *Diagnostic, comptime fmt: []const u8, args: anytype) Error {
    d.message = std.fmt.allocPrint(a, fmt, args) catch return error.OutOfMemory;
    return error.Invalid;
}

fn expectString(a: Allocator, e: *const toml.Entry, d: *Diagnostic) Error![]const u8 {
    return switch (e.value) {
        .string => |s| s,
        else => {
            d.line = e.line;
            return fail(a, d, "{s} must be a string", .{e.key});
        },
    };
}

fn tableString(a: Allocator, t: *const toml.Table, key: []const u8, d: *Diagnostic) Error!?[]const u8 {
    const e = t.get(key) orelse return null;
    return try expectString(a, e, d);
}

fn walkTable(a: Allocator, t: *const toml.Table, d: *Diagnostic, out: *std.ArrayList(Parameter)) Error!void {
    for (t.entries.items) |*e| {
        const value = try expectString(a, e, d);
        try out.append(a, .{ .name = e.key, .value = value });
    }
}

fn walkPatches(a: Allocator, t: *const toml.Table, d: *Diagnostic, out: *std.ArrayList(Patch)) Error!void {
    for (t.entries.items) |*e| {
        const file = try expectString(a, e, d);
        try out.append(a, .{ .name = e.key, .file = file });
    }
}

fn walkDependencies(a: Allocator, t: *const toml.Table, action: []const u8, d: *Diagnostic, out: *std.ArrayList(Dependency)) Error!void {
    for (t.entries.items) |*e| {
        const spec = try expectString(a, e, d);
        try out.append(a, .{ .action = action, .name = e.key, .spec = spec });
    }
}

/// Read overlay TOML from `text`. Tables `[replace]`, `[patches]`,
/// `[dependencies.add]` and `[dependencies.replace]` hold the edits.
pub fn parseSpec(a: Allocator, text: []const u8, d: *Diagnostic) Error!Spec {
    var td: toml.Diagnostic = .{};
    const root = toml.parse(a, text, &td) catch {
        d.line = td.line;
        d.message = std.fmt.allocPrint(a, "{s}", .{td.message}) catch return error.OutOfMemory;
        return error.Invalid;
    };
    const digest = (try tableString(a, root, "base_digest", d)) orelse return fail(a, d, "base_digest is required", .{});
    if (digest.len != 64) return fail(a, d, "base_digest must be a SHA-256 hex digest (64 characters)", .{});
    for (digest) |ch| if (!std.ascii.isHex(ch)) return fail(a, d, "base_digest must be a SHA-256 hex digest", .{});
    var spec: Spec = .{
        .base_digest = digest,
        .base_easyconfig = (try tableString(a, root, "base_easyconfig", d)) orelse "",
        .rationale = (try tableString(a, root, "rationale", d)) orelse "",
    };
    if (root.get("overlay_version")) |e| {
        spec.overlay_version = switch (e.value) {
            .int => |n| n,
            else => return fail(a, d, "overlay_version must be an integer", .{}),
        };
    }
    if (spec.overlay_version != 1) return fail(a, d, "overlay_version must be 1", .{});
    var parameters: std.ArrayList(Parameter) = .empty;
    var patches: std.ArrayList(Patch) = .empty;
    var dependencies: std.ArrayList(Dependency) = .empty;
    if (root.get("replace")) |e| switch (e.value) {
        .table => |t| try walkTable(a, t, d, &parameters),
        else => return fail(a, d, "[replace] must be a table", .{}),
    };
    if (root.get("patches")) |e| switch (e.value) {
        .table => |t| try walkPatches(a, t, d, &patches),
        else => return fail(a, d, "[patches] must be a table", .{}),
    };
    if (root.get("dependencies")) |e| switch (e.value) {
        .table => |deps| {
            if (deps.get("add")) |add| switch (add.value) {
                .table => |t| try walkDependencies(a, t, "add", d, &dependencies),
                else => return fail(a, d, "[dependencies.add] must be a table", .{}),
            };
            if (deps.get("replace")) |rep| switch (rep.value) {
                .table => |t| try walkDependencies(a, t, "replace", d, &dependencies),
                else => return fail(a, d, "[dependencies.replace] must be a table", .{}),
            };
        },
        else => return fail(a, d, "[dependencies] must be a table", .{}),
    };
    spec.parameters = try parameters.toOwnedSlice(a);
    spec.patches = try patches.toOwnedSlice(a);
    spec.dependencies = try dependencies.toOwnedSlice(a);
    return spec;
}

/// SHA-256 of `data` as lowercase hex, for digests in overlay files.
pub fn sha256Hex(a: Allocator, data: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    const hex = std.fmt.bytesToHex(hash, .lower);
    return a.dupe(u8, &hex);
}

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, std.mem.trimStart(u8, line, " \t"), " \t\r");
}

fn lineSetsParameter(line: []const u8, name: []const u8) bool {
    const t = trimLine(line);
    if (t.len <= name.len) return false;
    if (!std.mem.startsWith(u8, t, name)) return false;
    const rest = std.mem.trimStart(u8, t[name.len..], " \t");
    return std.mem.startsWith(u8, rest, "=");
}

fn replaceParameter(a: Allocator, text: []const u8, param: Parameter, d: *Diagnostic) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var replaced = false;
    while (lines.next()) |line| {
        if (!replaced and lineSetsParameter(line, param.name)) {
            const leading = std.mem.trimStart(u8, line, " \t");
            const indent_len = line.len - leading.len;
            const nl = try std.fmt.allocPrint(a, "{s}{s} = {s}", .{ line[0..indent_len], param.name, param.value });
            try out.appendSlice(a, nl);
            replaced = true;
        } else {
            try out.appendSlice(a, line);
        }
        if (lines.peek() != null) try out.append(a, '\n');
    }
    if (!replaced) return fail(a, d, "easyconfig has no parameter '{s}' to replace", .{param.name});
    return out.toOwnedSlice(a);
}

fn findArrayStart(text: []const u8, key: []const u8) ?usize {
    var pos: usize = 0;
    while (pos < text.len) {
        const rest = text[pos..];
        const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = rest[0..line_end];
        if (lineSetsParameter(line, key)) {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
                pos += line_end + 1;
                continue;
            };
            const after = std.mem.trimStart(u8, line[eq + 1 ..], " \t");
            if (std.mem.startsWith(u8, after, "[")) return pos + eq + 1 + (line[eq + 1 ..].len - after.len);
        }
        pos += line_end + 1;
    }
    return null;
}

fn findMatchingBracket(text: []const u8, open: usize) ?usize {
    var depth: i32 = 0;
    var i = open;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '#') {
            i += 1;
            while (i < text.len and text[i] != '\n') : (i += 1) {}
            continue;
        }
        if (ch == '\'' or ch == '"') {
            if (i + 2 < text.len and text[i + 1] == ch and text[i + 2] == ch) {
                const quote = ch;
                i += 3;
                while (i < text.len) {
                    if (text[i] == '\\') {
                        i += @min(2, text.len - i);
                        continue;
                    }
                    if (i + 2 < text.len and text[i] == quote and text[i + 1] == quote and text[i + 2] == quote) {
                        i += 3;
                        break;
                    }
                    i += 1;
                }
                continue;
            }
            const quote = ch;
            i += 1;
            while (i < text.len) {
                if (text[i] == '\\') {
                    i += @min(2, text.len - i);
                    continue;
                }
                if (text[i] == quote or text[i] == '\n') {
                    i += 1;
                    break;
                }
                i += 1;
            }
            continue;
        }
        if (ch == '[') {
            depth += 1;
        } else if (ch == ']') {
            depth -= 1;
            if (depth == 0) return i;
        }
        i += 1;
    }
    return null;
}

fn appendToArray(a: Allocator, text: []const u8, key: []const u8, entry: []const u8, d: *Diagnostic) Error![]u8 {
    if (findArrayStart(text, key)) |start| {
        const close = findMatchingBracket(text, start) orelse
            return fail(a, d, "easyconfig {s} list has no closing bracket", .{key});
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, text[0..close]);
        const inner = std.mem.trim(u8, text[start + 1 .. close], " \t\n\r");
        if (inner.len > 0) {
            if (inner[inner.len - 1] == ',') {
                if (close > 0 and text[close - 1] == '\n') {
                    try out.appendSlice(a, "    ");
                } else {
                    try out.appendSlice(a, "\n    ");
                }
                try out.appendSlice(a, entry);
                try out.appendSlice(a, ",\n");
                try out.appendSlice(a, text[close..]);
                return out.toOwnedSlice(a);
            }
            try out.appendSlice(a, ",\n    ");
        }
        try out.appendSlice(a, entry);
        try out.appendSlice(a, text[close..]);
        return out.toOwnedSlice(a);
    }
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, text);
    if (text.len > 0 and text[text.len - 1] != '\n') try out.append(a, '\n');
    const block = try std.fmt.allocPrint(a, "{s} = [\n    {s},\n]\n", .{ key, entry });
    try out.appendSlice(a, block);
    return out.toOwnedSlice(a);
}

fn patchEntry(a: Allocator, p: Patch) ![]const u8 {
    return std.fmt.allocPrint(a, "('{s}', '{s}')", .{ p.name, p.file });
}

fn replaceDependency(a: Allocator, text: []const u8, dep: Dependency, d: *Diagnostic) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const needle = try std.fmt.allocPrint(a, "('{s}',", .{dep.name});
    const idx = std.mem.indexOf(u8, text, needle) orelse
        return fail(a, d, "easyconfig has no dependency '{s}' to replace", .{dep.name});
    const start = idx;
    const end = std.mem.indexOfPos(u8, text, start, ")") orelse
        return fail(a, d, "easyconfig dependency '{s}' has no closing parenthesis", .{dep.name});
    try out.appendSlice(a, text[0..start]);
    try out.appendSlice(a, dep.spec);
    try out.appendSlice(a, text[end + 1 ..]);
    return out.toOwnedSlice(a);
}

/// Apply `spec` to `base_text`. Refuses when the digest of `base_text` differs
/// from `spec.base_digest`.
pub fn materialize(a: Allocator, base_text: []const u8, spec: Spec, d: *Diagnostic) Error![]u8 {
    const digest = try sha256Hex(a, base_text);
    if (!std.ascii.eqlIgnoreCase(digest, spec.base_digest)) {
        d.message = try std.fmt.allocPrint(a, "base digest is {s}, overlay pins {s}; upstream changed — refresh the overlay with eb-local overlay bump and eb-local overlay plan", .{ digest, spec.base_digest });
        return error.DigestMismatch;
    }
    var text = try a.dupe(u8, base_text);
    if (spec.parameters.len == 0 and spec.patches.len == 0 and spec.dependencies.len == 0) return text;
    for (spec.parameters) |p| {
        const next = try replaceParameter(a, text, p, d);
        a.free(text);
        text = next;
    }
    for (spec.patches) |p| {
        const entry = try patchEntry(a, p);
        const next = try appendToArray(a, text, "patches", entry, d);
        a.free(text);
        text = next;
    }
    for (spec.dependencies) |dep| {
        const next = if (std.mem.eql(u8, dep.action, "replace"))
            try replaceDependency(a, text, dep, d)
        else
            try appendToArray(a, text, "dependencies", dep.spec, d);
        a.free(text);
        text = next;
    }
    return text;
}

/// Paths for `overlay materialize`.
pub const MaterializeOptions = struct {
    overlay_path: []const u8 = "",
    base_path: []const u8 = "",
    out_dir: []const u8 = "",
    dry_run: bool = false,
    check: bool = false,
};

fn quoted(a: Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '"');
    for (value) |ch| switch (ch) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        else => try out.append(a, ch),
    };
    try out.append(a, '"');
    return out.toOwnedSlice(a);
}

fn writeProvenance(a: Allocator, opts: MaterializeOptions, spec: Spec, base_digest: []const u8, overlay_digest: []const u8, recipe_name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "provenance_version = 1\n");
    try out.print(a, "base_easyconfig = {s}\n", .{try quoted(a, opts.base_path)});
    try out.print(a, "base_digest = \"{s}\"\n", .{base_digest});
    try out.print(a, "overlay_file = {s}\n", .{try quoted(a, opts.overlay_path)});
    try out.print(a, "overlay_digest = \"{s}\"\n", .{overlay_digest});
    try out.print(a, "materialized_easyconfig = {s}\n", .{try quoted(a, recipe_name)});
    if (spec.rationale.len > 0) {
        try out.appendSlice(a, "rationale = \"\"\"\n");
        try out.appendSlice(a, spec.rationale);
        if (spec.rationale.len == 0 or spec.rationale[spec.rationale.len - 1] != '\n') try out.append(a, '\n');
        try out.appendSlice(a, "\"\"\"\n");
    }
    return out.toOwnedSlice(a);
}

fn failMsg(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("eb-local: " ++ fmt ++ "\n", args);
}

/// Read overlay and base files, verify the digest, and write, preview, or check the outputs.
pub fn runMaterialize(io: std.Io, a: Allocator, opts: MaterializeOptions) u8 {
    if (opts.dry_run and opts.check) {
        failMsg("overlay materialize takes --dry-run or --check, not both", .{});
        return 2;
    }
    if (opts.overlay_path.len == 0) {
        failMsg("overlay materialize needs --overlay FILE", .{});
        return 2;
    }
    if (opts.base_path.len == 0) {
        failMsg("overlay materialize needs --base PATH", .{});
        return 2;
    }
    const cwd = std.Io.Dir.cwd();
    var od: Diagnostic = .{};
    const overlay_text = cwd.readFileAlloc(io, opts.overlay_path, a, .limited(4 * 1024 * 1024)) catch |err| {
        failMsg("cannot read {s}: {s}", .{ opts.overlay_path, @errorName(err) });
        return 1;
    };
    const spec = parseSpec(a, overlay_text, &od) catch |e| switch (e) {
        error.Invalid => {
            failMsg("{s}", .{if (od.message.len > 0) od.message else "overlay file is invalid"});
            return 2;
        },
        error.OutOfMemory => return 1,
        else => return 1,
    };
    const base_text = cwd.readFileAlloc(io, opts.base_path, a, .limited(16 * 1024 * 1024)) catch |err| {
        failMsg("cannot read {s}: {s}", .{ opts.base_path, @errorName(err) });
        return 1;
    };
    const recipe = materialize(a, base_text, spec, &od) catch |e| switch (e) {
        error.DigestMismatch, error.Invalid => {
            failMsg("{s}", .{if (od.message.len > 0) od.message else "overlay cannot be materialized"});
            return 2;
        },
        error.OutOfMemory => return 1,
    };
    defer a.free(recipe);
    const overlay_digest = sha256Hex(a, overlay_text) catch return 1;
    const base_digest = sha256Hex(a, base_text) catch return 1;
    const out_dir = if (opts.out_dir.len > 0) opts.out_dir else std.fs.path.dirname(opts.overlay_path) orelse ".";
    const base_name = std.fs.path.basename(opts.base_path);
    const recipe_name = std.fmt.allocPrint(a, "materialized-{s}", .{base_name}) catch return 1;
    const recipe_path = std.fs.path.join(a, &.{ out_dir, recipe_name }) catch return 1;
    const provenance_path = std.fs.path.join(a, &.{ out_dir, "provenance.toml" }) catch return 1;
    const provenance = writeProvenance(a, .{ .overlay_path = opts.overlay_path, .base_path = opts.base_path, .out_dir = out_dir }, spec, base_digest, overlay_digest, recipe_name) catch return 1;
    defer a.free(provenance);
    var stdout = std.Io.File.stdout();
    if (opts.check) {
        const existing_recipe = cwd.readFileAlloc(io, recipe_path, a, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => {
                failMsg("cannot read {s}: {s}", .{ recipe_path, @errorName(err) });
                return 2;
            },
        };
        defer if (existing_recipe) |buf| a.free(buf);
        const existing_prov = cwd.readFileAlloc(io, provenance_path, a, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => {
                failMsg("cannot read {s}: {s}", .{ provenance_path, @errorName(err) });
                return 2;
            },
        };
        defer if (existing_prov) |buf| a.free(buf);
        const up_to_date = if (existing_recipe) |er|
            if (existing_prov) |ep|
                std.mem.eql(u8, er, recipe) and std.mem.eql(u8, ep, provenance)
            else
                false
        else
            false;
        const message = std.fmt.allocPrint(a, "{s} {s} and {s}\n", .{
            if (up_to_date) "up to date" else "would update",
            recipe_path,
            provenance_path,
        }) catch return 1;
        stdout.writeStreamingAll(io, message) catch return 1;
        return if (up_to_date) 0 else 1;
    }
    if (opts.dry_run) {
        const message = std.fmt.allocPrint(a, "would write {s} and {s}\n", .{ recipe_path, provenance_path }) catch return 1;
        stdout.writeStreamingAll(io, message) catch return 1;
        return 0;
    }
    cwd.createDirPath(io, out_dir) catch |err| {
        failMsg("cannot create {s}: {s}", .{ out_dir, @errorName(err) });
        return 1;
    };
    cwd.writeFile(io, .{ .sub_path = recipe_path, .data = recipe }) catch |err| {
        failMsg("cannot write {s}: {s}", .{ recipe_path, @errorName(err) });
        return 1;
    };
    cwd.writeFile(io, .{ .sub_path = provenance_path, .data = provenance }) catch |err| {
        failMsg("cannot write {s}: {s}", .{ provenance_path, @errorName(err) });
        return 1;
    };
    const message = std.fmt.allocPrint(a, "wrote {s} and {s}\n", .{ recipe_path, provenance_path }) catch return 1;
    stdout.writeStreamingAll(io, message) catch return 1;
    return 0;
}

test "parse overlay spec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\overlay_version = 1
        \\base_easyconfig = "Demo.eb"
        \\base_digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        \\rationale = "site tuning"
        \\
        \\[replace]
        \\preconfigopts = "'--enable-foo'"
        \\
        \\[patches]
        \\site = "site.patch"
        \\
        \\[dependencies.add]
        \\zlib = "('zlib', '1.2.13')"
    ;
    var d: Diagnostic = .{};
    const spec = try parseSpec(a, text, &d);
    try std.testing.expectEqual(@as(i64, 1), spec.overlay_version);
    try std.testing.expectEqual(@as(usize, 1), spec.parameters.len);
    try std.testing.expectEqual(@as(usize, 1), spec.patches.len);
    try std.testing.expectEqual(@as(usize, 1), spec.dependencies.len);
}

test "materialize refuses digest drift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = "easyblock = 'ConfigureMake'\n";
    const digest = try sha256Hex(a, base);
    var spec: Spec = .{ .base_digest = digest };
    var d: Diagnostic = .{};
    _ = try materialize(a, base, spec, &d);
    spec.base_digest = "0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expectError(error.DigestMismatch, materialize(a, base, spec, &d));
}

test "pinned overlay without edits is byte-identical" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = "easyblock = 'ConfigureMake'\nname = 'demo'\nversion = '1.0'\n";
    const digest = try sha256Hex(a, base);
    const spec: Spec = .{ .base_digest = digest };
    var d: Diagnostic = .{};
    const out = try materialize(a, base, spec, &d);
    try std.testing.expectEqualStrings(base, out);
}

test "parameter replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = "preconfigopts = '--old'\n";
    const digest = try sha256Hex(a, base);
    const spec: Spec = .{
        .base_digest = digest,
        .parameters = &.{.{ .name = "preconfigopts", .value = "'--new'" }},
    };
    var d: Diagnostic = .{};
    const out = try materialize(a, base, spec, &d);
    try std.testing.expectEqualStrings("preconfigopts = '--new'\n", out);
}

test "materialize populates diagnostic on failing edits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Non-string parameter value allocates diagnostic in caller arena.
    var bad_spec_diag: Diagnostic = .{};
    try std.testing.expectError(error.Invalid, parseSpec(a, "base_digest = 123\n", &bad_spec_diag));
    try std.testing.expectEqualStrings("base_digest must be a string", bad_spec_diag.message);

    // Parameter lookup failure populates diagnostic.
    const base_param = "name = 'demo'\n";
    var d1: Diagnostic = .{};
    try std.testing.expectError(error.Invalid, materialize(a, base_param, .{
        .base_digest = try sha256Hex(a, base_param),
        .parameters = &.{.{ .name = "preconfigopts", .value = "'--new'" }},
    }, &d1));
    try std.testing.expectEqualStrings("easyconfig has no parameter 'preconfigopts' to replace", d1.message);

    // Unclosed array bracket populates diagnostic.
    const base_arr = "patches = [\n    'a.patch',\n";
    var d2: Diagnostic = .{};
    try std.testing.expectError(error.Invalid, materialize(a, base_arr, .{
        .base_digest = try sha256Hex(a, base_arr),
        .patches = &.{.{ .name = "site", .file = "site.patch" }},
    }, &d2));
    try std.testing.expectEqualStrings("easyconfig patches list has no closing bracket", d2.message);

    // Dependency lookup failure and unclosed tuple both populate diagnostic.
    var d3: Diagnostic = .{};
    try std.testing.expectError(error.Invalid, materialize(a, base_param, .{
        .base_digest = try sha256Hex(a, base_param),
        .dependencies = &.{.{ .action = "replace", .name = "zlib", .spec = "('zlib', '1.3')" }},
    }, &d3));
    try std.testing.expectEqualStrings("easyconfig has no dependency 'zlib' to replace", d3.message);

    const base_dep = "dependencies = [('zlib', '1.2'\n";
    var d4: Diagnostic = .{};
    try std.testing.expectError(error.Invalid, materialize(a, base_dep, .{
        .base_digest = try sha256Hex(a, base_dep),
        .dependencies = &.{.{ .action = "replace", .name = "zlib", .spec = "('zlib', '1.3')" }},
    }, &d4));
    try std.testing.expectEqualStrings("easyconfig dependency 'zlib' has no closing parenthesis", d4.message);
}

test "parameter replacement preserves leading indent when line has trailing spaces or CR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = "  name = 'demo'   \nversion = '1.0'\r\n";
    const digest = try sha256Hex(a, base);
    const spec: Spec = .{
        .base_digest = digest,
        .parameters = &.{
            .{ .name = "name", .value = "'custom'" },
            .{ .name = "version", .value = "'2.0'" },
        },
    };
    var d: Diagnostic = .{};
    const out = try materialize(a, base, spec, &d);
    try std.testing.expectEqualStrings("  name = 'custom'\nversion = '2.0'\n", out);
}

test "appendToArray handles trailing commas without producing double commas" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = "dependencies = [\n    ('zlib', '1.3'),\n]\n";
    const digest = try sha256Hex(a, base);
    const deps = [_]Dependency{.{ .action = "add", .name = "pkg", .spec = "('pkg', '1.0')" }};
    const spec: Spec = .{
        .base_digest = digest,
        .dependencies = &deps,
    };
    var d: Diagnostic = .{};
    const out = try materialize(a, base, spec, &d);
    try std.testing.expect(std.mem.indexOf(u8, out, ",,") == null);
    try std.testing.expectEqualStrings("dependencies = [\n    ('zlib', '1.3'),\n    ('pkg', '1.0'),\n]\n", out);
}

test "findMatchingBracket ignores brackets inside string literals and comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = "patches = [\n    # [unbalanced comment\n    ('only-[one.patch', 1),\n    ('a]b.patch', 1),\n]\n";
    const digest = try sha256Hex(a, base);
    const patches = [_]Patch{.{ .name = "site", .file = "site.patch" }};
    const spec: Spec = .{
        .base_digest = digest,
        .patches = &patches,
    };
    var d: Diagnostic = .{};
    const out = try materialize(a, base, spec, &d);
    try std.testing.expectEqualStrings(
        "patches = [\n    # [unbalanced comment\n    ('only-[one.patch', 1),\n    ('a]b.patch', 1),\n    ('site', 'site.patch'),\n]\n",
        out,
    );
}
