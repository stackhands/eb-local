//! Secrets for a build: each names the variable eb receives and where its
//! value comes from. A build reads the ones it gets (config.buildSecrets),
//! after every other check; `config --check` and `doctor` read each one and
//! say only whether it can be read. Values go only into eb's environment
//! and are never printed. A failed read reports why without the value.
//! After the build, logs written during it are scanned and every occurrence
//! of a value is replaced.
const std = @import("std");
const linux = std.os.linux;
const common = @import("zig_common");
const sys = common.sys;
const fsx = common.fsx;
const proc = common.proc;
const config = @import("config.zig");
const storage = @import("storage.zig");
const Allocator = std.mem.Allocator;

/// Largest secret accepted from any source.
pub const value_limit = 64 * 1024;
/// How long nimvault may take (a GPG agent may ask for a passphrase).
pub const nimvault_timeout_ms = 30_000;

/// A secret's value, read for one build: the variable eb receives, and
/// what it is set to.
pub const Resolved = struct {
    name: []const u8,
    value: []const u8,
};

/// Why a secret could not be read, filled in when `error.Unavailable` is
/// returned. It names the secret and its source, never a value.
pub const Failure = struct {
    message: []const u8 = "",
};

/// `error.Unavailable` when a secret's source cannot give its value, with
/// the reason in the `Failure`.
pub const Error = error{Unavailable} || Allocator.Error;

/// Which nimvault runs and which vault it reads.
pub const Nimvault = struct {
    /// An absolute path; empty means the first nimvault on PATH.
    program: []const u8 = "",
    /// Passed as --vault; ~/ is HOME. Empty leaves nimvault to find the vault
    /// from NIMVAULT_VAULT_REPO or the current directory.
    vault: []const u8 = "",
};

fn fail(a: Allocator, f: *Failure, comptime fmt: []const u8, args: anytype) Error {
    f.message = try std.fmt.allocPrint(a, fmt, args);
    return error.Unavailable;
}

/// One trailing newline, as files and command output usually end, is not
/// part of the value.
fn trimNewline(v: []const u8) []const u8 {
    if (std.mem.endsWith(u8, v, "\r\n")) return v[0 .. v.len - 2];
    if (std.mem.endsWith(u8, v, "\n")) return v[0 .. v.len - 1];
    return v;
}

fn checked(a: Allocator, f: *Failure, s: config.Secret, v: []const u8) Error![]const u8 {
    if (v.len == 0) return fail(a, f, "secret {s} ({s}) is empty", .{ s.name, s.source });
    if (std.mem.indexOfScalar(u8, v, 0) != null) return fail(a, f, "secret {s} ({s}) holds a NUL byte", .{ s.name, s.source });
    return v;
}

fn fromFile(a: Allocator, f: *Failure, s: config.Secret, raw_path: []const u8, home: ?[]const u8) Error![]const u8 {
    const path = if (std.mem.startsWith(u8, raw_path, "~/")) blk: {
        const h = home orelse return fail(a, f, "secret {s}: {s} needs an absolute HOME", .{ s.name, s.source });
        if (h.len == 0 or h[0] != '/') return fail(a, f, "secret {s}: {s} needs an absolute HOME", .{ s.name, s.source });
        break :blk try std.fs.path.join(a, &.{ h, raw_path[2..] });
    } else raw_path;
    const opened = fsx.openRegular(fsx.cwd, path, false) catch |e|
        return fail(a, f, "secret {s}: cannot open {s} ({s}); a symbolic link is not followed", .{ s.name, path, storage.describeError(e) });
    defer sys.close(opened.fd);
    const st = opened.stat;
    if (st.uid != linux.getuid()) return fail(a, f, "secret {s}: {s} is not owned by you", .{ s.name, path });
    if (st.mode & 0o077 != 0) return fail(a, f, "secret {s}: {s} is readable or writable by others; chmod 600 it", .{ s.name, path });
    if (st.nlink != 1) return fail(a, f, "secret {s}: {s} has more than one link", .{ s.name, path });
    const bytes = fsx.readAll(a, opened.fd, value_limit) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return fail(a, f, "secret {s}: {s} is larger than {d} bytes", .{ s.name, path, value_limit }),
        else => return fail(a, f, "secret {s}: cannot read {s} ({s})", .{ s.name, path, storage.describeError(e) }),
    };
    return checked(a, f, s, trimNewline(bytes));
}

fn fromNimvault(a: Allocator, f: *Failure, s: config.Secret, entry: []const u8, env: *const std.process.Environ.Map, envp: proc.Envp, nv: Nimvault) Error![]const u8 {
    const exe = if (nv.program.len > 0) nv.program else (try proc.which(a, "nimvault", env.get("PATH") orelse "")) orelse
        return fail(a, f, "secret {s}: nimvault is not on PATH (or set nimvault.program)", .{s.name});
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ exe, "get", entry });
    if (nv.vault.len > 0) {
        const vault = if (std.mem.startsWith(u8, nv.vault, "~/")) blk: {
            const h = env.get("HOME") orelse return fail(a, f, "secret {s}: nimvault.vault {s} needs an absolute HOME", .{ s.name, nv.vault });
            if (h.len == 0 or h[0] != '/') return fail(a, f, "secret {s}: nimvault.vault {s} needs an absolute HOME", .{ s.name, nv.vault });
            break :blk try std.fs.path.join(a, &.{ h, nv.vault[2..] });
        } else nv.vault;
        try argv.appendSlice(a, &.{ "--vault", vault });
    }
    const r = proc.run(a, exe, argv.items, envp, .{
        .stdout_limit = value_limit,
        .stderr_limit = 4096,
        .timeout_ms = nimvault_timeout_ms,
        .grace_ms = 1000,
        .exec_error = true,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TimedOut => return fail(a, f, "secret {s}: nimvault get {s} took longer than {d} s (is the GPG agent waiting for a passphrase?)", .{ s.name, entry, nimvault_timeout_ms / 1000 }),
        error.StreamTooLong => return fail(a, f, "secret {s}: nimvault get {s} printed more than {d} bytes", .{ s.name, entry, value_limit }),
        else => return fail(a, f, "secret {s}: cannot run {s} ({s})", .{ s.name, exe, storage.describeError(e) }),
    };
    if (r.term.code() != 0) {
        // Its stderr, never its stdout: a partial value must not be shown.
        const why = std.mem.trim(u8, r.stderr, " \t\r\n");
        return fail(a, f, "secret {s}: nimvault get {s} exited {d}{s}{s}", .{ s.name, entry, r.term.code(), if (why.len > 0) ": " else "", why });
    }
    return checked(a, f, s, trimNewline(r.stdout));
}

/// The value of every secret, in order.
pub fn resolve(
    a: Allocator,
    secrets: []const config.Secret,
    env: *const std.process.Environ.Map,
    envp: proc.Envp,
    nv: Nimvault,
    f: *Failure,
) Error![]Resolved {
    var out: std.ArrayList(Resolved) = .empty;
    for (secrets) |s| {
        const colon = std.mem.indexOfScalar(u8, s.source, ':').?;
        const kind = s.source[0..colon];
        const rest = s.source[colon + 1 ..];
        const value = if (std.mem.eql(u8, kind, "env"))
            try checked(a, f, s, env.get(rest) orelse return fail(a, f, "secret {s}: {s} is not set", .{ s.name, rest }))
        else if (std.mem.eql(u8, kind, "file"))
            try fromFile(a, f, s, rest, env.get("HOME"))
        else
            try fromNimvault(a, f, s, rest, env, envp, nv);
        try out.append(a, .{ .name = s.name, .value = value });
    }
    return out.items;
}

/// What stands in for a value in a redacted log.
pub fn placeholder(a: Allocator, name: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "<secret {s} removed by eb-local>", .{name});
}

const Form = struct {
    /// Raw bytes, or null when this is the percent-encoded form, which is
    /// matched against `value` so either hex case counts.
    bytes: ?[]const u8,
    value: []const u8,
    name: []const u8,
};

fn unreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~", c) != null;
}

/// How many bytes of `text` are the percent-encoding of `value`. Hex digits
/// match in either case: an encoder may write `%2f` or `%2F`.
fn matchPercent(text: []const u8, value: []const u8) ?usize {
    var o: usize = 0;
    for (value) |c| {
        if (unreserved(c)) {
            if (o >= text.len or text[o] != c) return null;
            o += 1;
            continue;
        }
        if (o + 3 > text.len or text[o] != '%') return null;
        if (!hexEq(text[o + 1], c >> 4) or !hexEq(text[o + 2], c & 0xf)) return null;
        o += 3;
    }
    return o;
}

fn hexEq(got: u8, nib: u8) bool {
    const want: u8 = if (nib < 10) '0' + nib else 'A' + (nib - 10);
    if (got == want) return true;
    if (want >= 'A' and want <= 'F' and got == want - 'A' + 'a') return true;
    return false;
}

fn formsOf(a: Allocator, v: Resolved) Allocator.Error![3]Form {
    const enc = std.base64.standard.Encoder;
    const b64 = try a.alloc(u8, enc.calcSize(v.value.len));
    _ = enc.encode(b64, v.value);
    return .{
        .{ .bytes = v.value, .value = v.value, .name = v.name },
        .{ .bytes = b64, .value = v.value, .name = v.name },
        .{ .bytes = null, .value = v.value, .name = v.name },
    };
}

fn formLen(text: []const u8, f: Form) ?usize {
    if (f.bytes) |b| {
        if (!std.mem.startsWith(u8, text, b)) return null;
        return b.len;
    }
    return matchPercent(text, f.value);
}

fn containsForm(hay: []const u8, f: Form) bool {
    if (f.bytes) |b| return std.mem.indexOf(u8, hay, b) != null;
    // A percent-encoded value inside the placeholder.
    var i: usize = 0;
    while (i < hay.len) : (i += 1) if (matchPercent(hay[i..], f.value) != null) return true;
    return false;
}

/// The usual marker, or another one when that marker would itself contain a
/// value. A marker is never searched again, so it must not reintroduce one.
fn markerFor(a: Allocator, name: []const u8, forms: []const Form) Allocator.Error![]const u8 {
    const standard = try placeholder(a, name);
    if (!containsAny(standard, forms)) return standard;
    var n: u32 = 0;
    while (n < 10000) : (n += 1) {
        const alt = try std.fmt.allocPrint(a, "<redacted:{d}>", .{n});
        if (!containsAny(alt, forms)) return alt;
    }
    var present = std.mem.zeroes([256]bool);
    for (forms) |f| {
        if (f.bytes) |b| for (b) |c| {
            present[c] = true;
        };
        for (f.value) |c| present[c] = true;
    }
    var b: u8 = 1;
    while (b < 255 and present[b]) b += 1;
    const mark = try a.alloc(u8, 4);
    @memset(mark, b);
    return mark;
}

fn containsAny(hay: []const u8, forms: []const Form) bool {
    for (forms) |f| if (containsForm(hay, f)) return true;
    return false;
}

/// Shorter values would match ordinary text everywhere; they are not
/// redacted, and a build that has one is told so.
pub const min_redacted_len = 4;

/// Replace every value, in each of its forms, in `bytes`; null when none occurs.
/// The longest form wins where several start at the same byte, so a shorter
/// secret that is a prefix of a longer one does not leave the rest behind.
/// Percent-encoding matches either hex case.
pub fn redactText(a: Allocator, bytes: []const u8, values: []const Resolved) Allocator.Error!?[]u8 {
    var forms: std.ArrayList(Form) = .empty;
    for (values) |v| {
        if (v.value.len < min_redacted_len) continue;
        for (try formsOf(a, v)) |f| {
            // A fixed form shorter than the minimum is skipped. The
            // percent-encoded length depends on the text, so it is decided
            // at each match.
            if (f.bytes) |b| if (b.len < min_redacted_len) continue;
            try forms.append(a, f);
        }
    }
    if (forms.items.len == 0) return null;
    var markers = std.StringHashMap([]const u8).init(a);
    for (forms.items) |f| {
        if (markers.get(f.name) == null) try markers.put(f.name, try markerFor(a, f.name, forms.items));
    }
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var changed = false;
    while (i < bytes.len) {
        var best_at: usize = bytes.len;
        var best_len: usize = 0;
        var best_name: []const u8 = "";
        for (forms.items) |f| {
            const from = if (f.bytes) |b| std.mem.indexOf(u8, bytes[i..], b) else findPercent(bytes[i..], f.value);
            const at = from orelse continue;
            const n = formLen(bytes[i + at ..], f).?;
            if (n < min_redacted_len) continue;
            if (at < best_at or (at == best_at and n > best_len)) {
                best_at = at;
                best_len = n;
                best_name = f.name;
            }
        }
        if (best_len == 0) {
            try out.appendSlice(a, bytes[i..]);
            break;
        }
        try out.appendSlice(a, bytes[i .. i + best_at]);
        try out.appendSlice(a, markers.get(best_name).?);
        i += best_at + best_len;
        changed = true;
    }
    if (!changed) {
        out.deinit(a);
        return null;
    }
    return out.items;
}

fn findPercent(text: []const u8, value: []const u8) ?usize {
    var i: usize = 0;
    while (i < text.len) : (i += 1) if (matchPercent(text[i..], value) != null) return i;
    return null;
}

/// Largest log rewritten; a larger one is reported, not rewritten.
pub const log_limit: usize = 1 << 30;
/// Deepest directory searched; anything deeper is reported.
pub const max_depth = 16;

/// How long a decompressor or compressor may take over one log.
pub const codec_timeout_ms = 30 * 60_000;

/// A log that could not be checked or rewritten, and why.
pub const Failed = struct {
    path: []const u8,
    why: []const u8,
};

/// What `redactTree` did: how many logs it rewrote without the values, and
/// the logs it left as they were, by reason.
pub const RedactReport = struct {
    files: usize = 0,
    too_large: std.ArrayList([]const u8) = .empty,
    too_deep: std.ArrayList([]const u8) = .empty,
    /// Logs that could not be read, or decompressed, to check them.
    unchecked: std.ArrayList(Failed) = .empty,
    /// Logs that hold a value and could not be rewritten without it.
    unchanged: std.ArrayList(Failed) = .empty,
};

/// Where the programs for compressed logs are found, and their environment.
pub const Tools = struct {
    path: []const u8,
    envp: proc.Envp,
};

/// EasyBuild compresses the log it keeps in an installation with its
/// zip-logs command (gzip; bzip2 under EESSI-extend). A log with one of
/// these suffixes goes through the program named, which reads stdin and
/// writes stdout with -c, and decompresses with -d.
const codecs = [_]struct { suffix: []const u8, program: []const u8 }{
    .{ .suffix = ".bz2", .program = "bzip2" },
    .{ .suffix = ".gz", .program = "gzip" },
    .{ .suffix = ".xz", .program = "xz" },
    .{ .suffix = ".zst", .program = "zstd" },
};

fn codecOf(name: []const u8) ?[]const u8 {
    for (codecs) |k| if (std.mem.endsWith(u8, name, k.suffix)) return k.program;
    return null;
}

const CodecError = error{ Failed, TooLarge } || Allocator.Error;

/// `program flags` on `input`, for its output; error.Failed sets `why`.
fn runCodec(a: Allocator, tools: Tools, program: []const u8, flags: []const u8, input: []const u8, limit: usize, why: *[]const u8) CodecError![]u8 {
    const exe = (try proc.which(a, program, tools.path)) orelse {
        why.* = try std.fmt.allocPrint(a, "no {s} on PATH", .{program});
        return error.Failed;
    };
    const r = proc.run(a, exe, &.{ exe, flags }, tools.envp, .{
        .stdin = input,
        .stdout_limit = limit,
        .stderr_limit = 4096,
        .timeout_ms = codec_timeout_ms,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.TooLarge,
        else => {
            why.* = try std.fmt.allocPrint(a, "{s} {s}: {s}", .{ program, flags, @errorName(e) });
            return error.Failed;
        },
    };
    if (r.term.code() != 0) {
        const said = std.mem.trim(u8, r.stderr, " \t\r\n");
        why.* = try std.fmt.allocPrint(a, "{s} {s} exited {d}{s}{s}", .{ program, flags, r.term.code(), if (said.len > 0) ": " else "", said });
        return error.Failed;
    }
    return r.stdout;
}

/// Replace `dir/name`. EasyBuild leaves an installation's easybuild/
/// read-only; its owner gets write permission back for the rename only.
fn replace(a: Allocator, dir: sys.fd_t, name: []const u8, bytes: []const u8) (fsx.Error || Allocator.Error)!void {
    const st = try fsx.fstat(dir);
    const lend = st.mode & 0o200 == 0 and st.uid == linux.getuid();
    if (lend) try sys.fchmod(dir, st.perm() | 0o200);
    defer if (lend) sys.fchmod(dir, st.perm()) catch {};
    const ign: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    var prev: linux.Sigaction = undefined;
    _ = linux.sigaction(.XFSZ, &ign, &prev);
    defer _ = linux.sigaction(.XFSZ, &prev, null);
    try fsx.replaceContents(a, dir, name, bytes);
}

fn redactFile(a: Allocator, dir: sys.fd_t, name: []const u8, path: []const u8, values: []const Resolved, tools: Tools, report: *RedactReport) Allocator.Error!void {
    const opened = fsx.openRegular(dir, name, false) catch |e|
        return report.unchecked.append(a, .{ .path = path, .why = storage.describeError(e) });
    const bytes = fsx.readAll(a, opened.fd, log_limit) catch |e| {
        sys.close(opened.fd);
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return report.unchecked.append(a, .{ .path = path, .why = storage.describeError(e) });
    };
    sys.close(opened.fd);
    const program = codecOf(name);
    var why: []const u8 = "";
    var text: []const u8 = bytes;
    if (program) |p| text = runCodec(a, tools, p, "-dc", bytes, log_limit, &why) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooLarge => return report.too_large.append(a, path),
        error.Failed => return report.unchecked.append(a, .{ .path = path, .why = why }),
    };
    var out: []const u8 = try redactText(a, text, values) orelse return;
    if (program) |p| out = runCodec(a, tools, p, "-c", out, 2 * log_limit, &why) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooLarge => return report.unchanged.append(a, .{ .path = path, .why = "compressed, it is too large" }),
        error.Failed => return report.unchanged.append(a, .{ .path = path, .why = why }),
    };
    replace(a, dir, name, out) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return report.unchanged.append(a, .{ .path = path, .why = storage.describeError(e) });
    };
    report.files += 1;
}

/// Which files below a directory `redactTree` checks.
pub const Filter = enum {
    /// Every regular file.
    all,
    /// Only files in a directory named "easybuild": the logs and recipes an
    /// installation keeps, not the installed software itself.
    easybuild_dirs,
};

/// Redact regular files below `dir` (never through a symbolic link)
/// modified at or after `since` (seconds); compressed ones through the
/// program their suffix names, from `tools`.
pub fn redactTree(a: Allocator, dir_path: []const u8, since: i64, values: []const Resolved, filter: Filter, tools: Tools, report: *RedactReport) (fsx.Error || Allocator.Error)!void {
    if (values.len == 0) return;
    const dir = fsx.openDir(fsx.cwd, dir_path, false) catch |e| switch (e) {
        error.NotFound => return,
        else => return e,
    };
    defer sys.close(dir);
    try redactDir(a, dir, dir_path, since, values, filter, tools, report, 0);
}

fn redactDir(a: Allocator, dir: sys.fd_t, path: []const u8, since: i64, values: []const Resolved, filter: Filter, tools: Tools, report: *RedactReport, depth: usize) (fsx.Error || Allocator.Error)!void {
    const in_easybuild = std.mem.eql(u8, std.fs.path.basename(path), "easybuild");
    if (filter == .easybuild_dirs and !in_easybuild) {
        // An installation's root holds easybuild/; only that is searched,
        // not the installed software beside it.
        const is_root = if (fsx.statAt(dir, "easybuild", false)) |st| st.isDir() else |_| false;
        if (is_root) {
            const eb_path = try std.fs.path.join(a, &.{ path, "easybuild" });
            if (depth >= max_depth) {
                try report.too_deep.append(a, eb_path);
                return;
            }
            const sub = fsx.openDir(dir, "easybuild", false) catch |e| {
                return report.unchecked.append(a, .{ .path = eb_path, .why = storage.describeError(e) });
            };
            defer sys.close(sub);
            return redactDir(a, sub, eb_path, since, values, filter, tools, report, depth + 1);
        }
    }
    var it = try fsx.DirIter.init(a, dir);
    while (true) {
        const e = (it.next() catch |err| {
            try report.unchecked.append(a, .{ .path = path, .why = storage.describeError(err) });
            break;
        }) orelse break;
        const child = try std.fs.path.join(a, &.{ path, e.name });
        const st = fsx.statAt(dir, e.name, false) catch |err| {
            try report.unchecked.append(a, .{ .path = child, .why = storage.describeError(err) });
            continue;
        };
        if (st.isDir()) {
            if (depth >= max_depth) {
                try report.too_deep.append(a, child);
                continue;
            }
            const sub = fsx.openDir(dir, e.name, false) catch |err| {
                try report.unchecked.append(a, .{ .path = child, .why = storage.describeError(err) });
                continue;
            };
            defer sys.close(sub);
            redactDir(a, sub, child, since, values, filter, tools, report, depth + 1) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => try report.unchecked.append(a, .{ .path = child, .why = storage.describeError(err) }),
            };
            continue;
        }
        if (!st.isReg() or st.mtime.sec < since) continue;
        if (filter == .easybuild_dirs and !in_easybuild) continue;
        if (st.size > log_limit) {
            try report.too_large.append(a, child);
            continue;
        }
        try redactFile(a, dir, e.name, child, values, tools, report);
    }
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    env: std.process.Environ.Map,
    nv: Nimvault = .{},

    fn init() !Scratch {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        const a = arena.allocator();
        var cwd_buf: [sys.path_max]u8 = undefined;
        const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
        const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/secrets-test-{d}", .{ cwd, linux.getpid() });
        try common.atomic.makedirs(root);
        return .{ .arena = arena, .root = root, .env = std.process.Environ.Map.init(testing.allocator) };
    }

    fn deinit(s: *Scratch) void {
        fsx.deleteTree(s.arena.allocator(), fsx.cwd, s.root) catch {};
        s.env.deinit();
        s.arena.deinit();
    }

    fn write(s: *Scratch, name: []const u8, text: []const u8, mode: u32) ![]const u8 {
        const path = try std.fs.path.join(s.arena.allocator(), &.{ s.root, name });
        const fd = try sys.openat(fsx.cwd, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, mode);
        defer sys.close(fd);
        try sys.writeAll(fd, text);
        try sys.fchmod(fd, mode);
        return path;
    }
};

const no_env: proc.Envp = &[_:null]?[*:0]const u8{};

fn resolveOne(s: *Scratch, source: []const u8) !struct { value: ?[]const u8, message: []const u8 } {
    var f: Failure = .{};
    const r = resolve(s.arena.allocator(), &.{.{ .name = "TOKEN", .source = source, .from = "test" }}, &s.env, no_env, s.nv, &f) catch |e| switch (e) {
        error.Unavailable => return .{ .value = null, .message = f.message },
        else => return e,
    };
    return .{ .value = r[0].value, .message = "" };
}

test "env and file sources, and why a file is refused" {
    var s = try Scratch.init();
    defer s.deinit();
    try s.env.put("MY_TOKEN", "from-the-environment");
    try testing.expectEqualStrings("from-the-environment", (try resolveOne(&s, "env:MY_TOKEN")).value.?);
    try testing.expect(std.mem.indexOf(u8, (try resolveOne(&s, "env:ABSENT")).message, "ABSENT is not set") != null);

    // Empty or relative HOME must never resolve file:~/ or nimvault.vault ~/ relative to cwd.
    for ([_][]const u8{ "", "relative/home" }) |bad_home| {
        try s.env.put("HOME", bad_home);
        const file_res = try resolveOne(&s, "file:~/.secrets/token");
        try testing.expect(file_res.value == null);
        try testing.expect(std.mem.indexOf(u8, file_res.message, "absolute HOME") != null);

        s.nv = .{ .program = "/bin/echo", .vault = "~/vault" };
        const nv_res = try resolveOne(&s, "nimvault:entry");
        try testing.expect(nv_res.value == null);
        try testing.expect(std.mem.indexOf(u8, nv_res.message, "absolute HOME") != null);
        s.nv = .{};
    }
    _ = s.env.swapRemove("HOME");

    const good = try s.write("good", "s3cret-value\n", 0o600);
    const good_src = try std.fmt.allocPrint(s.arena.allocator(), "file:{s}", .{good});
    try testing.expectEqualStrings("s3cret-value", (try resolveOne(&s, good_src)).value.?);

    const open = try s.write("open", "x-value\n", 0o644);
    const r = try resolveOne(&s, try std.fmt.allocPrint(s.arena.allocator(), "file:{s}", .{open}));
    try testing.expect(r.value == null and std.mem.indexOf(u8, r.message, "chmod 600") != null);
    // The value never appears in a refusal.
    try testing.expect(std.mem.indexOf(u8, r.message, "x-value") == null);

    const empty = try s.write("empty", "\n", 0o600);
    try testing.expect(std.mem.indexOf(u8, (try resolveOne(&s, try std.fmt.allocPrint(s.arena.allocator(), "file:{s}", .{empty}))).message, "empty") != null);

    const link = try std.fs.path.join(s.arena.allocator(), &.{ s.root, "link" });
    var zt: [sys.path_max:0]u8 = undefined;
    var zl: [sys.path_max:0]u8 = undefined;
    _ = linux.symlinkat((try sys.z(&zt, good)).ptr, linux.AT.FDCWD, (try sys.z(&zl, link)).ptr);
    try testing.expect((try resolveOne(&s, try std.fmt.allocPrint(s.arena.allocator(), "file:{s}", .{link}))).value == null);

    const absent_path = try std.fs.path.join(s.arena.allocator(), &.{ s.root, "absent-secret" });
    const absent_res = try resolveOne(&s, try std.fmt.allocPrint(s.arena.allocator(), "file:{s}", .{absent_path}));
    try testing.expect(absent_res.value == null);
    try testing.expect(std.mem.indexOf(u8, absent_res.message, "[Errno 2] No such file or directory") != null);

    const no_perm = try s.write("no-perm", "hidden-val\n", 0o600);
    const dir_fd = try fsx.openDir(fsx.cwd, s.root, false);
    defer {
        sys.fchmod(dir_fd, 0o755) catch {};
        sys.close(dir_fd);
    }
    try sys.fchmod(dir_fd, 0o000);
    const perm_res = try resolveOne(&s, try std.fmt.allocPrint(s.arena.allocator(), "file:{s}", .{no_perm}));
    try testing.expect(perm_res.value == null);
    try testing.expect(std.mem.indexOf(u8, perm_res.message, "[Errno 13] Permission denied") != null);
    try testing.expect(std.mem.indexOf(u8, perm_res.message, "hidden-val") == null);
}

test "nimvault: the value from stdout, the reason from stderr only" {
    var s = try Scratch.init();
    defer s.deinit();
    _ = try s.write("nimvault",
        \\#!/bin/sh
        \\[ "$1" = get ] || exit 64
        \\case "$2" in
        \\  ok) printf 'vault-value\n' ;;
        \\  leak) printf 'partial-value'; echo 'gpg: decryption failed' >&2; exit 2 ;;
        \\  *) echo "no entry $2" >&2; exit 1 ;;
        \\esac
    , 0o700);
    try s.env.put("PATH", s.root);
    try testing.expectEqualStrings("vault-value", (try resolveOne(&s, "nimvault:ok")).value.?);
    const r = try resolveOne(&s, "nimvault:leak");
    try testing.expect(r.value == null);
    try testing.expect(std.mem.indexOf(u8, r.message, "decryption failed") != null);
    try testing.expect(std.mem.indexOf(u8, r.message, "partial-value") == null);
    try s.env.put("PATH", "/nonexistent");
    try testing.expect(std.mem.indexOf(u8, (try resolveOne(&s, "nimvault:ok")).message, "not on PATH") != null);
}

test "nimvault: a configured program and vault" {
    var s = try Scratch.init();
    defer s.deinit();
    // Prints its arguments, so the test sees the --vault it was given.
    const prog = try s.write("vault-tool",
        \\#!/bin/sh
        \\[ "$1" = get ] || exit 64
        \\printf '%s|%s|%s\n' "$2" "$3" "$4"
    , 0o700);
    try s.env.put("PATH", "/nonexistent");
    try s.env.put("HOME", "/home/someone");
    s.nv = .{ .program = prog };
    try testing.expectEqualStrings("ok||", (try resolveOne(&s, "nimvault:ok")).value.?);
    s.nv = .{ .program = prog, .vault = "~/private-vault" };
    try testing.expectEqualStrings("ok|--vault|/home/someone/private-vault", (try resolveOne(&s, "nimvault:ok")).value.?);
    s.nv = .{ .program = prog, .vault = "/srv/vault" };
    try testing.expectEqualStrings("ok|--vault|/srv/vault", (try resolveOne(&s, "nimvault:ok")).value.?);
}

test "logs written during the build are redacted" {
    var s = try Scratch.init();
    defer s.deinit();
    const a = s.arena.allocator();
    try common.atomic.makedirs(try std.fs.path.join(a, &.{ s.root, "logs", "sub" }));
    const log = try s.write("logs/sub/easybuild.log", "export TOKEN=s3cret-value\nother line s3cret-value\n", 0o640);
    _ = try s.write("logs/clean.log", "nothing here\n", 0o644);
    const values = [_]Resolved{ .{ .name = "TOKEN", .value = "s3cret-value" }, .{ .name = "SHORT", .value = "ab" } };
    var report: RedactReport = .{};
    try redactTree(a, try std.fs.path.join(a, &.{ s.root, "logs" }), 0, &values, .all, .{ .path = "", .envp = no_env }, &report);
    try testing.expectEqual(@as(usize, 1), report.files);
    const opened = try fsx.openRegular(fsx.cwd, log, false);
    defer sys.close(opened.fd);
    const text = try fsx.readAll(a, opened.fd, 4096);
    try testing.expect(std.mem.indexOf(u8, text, "s3cret-value") == null);
    try testing.expect(std.mem.indexOf(u8, text, "<secret TOKEN removed by eb-local>") != null);
    try testing.expectEqual(@as(u32, 0o640), opened.stat.perm());
}

test "a log in a read-only directory, and one without its decompressor" {
    var s = try Scratch.init();
    defer s.deinit();
    const a = s.arena.allocator();
    const dir = try std.fs.path.join(a, &.{ s.root, "easybuild" });
    try common.atomic.makedirs(dir);
    const log = try s.write("easybuild/plain.log", "token s3cret-value\n", 0o444);
    _ = try s.write("easybuild/zipped.log.bz2", "s3cret-value\n", 0o444);
    const dfd = try fsx.openDir(fsx.cwd, dir, false);
    defer sys.close(dfd);
    try sys.fchmod(dfd, 0o1555);
    defer sys.fchmod(dfd, 0o755) catch {};
    const values = [_]Resolved{.{ .name = "TOKEN", .value = "s3cret-value" }};
    var report: RedactReport = .{};
    try redactTree(a, dir, 0, &values, .all, .{ .path = "/nonexistent", .envp = no_env }, &report);
    try testing.expectEqual(@as(usize, 1), report.files);
    const opened = try fsx.openRegular(fsx.cwd, log, false);
    defer sys.close(opened.fd);
    try testing.expectEqualStrings("token <secret TOKEN removed by eb-local>\n", try fsx.readAll(a, opened.fd, 4096));
    try testing.expectEqual(@as(u32, 0o444), opened.stat.perm());
    try testing.expectEqual(@as(u32, 0o1555), (try fsx.fstat(dfd)).perm());
    try testing.expectEqual(@as(usize, 1), report.unchecked.items.len);
    try testing.expect(std.mem.endsWith(u8, report.unchecked.items[0].path, "/zipped.log.bz2"));
    try testing.expectEqualStrings("no bzip2 on PATH", report.unchecked.items[0].why);
}

test "a value is removed as it is, in base64 and percent-encoded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const values = [_]Resolved{.{ .name = "T", .value = "p@ss word/1" }};
    const text = "raw p@ss word/1 b64 cEBzcyB3b3JkLzE= url p%40ss%20word%2F1 low p%40ss%20word%2f1 end";
    const clean = (try redactText(a, text, &values)).?;
    try testing.expect(std.mem.indexOf(u8, clean, "p@ss") == null);
    try testing.expect(std.mem.indexOf(u8, clean, "cEBzcyB3b3JkLzE=") == null);
    try testing.expect(std.mem.indexOf(u8, clean, "p%40ss") == null);
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, clean, "<secret T removed by eb-local>"));
}

test "a shorter secret does not leave the tail of a longer one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const values = [_]Resolved{
        .{ .name = "SHORT", .value = "s3cret" },
        .{ .name = "LONG", .value = "s3cret-value" },
    };
    const clean = (try redactText(a, "token s3cret-value end", &values)).?;
    try testing.expect(std.mem.indexOf(u8, clean, "s3cret") == null);
    try testing.expect(std.mem.indexOf(u8, clean, "-value") == null);
    try testing.expect(std.mem.indexOf(u8, clean, "<secret LONG removed by eb-local>") != null);
}

test "the replacement does not contain the value it stands in for" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const values = [_]Resolved{.{ .name = "T", .value = "secret" }};
    const clean = (try redactText(a, "the secret is secret", &values)).?;
    try testing.expect(std.mem.indexOf(u8, clean, "secret") == null);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, clean, "<redacted:"));
}

test "an installation log nested past the search depth is reported" {
    var s = try Scratch.init();
    defer s.deinit();
    const a = s.arena.allocator();
    for ([_]usize{ max_depth + 2, max_depth }) |target_depth| {
        const branch = try std.fmt.allocPrint(a, "{s}/depth-{d}", .{ s.root, target_depth });
        var dir = try a.dupe(u8, branch);
        var depth: usize = 0;
        while (depth < target_depth) : (depth += 1) {
            dir = try std.fs.path.join(a, &.{ dir, "d" });
            try common.atomic.makedirs(dir);
        }
        const eb = try std.fs.path.join(a, &.{ dir, "easybuild" });
        try common.atomic.makedirs(eb);
        const log = try std.fs.path.join(a, &.{ eb, "easybuild.log" });
        const fd = try sys.openat(fsx.cwd, log, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        defer sys.close(fd);
        try sys.writeAll(fd, "copied s3cret-value\n");
        const values = [_]Resolved{.{ .name = "TOKEN", .value = "s3cret-value" }};
        var report: RedactReport = .{};
        try redactTree(a, branch, 0, &values, .easybuild_dirs, .{ .path = "", .envp = no_env }, &report);
        try testing.expect(report.too_deep.items.len > 0);
        try testing.expectEqual(@as(usize, 0), report.files);
        const opened = try fsx.openRegular(fsx.cwd, log, false);
        defer sys.close(opened.fd);
        const text = try fsx.readAll(a, opened.fd, 4096);
        try testing.expect(std.mem.indexOf(u8, text, "s3cret-value") != null);
    }
}

test "unreadable subdirectories and full writes are reported while sibling logs are redacted" {
    var s = try Scratch.init();
    defer s.deinit();
    const a = s.arena.allocator();
    const logs = try std.fs.path.join(a, &.{ s.root, "logs" });
    const locked = try std.fs.path.join(a, &.{ logs, "locked" });
    try common.atomic.makedirs(locked);
    _ = try s.write("logs/locked/hidden.log", "secret s3cret-value\n", 0o644);
    const sibling = try s.write("logs/sibling.log", "sibling s3cret-value\n", 0o644);
    const lfd = try fsx.openDir(fsx.cwd, locked, false);
    defer {
        sys.fchmod(lfd, 0o755) catch {};
        sys.close(lfd);
    }
    try sys.fchmod(lfd, 0o000);

    const values = [_]Resolved{.{ .name = "TOKEN", .value = "s3cret-value" }};
    var report: RedactReport = .{};
    try redactTree(a, logs, 0, &values, .all, .{ .path = "", .envp = no_env }, &report);
    try testing.expectEqual(@as(usize, 1), report.files);
    try testing.expectEqual(@as(usize, 1), report.unchecked.items.len);
    try testing.expectEqualStrings(locked, report.unchecked.items[0].path);
    try testing.expect(std.mem.indexOf(u8, report.unchecked.items[0].why, "Permission denied") != null);
    const sib_fd = try fsx.openRegular(fsx.cwd, sibling, false);
    defer sys.close(sib_fd.fd);
    try testing.expectEqualStrings("sibling <secret TOKEN removed by eb-local>\n", try fsx.readAll(a, sib_fd.fd, 4096));

    // When writing the redacted replacement hits the file-size limit, the log is reported unchanged.
    const inst_eb = try std.fs.path.join(a, &.{ s.root, "inst", "easybuild" });
    try common.atomic.makedirs(inst_eb);
    const eb_log = try s.write("inst/easybuild/build.log", "x s3cret-value\n", 0o644);
    var old: linux.rlimit = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.prlimit(0, .FSIZE, null, &old)));
    const lim: linux.rlimit = .{ .cur = 4, .max = old.max };
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.prlimit(0, .FSIZE, &lim, null)));
    const ign: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    var prev: linux.Sigaction = undefined;
    _ = linux.sigaction(.XFSZ, &ign, &prev);
    var full_report: RedactReport = .{};
    {
        defer {
            _ = linux.sigaction(.XFSZ, &prev, null);
            _ = linux.prlimit(0, .FSIZE, &old, null);
        }
        try redactTree(a, try std.fs.path.join(a, &.{ s.root, "inst" }), 0, &values, .easybuild_dirs, .{ .path = "", .envp = no_env }, &full_report);
    }
    try testing.expectEqual(@as(usize, 1), full_report.unchanged.items.len);
    try testing.expectEqualStrings(eb_log, full_report.unchanged.items[0].path);
    const orig_fd = try fsx.openRegular(fsx.cwd, eb_log, false);
    defer sys.close(orig_fd.fd);
    try testing.expectEqualStrings("x s3cret-value\n", try fsx.readAll(a, orig_fd.fd, 4096));
}

test "replace restores previous SIGXFSZ disposition on every path and reports EFBIG" {
    const H = struct {
        var hits: usize = 0;
        fn sentinel(_: linux.SIG) callconv(.c) void {
            hits += 1;
        }
    };
    H.hits = 0;

    var s = try Scratch.init();
    defer s.deinit();
    const a = s.arena.allocator();
    const logs = try std.fs.path.join(a, &.{ s.root, "logs" });
    try common.atomic.makedirs(logs);
    _ = try s.write("logs/ok.log", "x s3cret-value\n", 0o644);
    const big = try s.write("logs/big.log", "xxxxx s3cret-value\n", 0o644);
    const small = try s.write("logs/small.log", "z\n", 0o644);
    const lfd = try fsx.openDir(fsx.cwd, logs, false);
    defer sys.close(lfd);

    const custom: linux.Sigaction = .{ .handler = .{ .handler = H.sentinel }, .mask = linux.sigemptyset(), .flags = 0 };
    var orig: linux.Sigaction = undefined;
    _ = linux.sigaction(.XFSZ, &custom, &orig);
    defer _ = linux.sigaction(.XFSZ, &orig, null);

    var after: linux.Sigaction = undefined;
    // Normal return path restores previous disposition.
    try replace(a, lfd, "ok.log", "x <redacted>\n");
    _ = linux.sigaction(.XFSZ, null, &after);
    try testing.expectEqual(H.sentinel, after.handler.handler.?);

    // Non-EFBIG error return path restores previous disposition.
    try testing.expectError(error.NotFound, replace(a, lfd, "missing.log", "x\n"));
    _ = linux.sigaction(.XFSZ, null, &after);
    try testing.expectEqual(H.sentinel, after.handler.handler.?);

    // EFBIG error return path suppresses SIGXFSZ delivery and restores previous disposition.
    var old_lim: linux.rlimit = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.prlimit(0, .FSIZE, null, &old_lim)));
    const lim: linux.rlimit = .{ .cur = 4, .max = old_lim.max };
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.prlimit(0, .FSIZE, &lim, null)));
    {
        defer _ = linux.prlimit(0, .FSIZE, &old_lim, null);
        try testing.expectError(error.Unexpected, replace(a, lfd, "big.log", "x <secret TOKEN removed by eb-local>\n"));
        try testing.expectEqual(@as(usize, 0), H.hits);
        _ = linux.sigaction(.XFSZ, null, &after);
        try testing.expectEqual(H.sentinel, after.handler.handler.?);
    }

    // With SIG_DFL active, redactTree reports EFBIG on big.log, redacts small.log,
    // and leaves SIG_DFL intact.
    _ = try s.write("logs/small.log", "s s3cret-value\n", 0o644);
    const dfl: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(.XFSZ, &dfl, null);
    const values = [_]Resolved{.{ .name = "TOKEN", .value = "s3cret-value" }};
    const lim2: linux.rlimit = .{ .cur = 38, .max = old_lim.max };
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.prlimit(0, .FSIZE, &lim2, null)));
    var report: RedactReport = .{};
    {
        defer _ = linux.prlimit(0, .FSIZE, &old_lim, null);
        try redactTree(a, logs, 0, &values, .all, .{ .path = "", .envp = no_env }, &report);
    }
    _ = linux.sigaction(.XFSZ, null, &after);
    try testing.expectEqual(linux.SIG.DFL, after.handler.handler);
    try testing.expectEqual(@as(usize, 1), report.files);
    try testing.expectEqual(@as(usize, 1), report.unchanged.items.len);
    try testing.expectEqualStrings(big, report.unchanged.items[0].path);
    try testing.expectEqualStrings("[Errno 27] File too large", report.unchanged.items[0].why);
    const small_fd = try fsx.openRegular(fsx.cwd, small, false);
    defer sys.close(small_fd.fd);
    try testing.expectEqualStrings("s <secret TOKEN removed by eb-local>\n", try fsx.readAll(a, small_fd.fd, 4096));
}
