//! RPATH wrappers for compilers that have no build environment module.
//! `eb-local dev` falls back to them when the loaded compiler family has no
//! buildenv installed, so a program still records the library directory of
//! every module it links against, as EasyBuild's own wrappers do, instead
//! of linking without run paths and needing LD_LIBRARY_PATH.
const std = @import("std");
const linux = std.os.linux;
const common = @import("zig_common");
const sys = common.sys;
const fsx = common.fsx;
const proc = common.proc;
const Allocator = std.mem.Allocator;

/// The commands wrapped when they are on PATH: compiler drivers, then
/// linkers. MPI wrappers call these by name, so they are covered too.
pub const names = [_][]const u8{
    "gcc",    "g++",  "c++", "cc",  "gfortran", "clang",     "clang++", "flang",  "flang-new",
    "icx",    "icpx", "ifx", "nvc", "nvc++",    "nvfortran", "ld",      "ld.bfd", "ld.gold",
    "ld.lld",
};

/// The compilers that find their linker themselves, so a wrapped `ld` on
/// PATH never sees their links, and the linker of theirs that EasyBuild's
/// GCC build environment does not wrap. A program they link has run paths
/// only when they are wrapped themselves.
pub const self_linking = [_][]const u8{ "clang", "clang++", "flang", "flang-new", "ld.lld" };

/// A directory holding this file is skipped when a wrapper looks for the
/// command it stands in for, so wrappers never call each other.
pub const marker = ".eb-local-rpath";

/// One script for every name: it runs the next command of its own name on
/// PATH. When that command links, it adds a run path for each absolute
/// library directory named with -L, and for a compiler driver for each
/// LIBRARY_PATH entry, which EESSI's modules set and the driver passes to
/// the linker; system and compatibility-layer directories are left out, as
/// the loader finds those itself. --disable-new-dtags writes RPATH rather
/// than RUNPATH, so LD_LIBRARY_PATH cannot override it, as in EasyBuild.
pub const script =
    \\#!/bin/bash
    \\# RPATH wrapper written by eb-local; see `eb-local help`.
    \\name=${0##*/}
    \\real=
    \\IFS=: read -r -a path_dirs <<< "$PATH"
    \\for d in "${path_dirs[@]}"; do
    \\    if [ -n "$d" ] && [ ! -e "$d/.eb-local-rpath" ] && [ -f "$d/$name" ] && [ -x "$d/$name" ]; then
    \\        real=$d/$name
    \\        break
    \\    fi
    \\done
    \\if [ -z "$real" ]; then
    \\    echo "eb-local RPATH wrapper: no $name on PATH after the wrappers" >&2
    \\    exit 127
    \\fi
    \\case $name in ld | ld.*) linker=1 ;; *) linker=0 ;; esac
    \\link=1 info_only=1 want_dir=0
    \\[ $# -eq 0 ] && link=0
    \\dirs=()
    \\for arg in "$@"; do
    \\    if [ $want_dir = 1 ]; then
    \\        dirs+=("$arg")
    \\        want_dir=0
    \\        continue
    \\    fi
    \\    case $arg in
    \\        -c | -S | -E | -M | -MM | -fsyntax-only) [ $linker = 0 ] && link=0 ;;
    \\        -r | -Ur | --relocatable) link=0 ;;
    \\        -L | --library-path) want_dir=1 ;;
    \\        -L*) dirs+=("${arg#-L}") ;;
    \\        --library-path=*) dirs+=("${arg#--library-path=}") ;;
    \\    esac
    \\    case $arg in
    \\        -v | -V | --version | -qversion | --help | -dumpversion | -dumpfullversion | -dumpmachine | -print-* | --print-* | '-###') ;;
    \\        *) info_only=0 ;;
    \\    esac
    \\done
    \\[ $info_only = 1 ] && link=0
    \\[ $link = 1 ] || exec "$real" "$@"
    \\if [ $linker = 0 ] && [ -n "${LIBRARY_PATH-}" ]; then
    \\    IFS=: read -r -a library_dirs <<< "$LIBRARY_PATH"
    \\    dirs+=("${library_dirs[@]}")
    \\fi
    \\extra=()
    \\seen=:
    \\eprefix=${EESSI_EPREFIX-}
    \\while [[ $eprefix == *//* ]]; do eprefix=${eprefix//\/\//\/}; done
    \\while [ "${eprefix%/}" != "$eprefix" ] && [ "$eprefix" != / ]; do eprefix=${eprefix%/}; done
    \\for d in "${dirs[@]}"; do
    \\    while [[ $d == *//* ]]; do d=${d//\/\//\/}; done
    \\    while [ "${d%/}" != "$d" ] && [ "$d" != / ]; do d=${d%/}; done
    \\    case $d in /?*) ;; *) continue ;; esac
    \\    case $d in *,* | *:*) continue ;; esac
    \\    case $d in /lib | /lib/* | /lib64 | /lib64/* | /usr | /usr/*) continue ;; esac
    \\    if [ -n "$eprefix" ]; then
    \\        case $d in "$eprefix" | "$eprefix"/*) continue ;; esac
    \\    fi
    \\    case $seen in *":$d:"*) continue ;; esac
    \\    seen=$seen$d:
    \\    if [ $linker = 1 ]; then extra+=(-rpath "$d"); else extra+=("-Wl,-rpath,$d"); fi
    \\done
    \\if [ $linker = 1 ]; then extra+=(--disable-new-dtags); else extra+=("-Wl,--disable-new-dtags"); fi
    \\exec "$real" "$@" "${extra[@]}"
    \\
;

/// `NoCacheDir` when the cache directory, `$XDG_CACHE_HOME`, else
/// `$HOME/.cache`, is unset, empty or relative; `Unsafe` when the wrappers'
/// directory is not one the caller owns, or a wrapper cannot be written.
pub const Error = error{ NoCacheDir, Unsafe } || sys.Error || Allocator.Error;

/// The effective user cache directory: absolute `$XDG_CACHE_HOME`, or
/// absolute `$HOME/.cache` when XDG_CACHE_HOME is unset or empty.
pub fn cacheHome(a: Allocator, env: *const std.process.Environ.Map) Error![]const u8 {
    const base = if (nonEmpty(env.get("XDG_CACHE_HOME"))) |x|
        try a.dupe(u8, x)
    else if (nonEmpty(env.get("HOME"))) |h|
        try std.fs.path.join(a, &.{ h, ".cache" })
    else
        return error.NoCacheDir;
    if (base.len == 0 or base[0] != '/') return error.NoCacheDir;
    return base;
}

/// The directory for the wrappers of `found`: below the user's cache
/// directory, named by the names it holds and the script it writes.
pub fn directory(a: Allocator, env: *const std.process.Environ.Map, found: []const []const u8) Error![]const u8 {
    const cache = try cacheHome(a, env);
    const base = try std.fs.path.join(a, &.{ cache, "eb-local" });
    var h = std.hash.Wyhash.init(0);
    h.update(script);
    for (found) |n| {
        h.update(n);
        h.update("\x00");
    }
    return std.fmt.allocPrint(a, "{s}/rpath-{x:0>16}", .{ base, h.final() });
}

/// The wrapped names on `path`, in `names` order.
pub fn present(a: Allocator, path: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (names) |n| {
        const hit = proc.which(a, n, path) catch null;
        if (hit) |p| {
            // A wrapper already on PATH is not a compiler.
            const dir = std.fs.path.dirname(p) orelse continue;
            const m = std.fs.path.join(a, &.{ dir, marker }) catch return error.OutOfMemory;
            if (fsx.statAt(fsx.cwd, m, false)) |_| continue else |_| {}
            try out.append(a, n);
        }
    }
    return out.items;
}

/// The names among `among` that no wrapper covers on `path`: the first of
/// each name is neither one of eb-local's wrappers nor one of EasyBuild's,
/// which it writes as `rpath_wrappers/NAME_wrapper/NAME`.
pub fn unwrapped(a: Allocator, path: []const u8, among: []const []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(a);
    for (among) |n| {
        const hit = (try proc.which(a, n, path)) orelse continue;
        defer a.free(hit);
        const dir = std.fs.path.dirname(hit) orelse continue;
        const m = try std.fs.path.join(a, &.{ dir, marker });
        defer a.free(m);
        if (fsx.statAt(fsx.cwd, m, false)) |_| continue else |_| {}
        const parent = std.fs.path.dirname(dir) orelse "";
        const own = try std.fmt.allocPrint(a, "{s}_wrapper", .{n});
        defer a.free(own);
        if (std.mem.eql(u8, std.fs.path.basename(dir), own) and std.mem.eql(u8, std.fs.path.basename(parent), "rpath_wrappers")) continue;
        try out.append(a, n);
    }
    return out.toOwnedSlice(a);
}

/// Write the wrappers for `found` into `dir`, a directory the caller owns
/// and no one else can write; existing wrappers with the same bytes stay.
pub fn write(a: Allocator, dir: []const u8, found: []const []const u8) Error!void {
    if (std.fs.path.dirname(dir)) |parent| {
        if (fsx.statAt(fsx.cwd, parent, false)) |pst| {
            if (!pst.isDir() or pst.uid != linux.getuid()) return error.Unsafe;
        } else |_| {}
    }
    var first_missing: ?[]const u8 = null;
    {
        var probe: []const u8 = dir;
        while (probe.len > 1) {
            if (fsx.statAt(fsx.cwd, probe, true)) |_| break else |_| {}
            first_missing = probe;
            probe = std.fs.path.dirname(probe) orelse break;
        }
    }
    common.atomic.makedirs(dir) catch |e| return e;
    errdefer if (first_missing) |missing| fsx.deleteTree(a, fsx.cwd, missing) catch {};
    const st = try fsx.statAt(fsx.cwd, dir, false);
    if (!st.isDir() or st.uid != linux.getuid()) return error.Unsafe;
    if (std.fs.path.dirname(dir)) |parent| {
        const pst = try fsx.statAt(fsx.cwd, parent, false);
        if (!pst.isDir() or pst.uid != linux.getuid()) return error.Unsafe;
    }
    {
        var zb: [sys.path_max:0]u8 = undefined;
        const zp = try sys.z(&zb, dir);
        if (linux.errno(linux.fchmodat(linux.AT.FDCWD, zp.ptr, 0o700)) != .SUCCESS) return error.Unsafe;
    }
    for (found) |n| try put(a, try std.fs.path.join(a, &.{ dir, n }), script, 0o700);
    try put(a, try std.fs.path.join(a, &.{ dir, marker }), "", 0o600);
}

fn put(a: Allocator, path: []const u8, bytes: []const u8, mode: u32) Error!void {
    if (fsx.openRegular(fsx.cwd, path, false)) |f| {
        defer sys.close(f.fd);
        const old = fsx.readAll(a, f.fd, bytes.len + 1) catch null;
        if (old) |o| if (std.mem.eql(u8, o, bytes) and f.stat.perm() == mode and f.stat.uid == linux.getuid()) return;
    } else |_| {}
    var why: common.atomic.Why = .{};
    defer why.deinit(a);
    common.atomic.atomicWrite(a, path, bytes, .{ .mode = mode }, &why) catch return error.Unsafe;
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const x = v orelse return null;
    return if (x.len > 0) x else null;
}

test "the directory names its contents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    try env.put("HOME", "/home/u");
    const one = try directory(a, &env, &.{"clang"});
    const two = try directory(a, &env, &.{ "clang", "ld" });
    try std.testing.expect(std.mem.startsWith(u8, one, "/home/u/.cache/eb-local/rpath-"));
    try std.testing.expect(!std.mem.eql(u8, one, two));
    try env.put("XDG_CACHE_HOME", "/xdg");
    try std.testing.expect(std.mem.startsWith(u8, try directory(a, &env, &.{"clang"}), "/xdg/eb-local/rpath-"));
    try env.put("XDG_CACHE_HOME", "relative");
    try std.testing.expectError(error.NoCacheDir, directory(a, &env, &.{"clang"}));
}

test "a wrapper that cannot be written frees the reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/rpath-put-{d}", .{ cwd, linux.getpid() });
    defer fsx.deleteTree(a, fsx.cwd, root) catch {};
    try common.atomic.makedirs(root);
    const link = try std.fs.path.join(a, &.{ root, "clang" });
    var tb: [sys.path_max:0]u8 = undefined;
    var lb: [sys.path_max:0]u8 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.symlink((try sys.z(&tb, root)).ptr, (try sys.z(&lb, link)).ptr)));
    try std.testing.expectError(error.Unsafe, put(std.testing.allocator, link, script, 0o700));
}

test "failed wrapper write leaves no marker or newly created directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/rpath-clean-{d}", .{ cwd, linux.getpid() });
    defer fsx.deleteTree(a, fsx.cwd, root) catch {};
    try common.atomic.makedirs(root);

    // Pre-existing symlink at clang makes write() fail after makedirs:
    // marker must not be left behind to poison present/unwrapped.
    const bad_dir = try std.fs.path.join(a, &.{ root, "bad" });
    try common.atomic.makedirs(bad_dir);
    const link = try std.fs.path.join(a, &.{ bad_dir, "clang" });
    var tb: [sys.path_max:0]u8 = undefined;
    var lb: [sys.path_max:0]u8 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.symlink((try sys.z(&tb, bad_dir)).ptr, (try sys.z(&lb, link)).ptr)));
    try std.testing.expectError(error.Unsafe, write(a, bad_dir, &.{"clang"}));
    const m = try std.fs.path.join(a, &.{ bad_dir, marker });
    try std.testing.expectError(error.NotFound, fsx.statAt(fsx.cwd, m, false));

    const real_base = try std.fs.path.join(a, &.{ root, "real-base" });
    try common.atomic.makedirs(real_base);
    const link_base = try std.fs.path.join(a, &.{ root, "eb-local" });
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.symlink((try sys.z(&tb, real_base)).ptr, (try sys.z(&lb, link_base)).ptr)));
    const nested_dir = try std.fs.path.join(a, &.{ link_base, "rpath-link" });
    try std.testing.expectError(error.Unsafe, write(a, nested_dir, &.{"clang"}));
}

test "a compiler is unwrapped unless a wrapper of eb-local's or EasyBuild's comes first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/rpath-test-{d}", .{ cwd, linux.getpid() });
    defer fsx.deleteTree(a, fsx.cwd, root) catch {};
    const files = [_][]const u8{
        "llvm/bin/clang",                        "llvm/bin/ld.lld",
        "eb/rpath_wrappers/clang_wrapper/clang", "eb/rpath_wrappers/other_wrapper/ld.lld",
        "ours/clang",                            "ours/" ++ marker,
    };
    for (files) |rel| {
        const path = try std.fs.path.join(a, &.{ root, rel });
        try common.atomic.makedirs(std.fs.path.dirname(path).?);
        const fd = try sys.openat(fsx.cwd, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o755);
        defer sys.close(fd);
        try sys.writeAll(fd, "#!/bin/sh\n");
    }

    const cases = [_]struct { path: []const []const u8, want: []const []const u8 }{
        .{ .path = &.{"llvm/bin"}, .want = &.{ "clang", "ld.lld" } },
        .{ .path = &.{ "eb/rpath_wrappers/clang_wrapper", "llvm/bin" }, .want = &.{"ld.lld"} },
        .{ .path = &.{ "ours", "llvm/bin" }, .want = &.{"ld.lld"} },
        .{ .path = &.{ "eb/rpath_wrappers/other_wrapper", "llvm/bin" }, .want = &.{ "clang", "ld.lld" } },
        .{ .path = &.{}, .want = &.{} },
    };
    for (cases) |case| {
        var path: std.ArrayList(u8) = .empty;
        for (case.path, 0..) |d, i| {
            if (i > 0) try path.append(a, ':');
            try path.print(a, "{s}/{s}", .{ root, d });
        }
        const got = try unwrapped(std.testing.allocator, path.items, &self_linking);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqual(case.want.len, got.len);
        for (case.want, got) |w, g| try std.testing.expectEqualStrings(w, g);
    }
}
