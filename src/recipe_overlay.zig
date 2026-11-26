//! Declarative site overlays for upstream easyconfigs: parameter replacements,
//! patch additions, dependency variants, keyed by the base file digest.
const std = @import("std");
const common = @import("zig_common");
const toml = @import("toml.zig");
const storage = @import("storage.zig");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;

/// One parameter assignment to add to or replace in the upstream easyconfig.
pub const Parameter = struct {
    action: []const u8 = "replace",
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

fn pythonKeyword(name: []const u8) bool {
    const keywords = [_][]const u8{
        "False",  "None",   "True",    "and",      "as",       "assert", "async",
        "await",  "break",  "class",   "continue", "def",      "del",    "elif",
        "else",   "except", "finally", "for",      "from",     "global", "if",
        "import", "in",     "is",      "lambda",   "nonlocal", "not",    "or",
        "pass",   "raise",  "return",  "try",      "while",    "with",   "yield",
    };
    for (keywords) |keyword| {
        if (std.mem.eql(u8, name, keyword)) return true;
    }
    return false;
}

fn validateParameterName(a: Allocator, e: *const toml.Entry, d: *Diagnostic) Error!void {
    d.line = e.line;
    if (e.key.len == 0 or !(std.ascii.isAlphabetic(e.key[0]) or e.key[0] == '_')) {
        return fail(a, d, "parameter name is an invalid Python identifier", .{});
    }
    for (e.key[1..]) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) {
            return fail(a, d, "parameter name is an invalid Python identifier", .{});
        }
    }
    if (pythonKeyword(e.key)) {
        return fail(a, d, "parameter name '{s}' is a Python keyword", .{e.key});
    }
}

fn appendPythonString(a: Allocator, out: *std.ArrayList(u8), value: []const u8, d: *Diagnostic) Error!void {
    if (std.mem.indexOfAny(u8, value, "\r\n") != null) {
        return fail(a, d, "new [add] string values must not contain a newline", .{});
    }
    try out.append(a, '\'');
    for (value) |ch| switch (ch) {
        '\'' => try out.appendSlice(a, "\\'"),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\t' => try out.appendSlice(a, "\\t"),
        0...8, 11...31, 127 => try out.print(a, "\\x{x:0>2}", .{ch}),
        else => try out.append(a, ch),
    };
    try out.append(a, '\'');
}

fn appendPythonValue(a: Allocator, out: *std.ArrayList(u8), value: toml.Value, d: *Diagnostic) Error!void {
    switch (value) {
        .string => |s| try appendPythonString(a, out, s, d),
        .int => |n| try out.print(a, "{d}", .{n}),
        .boolean => |b| try out.appendSlice(a, if (b) "True" else "False"),
        .array => |values| {
            try out.append(a, '[');
            for (values, 0..) |item, index| {
                if (index > 0) try out.appendSlice(a, ", ");
                try appendPythonValue(a, out, item, d);
            }
            try out.append(a, ']');
        },
        .table => |table| {
            try out.append(a, '{');
            for (table.entries.items, 0..) |entry, index| {
                if (index > 0) try out.appendSlice(a, ", ");
                try appendPythonString(a, out, entry.key, d);
                try out.appendSlice(a, ": ");
                try appendPythonValue(a, out, entry.value, d);
            }
            try out.append(a, '}');
        },
    }
}

fn pythonValue(a: Allocator, e: *const toml.Entry, d: *Diagnostic) Error![]const u8 {
    d.line = e.line;
    var out: std.ArrayList(u8) = .empty;
    try appendPythonValue(a, &out, e.value, d);
    return out.toOwnedSlice(a);
}

fn walkParameterTable(a: Allocator, t: *const toml.Table, action: []const u8, d: *Diagnostic, out: *std.ArrayList(Parameter)) Error!void {
    for (t.entries.items) |*e| {
        try validateParameterName(a, e, d);
        const value = if (std.mem.eql(u8, action, "add"))
            try pythonValue(a, e, d)
        else
            try expectString(a, e, d);
        try out.append(a, .{ .action = action, .name = e.key, .value = value });
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

/// Read overlay TOML from `text`. Tables `[add]`, `[replace]`, `[patches]`,
/// `[dependencies.add]` and `[dependencies.replace]` hold the edits.
pub fn parseSpec(a: Allocator, text: []const u8, d: *Diagnostic) Error!Spec {
    var td: toml.Diagnostic = .{};
    const root = toml.parse(a, text, &td) catch {
        d.line = td.line;
        d.message = std.fmt.allocPrint(a, "{s}", .{td.message}) catch return error.OutOfMemory;
        return error.Invalid;
    };
    for (root.entries.items) |*e| {
        if (!std.mem.eql(u8, e.key, "overlay_version") and
            !std.mem.eql(u8, e.key, "base_easyconfig") and
            !std.mem.eql(u8, e.key, "base_digest") and
            !std.mem.eql(u8, e.key, "rationale") and
            !std.mem.eql(u8, e.key, "add") and
            !std.mem.eql(u8, e.key, "replace") and
            !std.mem.eql(u8, e.key, "patches") and
            !std.mem.eql(u8, e.key, "dependencies"))
        {
            d.line = e.line;
            return fail(a, d, "unknown key {s}", .{e.key});
        }
    }
    const digest_entry = root.get("base_digest") orelse {
        d.line = 1;
        return fail(a, d, "base_digest is required", .{});
    };
    const digest = try expectString(a, digest_entry, d);
    if (digest.len != 64) {
        d.line = digest_entry.line;
        return fail(a, d, "base_digest must be a SHA-256 hex digest (64 characters)", .{});
    }
    for (digest) |ch| if (!std.ascii.isHex(ch)) {
        d.line = digest_entry.line;
        return fail(a, d, "base_digest must be a SHA-256 hex digest", .{});
    };
    var spec: Spec = .{
        .base_digest = digest,
        .base_easyconfig = (try tableString(a, root, "base_easyconfig", d)) orelse "",
        .rationale = (try tableString(a, root, "rationale", d)) orelse "",
    };
    if (root.get("overlay_version")) |e| {
        spec.overlay_version = switch (e.value) {
            .int => |n| n,
            else => {
                d.line = e.line;
                return fail(a, d, "overlay_version must be an integer", .{});
            },
        };
        if (spec.overlay_version != 1) {
            d.line = e.line;
            return fail(a, d, "overlay_version must be 1", .{});
        }
    }
    var parameters: std.ArrayList(Parameter) = .empty;
    var patches: std.ArrayList(Patch) = .empty;
    var dependencies: std.ArrayList(Dependency) = .empty;
    if (root.get("add")) |e| switch (e.value) {
        .table => |t| try walkParameterTable(a, t, "add", d, &parameters),
        else => {
            d.line = e.line;
            return fail(a, d, "[add] must be a table", .{});
        },
    };
    if (root.get("replace")) |e| switch (e.value) {
        .table => |t| try walkParameterTable(a, t, "replace", d, &parameters),
        else => {
            d.line = e.line;
            return fail(a, d, "[replace] must be a table", .{});
        },
    };
    if (root.get("patches")) |e| switch (e.value) {
        .table => |t| try walkPatches(a, t, d, &patches),
        else => {
            d.line = e.line;
            return fail(a, d, "[patches] must be a table", .{});
        },
    };
    if (root.get("dependencies")) |e| switch (e.value) {
        .table => |deps| {
            for (deps.entries.items) |*de| {
                if (!std.mem.eql(u8, de.key, "add") and !std.mem.eql(u8, de.key, "replace")) {
                    d.line = de.line;
                    return fail(a, d, "unknown key dependencies.{s}", .{de.key});
                }
            }
            if (deps.get("add")) |add| switch (add.value) {
                .table => |t| try walkDependencies(a, t, "add", d, &dependencies),
                else => {
                    d.line = add.line;
                    return fail(a, d, "[dependencies.add] must be a table", .{});
                },
            };
            if (deps.get("replace")) |rep| switch (rep.value) {
                .table => |t| try walkDependencies(a, t, "replace", d, &dependencies),
                else => {
                    d.line = rep.line;
                    return fail(a, d, "[dependencies.replace] must be a table", .{});
                },
            };
        },
        else => {
            d.line = e.line;
            return fail(a, d, "[dependencies] must be a table", .{});
        },
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
    return rest.len > 0 and rest[0] == '=' and (rest.len == 1 or rest[1] != '=');
}

const PyLineState = struct {
    triple_quote: ?u8 = null,
    depth: usize = 0,

    fn isTopLevel(self: PyLineState) bool {
        return self.triple_quote == null and self.depth == 0;
    }

    fn advanceLine(self: *PyLineState, line: []const u8) void {
        var i: usize = 0;
        while (i < line.len) {
            if (self.triple_quote) |tq| {
                if (line[i] == '\\') {
                    i += @min(2, line.len - i);
                    continue;
                }
                if (i + 2 < line.len and line[i] == tq and line[i + 1] == tq and line[i + 2] == tq) {
                    self.triple_quote = null;
                    i += 3;
                    continue;
                }
                i += 1;
                continue;
            }
            const ch = line[i];
            if (ch == '#') break;
            if (ch == '\'' or ch == '"') {
                if (i + 2 < line.len and line[i + 1] == ch and line[i + 2] == ch) {
                    self.triple_quote = ch;
                    i += 3;
                    continue;
                }
                i += 1;
                while (i < line.len) {
                    if (line[i] == '\\') {
                        i += @min(2, line.len - i);
                        continue;
                    }
                    if (line[i] == ch) {
                        i += 1;
                        break;
                    }
                    i += 1;
                }
                continue;
            }
            if (ch == '(' or ch == '[' or ch == '{') {
                self.depth += 1;
            } else if ((ch == ')' or ch == ']' or ch == '}') and self.depth > 0) {
                self.depth -= 1;
            }
            i += 1;
        }
    }
};

fn endsWithBackslash(line: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, line, "\r");
    var bs: usize = 0;
    var i = trimmed.len;
    while (i > 0 and trimmed[i - 1] == '\\') : (i -= 1) bs += 1;
    return bs % 2 == 1;
}

fn replaceParameter(a: Allocator, text: []const u8, param: Parameter, d: *Diagnostic) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var replaced = false;
    var state: PyLineState = .{};
    while (lines.next()) |line| {
        if (!replaced and state.isTopLevel() and lineSetsParameter(line, param.name)) {
            var orig_state: PyLineState = .{};
            orig_state.advanceLine(line);
            var continued = orig_state.isTopLevel() and endsWithBackslash(line);
            while (!orig_state.isTopLevel() or continued) {
                const cont = lines.next() orelse break;
                orig_state.advanceLine(cont);
                continued = orig_state.isTopLevel() and endsWithBackslash(cont);
            }
            const leading = std.mem.trimStart(u8, line, " \t");
            const indent_len = line.len - leading.len;
            const nl = try std.fmt.allocPrint(a, "{s}{s} = {s}", .{ line[0..indent_len], param.name, param.value });
            try out.appendSlice(a, nl);
            replaced = true;
            state.advanceLine(nl);
        } else {
            try out.appendSlice(a, line);
            state.advanceLine(line);
        }
        if (lines.peek() != null) try out.append(a, '\n');
    }
    if (!replaced) return fail(a, d, "easyconfig has no parameter '{s}' to replace", .{param.name});
    return out.toOwnedSlice(a);
}

fn addParameter(a: Allocator, text: []const u8, param: Parameter, d: *Diagnostic) Error![]u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var state: PyLineState = .{};
    while (lines.next()) |line| {
        if (state.isTopLevel() and lineSetsParameter(line, param.name)) {
            return fail(a, d, "easyconfig already has parameter '{s}'; use [replace]", .{param.name});
        }
        state.advanceLine(line);
    }

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, text);
    if (text.len > 0 and text[text.len - 1] != '\n') try out.append(a, '\n');
    try out.print(a, "{s} = {s}\n", .{ param.name, param.value });
    return out.toOwnedSlice(a);
}

fn findArrayStart(text: []const u8, key: []const u8) ?usize {
    var pos: usize = 0;
    var state: PyLineState = .{};
    while (pos < text.len) {
        const rest = text[pos..];
        const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = rest[0..line_end];
        if (state.isTopLevel() and lineSetsParameter(line, key)) {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
                state.advanceLine(line);
                pos += line_end + 1;
                continue;
            };
            const after = std.mem.trimStart(u8, line[eq + 1 ..], " \t");
            if (std.mem.startsWith(u8, after, "[")) return pos + eq + 1 + (line[eq + 1 ..].len - after.len);
        }
        state.advanceLine(line);
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

fn lastArrayCodePos(slice: []const u8) ?usize {
    var last: ?usize = null;
    var i: usize = 0;
    while (i < slice.len) {
        const ch = slice[i];
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
            i += 1;
        } else if (ch == '#') {
            i += 1;
            while (i < slice.len and slice[i] != '\n') : (i += 1) {}
        } else if (ch == '\'' or ch == '"') {
            const end = @min(slice.len, skipPyString(slice, i));
            last = end - 1;
            i = end;
        } else {
            last = i;
            i += 1;
        }
    }
    return last;
}

fn appendToArray(a: Allocator, text: []const u8, key: []const u8, entry: []const u8, d: *Diagnostic) Error![]u8 {
    if (findArrayStart(text, key)) |start| {
        const close = findMatchingBracket(text, start) orelse
            return fail(a, d, "easyconfig {s} list has no closing bracket", .{key});
        var out: std.ArrayList(u8) = .empty;
        if (lastArrayCodePos(text[start + 1 .. close])) |rel_last| {
            const abs_last = start + 1 + rel_last;
            if (text[abs_last] == ',') {
                try out.appendSlice(a, text[0..close]);
            } else {
                try out.appendSlice(a, text[0 .. abs_last + 1]);
                try out.append(a, ',');
                try out.appendSlice(a, text[abs_last + 1 .. close]);
            }
            if (close > 0 and text[close - 1] == '\n') {
                try out.appendSlice(a, "    ");
                try out.appendSlice(a, entry);
                try out.appendSlice(a, ",\n");
            } else {
                try out.appendSlice(a, "\n    ");
                try out.appendSlice(a, entry);
            }
            try out.appendSlice(a, text[close..]);
            return out.toOwnedSlice(a);
        }
        try out.appendSlice(a, text[0..close]);
        if (close > 0 and text[close - 1] == '\n') {
            try out.appendSlice(a, "    ");
            try out.appendSlice(a, entry);
            try out.appendSlice(a, ",\n");
        } else {
            try out.appendSlice(a, entry);
        }
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

fn skipPyString(text: []const u8, start: usize) usize {
    const quote = text[start];
    if (start + 2 < text.len and text[start + 1] == quote and text[start + 2] == quote) {
        var i = start + 3;
        while (i < text.len) {
            if (text[i] == '\\') {
                i += @min(2, text.len - i);
                continue;
            }
            if (i + 2 < text.len and text[i] == quote and text[i + 1] == quote and text[i + 2] == quote) {
                return i + 3;
            }
            i += 1;
        }
        return text.len;
    }
    var i = start + 1;
    while (i < text.len) {
        if (text[i] == '\\') {
            i += @min(2, text.len - i);
            continue;
        }
        if (text[i] == quote or text[i] == '\n') return i + 1;
        i += 1;
    }
    return text.len;
}

fn skipWsAndComments(text: []const u8, start: usize, limit: usize) usize {
    var i = start;
    while (i < limit) {
        const ch = text[i];
        if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') {
            i += 1;
        } else if (ch == '#') {
            i += 1;
            while (i < limit and text[i] != '\n') : (i += 1) {}
        } else {
            break;
        }
    }
    return i;
}

fn tupleStartsWithDepName(text: []const u8, open_paren: usize, limit: usize, name: []const u8) bool {
    var i = skipWsAndComments(text, open_paren + 1, limit);
    if (i >= limit) return false;
    const quote = text[i];
    if (quote != '\'' and quote != '"') return false;
    if (i + 2 < limit and text[i + 1] == quote and text[i + 2] == quote) return false;
    i += 1;
    if (i + name.len >= limit) return false;
    if (!std.mem.eql(u8, text[i .. i + name.len], name)) return false;
    if (text[i + name.len] != quote) return false;
    const after = skipWsAndComments(text, i + name.len + 1, limit);
    return after < limit and text[after] == ',';
}

fn findMatchingParen(text: []const u8, open: usize, limit: usize) ?usize {
    var depth: i32 = 0;
    var i = open;
    while (i < limit) {
        const ch = text[i];
        if (ch == '#') {
            i += 1;
            while (i < limit and text[i] != '\n') : (i += 1) {}
            continue;
        }
        if (ch == '\'' or ch == '"') {
            i = @min(limit, skipPyString(text, i));
            continue;
        }
        if (ch == '(') {
            depth += 1;
        } else if (ch == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
        i += 1;
    }
    return null;
}

fn replaceDependency(a: Allocator, text: []const u8, dep: Dependency, d: *Diagnostic) Error![]u8 {
    const list_start = findArrayStart(text, "dependencies") orelse
        return fail(a, d, "easyconfig has no dependency '{s}' to replace", .{dep.name});
    const list_close = findMatchingBracket(text, list_start);
    const limit = list_close orelse text.len;

    var i = list_start + 1;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    while (i < limit) {
        const ch = text[i];
        if (ch == '#') {
            i += 1;
            while (i < limit and text[i] != '\n') : (i += 1) {}
            continue;
        }
        if (ch == '\'' or ch == '"') {
            i = @min(limit, skipPyString(text, i));
            continue;
        }
        if (ch == '(') {
            if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and
                tupleStartsWithDepName(text, i, limit, dep.name))
            {
                const end = findMatchingParen(text, i, limit) orelse
                    return fail(a, d, "easyconfig dependency '{s}' has no closing parenthesis", .{dep.name});
                var out: std.ArrayList(u8) = .empty;
                try out.appendSlice(a, text[0..i]);
                try out.appendSlice(a, dep.spec);
                try out.appendSlice(a, text[end + 1 ..]);
                return out.toOwnedSlice(a);
            }
            paren_depth += 1;
        } else if (ch == ')') {
            if (paren_depth > 0) paren_depth -= 1;
        } else if (ch == '[') {
            bracket_depth += 1;
        } else if (ch == ']') {
            if (bracket_depth > 0) bracket_depth -= 1;
        } else if (ch == '{') {
            brace_depth += 1;
        } else if (ch == '}') {
            if (brace_depth > 0) brace_depth -= 1;
        }
        i += 1;
    }
    if (list_close == null) {
        return fail(a, d, "easyconfig dependencies list has no closing bracket", .{});
    }
    return fail(a, d, "easyconfig has no dependency '{s}' to replace", .{dep.name});
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
        const next = if (std.mem.eql(u8, p.action, "add"))
            try addParameter(a, text, p, d)
        else
            try replaceParameter(a, text, p, d);
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
        '\r' => try out.appendSlice(a, "\\r"),
        '\t' => try out.appendSlice(a, "\\t"),
        0...8, 11...12, 14...31, 127 => try out.print(a, "\\u{x:0>4}", .{ch}),
        else => try out.append(a, ch),
    };
    try out.append(a, '"');
    return out.toOwnedSlice(a);
}

fn appendMultilineBody(a: Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    for (value, 0..) |ch, idx| switch (ch) {
        '\\' => try out.appendSlice(a, "\\\\"),
        '\r' => try out.appendSlice(a, "\\r"),
        0...8, 11...12, 14...31, 127 => try out.print(a, "\\u{x:0>4}", .{ch}),
        '"' => {
            const adj = (idx > 0 and value[idx - 1] == '"') or (idx + 1 < value.len and value[idx + 1] == '"') or idx + 1 == value.len;
            if (adj) try out.append(a, '\\');
            try out.append(a, '"');
        },
        else => try out.append(a, ch),
    };
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
        try appendMultilineBody(a, &out, spec.rationale);
        if (spec.rationale[spec.rationale.len - 1] != '\n') try out.append(a, '\n');
        try out.appendSlice(a, "\"\"\"\n");
    }
    return out.toOwnedSlice(a);
}

fn failMsg(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("eb-local: " ++ fmt ++ "\n", args);
}

fn writeStdout(io: std.Io, stdout: *std.Io.File, message: []const u8) bool {
    stdout.writeStreamingAll(io, message) catch |err| {
        failMsg("cannot write the result: {s}", .{@errorName(err)});
        return false;
    };
    return true;
}

fn readErrorText(err: anyerror) []const u8 {
    return switch (err) {
        error.NotFound => "FileNotFound",
        error.SymLink => "symlink is not followed",
        else => @errorName(err),
    };
}

fn readRegularFile(a: Allocator, path: []const u8, follow: bool, max_bytes: usize) ![]u8 {
    const opened = try common.fsx.openRegular(common.fsx.cwd, path, follow);
    defer common.sys.close(opened.fd);
    return try common.fsx.readAll(a, opened.fd, max_bytes);
}

fn readOptionalRegular(a: Allocator, path: []const u8, max_bytes: usize) error{Refused}!?[]u8 {
    if (common.fsx.statAt(common.fsx.cwd, path, false)) |st| {
        if (st.isLink()) {
            failMsg("cannot read {s}: symlink is not followed", .{path});
            return error.Refused;
        }
    } else |_| {}
    const opened = common.fsx.openRegular(common.fsx.cwd, path, false) catch |err| switch (err) {
        error.NotFound => return null,
        else => {
            failMsg("cannot read {s}: {s}", .{ path, readErrorText(err) });
            return error.Refused;
        },
    };
    defer common.sys.close(opened.fd);
    return common.fsx.readAll(a, opened.fd, max_bytes) catch |err| {
        failMsg("cannot read {s}: {s}", .{ path, readErrorText(err) });
        return error.Refused;
    };
}

fn checkDryRunOutputs(out_dir: []const u8, recipe_path: []const u8, provenance_path: []const u8) bool {
    var probe: []const u8 = out_dir;
    while (probe.len > 0 and !std.mem.eql(u8, probe, ".") and !std.mem.eql(u8, probe, "/")) {
        if (common.fsx.statAt(common.fsx.cwd, probe, true)) |st| {
            if (!st.isDir()) {
                failMsg("cannot write {s}: NotDir", .{recipe_path});
                return false;
            }
            break;
        } else |_| {}
        probe = std.fs.path.dirname(probe) orelse break;
    }
    for ([_][]const u8{ recipe_path, provenance_path }) |p| {
        if (common.fsx.statAt(common.fsx.cwd, p, false)) |st| {
            if (st.isLink()) {
                failMsg("cannot read {s}: symlink is not followed", .{p});
                return false;
            }
            if (!st.isReg()) {
                failMsg("cannot read {s}: {s}", .{ p, if (st.isDir()) "IsDir" else "NotRegularFile" });
                return false;
            }
        } else |err| if (err != error.NotFound and err != error.NotDir) {
            failMsg("cannot read {s}: {s}", .{ p, readErrorText(err) });
            return false;
        }
    }
    return true;
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
    var od: Diagnostic = .{};
    const overlay_text = readRegularFile(a, opts.overlay_path, true, 4 * 1024 * 1024) catch |err| {
        failMsg("cannot read {s}: {s}", .{ opts.overlay_path, readErrorText(err) });
        return 2;
    };
    const spec = parseSpec(a, overlay_text, &od) catch |e| switch (e) {
        error.Invalid => {
            const msg = if (od.message.len > 0) od.message else "overlay file is invalid";
            if (od.line > 0)
                failMsg("{s}:{d}: {s}", .{ opts.overlay_path, od.line, msg })
            else
                failMsg("{s}: {s}", .{ opts.overlay_path, msg });
            return 2;
        },
        error.OutOfMemory => return 1,
        else => return 1,
    };
    const base_text = readRegularFile(a, opts.base_path, true, 16 * 1024 * 1024) catch |err| {
        failMsg("cannot read {s}: {s}", .{ opts.base_path, readErrorText(err) });
        return 2;
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
        const existing_recipe = readOptionalRegular(a, recipe_path, 16 * 1024 * 1024) catch return 2;
        defer if (existing_recipe) |buf| a.free(buf);
        const existing_prov = readOptionalRegular(a, provenance_path, 4 * 1024 * 1024) catch return 2;
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
        if (!writeStdout(io, &stdout, message)) return 1;
        return if (up_to_date) 0 else 1;
    }
    if (opts.dry_run) {
        if (!checkDryRunOutputs(out_dir, recipe_path, provenance_path)) return 2;
        const message = std.fmt.allocPrint(a, "would write {s} and {s}\n", .{ recipe_path, provenance_path }) catch return 1;
        if (!writeStdout(io, &stdout, message)) return 1;
        return 0;
    }
    const prev_recipe = readRegularFile(a, recipe_path, false, 16 * 1024 * 1024) catch null;
    defer if (prev_recipe) |buf| a.free(buf);
    var first_missing: ?[]const u8 = null;
    {
        var probe: []const u8 = out_dir;
        while (probe.len > 0 and !std.mem.eql(u8, probe, ".") and !std.mem.eql(u8, probe, "/")) {
            if (common.fsx.statAt(common.fsx.cwd, probe, false)) |_| break else |_| {}
            first_missing = probe;
            probe = std.fs.path.dirname(probe) orelse break;
        }
    }
    common.atomic.makedirs(out_dir) catch |err| {
        failMsg("cannot create {s}: {s}", .{ out_dir, @errorName(err) });
        if (first_missing) |dir| common.fsx.deleteTree(a, common.fsx.cwd, dir) catch {};
        return 1;
    };
    var why: common.atomic.Why = .{};
    defer why.deinit(a);
    if (comptime build_options.test_ops) {
        if (storage.takeWriteErrno()) |e| {
            failMsg("cannot write {s}: {s}", .{ recipe_path, common.sys.describeErrno(e) });
            if (first_missing) |dir| common.fsx.deleteTree(a, common.fsx.cwd, dir) catch {};
            return 1;
        }
    }
    common.atomic.atomicWrite(a, recipe_path, recipe, .{ .mode = 0o644 }, &why) catch |err| {
        failMsg("cannot write {s}: {s}", .{ recipe_path, if (why.msg.len > 0) why.msg else @errorName(err) });
        if (first_missing) |dir| common.fsx.deleteTree(a, common.fsx.cwd, dir) catch {};
        return 1;
    };
    var why_prov: common.atomic.Why = .{};
    defer why_prov.deinit(a);
    common.atomic.atomicWrite(a, provenance_path, provenance, .{ .mode = 0o644 }, &why_prov) catch |err| {
        failMsg("cannot write {s}: {s}", .{ provenance_path, if (why_prov.msg.len > 0) why_prov.msg else @errorName(err) });
        if (prev_recipe) |data| {
            var why_rb: common.atomic.Why = .{};
            defer why_rb.deinit(a);
            common.atomic.atomicWrite(a, recipe_path, data, .{ .mode = 0o644 }, &why_rb) catch {};
        } else {
            common.sys.unlinkat(common.fsx.cwd, recipe_path, 0) catch {};
        }
        if (first_missing) |dir| common.fsx.deleteTree(a, common.fsx.cwd, dir) catch {};
        return 1;
    };
    const message = std.fmt.allocPrint(a, "wrote {s} and {s}\n", .{ recipe_path, provenance_path }) catch return 1;
    if (!writeStdout(io, &stdout, message)) return 1;
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

test "materialize keeps indent, trailing commas and brackets in strings" {
    const Row = struct {
        base: []const u8,
        parameters: []const Parameter = &.{},
        dependencies: []const Dependency = &.{},
        patches: []const Patch = &.{},
        expected: []const u8,
    };
    const params = [_]Parameter{
        .{ .name = "name", .value = "'custom'" },
        .{ .name = "version", .value = "'2.0'" },
    };
    const deps = [_]Dependency{.{ .action = "add", .name = "pkg", .spec = "('pkg', '1.0')" }};
    const patches = [_]Patch{.{ .name = "site", .file = "site.patch" }};
    const rows = [_]Row{
        .{
            .base = "  name = 'demo'   \nversion = '1.0'\r\n",
            .parameters = &params,
            .expected = "  name = 'custom'\nversion = '2.0'\n",
        },
        .{
            .base = "dependencies = [\n    ('zlib', '1.3'),\n]\n",
            .dependencies = &deps,
            .expected = "dependencies = [\n    ('zlib', '1.3'),\n    ('pkg', '1.0'),\n]\n",
        },
        .{
            .base = "patches = [\n    # [unbalanced comment\n    ('only-[one.patch', 1),\n    ('a]b.patch', 1),\n]\n",
            .patches = &patches,
            .expected = "patches = [\n    # [unbalanced comment\n    ('only-[one.patch', 1),\n    ('a]b.patch', 1),\n    ('site', 'site.patch'),\n]\n",
        },
    };
    for (rows) |row| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const spec: Spec = .{
            .base_digest = try sha256Hex(a, row.base),
            .parameters = row.parameters,
            .dependencies = row.dependencies,
            .patches = row.patches,
        };
        var d: Diagnostic = .{};
        const out = try materialize(a, row.base, spec, &d);
        try std.testing.expect(std.mem.indexOf(u8, out, ",,") == null);
        try std.testing.expectEqualStrings(row.expected, out);
    }
}
