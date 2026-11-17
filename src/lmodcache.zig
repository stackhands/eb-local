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

/// Write `cache_dir/spiderT.lua` from spider's stdout, then the timestamp.
/// A spider that cannot start, exits non-zero, or writes nothing leaves
/// both files as they were. Returns the process exit status.
pub fn run(io: std.Io, a: std.mem.Allocator, opts: Options) u8 {
    if (opts.prefix.len != 0) {
        if (opts.modulepath.len != 0 or opts.cache_dir.len != 0 or opts.timestamp.len != 0)
            fail("lmod-cache takes either --prefix or --modulepath, --cache-dir and --timestamp", .{});
        return runPrefix(io, a, opts);
    }
    if (opts.dry_run) {
        fail("--dry-run applies only with --prefix", .{});
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
    cwd.createDirPath(io, opts.cache_dir) catch |err| {
        fail("cannot create {s}: {s}", .{ opts.cache_dir, @errorName(err) });
        return 1;
    };
    const cache_path = std.fs.path.join(a, &.{ opts.cache_dir, "spiderT.lua" }) catch return 1;
    const tmp_path = std.fmt.allocPrint(a, "{s}.new", .{cache_path}) catch return 1;
    cwd.writeFile(io, .{ .sub_path = tmp_path, .data = ran.stdout }) catch |err| {
        fail("cannot write {s}: {s}", .{ tmp_path, @errorName(err) });
        return 1;
    };
    std.Io.Dir.renameAbsolute(tmp_path, cache_path, io) catch |err| {
        fail("cannot write {s}: {s}", .{ cache_path, @errorName(err) });
        return 1;
    };
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
