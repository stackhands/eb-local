//! `eb-local lmod-cache`: write the spider cache Lmod trusts.
//!
//! Lmod treats a timestamp newer than `spiderT.lua` as a stale cache and
//! then ignores the modules that file names. The cache is written only
//! after `spider` succeeds, and the timestamp is then set one second
//! older than the cache file.
const std = @import("std");
const linux = std.os.linux;
const build_options = @import("build_options");
const common = @import("zig_common");
const fsx = common.fsx;
const sys = common.sys;
const config = @import("config.zig");

const tool = "eb-local";

const cache_signals = [_]linux.SIG{ .INT, .TERM, .HUP, .QUIT };
var active_pgid = std.atomic.Value(linux.pid_t).init(0);
var first_signal = std.atomic.Value(u32).init(0);
var active_env: ?*const std.process.Environ.Map = null;

fn onCacheSignal(sig: linux.SIG, _: *const linux.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    _ = first_signal.cmpxchgStrong(0, @backingInt(sig), .seq_cst, .seq_cst);
    common.proc.killGroup(active_pgid.load(.seq_cst), sig);
}

const CacheGuard = struct {
    old: [cache_signals.len]linux.Sigaction,
    released: bool = false,

    fn hold() CacheGuard {
        var g: CacheGuard = .{ .old = undefined };
        var during = linux.sigemptyset();
        for (cache_signals) |sig| linux.sigaddset(&during, sig);
        const act: linux.Sigaction = .{
            .handler = .{ .sigaction = onCacheSignal },
            .mask = during,
            .flags = linux.SA.SIGINFO,
        };
        active_pgid.store(0, .seq_cst);
        first_signal.store(0, .seq_cst);
        for (cache_signals, 0..) |sig, i| {
            _ = linux.sigaction(sig, null, &g.old[i]);
            if (g.old[i].handler.handler != linux.SIG.IGN) _ = linux.sigaction(sig, &act, null);
        }
        return g;
    }

    fn release(g: *CacheGuard) void {
        if (g.released) return;
        g.released = true;
        for (cache_signals, 0..) |sig, i| _ = linux.sigaction(sig, &g.old[i], null);
    }

    fn received(_: *const CacheGuard) ?linux.SIG {
        return receivedSignal();
    }
};

fn receivedSignal() ?linux.SIG {
    const v = first_signal.load(.seq_cst);
    return if (v == 0) null else @fromBackingInt(@intCast(v));
}

fn reRaiseSignal(sig: linux.SIG) u8 {
    var dfl: linux.Sigaction = .{
        .handler = .{ .handler = linux.SIG.DFL },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    var old: linux.Sigaction = undefined;
    _ = linux.sigaction(sig, null, &old);
    if (old.handler.handler != linux.SIG.IGN) {
        _ = linux.sigaction(sig, &dfl, null);
        var set = linux.sigemptyset();
        linux.sigaddset(&set, sig);
        _ = linux.sigprocmask(linux.SIG.UNBLOCK, &set, null);
        _ = linux.kill(linux.getpid(), sig);
    }
    return 128 +| @as(u8, @intCast(@min(@backingInt(sig), 127)));
}

fn stopSignal(g: *CacheGuard, sig: linux.SIG) u8 {
    g.release();
    return reRaiseSignal(sig);
}

fn envpOf(a: std.mem.Allocator, map: *const std.process.Environ.Map) !common.proc.Envp {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    var it = map.iterator();
    while (it.next()) |kv| {
        const line = try std.fmt.allocPrintSentinel(a, "{s}={s}", .{ kv.key_ptr.*, kv.value_ptr.* }, 0);
        try list.append(a, line.ptr);
    }
    try list.append(a, null);
    const slice = try list.toOwnedSlice(a);
    return @ptrCast(slice.ptr);
}

fn firstMissingAncestor(path: []const u8) ?[]const u8 {
    var missing: ?[]const u8 = null;
    var probe = path;
    while (probe.len > 1 and !isDir(probe)) {
        missing = probe;
        probe = std.fs.path.dirname(probe) orelse break;
    }
    return missing;
}

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
        for (list.items) |seen| {
            if (std.mem.eql(u8, seen, part)) break;
        } else try list.append(a, part);
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

fn olderTimespec(cache_mtime: linux.timespec) linux.timespec {
    return .{ .sec = cache_mtime.sec - 1, .nsec = cache_mtime.nsec };
}

fn writeTimestamp(stamp_path: []const u8, cache_mtime: linux.timespec) bool {
    const existing: ?fsx.Stat = fsx.statAt(fsx.cwd, stamp_path, false) catch |err| switch (err) {
        error.NotFound => null,
        error.SymLink => {
            fail("cannot write {s}: symlink is not followed", .{stamp_path});
            return false;
        },
        else => {
            fail("cannot write {s}: {s}", .{ stamp_path, @errorName(err) });
            return false;
        },
    };
    if (existing) |st| {
        if (st.isLink()) {
            fail("cannot write {s}: symlink is not followed", .{stamp_path});
            return false;
        }
        if (!st.isReg()) {
            fail("cannot write {s}: {s}", .{ stamp_path, if (st.isDir()) sys.describe(error.IsDir) else sys.describe(error.NotRegularFile) });
            return false;
        }
    }
    const parent = std.fs.path.dirname(stamp_path) orelse "/";
    const base = std.fs.path.basename(stamp_path);
    const parent_fd = fsx.openDir(fsx.cwd, parent, true) catch |err| {
        fail("cannot write {s}: {s}", .{ stamp_path, @errorName(err) });
        return false;
    };
    defer sys.close(parent_fd);

    const older = olderTimespec(cache_mtime);
    const times: [2]linux.timespec = .{ older, older };
    const mode: u32 = if (existing) |st| st.perm() else 0o644;

    var rnd: [6]u8 = undefined;
    _ = sys.call(linux.getrandom, .{ &rnd, rnd.len, 0 }) catch {
        fail("cannot write {s}: random failure", .{stamp_path});
        return false;
    };
    var tmp_buf: [sys.path_max]u8 = undefined;
    const tmp_name = std.fmt.bufPrint(&tmp_buf, ".{s}.{d}.{x}.tmp", .{
        base,
        linux.getpid(),
        std.mem.readInt(u48, &rnd, .little),
    }) catch {
        fail("cannot write {s}: NameTooLong", .{stamp_path});
        return false;
    };

    if (sys.openat(parent_fd, tmp_name, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
    }, mode)) |tmp_fd| {
        if (existing != null) sys.fchmod(tmp_fd, mode) catch {};
        if (sys.call(linux.utimensat, .{ tmp_fd, @as(?[*:0]const u8, null), &times, @as(u32, 0) })) |_| {} else |err| {
            sys.close(tmp_fd);
            sys.unlinkat(parent_fd, tmp_name, 0) catch {};
            fail("cannot set the time of {s}: {s}", .{ stamp_path, @errorName(err) });
            return false;
        }
        sys.fsync(tmp_fd) catch |err| {
            sys.close(tmp_fd);
            sys.unlinkat(parent_fd, tmp_name, 0) catch {};
            fail("cannot write {s}: {s}", .{ stamp_path, @errorName(err) });
            return false;
        };
        sys.close(tmp_fd);
        if (fsx.statAt(parent_fd, base, false)) |cur| {
            if (cur.isLink()) {
                sys.unlinkat(parent_fd, tmp_name, 0) catch {};
                fail("cannot write {s}: symlink is not followed", .{stamp_path});
                return false;
            }
            if (!cur.isReg()) {
                sys.unlinkat(parent_fd, tmp_name, 0) catch {};
                fail("cannot write {s}: {s}", .{ stamp_path, sys.describe(error.IsDir) });
                return false;
            }
        } else |err| if (err != error.NotFound) {
            sys.unlinkat(parent_fd, tmp_name, 0) catch {};
            fail("cannot write {s}: {s}", .{ stamp_path, @errorName(err) });
            return false;
        }
        sys.renameat(parent_fd, tmp_name, parent_fd, base) catch |err| {
            sys.unlinkat(parent_fd, tmp_name, 0) catch {};
            fail("cannot write {s}: {s}", .{ stamp_path, @errorName(err) });
            return false;
        };
        sys.fsync(parent_fd) catch {};
        return true;
    } else |open_err| {
        if (existing != null and open_err == error.AccessDenied) {
            const fd = sys.openat(parent_fd, base, .{ .ACCMODE = .RDWR, .NOFOLLOW = true }, 0) catch |err| {
                const detail = if (err == error.SymLink) "symlink is not followed" else @errorName(err);
                fail("cannot write {s}: {s}", .{ stamp_path, detail });
                return false;
            };
            defer sys.close(fd);
            if (existing.?.size > 0) _ = linux.ftruncate(fd, 0);
            _ = sys.call(linux.utimensat, .{ fd, @as(?[*:0]const u8, null), &times, @as(u32, 0) }) catch |err| {
                fail("cannot set the time of {s}: {s}", .{ stamp_path, @errorName(err) });
                return false;
            };
            return true;
        }
        fail("cannot write {s}: {s}", .{ stamp_path, @errorName(open_err) });
        return false;
    }
}

fn fail(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(tool ++ ": " ++ fmt ++ "\n", args);
}

fn absolute(path: []const u8) bool {
    return std.fs.path.isAbsolute(path);
}

const walk_max = 5;
const accel_walk_max = 3;

var test_force_dt_unknown: bool = false;

fn effectiveType(raw_type: u8) u8 {
    if (comptime build_options.test_ops) {
        if (test_force_dt_unknown) return fsx.DT.UNKNOWN;
    }
    return raw_type;
}

fn isDirEntry(dir: sys.fd_t, entry_name: []const u8, raw_type: u8) bool {
    const t = effectiveType(raw_type);
    if (t == fsx.DT.DIR) return true;
    if (t != fsx.DT.UNKNOWN) return false;
    const st = fsx.statAt(dir, entry_name, false) catch return false;
    return st.isDir();
}

fn isDir(path: []const u8) bool {
    return if (fsx.statAt(fsx.cwd, path, true)) |st| st.isDir() else |_| false;
}

const storage = @import("storage.zig");
const writer_lock_signals = [_]linux.SIG{ .INT, .TERM, .HUP, .QUIT };
var writer_lock_cancel = std.atomic.Value(bool).init(false);
var writer_lock_signal = std.atomic.Value(u32).init(0);

fn onWriterLockSignal(sig: linux.SIG, _: *const linux.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    _ = writer_lock_signal.cmpxchgStrong(0, @backingInt(sig), .seq_cst, .seq_cst);
    writer_lock_cancel.store(true, .seq_cst);
}

const WriterCancelGuard = struct {
    old: [writer_lock_signals.len]linux.Sigaction,
    released: bool = false,

    fn hold() WriterCancelGuard {
        var g: WriterCancelGuard = .{ .old = undefined };
        var during = linux.sigemptyset();
        for (writer_lock_signals) |sig| linux.sigaddset(&during, sig);
        const act: linux.Sigaction = .{
            .handler = .{ .sigaction = onWriterLockSignal },
            .mask = during,
            .flags = linux.SA.SIGINFO,
        };
        writer_lock_signal.store(0, .seq_cst);
        writer_lock_cancel.store(false, .seq_cst);
        for (writer_lock_signals, 0..) |sig, i| {
            _ = linux.sigaction(sig, null, &g.old[i]);
            if (g.old[i].handler.handler != linux.SIG.IGN) _ = linux.sigaction(sig, &act, null);
        }
        return g;
    }

    fn release(g: *WriterCancelGuard) void {
        if (g.released) return;
        g.released = true;
        for (writer_lock_signals, 0..) |sig, i| _ = linux.sigaction(sig, &g.old[i], null);
    }

    fn received(_: *const WriterCancelGuard) ?linux.SIG {
        const v = writer_lock_signal.load(.seq_cst);
        return if (v == 0) null else @fromBackingInt(@intCast(v));
    }
};

fn reRaiseWriterSignal(g: *WriterCancelGuard, sig: linux.SIG) u8 {
    g.release();
    var old: linux.Sigaction = undefined;
    _ = linux.sigaction(sig, null, &old);
    if (old.handler.handler != linux.SIG.IGN) {
        const dfl: linux.Sigaction = .{
            .handler = .{ .handler = linux.SIG.DFL },
            .mask = linux.sigemptyset(),
            .flags = 0,
        };
        _ = linux.sigaction(sig, &dfl, null);
        var set = linux.sigemptyset();
        linux.sigaddset(&set, sig);
        _ = linux.sigprocmask(linux.SIG.UNBLOCK, &set, null);
        _ = linux.kill(linux.getpid(), sig);
    }
    return 128 +| @as(u8, @intCast(@min(@backingInt(sig), 127)));
}

fn existingAncestor(path: []const u8) []const u8 {
    var probe = path;
    while (probe.len > 1 and !isDir(probe)) {
        probe = std.fs.path.dirname(probe) orelse break;
    }
    return if (probe.len == 0) "/" else probe;
}

const DirHold = struct {
    fds: [3]sys.fd_t = .{ -1, -1, -1 },
    devs: [3]u64 = .{ 0, 0, 0 },
    inos: [3]u64 = .{ 0, 0, 0 },
    len: usize = 0,

    fn release(self: *DirHold) void {
        while (self.len > 0) {
            self.len -= 1;
            const fd = self.fds[self.len];
            if (fd >= 0) {
                _ = linux.flock(fd, std.posix.LOCK.UN);
                sys.close(fd);
                self.fds[self.len] = -1;
            }
        }
    }

    fn contains(self: *const DirHold, dev: u64, ino: u64) bool {
        for (0..self.len) |i| {
            if (self.devs[i] == dev and self.inos[i] == ino) return true;
        }
        return false;
    }

    fn lockExistingDir(self: *DirHold, path: []const u8, timeout_ms: u32) error{ Canceled, TimedOut, LockFailed }!void {
        if (self.len >= self.fds.len) return;
        var tries: usize = 0;
        while (tries < 8) : (tries += 1) {
            if (writer_lock_cancel.load(.seq_cst)) return error.Canceled;
            const dir_path = existingAncestor(path);
            const raw_fd = fsx.openDir(fsx.cwd, dir_path, true) catch |err| {
                if (err == error.NotFound) continue;
                fail("cannot open {s}: {s}", .{ dir_path, sys.describe(err) });
                return error.LockFailed;
            };
            const fd = sys.keepAboveStdio(raw_fd) catch |err| {
                sys.close(raw_fd);
                fail("cannot open {s}: {s}", .{ dir_path, sys.describe(err) });
                return error.LockFailed;
            };
            const st = fsx.fstat(fd) catch |err| {
                sys.close(fd);
                fail("cannot stat {s}: {s}", .{ dir_path, sys.describe(err) });
                return error.LockFailed;
            };
            if (self.contains(st.dev, st.ino)) {
                sys.close(fd);
                return;
            }
            common.state.lockExclusiveCancel(fd, timeout_ms, &writer_lock_cancel) catch |err| switch (err) {
                error.Canceled => {
                    sys.close(fd);
                    return error.Canceled;
                },
                error.TimedOut => {
                    sys.close(fd);
                    fail("timed out after {d} ms waiting for lock on {s}", .{ timeout_ms, dir_path });
                    return error.TimedOut;
                },
                else => |se| {
                    sys.close(fd);
                    if (storage.flockUnsupported(se)) return;
                    fail("cannot lock {s}: {s}", .{ dir_path, sys.describe(se) });
                    return error.LockFailed;
                },
            };
            const verify = fsx.statAt(fsx.cwd, dir_path, true) catch |err| switch (err) {
                error.NotFound => {
                    _ = linux.flock(fd, std.posix.LOCK.UN);
                    sys.close(fd);
                    continue;
                },
                else => {
                    _ = linux.flock(fd, std.posix.LOCK.UN);
                    sys.close(fd);
                    return error.LockFailed;
                },
            };
            if (verify.dev != st.dev or verify.ino != st.ino) {
                _ = linux.flock(fd, std.posix.LOCK.UN);
                sys.close(fd);
                continue;
            }
            self.fds[self.len] = fd;
            self.devs[self.len] = st.dev;
            self.inos[self.len] = st.ino;
            self.len += 1;
            return;
        }
    }

    fn lockPairOrdered(self: *DirHold, first_path: []const u8, second_path: []const u8, timeout_ms: u32) error{ Canceled, TimedOut, LockFailed }!void {
        const a_dir = existingAncestor(first_path);
        const b_dir = existingAncestor(second_path);
        const st_a = fsx.statAt(fsx.cwd, a_dir, true) catch null;
        const st_b = fsx.statAt(fsx.cwd, b_dir, true) catch null;
        if (st_a != null and st_b != null) {
            const sa = st_a.?;
            const sb = st_b.?;
            if (sb.dev < sa.dev or (sb.dev == sa.dev and sb.ino < sa.ino)) {
                try self.lockExistingDir(b_dir, timeout_ms);
                try self.lockExistingDir(a_dir, timeout_ms);
                return;
            }
        }
        try self.lockExistingDir(a_dir, timeout_ms);
        try self.lockExistingDir(b_dir, timeout_ms);
    }
};

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
        if (!isDirEntry(fd, e.name, e.type)) continue;
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
        if (!isDirEntry(fd, e.name, e.type)) continue;
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

fn validEessiVersion(v: []const u8) bool {
    if (v.len == 0 or std.mem.eql(u8, v, ".") or std.mem.eql(u8, v, "..")) return false;
    return std.mem.indexOfAny(u8, v, "/\\\x00") == null;
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

fn writeStdout(bytes: []const u8) bool {
    sys.writeAll(1, bytes) catch |err| {
        fail("cannot write the result: {s}", .{sys.describe(err)});
        return false;
    };
    return true;
}

/// Run Lmod's `update_lmod_system_cache_files` for one target.
pub fn runUpdate(io: std.Io, a: std.mem.Allocator, update_cmd: []const u8, target: Target) u8 {
    _ = io;
    const first_missing = firstMissingAncestor(target.cache_dir);
    const argv = updateArgv(a, update_cmd, target.cache_dir, target.modulepath) catch return 1;
    defer {
        a.free(argv[4]);
        a.free(argv);
    }
    const path_env = if (active_env) |m| m.get("PATH") else null;
    const exe = (common.proc.resolveExecutable(a, update_cmd, path_env) catch return 1) orelse {
        fail("cannot run {s}: NotFound", .{update_cmd});
        return 127;
    };
    defer a.free(exe);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const empty_envp = [_:null]?[*:0]const u8{null};
    const envp: common.proc.Envp = if (active_env) |m| (envpOf(arena.allocator(), m) catch return 1) else @ptrCast(&empty_envp);
    const ran = common.proc.run(arena.allocator(), exe, argv, envp, .{
        .stdout_limit = 64 * 1024,
        .stderr_limit = 64 * 1024,
        .pgid_out = &active_pgid,
        .wait_for_group = true,
        .exec_error = true,
    }) catch |err| {
        if (receivedSignal()) |sig| {
            if (first_missing) |dir| fsx.deleteTree(a, fsx.cwd, dir) catch {};
            return reRaiseSignal(sig);
        }
        fail("cannot run {s}: {s}", .{ update_cmd, @errorName(err) });
        return 127;
    };
    if (receivedSignal()) |sig| {
        if (first_missing) |dir| fsx.deleteTree(a, fsx.cwd, dir) catch {};
        return reRaiseSignal(sig);
    }
    const raw_code = ran.term.code();
    if (raw_code != 0) {
        const err_text = std.mem.trim(u8, ran.stderr, " \t\r\n");
        if (err_text.len > 0) std.debug.print("{s}\n", .{err_text});
        const code: u8 = @intCast(@min(raw_code, 255));
        fail("updating the Lmod cache failed for {s} using MODULEPATH: {s}", .{ target.archdir, target.modulepath });
        return code;
    }
    if (std.mem.trim(u8, ran.stdout, " \t\r\n").len > 0) {
        if (!writeStdout(ran.stdout)) return 1;
    }
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(a);
    line.print(a, "updated the Lmod cache for {s} using MODULEPATH: {s}\n", .{ target.archdir, target.modulepath }) catch return 1;
    if (!writeStdout(line.items)) return 1;
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
    if (opts.eessi_version.len > 0 and !validEessiVersion(opts.eessi_version)) {
        fail("--eessi-version '{s}' must be a single version directory name", .{opts.eessi_version});
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
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        for (targets) |t| {
            out.print(a, "{s}\n  cache-dir {s}\n  modulepath {s}\n", .{ t.archdir, t.cache_dir, t.modulepath }) catch return 1;
        }
        if (!writeStdout(out.items)) return 1;
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
        var target_hold: DirHold = .{};
        defer target_hold.release();
        var cancel_guard = WriterCancelGuard.hold();
        target_hold.lockExistingDir(t.cache_dir, storage.default_lock_timeout_ms) catch |err| switch (err) {
            error.Canceled => return reRaiseWriterSignal(&cancel_guard, cancel_guard.received() orelse .TERM),
            error.TimedOut, error.LockFailed => {
                cancel_guard.release();
                return 1;
            },
        };
        cancel_guard.release();
        const code = runUpdate(io, a, update_cmd, t);
        if (code != 0) return code;
    }
    return 0;
}

const InventoryError = error{InvalidInventory} || std.mem.Allocator.Error;
const VerifyInventoryError = error{ ModuleNotFound, Canceled } || InventoryError || common.proc.Error;

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
    for ([_][]const u8{ "BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS" }) |name| _ = child_env.swapRemove(name);
    try child_env.put("LMOD_RC", rc_path);
    try child_env.put("MODULEPATH", modulepath);
    if (ignore_cache) {
        try child_env.put("LMOD_IGNORE_CACHE", "yes");
    } else {
        _ = child_env.swapRemove("LMOD_IGNORE_CACHE");
    }
    _ = io;
    if (receivedSignal() != null) return error.Canceled;
    const bash = (try common.proc.resolveExecutable(a, "bash", child_env.get("PATH"))) orelse return error.ModuleNotFound;
    defer a.free(bash);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const envp = try envpOf(arena.allocator(), &child_env);
    const ran = common.proc.run(arena.allocator(), bash, &.{ bash, "--noprofile", "--norc", "-c", avail_script }, envp, .{
        .stdout_limit = 8 * 1024 * 1024,
        .stderr_limit = 8 * 1024 * 1024,
        .pgid_out = &active_pgid,
        .wait_for_group = true,
        .exec_error = true,
    }) catch |err| {
        if (receivedSignal() != null) return error.Canceled;
        return err;
    };
    if (receivedSignal() != null) return error.Canceled;
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

fn makeVerifyDir(a: std.mem.Allocator, cache_dir: []const u8) ![]u8 {
    return fsx.mkdtemp(a, cache_dir, ".eb-local-verify-");
}

fn installVerified(
    io: std.Io,
    a: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    opts: Options,
    cache_path: []const u8,
    candidate: []const u8,
) u8 {
    const tmp_dir = makeVerifyDir(a, opts.cache_dir) catch |err| switch (err) {
        error.OutOfMemory => return 1,
        else => {
            fail("cannot create a temporary directory in {s}: {s}", .{ opts.cache_dir, @errorName(err) });
            return 1;
        },
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
    const stat = fsx.statAt(fsx.cwd, candidate_path, false) catch return 1;
    if (!writeTimestamp(candidate_stamp, stat.mtime)) return 1;
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
        error.Canceled => return 130,
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
        error.Canceled => return 130,
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
    if (receivedSignal() != null) return 130;
    var why: common.atomic.Why = .{};
    defer why.deinit(a);
    common.atomic.atomicWrite(a, cache_path, candidate, .{ .mode = 0o644 }, &why) catch |err| {
        fail("cannot write {s}: {s}", .{ cache_path, if (why.msg.len > 0) why.msg else @errorName(err) });
        return 1;
    };
    return 0;
}

/// Write `cache_dir/spiderT.lua` from spider's stdout, then the timestamp.
/// A spider that cannot start, exits non-zero, or writes nothing leaves
/// both files as they were. Returns the process exit status.
pub fn run(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, opts: Options) u8 {
    active_env = env;
    defer active_env = null;
    var guard = CacheGuard.hold();
    defer guard.release();
    if (opts.prefix.len != 0) {
        if (opts.modulepath.len != 0 or opts.cache_dir.len != 0 or opts.timestamp.len != 0) {
            fail("lmod-cache takes either --prefix or --modulepath, --cache-dir and --timestamp", .{});
            return 2;
        }
        const code = runPrefix(io, a, opts);
        if (guard.received()) |sig| return stopSignal(&guard, sig);
        return code;
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
    var lock_err: []const u8 = "";
    const timeout_ms = storage.lockTimeoutMs(env, &lock_err) orelse {
        fail("{s}", .{lock_err});
        return 2;
    };
    var dir_hold: DirHold = .{};
    defer dir_hold.release();
    {
        var cancel_guard = WriterCancelGuard.hold();
        defer cancel_guard.release();
        const stamp_parent = std.fs.path.dirname(opts.timestamp) orelse "/";
        dir_hold.lockPairOrdered(opts.cache_dir, stamp_parent, timeout_ms) catch |err| switch (err) {
            error.Canceled => {
                dir_hold.release();
                return reRaiseWriterSignal(&cancel_guard, cancel_guard.received() orelse .TERM);
            },
            error.TimedOut, error.LockFailed => return 1,
        };
    }
    const spider = if (opts.spider.len == 0) "spider" else opts.spider;
    const argv = spiderArgv(a, spider, dirs) catch return 1;
    const spider_exe = (common.proc.resolveExecutable(a, spider, env.get("PATH")) catch return 1) orelse {
        fail("cannot run {s}: NotFound. Install Lmod and put spider on PATH, as https://lmod.readthedocs.io/en/latest/030_installing.html describes, or pass --spider with its path", .{spider});
        return 127;
    };
    const envp = envpOf(a, env) catch return 1;
    const ran = common.proc.run(a, spider_exe, argv, envp, .{
        .stdout_limit = 64 * 1024 * 1024,
        .stderr_limit = 64 * 1024,
        .pgid_out = &active_pgid,
        .wait_for_group = true,
        .exec_error = true,
    }) catch |err| {
        if (guard.received()) |sig| return stopSignal(&guard, sig);
        fail("cannot run {s}: {s}. Install Lmod and put spider on PATH, as https://lmod.readthedocs.io/en/latest/030_installing.html describes, or pass --spider with its path", .{ spider, @errorName(err) });
        return 127;
    };
    if (guard.received()) |sig| return stopSignal(&guard, sig);
    const raw_code = ran.term.code();
    if (raw_code != 0) {
        const err_text = std.mem.trim(u8, ran.stderr, " \t\r\n");
        if (err_text.len > 0) std.debug.print("{s}\n", .{err_text});
        const code: u8 = @intCast(@min(raw_code, 255));
        fail("{s} exited {d}; the cache was not changed", .{ spider, code });
        return code;
    }
    if (std.mem.trim(u8, ran.stdout, " \t\r\n").len == 0) {
        fail("{s} wrote nothing; the cache was not changed", .{spider});
        return 1;
    }
    const cwd = std.Io.Dir.cwd();
    const cache_path = std.fs.path.join(a, &.{ opts.cache_dir, "spiderT.lua" }) catch return 1;
    const prev_cache: ?[]const u8 = cwd.readFileAlloc(io, cache_path, a, .limited(64 * 1024 * 1024)) catch null;
    var first_missing: ?[]const u8 = null;
    {
        var probe: []const u8 = opts.cache_dir;
        while (probe.len > 1) {
            if (fsx.statAt(fsx.cwd, probe, false)) |_| break else |_| {}
            first_missing = probe;
            probe = std.fs.path.dirname(probe) orelse break;
        }
    }
    common.atomic.makedirs(opts.cache_dir) catch |err| {
        fail("cannot create {s}: {s}", .{ opts.cache_dir, @errorName(err) });
        if (first_missing) |dir| fsx.deleteTree(a, fsx.cwd, dir) catch {};
        return 1;
    };
    {
        var cancel_guard = WriterCancelGuard.hold();
        defer cancel_guard.release();
        dir_hold.lockExistingDir(opts.cache_dir, timeout_ms) catch |err| switch (err) {
            error.Canceled => {
                if (first_missing) |dir| fsx.deleteTree(a, fsx.cwd, dir) catch {};
                dir_hold.release();
                return reRaiseWriterSignal(&cancel_guard, cancel_guard.received() orelse .TERM);
            },
            error.TimedOut, error.LockFailed => {
                if (first_missing) |dir| fsx.deleteTree(a, fsx.cwd, dir) catch {};
                return 1;
            },
        };
    }
    const cleanup = struct {
        fn rollback(alloc: std.mem.Allocator, missing: ?[]const u8, path: []const u8, prev: ?[]const u8, wrote: bool) void {
            if (wrote) {
                if (prev) |data| {
                    var why: common.atomic.Why = .{};
                    defer why.deinit(alloc);
                    common.atomic.atomicWrite(alloc, path, data, .{ .mode = 0o644 }, &why) catch {};
                } else {
                    sys.unlinkat(fsx.cwd, path, 0) catch {};
                }
            }
            if (missing) |dir| fsx.deleteTree(alloc, fsx.cwd, dir) catch {};
        }
    }.rollback;
    var cache_written = false;
    if (opts.verify) {
        const code = installVerified(io, a, env, opts, cache_path, ran.stdout);
        if (guard.received()) |sig| {
            cleanup(a, first_missing, cache_path, prev_cache, false);
            return stopSignal(&guard, sig);
        }
        if (code != 0) {
            if (first_missing) |dir| fsx.deleteTree(a, fsx.cwd, dir) catch {};
            return code;
        }
        cache_written = true;
    } else {
        var why: common.atomic.Why = .{};
        defer why.deinit(a);
        common.atomic.atomicWrite(a, cache_path, ran.stdout, .{ .mode = 0o644 }, &why) catch |err| {
            fail("cannot write {s}: {s}", .{ cache_path, if (why.msg.len > 0) why.msg else @errorName(err) });
            cleanup(a, first_missing, cache_path, prev_cache, false);
            return 1;
        };
        cache_written = true;
    }
    const stat = fsx.statAt(fsx.cwd, cache_path, false) catch |err| {
        fail("cannot stat {s}: {s}", .{ cache_path, @errorName(err) });
        cleanup(a, first_missing, cache_path, prev_cache, cache_written);
        return 1;
    };
    if (!writeTimestamp(opts.timestamp, stat.mtime)) {
        cleanup(a, first_missing, cache_path, prev_cache, cache_written);
        return 1;
    }
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(a);
    line.print(a, "wrote {s}; {s} is older than it\n", .{ cache_path, opts.timestamp }) catch return 1;
    if (!writeStdout(line.items)) return 1;
    return 0;
}

test "a colon-separated module path drops empty segments" {
    const dirs = try moduleDirs(std.testing.allocator, ":/mod/a::/mod/b:/mod/a:");
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
    const ts = olderTimespec(.{ .sec = 5, .nsec = 20 });
    try std.testing.expectEqual(@as(i64, 4), ts.sec);
    try std.testing.expectEqual(@as(i64, 20), ts.nsec);
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

    test_force_dt_unknown = true;
    defer test_force_dt_unknown = false;
    const unknown_targets = try discoverTargets(a, opts);
    defer {
        for (unknown_targets) |t| {
            a.free(t.archdir);
            a.free(t.modulepath);
            a.free(t.cache_dir);
            a.free(t.timestamp);
        }
        a.free(unknown_targets);
    }
    try std.testing.expectEqual(@as(usize, 1), unknown_targets.len);
    try std.testing.expectEqualStrings(cpu, unknown_targets[0].archdir);
    try std.testing.expect(std.mem.indexOf(u8, unknown_targets[0].modulepath, accel) != null);
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

test "makeVerifyDir creates a private verification directory under cache_dir" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer a.free(base);

    const created = try makeVerifyDir(a, base);
    defer a.free(created);
    defer fsx.deleteTree(a, fsx.cwd, created) catch {};

    const expected_prefix = try std.fmt.allocPrint(a, "{s}/.eb-local-verify-", .{base});
    defer a.free(expected_prefix);
    try std.testing.expect(std.mem.startsWith(u8, created, expected_prefix));
    try std.testing.expectEqual(expected_prefix.len + 8, created.len);
    const st = try fsx.statAt(fsx.cwd, created, false);
    try std.testing.expect(st.isDir());
    try std.testing.expectEqual(@as(u32, 0), st.perm() & 0o077);

    const missing = try std.fmt.allocPrint(a, "{s}/missing", .{base});
    defer a.free(missing);
    try std.testing.expectError(error.NotFound, makeVerifyDir(a, missing));
}
