//! `eb-local lmod-cache`: write the spider cache Lmod trusts.
//!
//! Lmod treats a timestamp newer than `spiderT.lua` as a stale cache and
//! then ignores the modules that file names. The cache is written only
//! after `spider` succeeds, and the timestamp is then set one second
//! older than the cache file.
const std = @import("std");

const tool = "eb-local";

pub const Options = struct {
    modulepath: []const u8 = "",
    cache_dir: []const u8 = "",
    timestamp: []const u8 = "",
    /// Empty means the program `spider` on `PATH`.
    spider: []const u8 = "",
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

/// Write `cache_dir/spiderT.lua` from spider's stdout, then the timestamp.
/// A spider that cannot start, exits non-zero, or writes nothing leaves
/// both files as they were. Returns the process exit status.
pub fn run(io: std.Io, a: std.mem.Allocator, opts: Options) u8 {
    if (opts.modulepath.len == 0 or opts.cache_dir.len == 0 or opts.timestamp.len == 0) {
        fail("lmod-cache needs --modulepath, --cache-dir and --timestamp", .{});
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
