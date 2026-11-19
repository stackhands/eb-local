//! Host and container paths that must not leak into a build.
//!
//! `eb-local doctor` reports entries of `PERL5LIB`, `PYTHONPATH`, `R_LIBS*`,
//! `CMAKE_PREFIX_PATH` and `PKG_CONFIG_PATH`, and compiler-wrapper variables,
//! that resolve outside the approved prefixes. It also reports the timezone
//! `/etc/localtime` resolves to, a bind mount of that file, and host library
//! directories a container runtime injected. A build drops the foreign entries
//! only when `build.clear_foreign_prefixes` is set.
const std = @import("std");
const linux = std.os.linux;
const common = @import("zig_common");
const sys = common.sys;
const fsx = common.fsx;
const proc = common.proc;
const Allocator = std.mem.Allocator;

/// Path-list variables doctor inspects, besides every `R_LIBS*`.
pub const path_lists = [_][]const u8{
    "PERL5LIB", "PYTHONPATH", "CMAKE_PREFIX_PATH", "PKG_CONFIG_PATH",
};

/// Compiler variables whose value is a program or a path. `CCACHE_*`,
/// `SCCACHE_*` and `CMAKE_*_COMPILER_LAUNCHER` are recognised by name.
pub const compiler_vars = [_][]const u8{
    "CC",        "CXX",      "FC",        "F77",      "F90",       "F95",       "CPP",
    "OMPI_CC",   "OMPI_CXX", "OMPI_FC",   "OMPI_F77", "MPICH_CC",  "MPICH_CXX", "MPICH_FC",
    "MPICH_F77", "I_MPI_CC", "I_MPI_CXX", "I_MPI_FC", "I_MPI_F77", "I_MPI_F90", "RUSTC_WRAPPER",
};

/// What doctor prints for one finding. The words are in `main.zig`, so a
/// how-to that shows a line can be checked against that format.
pub const Code = enum {
    none,
    list_keep,
    list_drop,
    wrap_keep,
    wrap_drop,
    timezone,
    timezone_bind,
    host_lib,
    host_none,
};

/// One reported path: `name` is the variable, `path` the entry or target.
pub const Finding = struct {
    code: Code,
    name: []const u8 = "",
    path: []const u8 = "",
};

const install_vars = [_][]const u8{
    "EESSI_USER_INSTALL", "EESSI_PROJECT_INSTALL", "EESSI_SITE_INSTALL", "EESSI_CVMFS_INSTALL",
};

/// Prefixes a path may sit under: the EESSI repository, the install prefix,
/// the four EESSI install variables, `extra` (the site's approved prefixes),
/// eb-local's RPATH wrapper directory and its cache.
pub fn approvedPrefixes(a: Allocator, env: *const std.process.Environ.Map, extra: []const []const u8, install_prefix: []const u8) Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    try addPrefix(a, &list, "/cvmfs/software.eessi.io");
    if (env.get("EESSI_CVMFS_REPO")) |p| try addPrefix(a, &list, p);
    try addPrefix(a, &list, install_prefix);
    for (install_vars) |name| if (env.get(name)) |p| try addPrefix(a, &list, p);
    for (extra) |p| try addPrefix(a, &list, p);
    if (env.get("EB_LOCAL_RPATH_WRAPPERS")) |p| try addPrefix(a, &list, p);
    const xdg = if (env.get("XDG_CACHE_HOME")) |c| if (c.len > 1 and c[0] == '/') c else null else null;
    if (xdg) |cache| {
        try addPrefix(a, &list, try std.fs.path.join(a, &.{ cache, "eb-local" }));
    } else if (env.get("HOME")) |home| if (home.len > 1 and home[0] == '/') {
        const cache = try std.fs.path.join(a, &.{ home, ".cache" });
        try addPrefix(a, &list, try std.fs.path.join(a, &.{ cache, "eb-local" }));
    };
    return list.items;
}

fn addPrefix(a: Allocator, list: *std.ArrayList([]const u8), path: []const u8) Allocator.Error!void {
    const norm = lexical(a, path, false) orelse return;
    try pushUnique(a, list, norm);
    if (resolve(a, norm)) |real| try pushUnique(a, list, real);
}

fn pushUnique(a: Allocator, list: *std.ArrayList([]const u8), path: []const u8) Allocator.Error!void {
    for (list.items) |old| if (std.mem.eql(u8, old, path)) return;
    try list.append(a, path);
}

/// An absolute path with `.` and empty parts removed. `..` is refused when
/// `fold` is false, so a prefix cannot be escaped. `fold` collapses `..`
/// for a symlink target that is only displayed.
fn lexical(a: Allocator, path: []const u8, fold: bool) ?[]const u8 {
    if (path.len == 0 or path[0] != '/') return null;
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (!fold or parts.items.len == 0) return null;
            _ = parts.pop();
            continue;
        }
        parts.append(a, part) catch return null;
    }
    if (parts.items.len == 0) return null;
    const body = std.mem.join(a, "/", parts.items) catch return null;
    return std.fmt.allocPrint(a, "/{s}", .{body}) catch null;
}

/// Resolve existing components with realpath while keeping any non-existent
/// suffix, falling back to `norm` when no component exists on disk.
/// Stops rather than climbing past an unresolvable symlink.
fn resolve(a: Allocator, path: []const u8) ?[]const u8 {
    const norm = lexical(a, path, false) orelse return null;
    var cur: []const u8 = norm;
    var buf: [sys.path_max]u8 = undefined;
    while (cur.len > 1) {
        if (fsx.realpath(fsx.cwd, cur, &buf)) |real| {
            const suffix = norm[cur.len..];
            const joined = if (suffix.len == 0)
                real
            else if (std.mem.eql(u8, real, "/"))
                suffix
            else
                std.fmt.allocPrint(a, "{s}{s}", .{ real, suffix }) catch return null;
            return lexical(a, joined, false);
        } else |_| {
            if (fsx.statAt(fsx.cwd, cur, false)) |st| {
                if (st.isLink()) return null;
            } else |_| {}
        }
        cur = std.fs.path.dirname(cur) orelse break;
    }
    return norm;
}

fn under(path: []const u8, prefix: []const u8) bool {
    if (std.mem.eql(u8, path, prefix)) return true;
    return path.len > prefix.len and path[prefix.len] == '/' and std.mem.startsWith(u8, path, prefix);
}

fn inside(a: Allocator, path: []const u8, prefixes: []const []const u8) bool {
    const real_path = resolve(a, path) orelse return false;
    for (prefixes) |p| {
        const real_p = resolve(a, p) orelse lexical(a, p, false) orelse continue;
        if (under(real_path, real_p)) return true;
    }
    return false;
}

fn firstToken(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t");
    const cut = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    return trimmed[0..cut];
}

/// The program a compiler-wrapper variable names. An absolute path may
/// contain spaces; a following word is a flag only when it starts with `-`.
fn commandPath(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0 or trimmed[0] != '/') return firstToken(trimmed);
    if (std.mem.indexOfAny(u8, trimmed, " \t")) |i| {
        const rest = std.mem.trim(u8, trimmed[i..], " \t");
        if (rest.len > 0 and rest[0] == '-') return trimmed[0..i];
    }
    return trimmed;
}

const Split = struct { kept: []const []const u8, foreign: []const []const u8 };

/// A path-list entry is approved only when it is absolute and lies inside an
/// approved prefix. A relative entry, and an empty one, is foreign. The site
/// file's approved prefixes are absolute paths, and a build runs in its own
/// directory, so these entries stay unresolved.
fn splitList(a: Allocator, value: []const u8, prefixes: []const []const u8) Allocator.Error!Split {
    var kept: std.ArrayList([]const u8) = .empty;
    var foreign: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, value, ':');
    while (it.next()) |entry| {
        if (entry.len == 0 or entry[0] != '/') {
            try foreign.append(a, entry);
            continue;
        }
        if (inside(a, entry, prefixes)) try kept.append(a, entry) else try foreign.append(a, entry);
    }
    return .{ .kept = kept.items, .foreign = foreign.items };
}

fn isWrapperName(name: []const u8) bool {
    for (compiler_vars) |v| if (std.mem.eql(u8, name, v)) return true;
    if (std.mem.startsWith(u8, name, "CCACHE_") or std.mem.startsWith(u8, name, "SCCACHE_")) return true;
    return std.mem.startsWith(u8, name, "CMAKE_") and std.mem.endsWith(u8, name, "_COMPILER_LAUNCHER");
}

fn isRlibs(name: []const u8) bool {
    return std.mem.eql(u8, name, "R_LIBS") or std.mem.startsWith(u8, name, "R_LIBS_");
}

fn sortedKeys(a: Allocator, env: *const std.process.Environ.Map, pred: *const fn ([]const u8) bool) Allocator.Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (env.keys()) |k| if (pred(k)) try names.append(a, k);
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return names.items;
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn rlibsName(name: []const u8) bool {
    return isRlibs(name);
}

fn wrapperName(name: []const u8) bool {
    return isWrapperName(name);
}

/// Findings for this shell. `clear` selects the words doctor uses; it does
/// not change the environment.
pub fn scan(a: Allocator, env: *const std.process.Environ.Map, prefixes: []const []const u8, clear: bool, mountinfo: []const u8) Allocator.Error![]Finding {
    var out: std.ArrayList(Finding) = .empty;
    var foreign_any = false;
    for (path_lists) |name| if (env.get(name)) |value| {
        if (value.len == 0) continue;
        if (try appendList(a, &out, name, value, prefixes, clear)) foreign_any = true;
    };
    for (try sortedKeys(a, env, rlibsName)) |name| if (env.get(name)) |value| {
        if (value.len == 0) continue;
        if (try appendList(a, &out, name, value, prefixes, clear)) foreign_any = true;
    };
    for (try sortedKeys(a, env, wrapperName)) |name| if (env.get(name)) |value| {
        if (value.len == 0) continue;
        const token = commandPath(value);
        if (token.len == 0) continue;
        const path = if (std.mem.indexOfScalar(u8, token, '/') != null)
            token
        else
            (try proc.which(a, token, env.get("PATH") orelse "/usr/bin:/bin")) orelse continue;
        if (inside(a, path, prefixes)) continue;
        foreign_any = true;
        try out.append(a, .{ .code = if (clear) .wrap_drop else .wrap_keep, .name = name, .path = path });
    };
    if (!foreign_any) try out.append(a, .{ .code = .none });
    try out.append(a, .{ .code = .timezone, .path = timezoneTarget(a) });
    if (bindSource(a, mountinfo)) |src| try out.append(a, .{ .code = .timezone_bind, .path = src });
    const libs = try hostLibs(a, env, mountinfo);
    if (libs.len == 0) {
        try out.append(a, .{ .code = .host_none });
    } else for (libs) |dir| try out.append(a, .{ .code = .host_lib, .path = dir });
    return out.items;
}

fn appendList(a: Allocator, out: *std.ArrayList(Finding), name: []const u8, value: []const u8, prefixes: []const []const u8, clear: bool) Allocator.Error!bool {
    const split = try splitList(a, value, prefixes);
    if (split.foreign.len == 0) return false;
    const code: Code = if (clear) .list_drop else .list_keep;
    for (split.foreign) |entry| {
        // The locked report template prints the entry as-is. An empty entry
        // is shown as '', the same quotes a shell uses for an empty word.
        const shown = if (entry.len == 0) "''" else entry;
        try out.append(a, .{ .code = code, .name = name, .path = shown });
    }
    return true;
}

/// Drop foreign entries from `env`. An empty path list is removed. A
/// compiler-wrapper variable that resolves outside the prefixes is removed.
/// Approved entries stay. Nothing is added.
pub fn scrub(a: Allocator, env: *std.process.Environ.Map, prefixes: []const []const u8) Allocator.Error!void {
    for (path_lists) |name| try scrubList(a, env, name, prefixes);
    const rlibs = try sortedKeys(a, env, rlibsName);
    for (rlibs) |name| try scrubList(a, env, name, prefixes);
    const wrappers = try sortedKeys(a, env, wrapperName);
    for (wrappers) |name| {
        const value = env.get(name) orelse continue;
        const token = commandPath(value);
        if (token.len == 0) continue;
        const path = if (std.mem.indexOfScalar(u8, token, '/') != null)
            token
        else
            (try proc.which(a, token, env.get("PATH") orelse "/usr/bin:/bin")) orelse continue;
        if (!inside(a, path, prefixes)) _ = env.swapRemove(name);
    }
}

fn scrubList(a: Allocator, env: *std.process.Environ.Map, name: []const u8, prefixes: []const []const u8) Allocator.Error!void {
    const value = env.get(name) orelse return;
    const split = try splitList(a, value, prefixes);
    if (split.foreign.len == 0) return;
    if (split.kept.len == 0) {
        _ = env.swapRemove(name);
        return;
    }
    try env.put(name, try std.mem.join(a, ":", split.kept));
}

fn timezoneTarget(a: Allocator) []const u8 {
    var zb: [sys.path_max:0]u8 = undefined;
    const zp = sys.z(&zb, "/etc/localtime") catch return "(unreadable)";
    var buf: [sys.path_max]u8 = undefined;
    const n: isize = @bitCast(linux.readlinkat(linux.AT.FDCWD, zp.ptr, &buf, buf.len));
    if (n <= 0 or n >= buf.len) {
        if (fsx.statAt(fsx.cwd, "/etc/localtime", false)) |_| return "/etc/localtime" else |_| return "(unreadable)";
    }
    const raw = buf[0..@intCast(n)];
    if (raw.len > 0 and raw[0] == '/') return a.dupe(u8, raw) catch "(unreadable)";
    const joined = std.fs.path.join(a, &.{ "/etc", raw }) catch return a.dupe(u8, raw) catch "(unreadable)";
    return lexical(a, joined, true) orelse a.dupe(u8, raw) catch "(unreadable)";
}

fn unescape(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\' and i + 3 < text.len) {
            const oct = std.fmt.parseInt(u8, text[i + 1 .. i + 4], 8) catch {
                try out.append(a, text[i]);
                continue;
            };
            try out.append(a, oct);
            i += 3;
            continue;
        }
        try out.append(a, text[i]);
    }
    return out.items;
}

const MountPoint = struct { mount: []const u8, root: []const u8, source: []const u8 };

fn mounts(a: Allocator, mountinfo: []const u8) Allocator.Error![]const MountPoint {
    var out: std.ArrayList(MountPoint) = .empty;
    var lines = std.mem.splitScalar(u8, mountinfo, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const sep = std.mem.indexOf(u8, line, " - ") orelse continue;
        var left = std.mem.tokenizeScalar(u8, line[0..sep], ' ');
        var fields: [5][]const u8 = undefined;
        var n: usize = 0;
        while (n < 5) : (n += 1) fields[n] = left.next() orelse break;
        if (n < 5) continue;
        var right = std.mem.tokenizeScalar(u8, line[sep + 3 ..], ' ');
        _ = right.next() orelse continue;
        const source = right.next() orelse continue;
        try out.append(a, .{
            .mount = try unescape(a, fields[4]),
            .root = try unescape(a, fields[3]),
            .source = try unescape(a, source),
        });
    }
    return out.items;
}

fn bindSource(a: Allocator, mountinfo: []const u8) ?[]const u8 {
    const list = mounts(a, mountinfo) catch return null;
    var best: ?[]const u8 = null;
    for (list) |m| if (std.mem.eql(u8, m.mount, "/etc/localtime")) {
        best = if (m.root.len > 1) m.root else m.source;
    };
    return best;
}

fn hostLibs(a: Allocator, env: *const std.process.Environ.Map, mountinfo: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (dirNonEmpty(a, "/.singularity.d/libs")) try pushUnique(a, &out, "/.singularity.d/libs");
    const list = try mounts(a, mountinfo);
    for (list) |m| {
        if (std.mem.eql(u8, m.mount, "/.singularity.d/libs") or std.mem.startsWith(u8, m.mount, "/.singularity.d/libs/")) {
            try pushUnique(a, &out, m.mount);
            continue;
        }
        if (std.mem.indexOf(u8, std.fs.path.basename(m.mount), ".so") != null) {
            const parent = std.fs.path.dirname(m.mount) orelse m.mount;
            try pushUnique(a, &out, parent);
        }
    }
    for ([_][]const u8{ "APPTAINER_CONTAINLIBS", "SINGULARITY_CONTAINLIBS" }) |name| {
        const value = env.get(name) orelse continue;
        var it = std.mem.tokenizeAny(u8, value, ":, \t");
        while (it.next()) |entry| {
            if (entry.len == 0 or entry[0] != '/') continue;
            if (std.mem.indexOf(u8, std.fs.path.basename(entry), ".so") != null) {
                try pushUnique(a, &out, std.fs.path.dirname(entry) orelse entry);
            } else try pushUnique(a, &out, entry);
        }
    }
    return out.items;
}

fn dirNonEmpty(a: Allocator, path: []const u8) bool {
    const fd = fsx.openDir(fsx.cwd, path, false) catch return false;
    defer sys.close(fd);
    var it = fsx.DirIter.init(a, fd) catch return false;
    defer it.deinit(a);
    return (it.next() catch null) != null;
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

const Scratch = struct {
    arena: *std.heap.ArenaAllocator,
    env: std.process.Environ.Map,

    fn init(pairs: []const [2][]const u8) !*Scratch {
        const s = try testing.allocator.create(Scratch);
        s.arena = try testing.allocator.create(std.heap.ArenaAllocator);
        s.arena.* = std.heap.ArenaAllocator.init(testing.allocator);
        s.env = std.process.Environ.Map.init(s.arena.allocator());
        for (pairs) |p| try s.env.put(p[0], p[1]);
        return s;
    }

    fn deinit(s: *Scratch) void {
        s.arena.deinit();
        testing.allocator.destroy(s.arena);
        testing.allocator.destroy(s);
    }

    fn allocator(s: *Scratch) Allocator {
        return s.arena.allocator();
    }
};

test "a foreign path list entry is named and an approved one is kept" {
    var s = try Scratch.init(&.{
        .{ "PERL5LIB", "/opt/host/perl5:/cvmfs/software.eessi.io/versions/2026.06/compat" },
        .{ "PYTHONPATH", "/cvmfs/software.eessi.io/versions/2026.06/software" },
        .{ "R_LIBS_USER", "/opt/host/R/library" },
    });
    defer s.deinit();
    const a = s.allocator();
    const prefixes = try approvedPrefixes(a, &s.env, &.{}, "/home/u/eessi");
    const found = try scan(a, &s.env, prefixes, false, "");
    var perl = false;
    var rlibs = false;
    var python = false;
    for (found) |f| switch (f.code) {
        .list_keep => {
            if (std.mem.eql(u8, f.name, "PERL5LIB")) {
                perl = true;
                try testing.expectEqualStrings("/opt/host/perl5", f.path);
            }
            if (std.mem.eql(u8, f.name, "R_LIBS_USER")) rlibs = true;
        },
        .none => python = true,
        else => {},
    };
    try testing.expect(perl and rlibs);
    try testing.expect(!python);

    try scrub(a, &s.env, prefixes);
    try testing.expectEqualStrings("/cvmfs/software.eessi.io/versions/2026.06/compat", s.env.get("PERL5LIB").?);
    try testing.expect(s.env.get("R_LIBS_USER") == null);
    try testing.expect(s.env.get("PYTHONPATH") != null);
}

test "a path that climbs out of a prefix is foreign" {
    var s = try Scratch.init(&.{.{ "PKG_CONFIG_PATH", "/cvmfs/software.eessi.io/../opt/host/pkgconfig" }});
    defer s.deinit();
    const a = s.allocator();
    const prefixes = try approvedPrefixes(a, &s.env, &.{"/site/software"}, "/home/u/eessi");
    const found = try scan(a, &s.env, prefixes, true, "");
    var drop = false;
    for (found) |f| {
        if (f.code == .list_drop and std.mem.eql(u8, f.name, "PKG_CONFIG_PATH")) drop = true;
    }
    try testing.expect(drop);
    try testing.expect(inside(a, "/site/software/lib/pkgconfig", prefixes));
}

test "a compiler wrapper outside the prefixes is unset and one inside stays" {
    var s = try Scratch.init(&.{
        .{ "CC", "/usr/bin/gcc" },
        .{ "CXX", "/cvmfs/software.eessi.io/versions/2026.06/compat/bin/g++" },
        .{ "CMAKE_C_COMPILER_LAUNCHER", "/opt/host/ccache" },
        .{ "CCACHE_DIR", "/var/tmp/ccache" },
        .{ "PATH", "/usr/bin:/bin" },
    });
    defer s.deinit();
    const a = s.allocator();
    const prefixes = try approvedPrefixes(a, &s.env, &.{}, "/home/u/eessi");
    const found = try scan(a, &s.env, prefixes, false, "");
    var cc = false;
    var launcher = false;
    var cache = false;
    var cxx = false;
    for (found) |f| if (f.code == .wrap_keep) {
        if (std.mem.eql(u8, f.name, "CC")) cc = true;
        if (std.mem.eql(u8, f.name, "CMAKE_C_COMPILER_LAUNCHER")) launcher = true;
        if (std.mem.eql(u8, f.name, "CCACHE_DIR")) cache = true;
        if (std.mem.eql(u8, f.name, "CXX")) cxx = true;
    };
    try testing.expect(cc and launcher and cache);
    try testing.expect(!cxx);
    try scrub(a, &s.env, prefixes);
    try testing.expect(s.env.get("CC") == null);
    try testing.expect(s.env.get("CXX") != null);
    try testing.expect(s.env.get("OMPI_MCA_PML") == null);
}

test "a bind of /etc/localtime and an injected library directory are sentinels" {
    const info =
        \\1 0 0:1 / / rw - ext4 /dev/root rw
        \\2 1 8:1 /usr/share/zoneinfo/UTC /etc/localtime rw - ext4 /dev/sda1 rw
        \\3 1 8:1 /opt/host/lib /usr/lib/libcuda.so.1 rw - ext4 /dev/sda1 rw
        \\
    ;
    var s = try Scratch.init(&.{.{ "APPTAINER_CONTAINLIBS", "/opt/host/cuda/libcuda.so,/site/extra" }});
    defer s.deinit();
    const found = try scan(s.allocator(), &s.env, &.{}, false, info);
    var zone = false;
    var bind = false;
    var cuda = false;
    var extra = false;
    for (found) |f| switch (f.code) {
        .timezone_bind => {
            bind = true;
            try testing.expectEqualStrings("/usr/share/zoneinfo/UTC", f.path);
        },
        .timezone => zone = true,
        .host_lib => {
            if (std.mem.eql(u8, f.path, "/usr/lib")) cuda = true;
            if (std.mem.eql(u8, f.path, "/opt/host/cuda")) extra = true;
        },
        else => {},
    };
    try testing.expect(zone and bind and cuda and extra);
}

test "an empty shell has nothing foreign and no injected library directory" {
    var s = try Scratch.init(&.{});
    defer s.deinit();
    const found = try scan(s.allocator(), &s.env, &.{}, false, "1 0 0:1 / / rw - ext4 /dev/root rw\n");
    var none = false;
    var host = false;
    var bind = false;
    for (found) |f| switch (f.code) {
        .none => none = true,
        .host_none => host = true,
        .timezone_bind => bind = true,
        else => {},
    };
    try testing.expect(none and host);
    try testing.expect(!bind);
}

test "XDG_CACHE_HOME eb-local cache is approved even when HOME is unset" {
    var s = try Scratch.init(&.{
        .{ "XDG_CACHE_HOME", "/xdg/cache" },
        .{ "CC", "/xdg/cache/eb-local/rpath-1234/gcc" },
    });
    defer s.deinit();
    const a = s.allocator();
    const prefixes = try approvedPrefixes(a, &s.env, &.{}, "/home/u/eessi");
    try testing.expect(inside(a, "/xdg/cache/eb-local/rpath-1234/gcc", prefixes));
    try scrub(a, &s.env, prefixes);
    try testing.expectEqualStrings("/xdg/cache/eb-local/rpath-1234/gcc", s.env.get("CC").?);
}

test "a symlink inside an approved prefix pointing outside is rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/foreign-sym-{d}", .{ cwd, linux.getpid() });
    const approved = try std.fs.path.join(a, &.{ root, "approved" });
    const real_sub = try std.fs.path.join(a, &.{ approved, "real" });
    const outside = try std.fs.path.join(a, &.{ root, "outside" });
    try common.atomic.makedirs(real_sub);
    try common.atomic.makedirs(outside);
    defer fsx.deleteTree(a, fsx.cwd, root) catch {};

    const escape = try std.fs.path.join(a, &.{ approved, "ext" });
    var z_out: [sys.path_max:0]u8 = undefined;
    var z_esc: [sys.path_max:0]u8 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.symlinkat((try sys.z(&z_out, outside)).ptr, linux.AT.FDCWD, (try sys.z(&z_esc, escape)).ptr)));

    var s = try Scratch.init(&.{
        .{ "PYTHONPATH", try std.fmt.allocPrint(a, "{s}:{s}", .{ escape, real_sub }) },
    });
    defer s.deinit();
    const prefixes = try approvedPrefixes(a, &s.env, &.{}, approved);
    try testing.expect(!inside(a, escape, prefixes));
    try testing.expect(!inside(a, try std.fs.path.join(a, &.{ escape, "sub" }), prefixes));
    try testing.expect(inside(a, real_sub, prefixes));
    try scrub(a, &s.env, prefixes);
    try testing.expectEqualStrings(real_sub, s.env.get("PYTHONPATH").?);
}

test "an approved symlink prefix keeps its contents and rejects escapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/foreign-sym-prefix-{d}", .{ cwd, linux.getpid() });
    const real_target = try std.fs.path.join(a, &.{ root, "target" });
    const real_lib = try std.fs.path.join(a, &.{ real_target, "lib" });
    const outside = try std.fs.path.join(a, &.{ root, "outside" });
    try common.atomic.makedirs(real_lib);
    try common.atomic.makedirs(outside);
    defer fsx.deleteTree(a, fsx.cwd, root) catch {};

    const sym_prefix = try std.fs.path.join(a, &.{ root, "sym_prefix" });
    var z_target: [sys.path_max:0]u8 = undefined;
    var z_sym: [sys.path_max:0]u8 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.symlinkat((try sys.z(&z_target, real_target)).ptr, linux.AT.FDCWD, (try sys.z(&z_sym, sym_prefix)).ptr)));

    const escape = try std.fs.path.join(a, &.{ real_target, "ext" });
    var z_out: [sys.path_max:0]u8 = undefined;
    var z_esc: [sys.path_max:0]u8 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.symlinkat((try sys.z(&z_out, outside)).ptr, linux.AT.FDCWD, (try sys.z(&z_esc, escape)).ptr)));

    const sym_lib = try std.fs.path.join(a, &.{ sym_prefix, "lib" });
    const sym_future = try std.fs.path.join(a, &.{ sym_prefix, "future" });
    const sym_escape = try std.fs.path.join(a, &.{ sym_prefix, "ext" });

    // Direct prefixes slice containing the symlinked prefix itself.
    const direct = [_][]const u8{sym_prefix};
    try testing.expect(inside(a, sym_lib, &direct));
    try testing.expect(inside(a, real_lib, &direct));
    try testing.expect(inside(a, sym_future, &direct));
    try testing.expect(!inside(a, sym_escape, &direct));

    // A non-existent install prefix under a symlinked parent also resolves through the parent.
    const future_under_sym = try std.fs.path.join(a, &.{ sym_prefix, "nested", "eessi" });
    const future_under_real = try std.fs.path.join(a, &.{ real_target, "nested", "eessi", "lib" });
    var s = try Scratch.init(&.{
        .{ "PYTHONPATH", try std.fmt.allocPrint(a, "{s}:{s}:{s}", .{ sym_lib, sym_escape, future_under_real }) },
    });
    defer s.deinit();
    const prefixes = try approvedPrefixes(a, &s.env, &.{sym_prefix}, future_under_sym);
    try testing.expect(inside(a, sym_lib, prefixes));
    try testing.expect(inside(a, future_under_real, prefixes));
    try testing.expect(!inside(a, sym_escape, prefixes));

    const found = try scan(a, &s.env, prefixes, false, "");
    var kept_warn = false;
    for (found) |f| if (f.code == .list_keep) {
        try testing.expectEqualStrings(sym_escape, f.path);
        kept_warn = true;
    };
    try testing.expect(kept_warn);

    try scrub(a, &s.env, prefixes);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}:{s}", .{ sym_lib, future_under_real }), s.env.get("PYTHONPATH").?);
}

test "bindSource uses the last covering mount entry for /etc/localtime" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const mountinfo =
        \\80 1 0:80 /usr/share/zoneinfo/UTC /etc/localtime ro,relatime - tmpfs tmpfs rw
        \\81 80 0:81 /usr/share/zoneinfo/Europe/Amsterdam /etc/localtime ro,relatime - tmpfs tmpfs rw
        \\
    ;
    const src = bindSource(arena.allocator(), mountinfo) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("/usr/share/zoneinfo/Europe/Amsterdam", src);
}
