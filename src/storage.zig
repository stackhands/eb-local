//! Where a build may write: the allocation's own node-local mount, and a
//! durable installation prefix that is neither node-local nor shared
//! scratch. Mounts are read from /proc/self/mountinfo.
const std = @import("std");
const linux = std.os.linux;
const build_options = @import("build_options");
const common = @import("zig_common");
const sys = common.sys;
const fsx = common.fsx;
const Allocator = std.mem.Allocator;

/// Why a path was refused: in `message`, what was refused and why, as one
/// clause; in `fix`, what changes that, naming the setting, variable or
/// command, and for a setting its value and where it was set.
pub const Refusal = struct {
    message: []const u8 = "",
    fix: []const u8 = "",
};

/// `error.Refused` when a path may not be used, with what and why in the
/// `Refusal`.
pub const Error = error{Refused} || Allocator.Error;

fn refuse(a: Allocator, r: *Refusal, comptime what: []const u8, what_args: anytype, comptime fix: []const u8, fix_args: anytype) Error {
    const message = try std.fmt.allocPrint(a, what, what_args);
    // Not errdefer: every return is an error, and r keeps the message.
    const fixed = std.fmt.allocPrint(a, fix, fix_args) catch |e| {
        a.free(message);
        return e;
    };
    r.* = .{ .message = message, .fix = fixed };
    return error.Refused;
}

/// Format `e` with its kernel errno when it maps to `sys.Error`, otherwise
/// return the Zig error name.
pub fn describeError(e: anyerror) []const u8 {
    return if (sys.asError(e)) |se| sys.describe(se) else @errorName(e);
}

/// A line of `/proc/self/mountinfo`: where the file system is mounted, its
/// type, and its mount options.
pub const Mount = struct {
    target: []const u8,
    fstype: []const u8,
    options: []const u8,
};

/// mountinfo escapes space, tab, newline and backslash as \ooo.
fn unescape(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 3 < s.len) {
            const oct = s[i + 1 .. i + 4];
            if (oct[0] >= '0' and oct[0] <= '3' and oct[1] >= '0' and oct[1] <= '7' and oct[2] >= '0' and oct[2] <= '7') {
                const c: u8 = ((oct[0] - '0') << 6) | ((oct[1] - '0') << 3) | (oct[2] - '0');
                try out.append(a, c);
                i += 3;
                continue;
            }
        }
        try out.append(a, s[i]);
    }
    return out.items;
}

/// The mount `path` lies on: the last entry (a later mount covers an
/// earlier one) whose target is `path` or a parent of it.
pub fn mountOf(a: Allocator, mountinfo: []const u8, path: []const u8) Allocator.Error!?Mount {
    var best: ?Mount = null;
    var lines = std.mem.splitScalar(u8, mountinfo, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const sep = std.mem.indexOf(u8, line, " - ") orelse continue;
        var head = std.mem.tokenizeScalar(u8, line[0..sep], ' ');
        var fields: [6][]const u8 = undefined;
        var n: usize = 0;
        while (head.next()) |f| : (n += 1) {
            if (n < fields.len) fields[n] = f;
        }
        if (n < 6) continue;
        var tail = std.mem.tokenizeScalar(u8, line[sep + 3 ..], ' ');
        const fstype = tail.next() orelse continue;
        const target = try unescape(a, fields[4]);
        const inside = std.mem.eql(u8, target, "/") or std.mem.eql(u8, path, target) or
            (std.mem.startsWith(u8, path, target) and path.len > target.len and path[target.len] == '/');
        if (!inside) continue;
        if (best) |b| if (target.len < b.target.len) continue;
        best = .{ .target = target, .fstype = fstype, .options = fields[5] };
    }
    return best;
}

const Seen = struct { dev: u64, ino: u64, end_idx: usize };

fn pathOf(a: Allocator, parts: []const []const u8) Allocator.Error![]const u8 {
    if (parts.len == 0) return "/";
    var out: std.ArrayList(u8) = .empty;
    for (parts) |p| {
        try out.append(a, '/');
        try out.appendSlice(a, p);
    }
    return out.items;
}

fn readLink(a: Allocator, path: []const u8) Allocator.Error!?[]const u8 {
    var zb: [sys.path_max:0]u8 = undefined;
    const zp = sys.z(&zb, path) catch return null;
    var buf: [sys.path_max]u8 = undefined;
    const n = linux.readlinkat(linux.AT.FDCWD, zp.ptr, &buf, buf.len);
    if (linux.errno(n) != .SUCCESS or n == 0 or n >= buf.len) return null;
    return try a.dupe(u8, buf[0..n]);
}

fn existsDir(path: []const u8) bool {
    const st = fsx.statAt(fsx.cwd, path, false) catch return false;
    return st.isDir();
}

/// `path` made absolute and normal as `readlink -m` does. A symbolic link is
/// resolved even when its target does not exist yet, so `link/..` is the
/// parent of the link's target and a dangling link onto shared scratch is
/// visible to the prefix check. A link cycle is kept as a literal component,
/// which is what `readlink -m` prints, instead of being walked forever.
pub fn canonical(a: Allocator, path: []const u8, cwd: []const u8) Allocator.Error![]const u8 {
    const abs = if (path.len > 0 and path[0] == '/') path else try std.fs.path.join(a, &.{ cwd, path });
    var pending: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, abs, '/');
    while (it.next()) |part| try pending.append(a, part);
    var out: std.ArrayList([]const u8) = .empty;
    var seen: std.ArrayList(Seen) = .empty;
    var links: usize = 0;
    var missing = false;
    var idx: usize = 0;
    while (idx < pending.items.len) {
        while (seen.items.len > 0 and seen.items[seen.items.len - 1].end_idx <= idx) _ = seen.pop();
        const part = pending.items[idx];
        if (part.len == 0 or std.mem.eql(u8, part, ".")) {
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, part, "..")) {
            if (out.items.len > 0) _ = out.pop();
            if (missing and existsDir(try pathOf(a, out.items))) missing = false;
            idx += 1;
            continue;
        }
        if (missing) {
            try out.append(a, part);
            idx += 1;
            continue;
        }
        const next = try pathOf(a, try joined(a, out.items, part));
        const st = fsx.statAt(fsx.cwd, next, false) catch {
            missing = true;
            try out.append(a, part);
            idx += 1;
            continue;
        };
        if (!st.isLink()) {
            try out.append(a, part);
            idx += 1;
            continue;
        }
        var loop = false;
        for (seen.items) |s| if (s.dev == st.dev and s.ino == st.ino) {
            loop = true;
            break;
        };
        if (loop or links >= 40) {
            // The same link again in its own expansion, or more links than
            // Linux will follow: readlink -m stops and keeps the name.
            missing = true;
            try out.append(a, part);
            idx += 1;
            continue;
        }
        links += 1;
        const target = (try readLink(a, next)) orelse {
            missing = true;
            try out.append(a, part);
            idx += 1;
            continue;
        };
        var extra: std.ArrayList([]const u8) = .empty;
        if (target.len > 0 and target[0] == '/') {
            out.clearRetainingCapacity();
            missing = false;
        }
        var ti = std.mem.tokenizeScalar(u8, target, '/');
        while (ti.next()) |c| try extra.append(a, c);
        const delta: isize = @as(isize, @intCast(extra.items.len)) - 1;
        for (seen.items) |*s| {
            s.end_idx = @intCast(@as(isize, @intCast(s.end_idx)) + delta);
        }
        try seen.append(a, .{ .dev = st.dev, .ino = st.ino, .end_idx = idx + extra.items.len });
        // The link component is replaced by its target; idx stays so the
        // target is what the next iteration reads.
        var neu: std.ArrayList([]const u8) = .empty;
        try neu.appendSlice(a, pending.items[0..idx]);
        try neu.appendSlice(a, extra.items);
        try neu.appendSlice(a, pending.items[idx + 1 ..]);
        pending = neu;
    }
    return pathOf(a, out.items);
}

fn joined(a: Allocator, parts: []const []const u8, last: []const u8) Allocator.Error![]const []const u8 {
    var all: std.ArrayList([]const u8) = .empty;
    try all.appendSlice(a, parts);
    try all.append(a, last);
    return all.items;
}

/// Whether `path` is `root` or below it, compared by whole components; both
/// are already canonical.
pub fn under(path: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, root, "/")) return path.len > 0 and path[0] == '/';
    if (std.mem.eql(u8, path, root)) return true;
    return std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == '/';
}

/// The allocation's node-local mount that `jobRoot` checked.
pub const JobRoot = struct {
    path: []const u8,
};

/// storage.node_local_mount unless the site sets it: the user, a dot and
/// the job id.
pub const default_mount = "%u.%j";

/// The site file's node-local settings, each with where it was set, as
/// `eb-local config` shows it.
pub const NodeLocal = struct {
    root: []const u8,
    root_from: []const u8 = "default",
    mount: []const u8 = default_mount,
    mount_from: []const u8 = "default",
    fstype: []const u8 = "xfs",
    fstype_from: []const u8 = "default",
};

// What changes a refusal of the job's mount, for Refusal.fix.
const where_fix = "storage.node_local_root, {s} [{s}], and storage.node_local_mount, {s} [{s}], name it; " ++
    "build in an allocation that has a node-local disk, or set them in the site file to where Slurm mounts your job's node-local disk";
const job_fix = "eb-local finds the job's node-local mount by it; run eb-local inside the allocation, " ++
    "from salloc, srun or sbatch, and leave SLURM_JOB_ID as Slurm sets it";
const user_fix = "eb-local puts your user name, as id -un prints it, for %u in storage.node_local_mount, {s} [{s}]; " ++
    "run eb-local as a user that has one";
const pattern_fix = "Set it in the site file to one file name of letters, digits, '.', '_', '-', " ++
    "%u (the user) and %j (the job id), with %j in it";
const link_fix = "A link could lead a build onto another job's or shared storage, so none is followed; ";
const owner_fix = "storage.node_local_mount, {s} [{s}], names your job's own mount below storage.node_local_root, {s} [{s}], " ++
    "with %u for your user name and %j for the job id; set them in the site file to where Slurm mounts your job's node-local disk";
const mountinfo_fix = "eb-local reads the mount table to check that the job's mount is node-local; run it where /proc is mounted";
const fstype_fix = "A build's workspace must be on node-local disk, not shared or memory-backed storage; " ++
    "storage.node_local_fstype, {s} [{s}], names the nodes' file system: set it in the site file if their disks use another, " ++
    "or build in an allocation that has a node-local disk";
const own_mount_fix = "Each job's workspace must be a mount made for the job, which goes with it; " ++ where_fix;
const rw_fix = "A build writes its workspace there; build in an allocation whose node-local disk is writable, and tell the site";

fn whereArgs(nl: NodeLocal) struct { []const u8, []const u8, []const u8, []const u8 } {
    return .{ nl.root, nl.root_from, nl.mount, nl.mount_from };
}

/// A storage.node_local_mount: one file name of letters, digits, '.', '_',
/// '-', %u (the user) and %j (the job id). It must hold %j, so that each
/// allocation has a mount of its own.
pub fn validMountPattern(p: []const u8) bool {
    if (p.len == 0 or p.len > 255 or std.mem.indexOf(u8, p, "%j") == null) return false;
    var i: usize = 0;
    while (i < p.len) : (i += 1) {
        const c = p[i];
        if (c == '%') {
            if (i + 1 == p.len or (p[i + 1] != 'u' and p[i + 1] != 'j')) return false;
            i += 1;
        } else if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return false;
    }
    return true;
}

fn mountName(a: Allocator, pattern: []const u8, user: []const u8, job_id: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '%' and i + 1 < pattern.len) {
            const with: ?[]const u8 = switch (pattern[i + 1]) {
                'u' => user,
                'j' => job_id,
                else => null,
            };
            if (with) |w| {
                try out.appendSlice(a, w);
                i += 1;
                continue;
            }
        }
        try out.append(a, pattern[i]);
    }
    return out.toOwnedSlice(a);
}

/// The allocation's node-local mount: <root>/<mount>, the mount name with
/// the user and the job id filled in, an owned, writable, canonical
/// directory that is its own mount of `nl.fstype`.
pub fn jobRoot(
    a: Allocator,
    nl: NodeLocal,
    job_id: []const u8,
    user: []const u8,
    mountinfo: []const u8,
    uid: linux.uid_t,
    r: *Refusal,
) Error!JobRoot {
    const job_ok = job_id.len > 0 and job_id[0] != '0' and for (job_id) |c| {
        if (!std.ascii.isDigit(c)) break false;
    } else true;
    if (!job_ok) return refuse(a, r, "SLURM_JOB_ID={s} is not a Slurm job id", .{job_id}, job_fix, .{});
    if (user.len == 0 or std.mem.indexOfAny(u8, user, "/\x00") != null or std.mem.eql(u8, user, "..") or std.mem.eql(u8, user, "."))
        return refuse(a, r, "the user name \"{s}\" cannot be part of a path", .{user}, user_fix, .{ nl.mount, nl.mount_from });
    if (!validMountPattern(nl.mount))
        return refuse(a, r, "storage.node_local_mount, {s} [{s}], is not a mount name", .{ nl.mount, nl.mount_from }, pattern_fix, .{});
    const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ nl.root, try mountName(a, nl.mount, user, job_id) });
    const st = fsx.statAt(fsx.cwd, path, false) catch |e| return switch (e) {
        error.NotFound => refuse(a, r, "the node-local mount {s} does not exist", .{path}, where_fix, whereArgs(nl)),
        else => refuse(a, r, "the node-local mount {s} cannot be read ({s})", .{ path, @errorName(e) }, where_fix, whereArgs(nl)),
    };
    if (st.isLink()) return refuse(a, r, "the node-local mount {s} is a symbolic link", .{path}, link_fix ++
        "build in an allocation whose node-local mount is a directory of its own", .{});
    if (!st.isDir()) return refuse(a, r, "the node-local mount {s} is not a directory", .{path}, where_fix, whereArgs(nl));
    var zb: [sys.path_max:0]u8 = undefined;
    const zp = sys.z(&zb, path) catch return refuse(a, r, "the node-local mount {s} is too long a path", .{path}, where_fix, whereArgs(nl));
    if (linux.errno(linux.faccessat(linux.AT.FDCWD, zp.ptr, linux.W_OK | linux.X_OK, 0)) != .SUCCESS)
        return refuse(a, r, "the node-local mount {s} is not writable by you", .{path}, where_fix, whereArgs(nl));
    var buf: [sys.path_max]u8 = undefined;
    const real = fsx.realpath(fsx.cwd, path, &buf) catch |e|
        return refuse(a, r, "the node-local mount {s} cannot be resolved ({s})", .{ path, @errorName(e) }, where_fix, whereArgs(nl));
    if (!std.mem.eql(u8, real, path)) {
        var root_buf: [sys.path_max]u8 = undefined;
        const real_root = fsx.realpath(fsx.cwd, nl.root, &root_buf) catch nl.root;
        return refuse(a, r, "the node-local mount {s} is reached through a symbolic link, as {s}", .{ path, real }, link_fix ++
            "set storage.node_local_root, {s} [{s}], in the site file to the directory itself, {s}", .{ nl.root, nl.root_from, real_root });
    }
    if (st.uid != uid)
        return refuse(a, r, "the node-local mount {s} belongs to uid {d}, not to you (uid {d})", .{ path, st.uid, uid }, owner_fix, .{ nl.mount, nl.mount_from, nl.root, nl.root_from });
    const m = (try mountOf(a, mountinfo, path)) orelse
        return refuse(a, r, "no mount in /proc/self/mountinfo holds the node-local mount {s}", .{path}, mountinfo_fix, .{});
    if (!std.mem.eql(u8, m.fstype, nl.fstype))
        return refuse(a, r, "the node-local mount {s} is on {s}, not {s}", .{ path, m.fstype, nl.fstype }, fstype_fix, .{ nl.fstype, nl.fstype_from });
    if (!std.mem.eql(u8, m.target, path))
        return refuse(a, r, "the node-local mount {s} is not a mount of its own but part of {s}", .{ path, m.target }, own_mount_fix, whereArgs(nl));
    var opts = std.mem.tokenizeScalar(u8, m.options, ',');
    while (opts.next()) |o| {
        if (std.mem.eql(u8, o, "rw")) return .{ .path = path };
    }
    return refuse(a, r, "the node-local mount {s} is not mounted read-write ({s})", .{ path, m.options }, rw_fix, .{});
}

/// A workspace eb-local made: a real directory of the caller named
/// eb-local.XXXXXXXX directly in the job mount.
pub fn ownWorkspace(job_root: []const u8, path: []const u8, uid: linux.uid_t) bool {
    if (!std.mem.startsWith(u8, path, job_root) or path.len != job_root.len + 1 + "eb-local.".len + 8) return false;
    const name = path[job_root.len + 1 ..];
    if (path[job_root.len] != '/' or !std.mem.startsWith(u8, name, "eb-local.")) return false;
    for (name["eb-local.".len..]) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    const st = fsx.statAt(fsx.cwd, path, false) catch return false;
    return st.isDir() and st.uid == uid;
}

/// Remove `path` and everything under it that is on `dev`. A mount point,
/// whose device differs, is left in place, as `rm --one-file-system` does.
/// Symbolic links are removed, not followed.
pub fn removeTreeDevice(a: Allocator, path: []const u8, dev: u64) (fsx.Error || Allocator.Error)!void {
    try removeOnDevice(a, fsx.cwd, path, dev);
}

/// Remove `path` and everything under it on its own file system, as
/// `removeTreeDevice` does for the device `path` is on.
pub fn removeTree(a: Allocator, path: []const u8) (fsx.Error || Allocator.Error)!void {
    const st = try fsx.statAt(fsx.cwd, path, false);
    try removeTreeDevice(a, path, st.dev);
}

fn removeOnDevice(a: Allocator, dir: sys.fd_t, name: []const u8, dev: u64) (fsx.Error || Allocator.Error)!void {
    const st = try fsx.statAt(dir, name, false);
    if (st.dev != dev) return;
    if (!st.isDir()) {
        try sys.unlinkat(dir, name, 0);
        return;
    }
    const fd = fsx.openDir(dir, name, false) catch |e| blk: {
        if (e == error.AccessDenied and st.uid == linux.getuid()) {
            var zb: [sys.path_max:0]u8 = undefined;
            if (sys.z(&zb, name)) |zp| {
                _ = linux.fchmodat(dir, zp.ptr, @intCast((st.mode & 0o7777) | 0o700));
            } else |_| {}
            break :blk try fsx.openDir(dir, name, false);
        }
        return e;
    };
    if (st.uid == linux.getuid() and (st.mode & 0o700) != 0o700) {
        sys.fchmod(fd, @intCast((st.mode & 0o7777) | 0o700)) catch {};
    }
    {
        defer sys.close(fd);
        var it = try fsx.DirIter.init(a, fd);
        defer it.deinit(a);
        while (try it.next()) |e| try removeOnDevice(a, fd, e.name, dev);
    }
    try sys.unlinkat(dir, name, linux.AT.REMOVEDIR);
}

/// A new eb-local.XXXXXXXX directory, mode 0700, in `job_root`.
pub fn makeWorkspace(a: Allocator, job_root: []const u8) (fsx.Error || Allocator.Error)![]const u8 {
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        var raw: [8]u8 = undefined;
        if (linux.getrandom(&raw, raw.len, 0) != raw.len) return error.Unexpected;
        var name: [8]u8 = undefined;
        for (raw, 0..) |b, i| name[i] = alphabet[b % alphabet.len];
        const path = try std.fmt.allocPrint(a, "{s}/eb-local.{s}", .{ job_root, name });
        var zb: [sys.path_max:0]u8 = undefined;
        const zp = try sys.z(&zb, path);
        // mkdir applies the process umask. With umask 0777 the directory
        // would be mode 000 and could not be opened to correct it, so the
        // umask is cleared for this one call. eb-local is one thread.
        const previous: linux.mode_t = @intCast(linux.syscall1(.umask, 0));
        const rc = linux.mkdirat(linux.AT.FDCWD, zp.ptr, 0o700);
        _ = linux.syscall1(.umask, previous);
        if (sys.result(rc)) |made| {
            if (made != null) return path;
        } else |e| if (e != error.Exists) return e;
    }
    return error.Exists;
}

/// Capacity available to an unprivileged caller.
pub const Capacity = struct {
    bytes: u64,
    inodes: u64,
};

const StatFs = extern struct {
    fs_type: i64,
    block_size: i64,
    blocks: u64,
    blocks_free: u64,
    blocks_available: u64,
    files: u64,
    files_free: u64,
    fsid: [2]i32,
    name_max: i64,
    fragment_size: i64,
    flags: i64,
    spare: [4]i64,
};

/// Free bytes and inodes on the file system containing `path`.
pub fn capacity(path: []const u8) sys.Error!Capacity {
    var path_buf: [sys.path_max:0]u8 = undefined;
    const zpath = try sys.z(&path_buf, path);
    var stat: StatFs = undefined;
    const rc = linux.syscall2(.statfs, @intFromPtr(zpath.ptr), @intFromPtr(&stat));
    _ = try sys.result(rc);
    const size: u64 = @intCast(if (stat.fragment_size > 0) stat.fragment_size else stat.block_size);
    return .{
        .bytes = std.math.mul(u64, stat.blocks_available, size) catch std.math.maxInt(u64),
        .inodes = stat.files_free,
    };
}

/// Whether a mount option is present as one whole comma-separated word.
pub fn hasMountOption(options: []const u8, wanted: []const u8) bool {
    var words = std.mem.splitScalar(u8, options, ',');
    while (words.next()) |word| if (std.mem.eql(u8, word, wanted)) return true;
    return false;
}

/// Operational storage class for a workspace. Configured shared roots and
/// network file systems are shared; other file systems are node-local.
pub fn workspaceClass(path: []const u8, fstype: []const u8, shared_roots: []const []const u8) []const u8 {
    for (shared_roots) |root| if (under(path, root)) return "shared";
    const shared_types = [_][]const u8{
        "9p",   "afs",    "beegfs", "ceph", "cifs",  "cvmfs", "fuse.sshfs",
        "gpfs", "lustre", "nfs",    "nfs4", "panfs", "smb3",
    };
    for (shared_types) |kind| if (std.mem.eql(u8, fstype, kind)) return "shared";
    return "node-local";
}

/// Result of creating, writing, renaming, executing and removing one probe.
pub const WorkspaceProbe = struct {
    created: bool = false,
    written: bool = false,
    renamed: bool = false,
    executed: bool = false,
    removed: bool = false,
};

/// Exercise the file operations a build workspace needs. `execute_result` is
/// a test seam; null executes the renamed probe.
pub fn probeWorkspace(
    io: std.Io,
    a: Allocator,
    path: []const u8,
    execute_result: ?bool,
) (fsx.Error || sys.Error || std.process.RunError || Allocator.Error)!WorkspaceProbe {
    const dir = try fsx.openDir(fsx.cwd, path, false);
    defer sys.close(dir);
    var random: [8]u8 = undefined;
    if (linux.getrandom(&random, random.len, 0) != random.len) return error.Unexpected;
    const first = try std.fmt.allocPrint(a, ".eb-local-doctor-{x}.probe", .{std.mem.readInt(u64, &random, .little)});
    const renamed = try std.fmt.allocPrint(a, "{s}.run", .{first});
    const absolute = try std.fs.path.join(a, &.{ path, renamed });
    var result: WorkspaceProbe = .{};
    const fd = try sys.openat(dir, first, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o700);
    result.created = true;
    var current = first;
    defer sys.unlinkat(dir, current, 0) catch {};
    {
        defer sys.close(fd);
        try sys.writeAll(fd, "#!/bin/sh\nexit 0\n");
        result.written = true;
    }
    try sys.renameat(dir, first, dir, renamed);
    current = renamed;
    result.renamed = true;
    result.executed = execute_result orelse blk: {
        const ran = std.process.run(a, io, .{
            .argv = &.{absolute},
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        }) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => break :blk false,
            else => return err,
        };
        break :blk ran.term.success();
    };
    try sys.unlinkat(dir, renamed, 0);
    result.removed = true;
    return result;
}

/// Default milliseconds to wait on a contended `flock` lock.
pub const default_lock_timeout_ms: u32 = 300_000;

/// Outcome of acquiring a bounded exclusive lock.
pub const LockResult = union(enum) {
    held: sys.fd_t,
    unlocked,
    failed,
};

/// Resolve the lock wait timeout in milliseconds from `EB_LOCAL_LOCK_TIMEOUT_MS`.
pub fn lockTimeoutMs(env: ?*const std.process.Environ.Map, err_msg: *[]const u8) ?u32 {
    const map = env orelse return default_lock_timeout_ms;
    const raw = map.get("EB_LOCAL_LOCK_TIMEOUT_MS") orelse return default_lock_timeout_ms;
    if (raw.len == 0) return default_lock_timeout_ms;
    for (raw) |ch| if (!std.ascii.isDigit(ch)) {
        err_msg.* = "EB_LOCAL_LOCK_TIMEOUT_MS must be a positive integer of milliseconds";
        return null;
    };
    const ms = std.fmt.parseInt(u32, raw, 10) catch {
        err_msg.* = "EB_LOCAL_LOCK_TIMEOUT_MS must be a positive integer of milliseconds";
        return null;
    };
    if (ms == 0) {
        err_msg.* = "EB_LOCAL_LOCK_TIMEOUT_MS must be a positive integer of milliseconds";
        return null;
    }
    return ms;
}

/// Set in `main` from `EB_LOCAL_TEST_FLOCK_ERRNO`, only in the test artifact,
/// so a test can emulate `ENOLCK` or `EOPNOTSUPP` from `flock`.
pub var test_flock_errno: ?linux.E = null;

/// True when `e` represents an unsupported `flock` operation on this filesystem.
pub fn flockUnsupported(e: sys.Error) bool {
    return e == error.Unsupported or sys.last_errno == .NOLCK or sys.last_errno == .OPNOTSUPP or sys.last_errno == .NOSYS;
}

/// Open `lock_path` without following symlinks and hold an exclusive lock
/// via `common.state.lockExclusive` with a bounded timeout. When `notify` is
/// true and another process holds the lock, prints one waiting line on
/// stderr before waiting. When `flock` is unsupported (`ENOLCK`, `ENOTSUP`,
/// `EOPNOTSUPP`, `ENOSYS`), prints one warning on stderr when `notify` is
/// true and returns `.unlocked`.
pub fn acquireBoundedLock(a: Allocator, lock_path: []const u8, timeout_ms: u32, notify: bool, err_msg: *[]const u8) LockResult {
    const fd = sys.openat(fsx.cwd, lock_path, .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0o666) catch |err| {
        err_msg.* = std.fmt.allocPrint(a, "cannot lock {s}: {s}", .{ lock_path, sys.describe(err) }) catch "cannot lock file";
        return .failed;
    };
    if (comptime build_options.test_ops) {
        if (test_flock_errno) |te| {
            if (notify) common.cli.err("eb-local: warning: cannot lock {s} ({s}); continuing unlocked\n", .{ lock_path, sys.describeErrno(te) });
            sys.close(fd);
            return .unlocked;
        }
    }
    if (common.state.lockExclusive(fd, 0)) |_| {
        return .{ .held = fd };
    } else |err| switch (err) {
        error.TimedOut => {
            if (notify) common.cli.err("eb-local: waiting for lock {s}; another eb-local run holds it\n", .{lock_path});
            common.state.lockExclusive(fd, timeout_ms) catch |wait_err| switch (wait_err) {
                error.TimedOut => {
                    sys.close(fd);
                    err_msg.* = std.fmt.allocPrint(a, "timed out after {d} ms waiting for lock {s}", .{ timeout_ms, lock_path }) catch "timed out waiting for lock";
                    return .failed;
                },
                else => |se| {
                    if (flockUnsupported(se)) {
                        if (notify) common.cli.err("eb-local: warning: cannot lock {s} ({s}); continuing unlocked\n", .{ lock_path, sys.describe(se) });
                        sys.close(fd);
                        return .unlocked;
                    }
                    const msg = sys.describe(se);
                    sys.close(fd);
                    err_msg.* = std.fmt.allocPrint(a, "cannot lock {s}: {s}", .{ lock_path, msg }) catch "cannot lock file";
                    return .failed;
                },
            };
            return .{ .held = fd };
        },
        else => |se| {
            if (flockUnsupported(se)) {
                if (notify) common.cli.err("eb-local: warning: cannot lock {s} ({s}); continuing unlocked\n", .{ lock_path, sys.describe(se) });
                sys.close(fd);
                return .unlocked;
            }
            const msg = sys.describe(se);
            sys.close(fd);
            err_msg.* = std.fmt.allocPrint(a, "cannot lock {s}: {s}", .{ lock_path, msg }) catch "cannot lock file";
            return .failed;
        },
    }
}

/// Acquire a non-blocking exclusive lock on `path` without printing errors,
/// returning null when it cannot be opened or locked.
pub fn acquireOptionalLock(path: []const u8) ?sys.fd_t {
    const fd = sys.openat(fsx.cwd, path, .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0o666) catch return null;
    common.state.lockExclusive(fd, 0) catch {
        sys.close(fd);
        return null;
    };
    return fd;
}

/// Release a lock descriptor returned by `acquireBoundedLock` or `acquireOptionalLock`.
pub fn releaseLock(lock: *?sys.fd_t) void {
    const fd = lock.* orelse return;
    lock.* = null;
    _ = linux.flock(fd, std.posix.LOCK.UN);
    sys.close(fd);
}

/// True when `path` is absent, unlocked, or on a filesystem without `flock`.
pub fn tryLockFree(path: []const u8) bool {
    const fd = sys.openat(fsx.cwd, path, .{
        .ACCMODE = .RDWR,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0) catch |e| switch (e) {
        error.NotFound => return true,
        else => return false,
    };
    defer sys.close(fd);
    common.state.lockExclusive(fd, 0) catch |e| switch (e) {
        error.TimedOut => return false,
        else => |se| return flockUnsupported(se),
    };
    _ = linux.flock(fd, std.posix.LOCK.UN);
    return true;
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

test "acquireBoundedLock uses state.lockExclusive with bounded timeout" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/bounded-lock-{d}", .{ cwd, linux.getpid() });
    try common.atomic.makedirs(root);
    defer fsx.deleteTree(a, fsx.cwd, root) catch {};

    var msg: []const u8 = "";
    const lock_path = try std.fs.path.join(a, &.{ root, ".test.lock" });
    var holder: ?sys.fd_t = switch (acquireBoundedLock(a, lock_path, 50, false, &msg)) {
        .held => |fd| fd,
        else => return error.TestUnexpectedResult,
    };
    defer releaseLock(&holder);

    var msg2: []const u8 = "";
    try testing.expectEqual(LockResult.failed, acquireBoundedLock(a, lock_path, 40, false, &msg2));
    try testing.expect(std.mem.indexOf(u8, msg2, "timed out after 40 ms") != null);

    releaseLock(&holder);
    var again: ?sys.fd_t = switch (acquireBoundedLock(a, lock_path, 50, false, &msg2)) {
        .held => |fd| fd,
        else => return error.TestUnexpectedResult,
    };
    releaseLock(&again);

    sys.last_errno = .NOLCK;
    try testing.expect(flockUnsupported(error.Unexpected));
    sys.last_errno = .OPNOTSUPP;
    try testing.expect(flockUnsupported(error.Unsupported));

    var bad_env = std.process.Environ.Map.init(a);
    try bad_env.put("EB_LOCAL_LOCK_TIMEOUT_MS", "+100");
    try testing.expect(lockTimeoutMs(&bad_env, &msg) == null);
    try bad_env.put("EB_LOCAL_LOCK_TIMEOUT_MS", "1_000");
    try testing.expect(lockTimeoutMs(&bad_env, &msg) == null);
}

test "the mount a path lies on" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const info =
        \\22 1 0:21 / / rw,relatime - xfs /dev/sda1 rw
        \\40 22 0:40 / /local rw,nosuid - xfs /dev/nvme0n1 rw
        \\41 40 0:41 / /local/u.123 rw,nosuid shared:5 - xfs /dev/nvme0n1 rw
        \\50 22 0:50 / /home rw - gpfs home rw
        \\51 22 0:51 / /mnt/with\040space ro - tmpfs tmpfs ro
        \\52 22 0:52 / /mnt/lit\+40_1\1_0 rw - xfs /dev/sdb1 rw
    ;
    const m = (try mountOf(a, info, "/local/u.123")).?;
    try testing.expectEqualStrings("/local/u.123", m.target);
    try testing.expectEqualStrings("xfs", m.fstype);
    try testing.expectEqualStrings("/local", (try mountOf(a, info, "/local/u.123x")).?.target);
    try testing.expectEqualStrings("/local", (try mountOf(a, info, "/local/u.1234")).?.target);
    try testing.expectEqualStrings("gpfs", (try mountOf(a, info, "/home/u/x")).?.fstype);
    try testing.expectEqualStrings("/mnt/with space", (try mountOf(a, info, "/mnt/with space/a")).?.target);
    try testing.expectEqualStrings("/mnt/lit\\+40_1\\1_0", (try mountOf(a, info, "/mnt/lit\\+40_1\\1_0/a")).?.target);
    try testing.expectEqualStrings("/", (try mountOf(a, info, "/etc")).?.target);
}

test "describeError preserves sys.Error text and falls back to error name" {
    sys.last_errno = .SUCCESS;
    try testing.expectEqualStrings("[Errno 2] No such file or directory", describeError(error.NotFound));
    try testing.expectEqualStrings("OutOfMemory", describeError(error.OutOfMemory));
}

test "canonical paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/no/such/place", try canonical(a, "/no/such/./x/../place", "/"));
    try testing.expectEqualStrings("/tmp/a/b", try canonical(a, "a/b", "/tmp"));
    // link/.. is the parent of the link's target, as readlink -m has it.
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/canonical-test-{d}", .{ cwd, linux.getpid() });
    try common.atomic.makedirs(try std.fmt.allocPrint(a, "{s}/deep/target", .{root}));
    defer fsx.deleteTree(a, fsx.cwd, root) catch {};
    var zt: [sys.path_max:0]u8 = undefined;
    var zl: [sys.path_max:0]u8 = undefined;
    _ = linux.symlinkat((try sys.z(&zt, try std.fmt.allocPrint(a, "{s}/deep/target", .{root}))).ptr, linux.AT.FDCWD, (try sys.z(&zl, try std.fmt.allocPrint(a, "{s}/lnk", .{root}))).ptr);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/deep/eessi", .{root}), try canonical(a, try std.fmt.allocPrint(a, "{s}/lnk/../eessi", .{root}), "/"));
    try testing.expect(under("/a/b", "/a"));
    try testing.expect(under("/a", "/a"));
    try testing.expect(!under("/ab", "/a"));
    try testing.expect(under("/a/b", "/"));
    try testing.expect(under("/", "/"));
    try testing.expect(!under("", "/"));
}

test "canonical matches readlink -m, including a link whose target is missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/canonical-m-{d}", .{ cwd, linux.getpid() });
    try common.atomic.makedirs(try std.fmt.allocPrint(a, "{s}/deep/target", .{root}));
    try common.atomic.makedirs(try std.fmt.allocPrint(a, "{s}/scratch/real", .{root}));
    defer fsx.deleteTree(a, fsx.cwd, root) catch {};
    const link = struct {
        fn at(allocator: Allocator, from: []const u8, to: []const u8) !void {
            var zf: [sys.path_max:0]u8 = undefined;
            var zt: [sys.path_max:0]u8 = undefined;
            _ = linux.symlinkat((try sys.z(&zt, to)).ptr, linux.AT.FDCWD, (try sys.z(&zf, from)).ptr);
            _ = allocator;
        }
    }.at;
    try link(a, try std.fmt.allocPrint(a, "{s}/lnk", .{root}), try std.fmt.allocPrint(a, "{s}/deep/target", .{root}));
    try link(a, try std.fmt.allocPrint(a, "{s}/dangling", .{root}), try std.fmt.allocPrint(a, "{s}/missing/target", .{root}));
    try link(a, try std.fmt.allocPrint(a, "{s}/rel", .{root}), "missing/target");
    try link(a, try std.fmt.allocPrint(a, "{s}/loop", .{root}), try std.fmt.allocPrint(a, "{s}/loop", .{root}));
    try link(a, try std.fmt.allocPrint(a, "{s}/a", .{root}), try std.fmt.allocPrint(a, "{s}/b", .{root}));
    try link(a, try std.fmt.allocPrint(a, "{s}/b", .{root}), try std.fmt.allocPrint(a, "{s}/a", .{root}));
    try link(a, try std.fmt.allocPrint(a, "{s}/toscratch", .{root}), try std.fmt.allocPrint(a, "{s}/scratch/not-yet", .{root}));
    // Each path below root, and what GNU readlink -m prints for it: the
    // contract of canonical. The host's readlink is not asked, because uutils
    // readlink, /usr/bin/readlink on Ubuntu 26.04, exits 1 on a link cycle
    // where GNU readlink -m keeps the name.
    const cases = [_][2][]const u8{
        .{ "lnk/../eessi", "deep/eessi" },
        .{ "dangling/../eessi", "missing/eessi" },
        .{ "dangling", "missing/target" },
        .{ "rel/../eessi", "missing/eessi" },
        .{ "loop/x", "loop/x" },
        .{ "a/x", "a/x" },
        .{ "no/such/./x/../place", "no/such/place" },
        .{ "toscratch/sources", "scratch/not-yet/sources" },
        .{ "deep/target/../../scratch/real", "scratch/real" },
        .{ "lnk/../../lnk/sub", "deep/target/sub" },
    };
    for (cases) |case| {
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, case[0] });
        const want = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, case[1] });
        const got = try canonical(a, path, "/");
        if (!std.mem.eql(u8, got, want)) {
            std.debug.print("canonical {s}\nreadlink  {s}\npath      {s}\n", .{ got, want, path });
            return error.TestUnexpectedResult;
        }
    }
    // The dangling link names scratch even though scratch/not-yet does not exist.
    const resolved = try canonical(a, try std.fmt.allocPrint(a, "{s}/toscratch/sources", .{root}), "/");
    try testing.expect(under(resolved, try std.fmt.allocPrint(a, "{s}/scratch", .{root})));
}

test "a workspace is private even when the umask clears every bit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/umask-ws-{d}", .{ cwd, linux.getpid() });
    try common.atomic.makedirs(root);
    defer fsx.deleteTree(a, fsx.cwd, root) catch {};
    const old: linux.mode_t = @intCast(linux.syscall1(.umask, 0o777));
    defer _ = linux.syscall1(.umask, old);
    const path = try makeWorkspace(a, root);
    try testing.expectEqual(@as(u32, 0o700), (try fsx.statAt(fsx.cwd, path, false)).perm());
}

test "a workspace that cannot be made says why, and leaves the umask as it was" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/no-ws-{d}", .{ cwd, linux.getpid() });
    try common.atomic.makedirs(root);
    defer fsx.deleteTree(a, fsx.cwd, root) catch {};
    const old: linux.mode_t = @intCast(linux.syscall1(.umask, 0o027));
    defer _ = linux.syscall1(.umask, old);
    try testing.expectError(error.NotFound, makeWorkspace(a, try std.fmt.allocPrint(a, "{s}/gone", .{root})));
    const file = try std.fmt.allocPrint(a, "{s}/file", .{root});
    sys.close(try sys.openat(fsx.cwd, file, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o600));
    try testing.expectError(error.NotDir, makeWorkspace(a, file));
    const long = try a.alloc(u8, sys.path_max);
    @memset(long, 'x');
    try testing.expectError(error.NameTooLong, makeWorkspace(a, long));
    try testing.expectEqual(@as(usize, 0o027), linux.syscall1(.umask, 0o027));
}

test "removeTree stays on one device" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/one-fs-{d}", .{ cwd, linux.getpid() });
    const nested = try std.fmt.allocPrint(a, "{s}/sub", .{root});
    const file = try std.fmt.allocPrint(a, "{s}/sub/f", .{root});
    try common.atomic.makedirs(nested);
    defer fsx.deleteTree(a, fsx.cwd, root) catch {};
    const fd = try sys.openat(fsx.cwd, file, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    sys.close(fd);
    const dev = (try fsx.statAt(fsx.cwd, root, false)).dev;
    try removeTreeDevice(a, root, dev +% 1);
    try testing.expect((try fsx.statAt(fsx.cwd, file, false)).isReg());
    try removeTree(a, root);
    try testing.expectError(error.NotFound, fsx.statAt(fsx.cwd, root, false));
}

test "the job mount is refused when another user owns it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const nodes = try std.fmt.allocPrint(a, "{s}/.zig-cache/storage-test-{d}", .{ cwd, linux.getpid() });
    const job = try std.fmt.allocPrint(a, "{s}/u.42", .{nodes});
    try common.atomic.makedirs(job);
    defer fsx.deleteTree(a, fsx.cwd, nodes) catch {};
    const info = try std.fmt.allocPrint(a, "1 0 0:1 / / rw - ext4 /dev/x rw\n2 1 0:2 / {s} rw,relatime - xfs /dev/y rw\n", .{job});
    var r: Refusal = .{};
    const ok = try jobRoot(a, .{ .root = nodes }, "42", "u", info, linux.getuid(), &r);
    try testing.expectEqualStrings(job, ok.path);
    try testing.expectError(error.Refused, jobRoot(a, .{ .root = nodes }, "42", "u", info, linux.getuid() + 1, &r));
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "the node-local mount {s} belongs to uid {d}, not to you (uid {d})", .{ job, linux.getuid(), linux.getuid() + 1 }), r.message);
    try testing.expectError(error.Refused, jobRoot(a, .{ .root = nodes, .fstype = "gpfs" }, "42", "u", info, linux.getuid(), &r));
    try testing.expectError(error.Refused, jobRoot(a, .{ .root = nodes }, "042", "u", info, linux.getuid(), &r));
    try testing.expectError(error.Refused, jobRoot(a, .{ .root = nodes, .mount = "job-%j" }, "42", "u", info, linux.getuid(), &r));
    try testing.expectError(error.Refused, jobRoot(a, .{ .root = nodes, .mount = "%u" }, "42", "u", info, linux.getuid(), &r));
    try testing.expect(std.mem.indexOf(u8, r.message, "node_local_mount") != null);
}

test "a refused job mount says what, why, and the setting that changes it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const nodes = try std.fmt.allocPrint(a, "{s}/.zig-cache/refusal-test-{d}", .{ cwd, linux.getpid() });
    const job = try std.fmt.allocPrint(a, "{s}/u.42", .{nodes});
    try common.atomic.makedirs(job);
    defer fsx.deleteTree(a, fsx.cwd, nodes) catch {};
    const nl: NodeLocal = .{ .root = nodes, .root_from = "site /etc/eb-local/config.toml:3", .fstype_from = "site /etc/eb-local/config.toml:5" };
    const uid = linux.getuid();
    const table = struct {
        fn of(allocator: Allocator, target: []const u8, options: []const u8, fstype: []const u8) ![]const u8 {
            return std.fmt.allocPrint(allocator, "1 0 0:1 / / rw - ext4 /dev/x rw\n2 1 0:2 / {s} {s} - {s} /dev/y rw\n", .{ target, options, fstype });
        }
    }.of;
    var r: Refusal = .{};
    const where = try std.fmt.allocPrint(a, "storage.node_local_root, {s} [site /etc/eb-local/config.toml:3], and storage.node_local_mount, %u.%j [default], name it; " ++
        "build in an allocation that has a node-local disk, or set them in the site file to where Slurm mounts your job's node-local disk", .{nodes});

    try testing.expectError(error.Refused, jobRoot(a, nl, "43", "u", try table(a, job, "rw", "xfs"), uid, &r));
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "the node-local mount {s}/u.43 does not exist", .{nodes}), r.message);
    try testing.expectEqualStrings(where, r.fix);

    try testing.expectError(error.Refused, jobRoot(a, nl, "42", "u", try table(a, job, "rw", "gpfs"), uid, &r));
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "the node-local mount {s} is on gpfs, not xfs", .{job}), r.message);
    try testing.expect(std.mem.indexOf(u8, r.fix, "storage.node_local_fstype, xfs [site /etc/eb-local/config.toml:5], names the nodes' file system") != null);

    try testing.expectError(error.Refused, jobRoot(a, nl, "42", "u", try table(a, nodes, "rw", "xfs"), uid, &r));
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "the node-local mount {s} is not a mount of its own but part of {s}", .{ job, nodes }), r.message);
    try testing.expect(std.mem.endsWith(u8, r.fix, where));

    try testing.expectError(error.Refused, jobRoot(a, nl, "42", "u", try table(a, job, "ro,relatime", "xfs"), uid, &r));
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "the node-local mount {s} is not mounted read-write (ro,relatime)", .{job}), r.message);

    try testing.expectError(error.Refused, jobRoot(a, nl, "4x2", "u", "", uid, &r));
    try testing.expectEqualStrings("SLURM_JOB_ID=4x2 is not a Slurm job id", r.message);
    try testing.expect(std.mem.indexOf(u8, r.fix, "run eb-local inside the allocation") != null);

    // A link in the root is named with the directory it leads to; the job's
    // own mount as a link is refused without one.
    const link = try std.fmt.allocPrint(a, "{s}-link", .{nodes});
    var zt: [sys.path_max:0]u8 = undefined;
    var zl: [sys.path_max:0]u8 = undefined;
    var zlink_buf: [sys.path_max:0]u8 = undefined;
    const zlink = try sys.z(&zlink_buf, link);
    _ = linux.symlinkat((try sys.z(&zt, nodes)).ptr, linux.AT.FDCWD, zlink.ptr);
    defer _ = linux.unlinkat(linux.AT.FDCWD, zlink.ptr, 0);
    try testing.expectError(error.Refused, jobRoot(a, .{ .root = link }, "42", "u", try table(a, job, "rw", "xfs"), uid, &r));
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "the node-local mount {s}/u.42 is reached through a symbolic link, as {s}", .{ link, job }), r.message);
    try testing.expect(std.mem.endsWith(u8, r.fix, try std.fmt.allocPrint(a, "set storage.node_local_root, {s} [default], in the site file to the directory itself, {s}", .{ link, nodes })));
    const alias = try std.fmt.allocPrint(a, "{s}/u.44", .{nodes});
    _ = linux.symlinkat((try sys.z(&zt, job)).ptr, linux.AT.FDCWD, (try sys.z(&zl, alias)).ptr);
    try testing.expectError(error.Refused, jobRoot(a, nl, "44", "u", try table(a, alias, "rw", "xfs"), uid, &r));
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "the node-local mount {s} is a symbolic link", .{alias}), r.message);
}

test "the allocation's mount name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("u.42", try mountName(a, default_mount, "u", "42"));
    try testing.expectEqualStrings("job-42", try mountName(a, "job-%j", "u", "42"));
    try testing.expectEqualStrings("u_42_u", try mountName(a, "%u_%j_%u", "u", "42"));
    // A user name is filled in, never read as a pattern.
    try testing.expectEqualStrings("a%jb.42", try mountName(a, default_mount, "a%jb", "42"));
    for ([_][]const u8{ default_mount, "%j", "job-%j", "slurm.%j.%u" }) |ok|
        try testing.expect(validMountPattern(ok));
    for ([_][]const u8{ "", "%u", "u.42", "%u/%j", "../%j", "%x%j", "%j%", "%%j", "%j %u", "%j/" }) |bad|
        try testing.expect(!validMountPattern(bad));
}

test "removeTree removes read-only subdirectories owned by the caller" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/ro-tree-{d}", .{ cwd, linux.getpid() });
    const ro_dir = try std.fmt.allocPrint(a, "{s}/sub dir", .{root});
    const file = try std.fmt.allocPrint(a, "{s}/read-only.txt", .{ro_dir});
    try common.atomic.makedirs(ro_dir);
    defer removeTree(a, root) catch {};
    const fd = try sys.openat(fsx.cwd, file, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o444);
    sys.close(fd);
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.fchmodat(linux.AT.FDCWD, (try sys.z(&zb, ro_dir)).ptr, 0o555);
    _ = linux.fchmodat(linux.AT.FDCWD, (try sys.z(&zb, root)).ptr, 0o555);
    try removeTree(a, root);
    try testing.expectError(error.NotFound, fsx.statAt(fsx.cwd, root, false));
}
