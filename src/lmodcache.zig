//! `eb-local lmod-cache`: write the spider cache Lmod trusts.
//!
//! Lmod treats a timestamp newer than `spiderT.lua` as a stale cache and
//! then ignores the modules that file names. The cache is written only
//! after `spider` succeeds, and the timestamp is then set one second
//! older than the cache file.
const std = @import("std");
const linux = std.os.linux;
const common = @import("zig_common");
const fsx = common.fsx;
const sys = common.sys;
const config = @import("config.zig");

const tool = "eb-local";

/// One CPU target tree to refresh when walking `--prefix`.
pub const Target = struct {
    archdir: []const u8,
    modulepath: []const u8,
    cache_dir: []const u8,
    timestamp: []const u8,
};

/// Names the directories, cache paths and spider command for `lmod-cache`.
pub const Options = struct {
    modulepath: []const u8 = "",
    cache_dir: []const u8 = "",
    timestamp: []const u8 = "",
    /// Empty means the program `spider` on `PATH`.
    spider: []const u8 = "",
    /// Walk `software/…/<cpu>/modules/all` when set (absolute).
    prefix: []const u8 = "",
    /// When set with `--prefix`, only `versions/<VER>/software`.
    eessi_version: []const u8 = "",
    /// Path to Lmod's `update_lmod_system_cache_files`; resolved from `prefix` when empty.
    update_cmd: []const u8 = "",
    dry_run: bool = false,
    verify: bool = false,
};

/// Directories in a colon-separated module path, empty segments dropped.
pub fn moduleDirs(a: std.mem.Allocator, spec: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, spec, ':');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        try list.append(a, part);
    }
    return try list.toOwnedSlice(a);
}

/// `spider -o spiderT` and one argument per module directory.
pub fn spiderArgv(a: std.mem.Allocator, spider: []const u8, dirs: []const []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    try list.append(a, spider);
    try list.append(a, "-o");
    try list.append(a, "spiderT");
    for (dirs) |dir| try list.append(a, dir);
    return try list.toOwnedSlice(a);
}

/// One second before the cache file, which is what makes Lmod trust it.
pub fn olderThan(cache: std.Io.Timestamp) std.Io.Timestamp {
    return cache.subDuration(.{ .nanoseconds = std.time.ns_per_s });
}

fn fail(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(tool ++ ": " ++ fmt ++ "\n", args);
}

fn absolute(path: []const u8) bool {
    return std.fs.path.isAbsolute(path);
}

const walk_max = 5;
const accel_walk_max = 3;

fn isDir(path: []const u8) bool {
    return if (fsx.statAt(fsx.cwd, path, true)) |st| st.isDir() else |_| false;
}

fn dirHasAll(base: []const u8) bool {
    const all = std.fs.path.join(std.heap.page_allocator, &.{ base, "modules", "all" }) catch return false;
    defer std.heap.page_allocator.free(all);
    return isDir(all);
}

/// Colon-separated paths for `archdir`, with accelerator trees prepended like EESSI's script.
pub fn modulepathForArch(a: std.mem.Allocator, archdir: []const u8, accel_alls: []const []const u8) ![]const u8 {
    const main_all = try std.fs.path.join(a, &.{ archdir, "modules", "all" });
    var parts: std.ArrayList([]const u8) = .empty;
    for (accel_alls) |p| try parts.append(a, p);
    try parts.append(a, main_all);
    const joined = try std.mem.join(a, ":", parts.items);
    a.free(main_all);
    parts.deinit(a);
    return joined;
}

fn findAccelModuleAll(a: std.mem.Allocator, root: []const u8, depth: usize, out: *std.ArrayList([]const u8)) !void {
    if (depth > accel_walk_max) return;
    const fd = fsx.openDir(fsx.cwd, root, false) catch return;
    defer sys.close(fd);
    var it = fsx.DirIter.init(a, fd) catch return;
    defer it.deinit(a);
    while (it.next() catch null) |e| {
        if (e.type != fsx.DT.DIR) continue;
        if (std.mem.eql(u8, e.name, "modules")) {
            const all = try std.fs.path.join(a, &.{ root, e.name, "all" });
            defer a.free(all);
            if (isDir(all)) try out.append(a, try a.dupe(u8, all));
            continue;
        }
        const child = try std.fs.path.join(a, &.{ root, e.name });
        defer a.free(child);
        try findAccelModuleAll(a, child, depth + 1, out);
    }
}

fn findArchdirs(a: std.mem.Allocator, root: []const u8, depth: usize, out: *std.ArrayList([]const u8)) !void {
    if (depth > walk_max) return;
    const fd = fsx.openDir(fsx.cwd, root, false) catch return;
    defer sys.close(fd);
    var it = fsx.DirIter.init(a, fd) catch return;
    defer it.deinit(a);
    while (it.next() catch null) |e| {
        if (e.type != fsx.DT.DIR) continue;
        if (std.mem.eql(u8, e.name, "modules")) {
            const archdir = root;
            if (!dirHasAll(archdir)) continue;
            var duped = false;
            for (out.items) |existing| {
                if (std.mem.eql(u8, existing, archdir)) {
                    duped = true;
                    break;
                }
            }
            if (!duped) try out.append(a, try a.dupe(u8, archdir));
            continue;
        }
        const child = try std.fs.path.join(a, &.{ root, e.name });
        defer a.free(child);
        try findArchdirs(a, child, depth + 1, out);
    }
}

fn lessThanStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn softwareRoots(a: std.mem.Allocator, prefix: []const u8, version: []const u8) ![]const []const u8 {
    const versions = try std.fs.path.join(a, &.{ prefix, "versions" });
    defer a.free(versions);
    var roots: std.ArrayList([]const u8) = .empty;
    if (isDir(versions)) {
        if (version.len > 0) {
            const one = try std.fs.path.join(a, &.{ versions, version, "software" });
            if (isDir(one)) try roots.append(a, one);
            return try roots.toOwnedSlice(a);
        }
        const fd = fsx.openDir(fsx.cwd, versions, false) catch return try roots.toOwnedSlice(a);
        defer sys.close(fd);
        var it = fsx.DirIter.init(a, fd) catch return try roots.toOwnedSlice(a);
        defer it.deinit(a);
        while (it.next() catch null) |e| {
            if (e.type != fsx.DT.DIR) continue;
            const sw = try std.fs.path.join(a, &.{ versions, e.name, "software" });
            if (isDir(sw)) try roots.append(a, sw);
        }
        return try roots.toOwnedSlice(a);
    }
    const direct = try std.fs.path.join(a, &.{ prefix, "software" });
    if (isDir(direct)) {
        try roots.append(a, direct);
        return try roots.toOwnedSlice(a);
    }
    try roots.append(a, try a.dupe(u8, prefix));
    return try roots.toOwnedSlice(a);
}

/// Discover CPU targets under `prefix`, matching EESSI's `update_lmod_caches.sh` layout.
pub fn discoverTargets(a: std.mem.Allocator, opts: Options) ![]Target {
    var archdirs: std.ArrayList([]const u8) = .empty;
    const roots = try softwareRoots(a, opts.prefix, opts.eessi_version);
    defer {
        for (roots) |r| a.free(r);
        a.free(roots);
    }
    for (roots) |sw| {
        try findArchdirs(a, sw, 0, &archdirs);
    }
    std.mem.sort([]const u8, archdirs.items, {}, lessThanStr);
    var targets: std.ArrayList(Target) = .empty;
    for (archdirs.items) |archdir| {
        var accel: std.ArrayList([]const u8) = .empty;
        const accel_root = try std.fs.path.join(a, &.{ archdir, "accel" });
        defer a.free(accel_root);
        if (isDir(accel_root)) try findAccelModuleAll(a, accel_root, 0, &accel);
        std.mem.sort([]const u8, accel.items, {}, lessThanStr);
        const modulepath = try modulepathForArch(a, archdir, accel.items);
        for (accel.items) |p| a.free(p);
        accel.deinit(a);
        const cache_dir = try std.fs.path.join(a, &.{ archdir, ".lmod", "cache" });
        const timestamp = try std.fs.path.join(a, &.{ cache_dir, "timestamp" });
        try targets.append(a, .{
            .archdir = try a.dupe(u8, archdir),
            .modulepath = modulepath,
            .cache_dir = cache_dir,
            .timestamp = timestamp,
        });
    }
    for (archdirs.items) |d| a.free(d);
    archdirs.deinit(a);
    return try targets.toOwnedSlice(a);
}

fn nativeMachine(buf: *[64]u8) []const u8 {
    var u: linux.utsname = undefined;
    _ = linux.uname(&u);
    const name = std.mem.sliceTo(&u.machine, 0);
    @memcpy(buf[0..name.len], name);
    return buf[0..name.len];
}

fn defaultUpdateCmd(a: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    var machine_buf: [64]u8 = undefined;
    const m = nativeMachine(&machine_buf);
    const path = try std.fs.path.join(a, &.{
        prefix,
        "compat",
        "linux",
        m,
        "usr/share/Lmod/libexec/update_lmod_system_cache_files",
    });
    if (fsx.statAt(fsx.cwd, path, false)) |_| return path else |_| return error.MissingUpdateCmd;
}

fn updateArgv(a: std.mem.Allocator, cmd: []const u8, cache_dir: []const u8, modulepath: []const u8) ![]const []const u8 {
    const timestamp = try std.fs.path.join(a, &.{ cache_dir, "timestamp" });
    const argv = try a.dupe([]const u8, &.{ cmd, "-d", cache_dir, "-t", timestamp, modulepath });
    return argv;
}

/// Run Lmod's `update_lmod_system_cache_files` for one target.
pub fn runUpdate(io: std.Io, a: std.mem.Allocator, update_cmd: []const u8, target: Target) u8 {
    const argv = updateArgv(a, update_cmd, target.cache_dir, target.modulepath) catch return 1;
    defer {
        a.free(argv[4]);
        a.free(argv);
    }
    const ran = std.process.run(a, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| {
        fail("cannot run {s}: {s}", .{ update_cmd, @errorName(err) });
        return 127;
    };
    if (!ran.term.success()) {
        const err_text = std.mem.trim(u8, ran.stderr, " \t\r\n");
        if (err_text.len > 0) std.debug.print("{s}\n", .{err_text});
        const code: u8 = switch (ran.term) {
            .exited => |exited| if (exited == 0) 1 else exited,
            else => 1,
        };
        fail("updating the Lmod cache failed for {s} using MODULEPATH: {s}", .{ target.archdir, target.modulepath });
        return code;
    }
    if (std.mem.trim(u8, ran.stdout, " \t\r\n").len > 0) {
        var out = std.Io.File.stdout();
        out.writeStreamingAll(io, ran.stdout) catch {};
    }
    var line: std.ArrayList(u8) = .empty;
    line.print(a, "updated the Lmod cache for {s} using MODULEPATH: {s}\n", .{ target.archdir, target.modulepath }) catch return 1;
    var out = std.Io.File.stdout();
    out.writeStreamingAll(io, line.items) catch |err| {
        fail("cannot write the result: {s}", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn runPrefix(io: std.Io, a: std.mem.Allocator, opts: Options) u8 {
    if (opts.spider.len != 0) {
        fail("--spider applies only with --modulepath, --cache-dir and --timestamp", .{});
        return 2;
    }
    if (opts.verify) {
        fail("--verify applies only with --modulepath, --cache-dir and --timestamp", .{});
        return 2;
    }
    if (!absolute(opts.prefix)) {
        fail("--prefix {s} is not an absolute path", .{opts.prefix});
        return 2;
    }
    if (!isDir(opts.prefix)) {
        fail("{s} does not point to an existing directory", .{opts.prefix});
        return 2;
    }
    const targets = discoverTargets(a, opts) catch |err| {
        fail("cannot walk {s}: {s}", .{ opts.prefix, @errorName(err) });
        return 1;
    };
    defer {
        for (targets) |t| {
            a.free(t.archdir);
            a.free(t.modulepath);
            a.free(t.cache_dir);
            a.free(t.timestamp);
        }
        a.free(targets);
    }
    if (targets.len == 0) {
        fail("under {s} found no CPU target with modules/all", .{opts.prefix});
        return 1;
    }
    if (opts.dry_run) {
        for (targets) |t| {
            var line: std.ArrayList(u8) = .empty;
            line.print(a, "{s}\n  cache-dir {s}\n  modulepath {s}\n", .{ t.archdir, t.cache_dir, t.modulepath }) catch return 1;
            var out = std.Io.File.stdout();
            out.writeStreamingAll(io, line.items) catch return 1;
        }
        return 0;
    }
    const resolved = blk: {
        if (opts.update_cmd.len > 0) break :blk .{ opts.update_cmd, false };
        const path = defaultUpdateCmd(a, opts.prefix) catch {
            fail("expected to find Lmod's cache update script under {s}/compat/linux/…/update_lmod_system_cache_files; pass --update-cmd", .{opts.prefix});
            return 2;
        };
        break :blk .{ path, true };
    };
    defer if (resolved[1]) a.free(resolved[0]);
    const update_cmd = resolved[0];
    for (targets) |t| {
        const code = runUpdate(io, a, update_cmd, t);
        if (code != 0) return code;
    }
    return 0;
}

const InventoryError = error{InvalidInventory} || std.mem.Allocator.Error;
const VerifyInventoryError = error{ModuleNotFound} || InventoryError || std.process.RunError;

fn inventoryLess(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn validMarker(marker: []const u8) bool {
    if (marker.len < 3 or marker[0] != '(' or marker[marker.len - 1] != ')') return false;
    const inner = marker[1 .. marker.len - 1];
    for (inner) |ch| switch (ch) {
        'D', 'H', 'L', 'S', 'E', 'm', '@', ',', ':' => {},
        else => return false,
    };
    return true;
}

/// Module names from `module --terse avail`, sorted and deduplicated.
fn normalizeInventory(a: std.mem.Allocator, text: []const u8) InventoryError![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '/' and line[line.len - 1] == ':') continue;
        if (std.mem.eql(u8, line, "No module(s) or extension(s) found!")) continue;
        if (line.len > 1 and line[line.len - 1] == '/' and config.validModule(line[0 .. line.len - 1])) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next() orelse continue;
        if (!config.validModule(name)) return error.InvalidInventory;
        var saw_alias = false;
        while (fields.next()) |marker| {
            if (!saw_alias and std.mem.eql(u8, marker, "->")) {
                const target = fields.next() orelse return error.InvalidInventory;
                if (!config.validModule(target)) return error.InvalidInventory;
                saw_alias = true;
                continue;
            }
            if (!validMarker(marker)) return error.InvalidInventory;
        }
        try names.append(a, try a.dupe(u8, name));
    }
    std.mem.sort([]const u8, names.items, {}, inventoryLess);
    var write: usize = 0;
    for (names.items) |name| {
        if (write > 0 and std.mem.eql(u8, names.items[write - 1], name)) continue;
        names.items[write] = name;
        write += 1;
    }
    names.shrinkRetainingCapacity(write);
    return names.toOwnedSlice(a);
}

fn sameInventory(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (!std.mem.eql(u8, a, b)) return false;
    return true;
}

const avail_script =
    \\if command -v module >/dev/null 2>&1; then
    \\    module --terse avail
    \\elif [ -n "${LMOD_CMD:-}" ]; then
    \\    "$LMOD_CMD" bash --terse avail
    \\else
    \\    echo "module command and LMOD_CMD are unavailable" >&2
    \\    exit 127
    \\fi
;

fn readInventory(
    io: std.Io,
    a: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    rc_path: []const u8,
    modulepath: []const u8,
    ignore_cache: bool,
) VerifyInventoryError![]const []const u8 {
    var child_env = try env.clone(a);
    defer child_env.deinit();
    try child_env.put("LMOD_RC", rc_path);
    try child_env.put("MODULEPATH", modulepath);
    if (ignore_cache) {
        try child_env.put("LMOD_IGNORE_CACHE", "yes");
    } else {
        _ = child_env.swapRemove("LMOD_IGNORE_CACHE");
    }
    const ran = try std.process.run(a, io, .{
        .argv = &.{ "bash", "--noprofile", "--norc", "-c", avail_script },
        .environ_map = &child_env,
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(8 * 1024 * 1024),
    });
    switch (ran.term) {
        .exited => |code| if (code == 127) return error.ModuleNotFound else if (code != 0) return error.InvalidInventory,
        else => return error.InvalidInventory,
    }
    const combined = try std.mem.concat(a, u8, &.{ ran.stdout, ran.stderr });
    return normalizeInventory(a, combined);
}

fn luaQuote(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '"');
    for (value) |byte| switch (byte) {
        '\\', '"' => {
            try out.append(a, '\\');
            try out.append(a, byte);
        },
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        else => {
            if (byte < 0x20 or byte == 0x7f) return error.InvalidArgument;
            try out.append(a, byte);
        },
    };
    try out.append(a, '"');
    return out.toOwnedSlice(a);
}

fn installVerified(
    io: std.Io,
    a: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    opts: Options,
    cache_path: []const u8,
    candidate: []const u8,
) u8 {
    var random: [8]u8 = undefined;
    if (linux.getrandom(&random, random.len, 0) != random.len) {
        fail("cannot name a temporary cache; the cache was not changed", .{});
        return 1;
    }
    const tmp_dir = std.fmt.allocPrint(a, "{s}/.eb-local-verify-{x}", .{
        opts.cache_dir,
        std.mem.readInt(u64, &random, .little),
    }) catch return 1;
    common.atomic.makedirs(tmp_dir) catch |err| {
        fail("cannot create {s}: {s}", .{ tmp_dir, @errorName(err) });
        return 1;
    };
    defer fsx.deleteTree(a, fsx.cwd, tmp_dir) catch {};
    const candidate_path = std.fs.path.join(a, &.{ tmp_dir, "spiderT.lua" }) catch return 1;
    const candidate_stamp = std.fs.path.join(a, &.{ tmp_dir, "timestamp" }) catch return 1;
    const rc_path = std.fs.path.join(a, &.{ tmp_dir, "lmodrc.lua" }) catch return 1;
    const cwd = std.Io.Dir.cwd();
    cwd.writeFile(io, .{ .sub_path = candidate_path, .data = candidate }) catch |err| {
        fail("cannot write {s}: {s}", .{ candidate_path, @errorName(err) });
        return 1;
    };
    const stat = cwd.statFile(io, candidate_path, .{}) catch return 1;
    const stamp = std.Io.Dir.createFileAbsolute(io, candidate_stamp, .{}) catch return 1;
    stamp.setTimestamps(io, .{
        .access_timestamp = .{ .new = olderThan(stat.mtime) },
        .modify_timestamp = .{ .new = olderThan(stat.mtime) },
    }) catch {
        stamp.close(io);
        return 1;
    };
    stamp.close(io);
    const quoted_dir = luaQuote(a, tmp_dir) catch {
        fail("cannot write a temporary LMOD_RC; the cache was not changed", .{});
        return 1;
    };
    const quoted_stamp = luaQuote(a, candidate_stamp) catch return 1;
    const rc = std.fmt.allocPrint(a,
        \\scDescriptT = {{
        \\  {{ ["dir"] = {s}, ["timestamp"] = {s} }},
        \\}}
        \\
    , .{ quoted_dir, quoted_stamp }) catch return 1;
    cwd.writeFile(io, .{ .sub_path = rc_path, .data = rc }) catch |err| {
        fail("cannot write {s}: {s}", .{ rc_path, @errorName(err) });
        return 1;
    };
    const cached = readInventory(io, a, env, rc_path, opts.modulepath, false) catch |err| switch (err) {
        error.ModuleNotFound => {
            fail("module command not found; the cache was not changed", .{});
            return 127;
        },
        else => {
            fail("cannot parse the candidate cache inventory; the cache was not changed", .{});
            return 1;
        },
    };
    const uncached = readInventory(io, a, env, rc_path, opts.modulepath, true) catch |err| switch (err) {
        error.ModuleNotFound => {
            fail("module command not found; the cache was not changed", .{});
            return 127;
        },
        else => {
            fail("cannot parse the uncached module inventory; the cache was not changed", .{});
            return 1;
        },
    };
    if (!sameInventory(cached, uncached)) {
        fail("candidate and uncached module inventories differ; the cache was not changed", .{});
        return 1;
    }
    std.Io.Dir.renameAbsolute(candidate_path, cache_path, io) catch |err| {
        fail("cannot write {s}: {s}", .{ cache_path, @errorName(err) });
        return 1;
    };
    return 0;
}

/// Write `cache_dir/spiderT.lua` from spider's stdout, then the timestamp.
/// A spider that cannot start, exits non-zero, or writes nothing leaves
/// both files as they were. Returns the process exit status.
pub fn run(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, opts: Options) u8 {
    if (opts.prefix.len != 0) {
        if (opts.modulepath.len != 0 or opts.cache_dir.len != 0 or opts.timestamp.len != 0) {
            fail("lmod-cache takes either --prefix or --modulepath, --cache-dir and --timestamp", .{});
            return 2;
        }
        return runPrefix(io, a, opts);
    }
    if (opts.dry_run) {
        fail("--dry-run applies only with --prefix", .{});
        return 2;
    }
    if (opts.eessi_version.len != 0 or opts.update_cmd.len != 0) {
        fail("--eessi-version and --update-cmd apply only with --prefix", .{});
        return 2;
    }
    if (opts.modulepath.len == 0 or opts.cache_dir.len == 0 or opts.timestamp.len == 0) {
        fail("lmod-cache needs --modulepath, --cache-dir and --timestamp, or --prefix", .{});
        return 2;
    }
    const dirs = moduleDirs(a, opts.modulepath) catch return 1;
    if (dirs.len == 0) {
        fail("--modulepath names no directory", .{});
        return 2;
    }
    for (dirs) |dir| if (!absolute(dir)) {
        fail("--modulepath {s} is not an absolute path", .{dir});
        return 2;
    };
    if (!absolute(opts.cache_dir)) {
        fail("--cache-dir {s} is not an absolute path", .{opts.cache_dir});
        return 2;
    }
    if (!absolute(opts.timestamp)) {
        fail("--timestamp {s} is not an absolute path", .{opts.timestamp});
        return 2;
    }
    const spider = if (opts.spider.len == 0) "spider" else opts.spider;
    const argv = spiderArgv(a, spider, dirs) catch return 1;
    const ran = std.process.run(a, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| {
        fail("cannot run {s}: {s}. Install Lmod and put spider on PATH, as https://lmod.readthedocs.io/en/latest/030_installing.html describes, or pass --spider with its path", .{ spider, @errorName(err) });
        return 127;
    };
    if (!ran.term.success()) {
        const err_text = std.mem.trim(u8, ran.stderr, " \t\r\n");
        if (err_text.len > 0) std.debug.print("{s}\n", .{err_text});
        const code: u8 = switch (ran.term) {
            .exited => |exited| if (exited == 0) 1 else exited,
            else => 1,
        };
        fail("{s} exited {d}; the cache was not changed", .{ spider, code });
        return code;
    }
    if (std.mem.trim(u8, ran.stdout, " \t\r\n").len == 0) {
        fail("{s} wrote nothing; the cache was not changed", .{spider});
        return 1;
    }
    const cwd = std.Io.Dir.cwd();
    var first_missing: ?[]const u8 = null;
    {
        var probe: []const u8 = opts.cache_dir;
        while (probe.len > 1 and !isDir(probe)) {
            first_missing = probe;
            probe = std.fs.path.dirname(probe) orelse break;
        }
    }
    cwd.createDirPath(io, opts.cache_dir) catch |err| {
        fail("cannot create {s}: {s}", .{ opts.cache_dir, @errorName(err) });
        return 1;
    };
    const cache_path = std.fs.path.join(a, &.{ opts.cache_dir, "spiderT.lua" }) catch return 1;
    const tmp_path = std.fmt.allocPrint(a, "{s}.new", .{cache_path}) catch return 1;
    if (opts.verify) {
        const code = installVerified(io, a, env, opts, cache_path, ran.stdout);
        if (code != 0) {
            if (first_missing) |dir| fsx.deleteTree(a, fsx.cwd, dir) catch {};
            return code;
        }
    } else {
        cwd.writeFile(io, .{ .sub_path = tmp_path, .data = ran.stdout }) catch |err| {
            fail("cannot write {s}: {s}", .{ tmp_path, @errorName(err) });
            return 1;
        };
        std.Io.Dir.renameAbsolute(tmp_path, cache_path, io) catch |err| {
            fail("cannot write {s}: {s}", .{ cache_path, @errorName(err) });
            return 1;
        };
    }
    const stat = cwd.statFile(io, cache_path, .{}) catch |err| {
        fail("cannot stat {s}: {s}", .{ cache_path, @errorName(err) });
        return 1;
    };
    const stamp = std.Io.Dir.createFileAbsolute(io, opts.timestamp, .{}) catch |err| {
        fail("cannot write {s}: {s}", .{ opts.timestamp, @errorName(err) });
        return 1;
    };
    defer stamp.close(io);
    stamp.setTimestamps(io, .{
        .access_timestamp = .{ .new = olderThan(stat.mtime) },
        .modify_timestamp = .{ .new = olderThan(stat.mtime) },
    }) catch |err| {
        fail("cannot set the time of {s}: {s}", .{ opts.timestamp, @errorName(err) });
        return 1;
    };
    var line: std.ArrayList(u8) = .empty;
    line.print(a, "wrote {s}; {s} is older than it\n", .{ cache_path, opts.timestamp }) catch return 1;
    var out = std.Io.File.stdout();
    out.writeStreamingAll(io, line.items) catch |err| {
        fail("cannot write the result: {s}", .{@errorName(err)});
        return 1;
    };
    return 0;
}

test "a colon-separated module path drops empty segments" {
    const dirs = try moduleDirs(std.testing.allocator, ":/mod/a::/mod/b:");
    defer std.testing.allocator.free(dirs);
    try std.testing.expectEqual(@as(usize, 2), dirs.len);
    try std.testing.expectEqualStrings("/mod/a", dirs[0]);
    try std.testing.expectEqualStrings("/mod/b", dirs[1]);
}

test "spider is asked for spiderT and each directory" {
    const argv = try spiderArgv(std.testing.allocator, "spider", &.{ "/mod/a", "/mod/b" });
    defer std.testing.allocator.free(argv);
    try std.testing.expectEqual(@as(usize, 5), argv.len);
    try std.testing.expectEqualStrings("spider", argv[0]);
    try std.testing.expectEqualStrings("-o", argv[1]);
    try std.testing.expectEqualStrings("spiderT", argv[2]);
    try std.testing.expectEqualStrings("/mod/a", argv[3]);
    try std.testing.expectEqualStrings("/mod/b", argv[4]);
}

test "the timestamp is one second before the cache" {
    const cache: std.Io.Timestamp = .{ .nanoseconds = 5 * std.time.ns_per_s + 20 };
    try std.testing.expectEqual(@as(i96, 4 * std.time.ns_per_s + 20), olderThan(cache).nanoseconds);
}

test "modulepath lists accelerators before the CPU tree" {
    const spec = try modulepathForArch(std.testing.allocator, "/stack/cpu", &.{
        "/stack/cpu/accel/a/cc/modules/all",
        "/stack/cpu/accel/b/cc/modules/all",
    });
    defer std.testing.allocator.free(spec);
    try std.testing.expectEqualStrings(
        "/stack/cpu/accel/a/cc/modules/all:/stack/cpu/accel/b/cc/modules/all:/stack/cpu/modules/all",
        spec,
    );
}

test "discovering targets under a versioned prefix" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer a.free(base);
    const rel = "versions/2026.06/software/linux/x86_64/amd/zen4";
    try tmp.dir.createDirPath(std.testing.io, rel ++ "/modules/all");
    try tmp.dir.createDirPath(std.testing.io, rel ++ "/accel/nvidia/cc90/modules/all");
    const cpu = try std.fs.path.join(a, &.{ base, "versions", "2026.06", "software", "linux", "x86_64", "amd", "zen4" });
    defer a.free(cpu);
    const accel = try std.fs.path.join(a, &.{ cpu, "accel", "nvidia", "cc90", "modules", "all" });
    defer a.free(accel);
    const all = try std.fs.path.join(a, &.{ cpu, "modules", "all" });
    defer a.free(all);
    const opts: Options = .{ .prefix = base, .eessi_version = "2026.06" };
    const targets = try discoverTargets(a, opts);
    defer {
        for (targets) |t| {
            a.free(t.archdir);
            a.free(t.modulepath);
            a.free(t.cache_dir);
            a.free(t.timestamp);
        }
        a.free(targets);
    }
    try std.testing.expectEqual(@as(usize, 1), targets.len);
    try std.testing.expectEqualStrings(cpu, targets[0].archdir);
    try std.testing.expect(std.mem.indexOf(u8, targets[0].modulepath, accel) != null);
    try std.testing.expect(std.mem.indexOf(u8, targets[0].modulepath, all) != null);
}

test "normalizeInventory skips directory headers and accepts loaded and alias lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = try normalizeInventory(
        a,
        "/modules:\nGSL/\nGSL/2.7\nGSL/2.8 (L,D)\npigz/\npigz/2.8 (L)\nGSL/default -> GSL/2.8 (H)\n",
    );
    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expectEqualStrings("GSL/2.7", items[0]);
    try std.testing.expectEqualStrings("GSL/2.8", items[1]);
    try std.testing.expectEqualStrings("GSL/default", items[2]);
    try std.testing.expectEqualStrings("pigz/2.8", items[3]);
    try std.testing.expectError(error.InvalidInventory, normalizeInventory(a, "Lmod has detected the following error:\n"));
    try std.testing.expectError(error.InvalidInventory, normalizeInventory(a, "GSL/default ->\n"));
}
