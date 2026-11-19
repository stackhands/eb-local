//! CernVM-FS checks for `eb-local doctor --cvmfs`.
//! A build does not call any of this, and it sets no client variable.
const std = @import("std");
const linux = std.os.linux;
const common = @import("zig_common");
const sys = common.sys;
const fsx = common.fsx;
const proc = common.proc;

const Allocator = std.mem.Allocator;

/// The repository path doctor stats, and the name `cvmfs_config probe` takes.
pub const Repo = struct {
    path: []const u8,
    name: []const u8,
};

/// What a stat of the repository mount means.
pub const Mount = enum { ok, enotconn, eio, absent };

/// Whether the client uses a proxy, talks directly, or has no setting.
pub const ProxyMode = enum { unset, direct, proxy };

/// The HTTP proxy the client would use, and the file or variable it came from.
pub const Proxy = struct {
    mode: ProxyMode = .unset,
    value: []const u8 = "",
    from: []const u8 = "",
    /// True when `CVMFS_HTTP_PROXY` in the process environment won over the files.
    host_injected: bool = false,
};

/// One run of `cvmfs_config` or `srun`.
pub const Tool = struct {
    present: bool = false,
    code: u32 = 0,
    timed_out: bool = false,
};

/// Why a parallel metadata read ran, or why it did not.
pub const ParallelKind = enum { off, stale, outside, srun_ok, srun_fail, srun_timeout, fork_ok, fork_fail };

/// A parallel metadata read, or why it did not run.
pub const Parallel = struct {
    kind: ParallelKind = .off,
    tasks: u8 = 0,
    code: u32 = 0,
};

/// `EESSI_CVMFS_REPO` when it is absolute, otherwise the public EESSI repository.
pub fn repository(env: *const std.process.Environ.Map) Repo {
    const fallback = "/cvmfs/software.eessi.io";
    const raw = env.get("EESSI_CVMFS_REPO") orelse fallback;
    var path: []const u8 = if (raw.len > 0 and raw[0] == '/') raw else fallback;
    while (path.len > 1 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
    var name = std.fs.path.basename(path);
    if (name.len == 0 or std.mem.eql(u8, name, "/") or std.mem.indexOfScalar(u8, name, '/') != null)
        name = "software.eessi.io";
    return .{ .path = path, .name = name };
}

/// `forced` is a test seam: `ENOTCONN`, `EIO`, `ABSENT` or `OK`. Otherwise stat `path`.
pub fn mountState(path: []const u8, forced: ?[]const u8) Mount {
    if (forced) |name| {
        if (std.mem.eql(u8, name, "OK")) return .ok;
        if (std.mem.eql(u8, name, "ENOTCONN")) return .enotconn;
        if (std.mem.eql(u8, name, "EIO")) return .eio;
        if (std.mem.eql(u8, name, "ABSENT")) return .absent;
        return .eio;
    }
    if (fsx.statAt(fsx.cwd, path, false)) |st| {
        return if (st.isDir()) .ok else .absent;
    } else |_| {}
    var buf: [sys.path_max:0]u8 = undefined;
    const z = sys.z(&buf, path) catch return .absent;
    var x: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, z.ptr, 0, .{ .TYPE = true }, &x);
    return switch (linux.errno(rc)) {
        .SUCCESS => if (x.mode & fsx.S.IFMT == fsx.S.IFDIR) .ok else .absent,
        .NOENT, .NOTDIR => .absent,
        .NOTCONN => .enotconn,
        else => .eio,
    };
}

/// The effective `CVMFS_HTTP_PROXY`. A non-empty environment value wins.
/// Otherwise the last assignment in the client files wins, from
/// `default.conf` through `config.d/<repo>.local`. `DIRECT` is direct mode.
pub fn readProxy(a: Allocator, env: *const std.process.Environ.Map, config_root: []const u8, repo_name: []const u8) Allocator.Error!Proxy {
    if (env.get("CVMFS_HTTP_PROXY")) |v| {
        const value = std.mem.trim(u8, v, " \t");
        if (value.len > 0) return proxyFrom(a, value, "environment CVMFS_HTTP_PROXY", true);
    }
    const files = try configFiles(a, config_root, repo_name);
    var found: ?Proxy = null;
    for (files) |path| {
        const text = readFile(a, path) orelse continue;
        if (proxyLine(text)) |value| {
            found = if (value.len == 0) null else try proxyFrom(a, value, path, false);
        }
    }
    return found orelse .{};
}

fn proxyFrom(a: Allocator, value: []const u8, from: []const u8, host: bool) Allocator.Error!Proxy {
    const mode: ProxyMode = if (std.mem.eql(u8, value, "DIRECT")) .direct else .proxy;
    return .{
        .mode = mode,
        .value = try a.dupe(u8, value),
        .from = try a.dupe(u8, from),
        .host_injected = host,
    };
}

fn configFiles(a: Allocator, root: []const u8, repo_name: []const u8) Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    try list.append(a, try std.fs.path.join(a, &.{ root, "default.conf" }));
    try list.append(a, try std.fs.path.join(a, &.{ root, "default.local" }));
    if (std.mem.indexOfScalar(u8, repo_name, '.')) |dot| {
        const domain = repo_name[dot + 1 ..];
        if (domain.len > 0) {
            try list.append(a, try std.fs.path.join(a, &.{ root, "domain.d", try std.fmt.allocPrint(a, "{s}.conf", .{domain}) }));
            try list.append(a, try std.fs.path.join(a, &.{ root, "domain.d", try std.fmt.allocPrint(a, "{s}.local", .{domain}) }));
        }
    }
    try list.append(a, try std.fs.path.join(a, &.{ root, "config.d", try std.fmt.allocPrint(a, "{s}.conf", .{repo_name}) }));
    try list.append(a, try std.fs.path.join(a, &.{ root, "config.d", try std.fmt.allocPrint(a, "{s}.local", .{repo_name}) }));
    return list.items;
}

fn readFile(a: Allocator, path: []const u8) ?[]const u8 {
    const opened = fsx.openRegular(fsx.cwd, path, true) catch return null;
    defer sys.close(opened.fd);
    return fsx.readAll(a, opened.fd, 1 << 20) catch null;
}

/// The last `CVMFS_HTTP_PROXY=` in a client file. Quotes around the value
/// are removed. A comment and a blank line are ignored.
fn proxyLine(text: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export") and line.len > 6 and (line[6] == ' ' or line[6] == '\t'))
            line = std.mem.trim(u8, line[6..], " \t");
        const key = "CVMFS_HTTP_PROXY";
        if (!std.mem.startsWith(u8, line, key)) continue;
        var rest = std.mem.trim(u8, line[key.len..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        var value = std.mem.trim(u8, rest[1..], " \t");
        if (value.len > 0 and (value[0] == '"' or value[0] == '\'')) {
            const q = value[0];
            if (std.mem.indexOfScalarPos(u8, value, 1, q)) |end| {
                value = std.mem.trim(u8, value[1..end], " \t");
            } else continue;
        } else {
            if (std.mem.indexOfScalar(u8, value, '#')) |hash| value = std.mem.trimEnd(u8, value[0..hash], " \t");
        }
        found = value;
    }
    return found;
}

/// Run `argv[0]`, already an absolute path. A missing program is `present = false`.
pub fn runTool(a: Allocator, exe: ?[]const u8, argv: []const []const u8, envp: proc.Envp) Tool {
    const path = exe orelse return .{};
    const r = proc.run(a, path, argv, envp, .{
        .stdout_limit = 64 << 10,
        .stderr_limit = 4096,
        .timeout_ms = 20_000,
        .stdout_overflow = .truncate,
    }) catch |e| switch (e) {
        error.TimedOut => return .{ .present = true, .timed_out = true },
        else => return .{ .present = true, .code = 127 },
    };
    defer r.deinit(a);
    return .{ .present = true, .code = r.term.code() };
}

/// Read repository metadata from `tasks` processes. `srun`, when its path is
/// set, runs `srun -n N stat <repo>`. Otherwise this process forks.
/// A stale mount and a shell outside an allocation are not probed.
pub fn parallelProbe(a: Allocator, repo: []const u8, tasks: u8, in_job: bool, stale: bool, srun: ?[]const u8, envp: proc.Envp) Parallel {
    if (tasks == 0) return .{};
    if (stale) return .{ .kind = .stale, .tasks = tasks };
    if (!in_job) return .{ .kind = .outside, .tasks = tasks };
    if (srun) |exe| {
        const n = std.fmt.allocPrint(a, "{d}", .{tasks}) catch return .{ .kind = .srun_fail, .tasks = tasks, .code = 127 };
        const tool = runTool(a, exe, &.{ exe, "-n", n, "stat", repo }, envp);
        if (tool.timed_out) return .{ .kind = .srun_timeout, .tasks = tasks };
        if (tool.code == 0) return .{ .kind = .srun_ok, .tasks = tasks };
        return .{ .kind = .srun_fail, .tasks = tasks, .code = tool.code };
    }
    const failed = forkReads(repo, tasks);
    if (failed == 0) return .{ .kind = .fork_ok, .tasks = tasks };
    return .{ .kind = .fork_fail, .tasks = tasks, .code = failed };
}

fn oneRead(path: []const u8) u8 {
    var buf: [sys.path_max:0]u8 = undefined;
    const z = sys.z(&buf, path) catch return 1;
    const opened = linux.openat(linux.AT.FDCWD, z.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return 1;
    const fd: i32 = @intCast(opened);
    var dents: [1024]u8 align(8) = undefined;
    const n = while (true) {
        const got = linux.getdents64(fd, &dents, dents.len);
        if (linux.errno(got) == .INTR) continue;
        break got;
    };
    _ = linux.close(fd);
    if (linux.errno(n) != .SUCCESS or n == 0) return 1;
    return 0;
}

fn forkReads(path: []const u8, n: u8) u32 {
    var failed: u32 = 0;
    var pids: [8]i32 = undefined;
    var started: usize = 0;
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        if (started == pids.len) {
            for (pids[0..started]) |pid| {
                if (!reapOk(pid)) failed += 1;
            }
            started = 0;
        }
        const pid: isize = @bitCast(linux.fork());
        if (pid == 0) linux.exit_group(oneRead(path));
        if (pid < 0) {
            failed += 1;
            continue;
        }
        pids[started] = @intCast(pid);
        started += 1;
    }
    for (pids[0..started]) |pid| {
        if (!reapOk(pid)) failed += 1;
    }
    return failed;
}

fn reapOk(pid: i32) bool {
    var raw: i32 = 0;
    while (true) {
        const rc = linux.wait4(pid, &raw, 0, null);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                const status: u32 = @bitCast(raw);
                return linux.W.IFEXITED(status) and linux.W.EXITSTATUS(status) == 0;
            },
            .INTR => continue,
            else => return false,
        }
    }
}

const testing = std.testing;

fn scratch(a: Allocator) ![]u8 {
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/cvmfs-{d}-{d}", .{ cwd, linux.getpid(), @intFromPtr(&cwd_buf) });
    try common.atomic.makedirs(root);
    return root;
}

fn writeAt(path: []const u8, text: []const u8) !void {
    const fd = try sys.openat(fsx.cwd, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    defer sys.close(fd);
    try sys.writeAll(fd, text);
}

test "the repository is EESSI unless EESSI_CVMFS_REPO is an absolute path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    const pub_repo = repository(&env);
    try testing.expectEqualStrings("/cvmfs/software.eessi.io", pub_repo.path);
    try testing.expectEqualStrings("software.eessi.io", pub_repo.name);
    try env.put("EESSI_CVMFS_REPO", "relative/repo");
    try testing.expectEqualStrings("software.eessi.io", repository(&env).name);
    try env.put("EESSI_CVMFS_REPO", "/cvmfs/software.example/");
    const named = repository(&env);
    try testing.expectEqualStrings("/cvmfs/software.example", named.path);
    try testing.expectEqualStrings("software.example", named.name);
}

test "a stat names a directory, a missing path and a forced stale mount" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try scratch(arena.allocator());
    defer fsx.deleteTree(arena.allocator(), fsx.cwd, root) catch {};
    try testing.expectEqual(Mount.ok, mountState(root, null));
    try testing.expectEqual(Mount.absent, mountState(try std.fmt.allocPrint(arena.allocator(), "{s}/missing", .{root}), null));
    try testing.expectEqual(Mount.enotconn, mountState(root, "ENOTCONN"));
    try testing.expectEqual(Mount.eio, mountState(root, "EIO"));
    try testing.expectEqual(Mount.absent, mountState(root, "ABSENT"));
}

test "the environment proxy wins, and a later client file wins over an earlier one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try scratch(a);
    defer fsx.deleteTree(a, fsx.cwd, root) catch {};
    try common.atomic.makedirs(try std.fs.path.join(a, &.{ root, "domain.d" }));
    try common.atomic.makedirs(try std.fs.path.join(a, &.{ root, "config.d" }));
    try writeAt(try std.fs.path.join(a, &.{ root, "default.local" }), "CVMFS_HTTP_PROXY=http://old:3128\n");
    try writeAt(try std.fs.path.join(a, &.{ root, "domain.d", "eessi.io.local" }), "export CVMFS_HTTP_PROXY=\"http://domain:3128\"\n");
    try writeAt(try std.fs.path.join(a, &.{ root, "config.d", "software.eessi.io.local" }), "# comment\nCVMFS_HTTP_PROXY=DIRECT\n");

    var env = std.process.Environ.Map.init(a);
    const from_file = try readProxy(a, &env, root, "software.eessi.io");
    try testing.expectEqual(ProxyMode.direct, from_file.mode);
    try testing.expect(!from_file.host_injected);
    try testing.expect(std.mem.endsWith(u8, from_file.from, "config.d/software.eessi.io.local"));

    try env.put("CVMFS_HTTP_PROXY", " http://host:3128 ");
    const from_env = try readProxy(a, &env, root, "software.eessi.io");
    try testing.expect(from_env.host_injected);
    try testing.expectEqualStrings("http://host:3128", from_env.value);
    try testing.expectEqualStrings("environment CVMFS_HTTP_PROXY", from_env.from);
}

test "an empty CVMFS_HTTP_PROXY clears an earlier file assignment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try scratch(a);
    defer fsx.deleteTree(a, fsx.cwd, root) catch {};
    try common.atomic.makedirs(try std.fs.path.join(a, &.{ root, "config.d" }));
    try writeAt(try std.fs.path.join(a, &.{ root, "default.conf" }), "CVMFS_HTTP_PROXY=\"http://old:3128\"\n");
    try writeAt(try std.fs.path.join(a, &.{ root, "default.local" }), "CVMFS_HTTP_PROXY=\"\"\n");

    var env = std.process.Environ.Map.init(a);
    const cleared_by_later_file = try readProxy(a, &env, root, "software.eessi.io");
    try testing.expectEqual(ProxyMode.unset, cleared_by_later_file.mode);

    try writeAt(
        try std.fs.path.join(a, &.{ root, "config.d", "software.eessi.io.local" }),
        "CVMFS_HTTP_PROXY=\"http://first:3128\"\nCVMFS_HTTP_PROXY=\n",
    );
    const cleared_in_same_file = try readProxy(a, &env, root, "software.eessi.io");
    try testing.expectEqual(ProxyMode.unset, cleared_in_same_file.mode);
}

test "export with tab prefix sets CVMFS_HTTP_PROXY" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try scratch(a);
    defer fsx.deleteTree(a, fsx.cwd, root) catch {};
    try writeAt(try std.fs.path.join(a, &.{ root, "default.local" }), "export\tCVMFS_HTTP_PROXY=\"http://tab:3128\"\n");

    var env = std.process.Environ.Map.init(a);
    const got = try readProxy(a, &env, root, "software.eessi.io");
    try testing.expectEqual(ProxyMode.proxy, got.mode);
    try testing.expectEqualStrings("http://tab:3128", got.value);
}

test "quoted CVMFS_HTTP_PROXY trims surrounding spaces and tabs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try scratch(a);
    defer fsx.deleteTree(a, fsx.cwd, root) catch {};
    var env = std.process.Environ.Map.init(a);

    try writeAt(try std.fs.path.join(a, &.{ root, "default.local" }), "CVMFS_HTTP_PROXY=\" DIRECT \"\n");
    const direct = try readProxy(a, &env, root, "software.eessi.io");
    try testing.expectEqual(ProxyMode.direct, direct.mode);
    try testing.expectEqualStrings("DIRECT", direct.value);

    try writeAt(try std.fs.path.join(a, &.{ root, "default.local" }), "CVMFS_HTTP_PROXY=\" \t \"\n");
    const blank = try readProxy(a, &env, root, "software.eessi.io");
    try testing.expectEqual(ProxyMode.unset, blank.mode);
}

test "a parallel read uses srun when it is on PATH, and forks when it is not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try scratch(a);
    defer fsx.deleteTree(a, fsx.cwd, root) catch {};
    const repo = try std.fs.path.join(a, &.{ root, "repo" });
    try common.atomic.makedirs(repo);
    const no_env: proc.Envp = &[_:null]?[*:0]const u8{};
    const forked = parallelProbe(a, repo, 2, true, false, null, no_env);
    try testing.expectEqual(ParallelKind.fork_ok, forked.kind);

    const bin = try std.fs.path.join(a, &.{ root, "bin" });
    try common.atomic.makedirs(bin);
    const srun = try std.fs.path.join(a, &.{ bin, "srun" });
    const fd = try sys.openat(fsx.cwd, srun, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o755);
    try sys.writeAll(fd,
        \\#!/bin/sh
        \\dir=$(dirname "$0")
        \\printf '%s\n' "$@" > "$dir/argv"
        \\exit 0
        \\
    );
    _ = linux.fchmod(fd, 0o755);
    sys.close(fd);
    const found = (try proc.which(a, "srun", bin)).?;
    const ran = parallelProbe(a, repo, 2, true, false, found, no_env);
    try testing.expectEqual(ParallelKind.srun_ok, ran.kind);
    const recorded = readFile(a, try std.fs.path.join(a, &.{ bin, "argv" })).?;
    try testing.expect(std.mem.indexOf(u8, recorded, "-n\n2\nstat\n") != null);
    try testing.expect(std.mem.indexOf(u8, recorded, repo) != null);

    const outside = parallelProbe(a, repo, 2, false, false, null, no_env);
    try testing.expectEqual(ParallelKind.outside, outside.kind);
    const stale = parallelProbe(a, repo, 2, true, true, found, no_env);
    try testing.expectEqual(ParallelKind.stale, stale.kind);

    const many = parallelProbe(a, repo, 11, true, false, null, no_env);
    try testing.expectEqual(ParallelKind.fork_ok, many.kind);
    try testing.expectEqual(@as(u8, 11), many.tasks);
}

test "readProxy ignores a FIFO client config file instead of blocking" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try scratch(a);
    defer fsx.deleteTree(a, fsx.cwd, root) catch {};
    const fifo = try std.fs.path.join(a, &.{ root, "default.local" });
    var zbuf: [sys.path_max:0]u8 = undefined;
    const zfifo = try sys.z(&zbuf, fifo);
    try testing.expectEqual(
        linux.E.SUCCESS,
        linux.errno(linux.mknodat(linux.AT.FDCWD, zfifo.ptr, 0o010600, 0)),
    );
    var env = std.process.Environ.Map.init(a);
    const got = try readProxy(a, &env, root, "software.eessi.io");
    try testing.expectEqual(ProxyMode.unset, got.mode);
}
