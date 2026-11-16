//! Run EasyBuild through EESSI-extend with no site file and no Slurm job.
//!
//! EESSI-extend reads EESSI_USER_INSTALL, EESSI_PROJECT_INSTALL,
//! EESSI_SITE_INSTALL and EESSI_CVMFS_INSTALL when it loads, and treats a
//! present empty value as set (`os.getenv(name) ~= nil`). This chooses
//! exactly one of those, then a shell sources the EESSI init, loads the
//! module and execs eb. The module sets the hooks, the RPATH and
//! EASYBUILD_UMASK; nothing here replaces them.
const std = @import("std");
const linux = std.os.linux;
const common = @import("zig_common");
const sys = common.sys;
const fsx = common.fsx;
const proc = common.proc;
const Allocator = std.mem.Allocator;

pub const Mode = enum { user, project, site, cvmfs };

pub const Selection = struct {
    mode: Mode,
    /// Process umask, as octal digits: 077, 002 or 022.
    umask: []const u8,
};

pub const SelectError = error{TooMany};

pub const too_many = "eb-local: set exactly one of EESSI_USER_INSTALL, EESSI_PROJECT_INSTALL, EESSI_SITE_INSTALL, EESSI_CVMFS_INSTALL";

const Name = struct {
    name: []const u8,
    mode: Mode,
    umask: []const u8,
};

/// The order is the order the refusal names them. A present empty value
/// counts: EESSI-extend uses the same test.
const names = [_]Name{
    .{ .name = "EESSI_USER_INSTALL", .mode = .user, .umask = "077" },
    .{ .name = "EESSI_PROJECT_INSTALL", .mode = .project, .umask = "002" },
    .{ .name = "EESSI_SITE_INSTALL", .mode = .site, .umask = "022" },
    .{ .name = "EESSI_CVMFS_INSTALL", .mode = .cvmfs, .umask = "022" },
};

/// The install variable that selects MODE.
pub fn variable(mode: Mode) []const u8 {
    for (names) |n| if (n.mode == mode) return n.name;
    unreachable;
}

/// `EB_LOCAL_EESSI_EXTEND` is how a caller that can pass only one program
/// (an eb-stack target's EasyBuild command) selects this launcher. Every
/// argument is then eb's. Empty and `0` leave the ordinary commands alone.
pub fn engaged(env: *const std.process.Environ.Map) bool {
    const v = env.get("EB_LOCAL_EESSI_EXTEND") orelse return false;
    return v.len != 0 and !std.mem.eql(u8, v, "0");
}

/// None of the four is a user install, and nothing is exported. On EESSI
/// 2026.06 the module's help text says `$HOME/EESSI`, and the loaded module
/// uses `$HOME/eessi` without requiring that directory to exist. Exporting
/// the uppercase path would make the module demand a directory it does not use.
pub fn select(env: *const std.process.Environ.Map) SelectError!Selection {
    var chosen: ?usize = null;
    for (names, 0..) |n, i| {
        if (env.get(n.name) != null) {
            if (chosen != null) return error.TooMany;
            chosen = i;
        }
    }
    const i = chosen orelse return .{ .mode = .user, .umask = "077" };
    return .{ .mode = names[i].mode, .umask = names[i].umask };
}

/// Drop the launcher switch, so a build that itself runs eb-local does not
/// enter this mode again. Install variables are left as the caller set them.
pub fn apply(env: *std.process.Environ.Map) void {
    _ = env.swapRemove("EB_LOCAL_EESSI_EXTEND");
}

/// `$1` is the umask, `$2` is the mode, and the rest are eb's arguments.
/// EESSI's init is not safe under `nounset`. The compat-layer `ld` goes on
/// `PATH` even when `rustc` is absent: a failing command substitution under
/// `pipefail` would exit before the module loads. `WORKING_DIR` is the
/// caller's: unset, the module's default is `/tmp/$USER`, one per user,
/// where a shared default would leave every other user's build unable to
/// write the first one's directories.
pub const script =
    \\set -eo pipefail
    \\unset EB_LOCAL_EESSI_EXTEND || true
    \\umask_bits=$1
    \\mode=$2
    \\shift 2
    \\repo=${EESSI_CVMFS_REPO:-/cvmfs/software.eessi.io}
    \\ver=${EESSI_VERSION:-2026.06}
    \\init=${repo}/versions/${ver}/init/lmod/bash
    \\if [[ ! -e $init ]]; then
    \\  echo "eb-local: missing ${init}" >&2
    \\  exit 2
    \\fi
    \\# shellcheck disable=SC1090
    \\source "$init"
    \\# The module sets EASYBUILD_UMASK (077 and the sticky bit for a user
    \\# prefix, 002 with the setgid bit for a project, 022 for site and
    \\# cvmfs). The process umask matches, for the user prefix created here
    \\# and for files eb creates outside that setting. No --umask is added,
    \\# so the module's value stands, and so do its hooks.
    \\umask "$umask_bits"
    \\# A named user prefix must exist or the module refuses to load. With
    \\# no install variable set, export nothing: the module uses $HOME/eessi
    \\# and does not require that directory yet. An empty value is set, so
    \\# it is not this default, and there is no path to create.
    \\if [[ $mode == user && -n ${EESSI_USER_INSTALL:-} ]]; then
    \\  mkdir -p -- "$EESSI_USER_INSTALL"
    \\fi
    \\unset RUSTC_WRAPPER CARGO_BUILD_RUSTC_WRAPPER RUSTC_WORKSPACE_WRAPPER RUSTFLAGS CARGO_ENCODED_RUSTFLAGS \
    \\  CMAKE_C_COMPILER_LAUNCHER CMAKE_CXX_COMPILER_LAUNCHER CMAKE_Fortran_COMPILER_LAUNCHER || true
    \\eval "$(env | awk -F= '/^CARGO_TARGET_[A-Z0-9_]*_(LINKER|RUSTFLAGS)=/{print "unset "$1}')"
    \\export LINKER=${CC:-gcc}
    \\_triple=""
    \\if _host=$(rustc -vV 2>/dev/null); then
    \\  _triple=$(printf '%s\n' "$_host" | awk '/^host:/{print $2}')
    \\fi
    \\_triple_env=$(printf %s "${_triple}" | tr '[:lower:]-' '[:upper:]_')
    \\if [[ -n ${_triple_env} ]]; then
    \\  eval "export CARGO_TARGET_${_triple_env}_LINKER=\${CC:-gcc}"
    \\fi
    \\_arch=$(uname -m)
    \\export PATH="${EESSI_EPREFIX:-${repo}/versions/${ver}/compat/linux/${_arch}}/usr/bin:${PATH}"
    \\module load EESSI-extend
    \\exec eb "$@"
;

pub fn commandLine(a: Allocator, sel: Selection, eb_args: []const []const u8) Allocator.Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(a);
    try argv.appendSlice(a, &.{
        "/bin/bash", "--noprofile", "--norc", "-c", script, "eb-local", sel.umask, @tagName(sel.mode),
    });
    try argv.appendSlice(a, eb_args);
    return try argv.toOwnedSlice(a);
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

fn put(env: *std.process.Environ.Map, k: []const u8, v: []const u8) !void {
    try env.put(k, v);
}

test "a present empty install variable is that mode" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try put(&env, "EESSI_SITE_INSTALL", "");
    const site = try select(&env);
    try testing.expectEqual(Mode.site, site.mode);
    try testing.expectEqualStrings("022", site.umask);

    try put(&env, "EESSI_CVMFS_INSTALL", "");
    try testing.expectError(error.TooMany, select(&env));
    _ = env.swapRemove("EESSI_SITE_INSTALL");
    const cvmfs = try select(&env);
    try testing.expectEqual(Mode.cvmfs, cvmfs.mode);
    try testing.expectEqualStrings("022", cvmfs.umask);

    _ = env.swapRemove("EESSI_CVMFS_INSTALL");
    try put(&env, "EESSI_USER_INSTALL", "");
    const user = try select(&env);
    try testing.expectEqual(Mode.user, user.mode);
    try testing.expectEqualStrings("077", user.umask);

    try put(&env, "EESSI_PROJECT_INSTALL", "/project");
    try testing.expectError(error.TooMany, select(&env));
}

test "no install variable is a user install and exports nothing" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    const sel = try select(&env);
    try testing.expectEqual(Mode.user, sel.mode);
    try testing.expectEqualStrings("077", sel.umask);
    apply(&env);
    try testing.expect(env.get("EESSI_USER_INSTALL") == null);
}

test "a project prefix is group-writable and a named user prefix is private" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try put(&env, "EESSI_PROJECT_INSTALL", "/project/eessi");
    const project = try select(&env);
    try testing.expectEqual(Mode.project, project.mode);
    try testing.expectEqualStrings("002", project.umask);
    _ = env.swapRemove("EESSI_PROJECT_INSTALL");
    try put(&env, "EESSI_USER_INSTALL", "/home/u/mine");
    const user = try select(&env);
    try testing.expectEqual(Mode.user, user.mode);
    try testing.expectEqualStrings("077", user.umask);
}

test "the launcher switch is only a non-empty value other than zero" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testing.expect(!engaged(&env));
    try put(&env, "EB_LOCAL_EESSI_EXTEND", "");
    try testing.expect(!engaged(&env));
    try put(&env, "EB_LOCAL_EESSI_EXTEND", "0");
    try testing.expect(!engaged(&env));
    try put(&env, "EB_LOCAL_EESSI_EXTEND", "1");
    try testing.expect(engaged(&env));
}

test "eb arguments follow the mode and the umask" {
    const sel: Selection = .{ .mode = .site, .umask = "022" };
    const argv = try commandLine(testing.allocator, sel, &.{ "--robot", "zlib.eb" });
    defer testing.allocator.free(argv);
    try testing.expectEqualStrings("/bin/bash", argv[0]);
    try testing.expectEqualStrings("022", argv[6]);
    try testing.expectEqualStrings("site", argv[7]);
    try testing.expectEqualStrings("--robot", argv[8]);
    try testing.expectEqualStrings("zlib.eb", argv[9]);
}

const Run = struct {
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    env: std.process.Environ.Map,

    fn init() !Run {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var cwd_buf: [sys.path_max]u8 = undefined;
        const cwd = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
        const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/extend-test-{d}-{d}", .{ cwd, linux.getpid(), seq.fetchAdd(1, .monotonic) });
        try common.atomic.makedirs(root);
        var env = std.process.Environ.Map.init(testing.allocator);
        errdefer env.deinit();
        const home = try std.fs.path.join(a, &.{ root, "home" });
        try common.atomic.makedirs(home);
        const bin = try std.fs.path.join(a, &.{ root, "bin" });
        try common.atomic.makedirs(bin);
        try env.put("HOME", home);
        try env.put("PATH", try std.fmt.allocPrint(a, "{s}:/usr/bin:/bin", .{bin}));
        try env.put("EESSI_CVMFS_REPO", try std.fs.path.join(a, &.{ root, "repo" }));
        return .{ .arena = arena, .root = root, .env = env };
    }

    fn deinit(self: *Run) void {
        fsx.deleteTree(self.arena.allocator(), fsx.cwd, self.root) catch {};
        self.env.deinit();
        self.arena.deinit();
    }

    fn write(self: *Run, rel: []const u8, text: []const u8, mode: u32) !void {
        const a = self.arena.allocator();
        const path = try std.fs.path.join(a, &.{ self.root, rel });
        if (std.fs.path.dirname(path)) |dir| try common.atomic.makedirs(dir);
        const fd = try sys.openat(fsx.cwd, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, mode);
        defer sys.close(fd);
        try sys.writeAll(fd, text);
        try sys.fchmod(fd, mode);
    }

    /// A repository whose init defines `module` and, on load, the hooks,
    /// the EasyBuild umask and the EasyBuild prefix the real module sets.
    /// `eb` prints the process umask and then the environment.
    fn fake(self: *Run, version: []const u8, eprefix: ?[]const u8) !void {
        var init_text: std.ArrayList(u8) = .empty;
        errdefer init_text.deinit(self.arena.allocator());
        const a = self.arena.allocator();
        try init_text.appendSlice(a,
            \\module() {
            \\  if [ "$1" = load ]; then
            \\    export EASYBUILD_HOOKS=/eessi/init/easybuild/eb_hooks.py
            \\    export EASYBUILD_RPATH=1
            \\    export EASYBUILD_UMASK=from-the-module
            \\    export EASYBUILD_PREFIX="${WORKING_DIR:-/tmp/$USER}/easybuild"
            \\  fi
            \\}
            \\
        );
        if (eprefix) |e| try init_text.print(a, "export EESSI_EPREFIX={s}\n", .{e});
        const rel = try std.fmt.allocPrint(a, "repo/versions/{s}/init/lmod/bash", .{version});
        try self.write(rel, init_text.items, 0o644);
        try self.write("bin/eb",
            \\#!/bin/sh
            \\umask
            \\env
            \\
        , 0o755);
    }

    fn launch(self: *Run, eb_args: []const []const u8) !proc.Result {
        const a = self.arena.allocator();
        const sel = select(&self.env) catch |err| switch (err) {
            error.TooMany => return .{
                .term = .{ .exited = 3 },
                .stdout = try a.dupe(u8, ""),
                .stderr = try a.dupe(u8, too_many),
            },
        };
        apply(&self.env);
        const argv = try commandLine(a, sel, eb_args);
        const envp = try envBlock(a, &self.env);
        return proc.run(a, argv[0], argv, envp, .{
            .stdout_limit = 1 << 20,
            .stderr_limit = 1 << 20,
            .timeout_ms = 30_000,
        });
    }
};

var seq: std.atomic.Value(u32) = .init(0);

fn envBlock(a: Allocator, map: *const std.process.Environ.Map) Allocator.Error!proc.Envp {
    var lines: std.ArrayList([:0]u8) = .empty;
    errdefer {
        for (lines.items) |line| a.free(line);
        lines.deinit(a);
    }
    var it = map.iterator();
    while (it.next()) |kv| {
        const line = try std.fmt.allocPrintSentinel(a, "{s}={s}", .{ kv.key_ptr.*, kv.value_ptr.* }, 0);
        errdefer a.free(line);
        try lines.append(a, line);
    }
    var block: std.ArrayList(?[*:0]const u8) = .empty;
    errdefer block.deinit(a);
    for (lines.items) |line| try block.append(a, line.ptr);
    try block.append(a, null);
    const owned = try block.toOwnedSlice(a);
    lines.deinit(a);
    return @ptrCast(owned.ptr);
}

fn envVar(text: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len > name.len and std.mem.startsWith(u8, line, name) and line[name.len] == '=')
            return line[name.len + 1 ..];
    }
    return null;
}

fn firstLine(text: []const u8) []const u8 {
    const n = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return text[0..n];
}

fn ok(r: proc.Result) !void {
    if (r.term.code() != 0) {
        std.debug.print("status {d}\n{s}\n", .{ r.term.code(), r.stderr });
        return error.TestUnexpectedResult;
    }
}

fn machine(buf: *[64]u8) []const u8 {
    var u: linux.utsname = undefined;
    _ = linux.uname(&u);
    const name = std.mem.sliceTo(&u.machine, 0);
    @memcpy(buf[0..name.len], name);
    return buf[0..name.len];
}

fn kept(text: []const u8) !void {
    try testing.expectEqualStrings("/eessi/init/easybuild/eb_hooks.py", envVar(text, "EASYBUILD_HOOKS").?);
    try testing.expectEqualStrings("1", envVar(text, "EASYBUILD_RPATH").?);
    try testing.expectEqualStrings("from-the-module", envVar(text, "EASYBUILD_UMASK").?);
    try testing.expect(envVar(text, "EESSI_EASYBUILD_HOOKS_OVERRIDE") == null);
}

test "without a version it loads the current EESSI" {
    var r = try Run.init();
    defer r.deinit();
    try r.fake("2026.06", null);
    const out = try r.launch(&.{});
    try ok(out);
    try kept(out.stdout);
    var arch_buf: [64]u8 = undefined;
    const compat = try std.fmt.allocPrint(r.arena.allocator(), "{s}/repo/versions/2026.06/compat/linux/{s}/usr/bin:", .{ r.root, machine(&arch_buf) });
    const path = envVar(out.stdout, "PATH").?;
    try testing.expect(std.mem.startsWith(u8, path, compat));
    try testing.expectEqualStrings("0077", firstLine(out.stdout));
}

test "the compat layer comes from the init" {
    var r = try Run.init();
    defer r.deinit();
    try r.fake("2026.06", "/opt/eessi-compat");
    const out = try r.launch(&.{});
    try ok(out);
    const path = envVar(out.stdout, "PATH").?;
    try testing.expect(std.mem.startsWith(u8, path, "/opt/eessi-compat/usr/bin:"));
}

test "a named user prefix is created private" {
    var r = try Run.init();
    defer r.deinit();
    try r.fake("2026.06", null);
    const prefix = try std.fs.path.join(r.arena.allocator(), &.{ r.root, "home/eessi-mine" });
    try r.env.put("EESSI_USER_INSTALL", prefix);
    const out = try r.launch(&.{});
    try ok(out);
    const st = try fsx.statAt(fsx.cwd, prefix, false);
    try testing.expect(st.isDir());
    try testing.expectEqual(@as(u32, 0o700), st.perm());
    try testing.expectEqualStrings(prefix, envVar(out.stdout, "EESSI_USER_INSTALL").?);
    try testing.expectEqualStrings("0077", firstLine(out.stdout));
    try kept(out.stdout);
}

test "with no install variable nothing is exported or created" {
    var r = try Run.init();
    defer r.deinit();
    try r.fake("2026.06", null);
    const out = try r.launch(&.{});
    try ok(out);
    try testing.expect(envVar(out.stdout, "EESSI_USER_INSTALL") == null);
    try testing.expectEqualStrings("0077", firstLine(out.stdout));
    // The module's help text says $HOME/EESSI. The loaded module uses
    // $HOME/eessi, and does not need that directory at load time.
    for ([_][]const u8{ "home/EESSI", "home/eessi" }) |rel| {
        const path = try std.fs.path.join(r.arena.allocator(), &.{ r.root, rel });
        try testing.expect(fsx.statAt(fsx.cwd, path, false) == error.NotFound);
    }
}

test "a project prefix is not created" {
    var r = try Run.init();
    defer r.deinit();
    try r.fake("2026.06", null);
    const project = try std.fs.path.join(r.arena.allocator(), &.{ r.root, "project" });
    try r.env.put("EESSI_PROJECT_INSTALL", project);
    const out = try r.launch(&.{});
    try ok(out);
    try testing.expect(fsx.statAt(fsx.cwd, project, false) == error.NotFound);
    try testing.expect(envVar(out.stdout, "EESSI_USER_INSTALL") == null);
    try testing.expectEqualStrings(project, envVar(out.stdout, "EESSI_PROJECT_INSTALL").?);
    try testing.expectEqualStrings("0002", firstLine(out.stdout));
    try kept(out.stdout);
}

test "an empty site install is not a user prefix" {
    var r = try Run.init();
    defer r.deinit();
    try r.fake("2026.06", null);
    try r.env.put("EESSI_SITE_INSTALL", "");
    const out = try r.launch(&.{});
    try ok(out);
    const home = try std.fs.path.join(r.arena.allocator(), &.{ r.root, "home/EESSI" });
    try testing.expect(fsx.statAt(fsx.cwd, home, false) == error.NotFound);
    try testing.expect(envVar(out.stdout, "EESSI_USER_INSTALL") == null);
    try testing.expectEqualStrings("", envVar(out.stdout, "EESSI_SITE_INSTALL").?);
    try testing.expectEqualStrings("0022", firstLine(out.stdout));
    try kept(out.stdout);
}

test "an empty cvmfs install is not a user prefix" {
    var r = try Run.init();
    defer r.deinit();
    try r.fake("2026.06", null);
    try r.env.put("EESSI_CVMFS_INSTALL", "");
    const out = try r.launch(&.{});
    try ok(out);
    const home = try std.fs.path.join(r.arena.allocator(), &.{ r.root, "home/EESSI" });
    try testing.expect(fsx.statAt(fsx.cwd, home, false) == error.NotFound);
    try testing.expect(envVar(out.stdout, "EESSI_USER_INSTALL") == null);
    try testing.expectEqualStrings("", envVar(out.stdout, "EESSI_CVMFS_INSTALL").?);
    try testing.expectEqualStrings("0022", firstLine(out.stdout));
}

test "an empty user install does not create the default prefix" {
    var r = try Run.init();
    defer r.deinit();
    try r.fake("2026.06", null);
    try r.env.put("EESSI_USER_INSTALL", "");
    const out = try r.launch(&.{});
    try ok(out);
    const home = try std.fs.path.join(r.arena.allocator(), &.{ r.root, "home/EESSI" });
    try testing.expect(fsx.statAt(fsx.cwd, home, false) == error.NotFound);
    try testing.expectEqualStrings("", envVar(out.stdout, "EESSI_USER_INSTALL").?);
    try testing.expectEqualStrings("0077", firstLine(out.stdout));
}

test "an empty site install with a user prefix is refused" {
    var r = try Run.init();
    defer r.deinit();
    try r.fake("2026.06", null);
    try r.env.put("EESSI_SITE_INSTALL", "");
    try r.env.put("EESSI_USER_INSTALL", "/x");
    const out = try r.launch(&.{});
    try testing.expectEqual(@as(u32, 3), out.term.code());
    const home = try std.fs.path.join(r.arena.allocator(), &.{ r.root, "home/EESSI" });
    try testing.expect(fsx.statAt(fsx.cwd, home, false) == error.NotFound);
}

test "two prefixes are refused" {
    var r = try Run.init();
    defer r.deinit();
    try r.fake("2026.06", null);
    try r.env.put("EESSI_USER_INSTALL", "/x");
    try r.env.put("EESSI_PROJECT_INSTALL", "/y");
    const out = try r.launch(&.{});
    try testing.expectEqual(@as(u32, 3), out.term.code());
}

test "a missing version is reported" {
    var r = try Run.init();
    defer r.deinit();
    try r.fake("2026.06", null);
    try r.env.put("EESSI_VERSION", "2025.06");
    const out = try r.launch(&.{});
    try testing.expectEqual(@as(u32, 2), out.term.code());
    try testing.expect(std.mem.indexOf(u8, out.stderr, "versions/2025.06/init") != null);
}

test "the build directory is the caller's WORKING_DIR or one of the user's own" {
    var r = try Run.init();
    defer r.deinit();
    try r.fake("2026.06", null);
    try r.env.put("USER", "alice");
    const out = try r.launch(&.{});
    try ok(out);
    try testing.expect(envVar(out.stdout, "WORKING_DIR") == null);
    try testing.expectEqualStrings("/tmp/alice/easybuild", envVar(out.stdout, "EASYBUILD_PREFIX").?);

    try r.env.put("WORKING_DIR", "/local/alice");
    const chosen = try r.launch(&.{});
    try ok(chosen);
    try testing.expectEqualStrings("/local/alice", envVar(chosen.stdout, "WORKING_DIR").?);
    try testing.expectEqualStrings("/local/alice/easybuild", envVar(chosen.stdout, "EASYBUILD_PREFIX").?);
}

test "rustc is optional and a host wrapper does not reach eb" {
    var r = try Run.init();
    defer r.deinit();
    try r.fake("2026.06", null);
    try r.write("bin/rustc",
        \\#!/bin/sh
        \\printf '%s\n' 'rustc 1.0' 'host: x86_64-unknown-linux-gnu'
        \\
    , 0o755);
    try r.env.put("RUSTC_WRAPPER", "sccache");
    try r.env.put("CMAKE_C_COMPILER_LAUNCHER", "ccache");
    try r.env.put("CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS", "-C link-arg=-fuse-ld=mold");
    const out = try r.launch(&.{"--show-config"});
    try ok(out);
    try testing.expect(envVar(out.stdout, "RUSTC_WRAPPER") == null);
    try testing.expect(envVar(out.stdout, "CMAKE_C_COMPILER_LAUNCHER") == null);
    try testing.expect(envVar(out.stdout, "CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS") == null);
    try testing.expectEqualStrings("gcc", envVar(out.stdout, "CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER").?);
    try testing.expectEqualStrings("gcc", envVar(out.stdout, "LINKER").?);
}

test "without rustc the compat linker is still on PATH" {
    var r = try Run.init();
    defer r.deinit();
    try r.fake("2026.06", null);
    const out = try r.launch(&.{});
    try ok(out);
    try testing.expect(envVar(out.stdout, "CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER") == null);
    const path = envVar(out.stdout, "PATH").?;
    try testing.expect(std.mem.indexOf(u8, path, "/compat/linux/") != null);
}
