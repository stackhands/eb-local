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
    \\for d in "${dirs[@]}"; do
    \\    d=${d%/}
    \\    case $d in /?*) ;; *) continue ;; esac
    \\    case $d in *,* | *:*) continue ;; esac
    \\    case $d in /lib | /lib/* | /lib64 | /lib64/* | /usr | /usr/*) continue ;; esac
    \\    if [ -n "${EESSI_EPREFIX-}" ]; then
    \\        case $d in "$EESSI_EPREFIX" | "$EESSI_EPREFIX"/*) continue ;; esac
    \\    fi
    \\    case $seen in *":$d:"*) continue ;; esac
    \\    seen=$seen$d:
    \\    if [ $linker = 1 ]; then extra+=(-rpath "$d"); else extra+=("-Wl,-rpath,$d"); fi
    \\done
    \\if [ $linker = 1 ]; then extra+=(--disable-new-dtags); else extra+=("-Wl,--disable-new-dtags"); fi
    \\exec "$real" "$@" "${extra[@]}"
    \\
;

pub const Error = error{ NoCacheDir, Unsafe } || sys.Error || Allocator.Error;

/// The directory for the wrappers of `found`: below the user's cache
/// directory, named by the names it holds and the script it writes.
pub fn directory(a: Allocator, env: *const std.process.Environ.Map, found: []const []const u8) Error![]const u8 {
    const base = if (nonEmpty(env.get("XDG_CACHE_HOME"))) |x|
        try std.fs.path.join(a, &.{ x, "eb-local" })
    else if (nonEmpty(env.get("HOME"))) |h|
        try std.fs.path.join(a, &.{ h, ".cache", "eb-local" })
    else
        return error.NoCacheDir;
    if (base[0] != '/') return error.NoCacheDir;
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

/// Write the wrappers for `found` into `dir`, a directory the caller owns
/// and no one else can write; existing wrappers with the same bytes stay.
pub fn write(a: Allocator, dir: []const u8, found: []const []const u8) Error!void {
    common.atomic.makedirs(dir) catch |e| return e;
    const st = try fsx.statAt(fsx.cwd, dir, false);
    if (!st.isDir() or st.uid != linux.getuid()) return error.Unsafe;
    {
        var zb: [sys.path_max:0]u8 = undefined;
        const zp = try sys.z(&zb, dir);
        if (linux.errno(linux.fchmodat(linux.AT.FDCWD, zp.ptr, 0o700)) != .SUCCESS) return error.Unsafe;
    }
    try put(a, try std.fs.path.join(a, &.{ dir, marker }), "", 0o600);
    for (found) |n| try put(a, try std.fs.path.join(a, &.{ dir, n }), script, 0o700);
}

fn put(a: Allocator, path: []const u8, bytes: []const u8, mode: u32) Error!void {
    if (fsx.openRegular(fsx.cwd, path, false)) |f| {
        defer sys.close(f.fd);
        const old = fsx.readAll(a, f.fd, bytes.len + 1) catch null;
        if (old) |o| if (std.mem.eql(u8, o, bytes) and f.stat.perm() == mode and f.stat.uid == linux.getuid()) return;
    } else |_| {}
    var why: common.atomic.Why = .{};
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
