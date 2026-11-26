//! MPI transport checks for `eb-local doctor --mpi`.
//! The overrides are applied only to the hello this module runs.
//! A build does not call this and does not set them.
const std = @import("std");
const common = @import("zig_common");
const sys = common.sys;
const fsx = common.fsx;
const proc = common.proc;

const Allocator = std.mem.Allocator;

/// A site-approved transport. `ofi` uses the Open MPI cm/ofi pair.
/// `ucx` uses the ucx point-to-point layer and turns ofi off.
pub const Transport = enum { ofi, ucx };

/// One line of `hello rank=R size=S cpu=C cpus=N`.
pub const Rank = struct {
    rank: u32,
    size: u32,
    cpu: i64,
    cpus: i64,
};

/// The compiler and the two-rank run for one transport.
pub const Hello = struct {
    source_error: ?[]const u8 = null,
    missing_compiler: bool = false,
    missing_launcher: bool = false,
    compile_code: u32 = 0,
    compile_timeout: bool = false,
    ran: bool = false,
    run_code: u32 = 0,
    run_timeout: bool = false,
    ranks: []const Rank = &.{},
    /// `OMPI_MCA_pml=... OMPI_MCA_mtl=...`, set only on the hello.
    override_text: []const u8 = "",
};

/// A short reading of `fi_info` or `ucx_info`.
pub const Summary = struct {
    present: bool = false,
    line: []const u8 = "",
    code: u32 = 0,
    timed_out: bool = false,
};

const hello_source =
    \\#include <mpi.h>
    \\#include <sched.h>
    \\#include <stdio.h>
    \\#include <unistd.h>
    \\int main(int argc, char **argv) {
    \\    int rank = 0, size = 1;
    \\    MPI_Init(&argc, &argv);
    \\    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    \\    MPI_Comm_size(MPI_COMM_WORLD, &size);
    \\    long cpus = sysconf(_SC_NPROCESSORS_ONLN);
    \\    printf("hello rank=%d size=%d cpu=%d cpus=%ld\n", rank, size, sched_getcpu(), cpus);
    \\    fflush(stdout);
    \\    MPI_Finalize();
    \\    return 0;
    \\}
;

/// `ofi` or `ucx`, the only transports a site file may name.
pub fn parseTransport(name: []const u8) ?Transport {
    return std.meta.stringToEnum(Transport, name);
}

/// The two variables set on the hello, and nowhere else.
pub fn overrideText(transport: Transport) []const u8 {
    return switch (transport) {
        .ofi => "OMPI_MCA_pml=cm OMPI_MCA_mtl=ofi",
        .ucx => "OMPI_MCA_pml=ucx OMPI_MCA_mtl=^ofi",
    };
}

const Pair = struct { pml: []const u8, mtl: []const u8 };

fn pair(transport: Transport) Pair {
    return switch (transport) {
        .ofi => .{ .pml = "cm", .mtl = "ofi" },
        .ucx => .{ .pml = "ucx", .mtl = "^ofi" },
    };
}

const Ran = struct {
    code: u32,
    timed_out: bool,
    stdout: []const u8,
};

fn run(a: Allocator, exe: []const u8, argv: []const []const u8, envp: proc.Envp) Ran {
    const r = proc.run(a, exe, argv, envp, .{
        .stdout_limit = 64 << 10,
        .stderr_limit = 4096,
        .timeout_ms = 20_000,
        .stdout_overflow = .truncate,
    }) catch |e| switch (e) {
        error.TimedOut => return .{ .code = 124, .timed_out = true, .stdout = "" },
        else => return .{ .code = 127, .timed_out = false, .stdout = "" },
    };
    const stdout = a.dupe(u8, r.stdout) catch "";
    r.deinit(a);
    return .{ .code = r.term.code(), .timed_out = false, .stdout = stdout };
}

/// The first non-empty line of `argv`, at most 160 bytes.
pub fn summarize(a: Allocator, exe: ?[]const u8, argv: []const []const u8, envp: proc.Envp) Summary {
    const path = exe orelse return .{};
    const ran = run(a, path, argv, envp);
    return .{
        .present = true,
        .line = firstLine(ran.stdout),
        .code = ran.code,
        .timed_out = ran.timed_out,
    };
}

fn firstLine(text: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        return line[0..@min(line.len, 160)];
    }
    return "";
}

/// Compile `work/hello.c` with `mpicc` and run it with `mpirun -np 2`.
/// The two Open MPI variables are added to a copy of `base` for that run.
pub fn runHello(
    a: Allocator,
    transport: Transport,
    mpicc: ?[]const u8,
    mpirun: ?[]const u8,
    work: []const u8,
    base: *const std.process.Environ.Map,
    base_envp: proc.Envp,
) Allocator.Error!Hello {
    const text = overrideText(transport);
    const compiler = mpicc orelse return .{ .missing_compiler = true, .override_text = text };
    const src = try std.fs.path.join(a, &.{ work, "hello.c" });
    const bin = try std.fs.path.join(a, &.{ work, "hello" });
    var why: common.atomic.Why = .{};
    defer why.deinit(a);
    common.atomic.atomicWrite(a, src, hello_source, .{ .mode = 0o644 }, &why) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const msg = if (why.msg.len > 0) try a.dupe(u8, why.msg) else try a.dupe(u8, common.atomic.describe(err));
            return .{ .source_error = msg, .override_text = text };
        },
    };
    const compiled = run(a, compiler, &.{ compiler, "-o", bin, src }, base_envp);
    if (compiled.timed_out) return .{ .compile_timeout = true, .compile_code = compiled.code, .override_text = text };
    if (compiled.code != 0) return .{ .compile_code = compiled.code, .override_text = text };
    const launcher = mpirun orelse return .{ .missing_launcher = true, .override_text = text };
    const envp = envpWith(a, base, pair(transport)) catch |e| switch (e) {
        error.InvalidArgument => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const ran = run(a, launcher, &.{ launcher, "-np", "2", bin }, envp);
    return .{
        .ran = true,
        .run_code = ran.code,
        .run_timeout = ran.timed_out,
        .ranks = try parseRanks(a, ran.stdout),
        .override_text = text,
    };
}

fn envpWith(a: Allocator, base: *const std.process.Environ.Map, values: Pair) (Allocator.Error || error{InvalidArgument})!proc.Envp {
    var b: common.env.Builder = .init(a);
    var it = base.iterator();
    while (it.next()) |kv| try b.set(kv.key_ptr.*, kv.value_ptr.*);
    try b.set("OMPI_MCA_pml", values.pml);
    try b.set("OMPI_MCA_mtl", values.mtl);
    return b.envp();
}

/// Ranks from lines `hello rank=R size=S cpu=C cpus=N`.
pub fn parseRanks(a: Allocator, text: []const u8) Allocator.Error![]const Rank {
    var list: std.ArrayList(Rank) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const start = std.mem.indexOf(u8, line, "hello rank=") orelse continue;
        const hello = line[start..];
        const rank = field(hello, "rank=") orelse continue;
        const size = field(hello, " size=") orelse continue;
        const cpus = field(hello, " cpus=") orelse continue;
        const cpu = field(hello, " cpu=") orelse continue;
        try list.append(a, .{
            .rank = std.math.cast(u32, rank) orelse continue,
            .size = std.math.cast(u32, size) orelse continue,
            .cpu = cpu,
            .cpus = cpus,
        });
    }
    return list.items;
}

fn field(line: []const u8, key: []const u8) ?i64 {
    const at = std.mem.indexOf(u8, line, key) orelse return null;
    const rest = line[at + key.len ..];
    const end = std.mem.indexOfAny(u8, rest, " \t\r") orelse rest.len;
    return std.fmt.parseInt(i64, rest[0..end], 10) catch null;
}

/// True when every reported rank ran on one CPU.
pub fn sharedCpu(ranks: []const Rank) bool {
    if (ranks.len < 2 or ranks[0].cpu < 0) return false;
    for (ranks[1..]) |r| if (r.cpu != ranks[0].cpu) return false;
    return true;
}

const testing = std.testing;

fn scratch(a: Allocator) ![]u8 {
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/mpi-{d}-{d}", .{ cwd, std.os.linux.getpid(), @intFromPtr(&cwd_buf) });
    try common.atomic.makedirs(root);
    return root;
}

fn install(path: []const u8, text: []const u8) !void {
    const fd = try sys.openat(fsx.cwd, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o755);
    defer sys.close(fd);
    try sys.writeAll(fd, text);
    _ = std.os.linux.fchmod(fd, 0o755);
}

test "the hello override is only ofi or ucx and is not a provider variable" {
    try testing.expectEqualStrings("OMPI_MCA_pml=cm OMPI_MCA_mtl=ofi", overrideText(.ofi));
    try testing.expectEqualStrings("OMPI_MCA_pml=ucx OMPI_MCA_mtl=^ofi", overrideText(.ucx));
    try testing.expect(parseTransport("ofi") != null);
    try testing.expect(parseTransport("ucx") != null);
    try testing.expect(parseTransport("tcp") == null);
    try testing.expect(std.mem.indexOf(u8, overrideText(.ofi), "FI_PROVIDER") == null);
    try testing.expect(std.mem.indexOf(u8, hello_source, "OMPI_MCA") == null);
}

test "two ranks on one CPU are a shared binding" {
    const same = [_]Rank{
        .{ .rank = 0, .size = 2, .cpu = 3, .cpus = 8 },
        .{ .rank = 1, .size = 2, .cpu = 3, .cpus = 8 },
    };
    try testing.expect(sharedCpu(&same));
    const split = [_]Rank{
        .{ .rank = 0, .size = 2, .cpu = 0, .cpus = 8 },
        .{ .rank = 1, .size = 2, .cpu = 1, .cpus = 8 },
    };
    try testing.expect(!sharedCpu(&split));
    const unknown = [_]Rank{
        .{ .rank = 0, .size = 2, .cpu = -1, .cpus = 8 },
        .{ .rank = 1, .size = 2, .cpu = -1, .cpus = 8 },
    };
    try testing.expect(!sharedCpu(&unknown));
}

test "parseRanks ignores rank, size, and cpus prefixes before hello rank=" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ranks = try parseRanks(a, "[rank=9 mysize=99 ncpus=64] hello rank=0 size=2 cpu=3 cpus=8\n");
    try testing.expectEqual(@as(usize, 1), ranks.len);
    try testing.expectEqual(@as(u32, 0), ranks[0].rank);
    try testing.expectEqual(@as(u32, 2), ranks[0].size);
    try testing.expectEqual(@as(i64, 3), ranks[0].cpu);
    try testing.expectEqual(@as(i64, 8), ranks[0].cpus);
}

test "the hello sees the transport override and the caller environment does not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try scratch(a);
    defer fsx.deleteTree(a, fsx.cwd, root) catch {};
    const bin = try std.fs.path.join(a, &.{ root, "bin" });
    const work = try std.fs.path.join(a, &.{ root, "work" });
    try common.atomic.makedirs(bin);
    try common.atomic.makedirs(work);
    const record = try std.fs.path.join(a, &.{ root, "record" });
    try install(try std.fs.path.join(a, &.{ bin, "mpicc" }),
        \\#!/bin/sh
        \\out=
        \\while [ $# -gt 0 ]; do
        \\  if [ "$1" = -o ]; then out=$2; shift 2; continue; fi
        \\  shift
        \\done
        \\/bin/cat > "$out" << 'END'
        \\#!/bin/sh
        \\echo "hello rank=0 size=2 cpu=0 cpus=2"
        \\echo "hello rank=1 size=2 cpu=1 cpus=2"
        \\END
        \\/bin/chmod +x "$out"
        \\
    );
    try install(try std.fs.path.join(a, &.{ bin, "mpirun" }), try std.fmt.allocPrint(a,
        \\#!/bin/sh
        \\printf '%s\n' "pml=${{OMPI_MCA_pml-}}" "mtl=${{OMPI_MCA_mtl-}}" >> {s}
        \\prog=
        \\for a in "$@"; do prog=$a; done
        \\"$prog"
        \\
    , .{record}));
    try install(try std.fs.path.join(a, &.{ bin, "fi_info" }),
        \\#!/bin/sh
        \\echo "provider: tcp"
        \\
    );
    var env = std.process.Environ.Map.init(a);
    const no_env: proc.Envp = &[_:null]?[*:0]const u8{};
    const mpicc = (try proc.which(a, "mpicc", bin)).?;
    const mpirun = (try proc.which(a, "mpirun", bin)).?;
    const hello = try runHello(a, .ofi, mpicc, mpirun, work, &env, no_env);
    try testing.expect(hello.ran);
    try testing.expectEqual(@as(u32, 0), hello.run_code);
    try testing.expectEqual(@as(usize, 2), hello.ranks.len);
    try testing.expect(!sharedCpu(hello.ranks));
    try testing.expect(env.get("OMPI_MCA_pml") == null);
    const noted = readAll(a, record).?;
    try testing.expect(std.mem.indexOf(u8, noted, "pml=cm\nmtl=ofi\n") != null);
    const info = summarize(a, try proc.which(a, "fi_info", bin), &.{ (try proc.which(a, "fi_info", bin)).?, "-l" }, no_env);
    try testing.expectEqualStrings("provider: tcp", info.line);
}

fn readAll(a: Allocator, path: []const u8) ?[]const u8 {
    const fd = sys.openat(fsx.cwd, path, .{}, 0) catch return null;
    defer sys.close(fd);
    return fsx.readAll(a, fd, 1 << 20) catch null;
}

test "an unwritable work directory or symlink at hello.c does not report OutOfMemory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try scratch(a);
    defer fsx.deleteTree(a, fsx.cwd, root) catch {};
    const target = try std.fs.path.join(a, &.{ root, "outside.c" });
    var why: common.atomic.Why = .{};
    defer why.deinit(a);
    try common.atomic.atomicWrite(a, target, "keep\n", .{ .mode = 0o644 }, &why);
    const src = try std.fs.path.join(a, &.{ root, "hello.c" });
    var z_target: [sys.path_max:0]u8 = undefined;
    var z_src: [sys.path_max:0]u8 = undefined;
    try testing.expectEqual(
        std.os.linux.E.SUCCESS,
        std.os.linux.errno(std.os.linux.symlinkat((try sys.z(&z_target, target)).ptr, std.os.linux.AT.FDCWD, (try sys.z(&z_src, src)).ptr)),
    );
    var env = std.process.Environ.Map.init(a);
    const no_env: proc.Envp = &[_:null]?[*:0]const u8{};
    const hello = try runHello(a, .ofi, "/bin/true", "/bin/true", root, &env, no_env);
    try testing.expect(hello.source_error != null);
    try testing.expect(!hello.ran);
    try testing.expectEqualStrings("keep\n", readAll(a, target).?);

    const ro_dir = try std.fs.path.join(a, &.{ root, "ro" });
    try common.atomic.makedirs(ro_dir);
    var z_ro: [sys.path_max:0]u8 = undefined;
    const z_ro_p = try sys.z(&z_ro, ro_dir);
    try testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.fchmodat(std.os.linux.AT.FDCWD, z_ro_p.ptr, 0o555)));
    defer _ = std.os.linux.fchmodat(std.os.linux.AT.FDCWD, z_ro_p.ptr, 0o755);
    const ro_hello = try runHello(a, .ofi, "/bin/true", "/bin/true", ro_dir, &env, no_env);
    try testing.expect(ro_hello.source_error != null);
    try testing.expect(!ro_hello.ran);
}
