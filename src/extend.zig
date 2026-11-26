//! Run EasyBuild through EESSI-extend with no Slurm job.
//!
//! EESSI-extend reads EESSI_USER_INSTALL, EESSI_PROJECT_INSTALL,
//! EESSI_SITE_INSTALL and EESSI_CVMFS_INSTALL when it loads, and treats a
//! present empty value as set (`os.getenv(name) ~= nil`). This allows at
//! most one of those, then a shell sources the EESSI init, loads the
//! module and execs eb. The module sets the hooks, the RPATH and
//! EASYBUILD_UMASK; nothing here replaces them.
const std = @import("std");
const linux = std.os.linux;
const common = @import("zig_common");
const sys = common.sys;
const fsx = common.fsx;
const proc = common.proc;
const Allocator = std.mem.Allocator;

/// The install EESSI-extend makes, chosen by which install variable is set:
/// `EESSI_USER_INSTALL`, `EESSI_PROJECT_INSTALL`, `EESSI_SITE_INSTALL` or
/// `EESSI_CVMFS_INSTALL`.
pub const Mode = enum { user, project, site, cvmfs };

/// What `select` chose: the install mode, and the umask the launcher runs
/// with for it, the one EESSI-extend sets for that mode.
pub const Selection = struct {
    mode: Mode,
    /// Process umask, as octal digits: 077, 002 or 022.
    umask: []const u8,
};

/// `error.TooMany` when more than one install variable is set, a present
/// empty one included; `tooMany` says which.
pub const SelectError = error{TooMany};

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

/// Why `select` refused: each install variable that is set, with its
/// value, and what EESSI-extend does with them. With a project and a user
/// variable it loads and makes a private user install; with a site or a
/// cvmfs one and another it refuses to load. One of them is usually left
/// from an earlier session.
pub fn tooMany(a: Allocator, env: *const std.process.Environ.Map) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var set: usize = 0;
    for (names) |n| {
        if (env.get(n.name) != null) set += 1;
    }
    try out.appendSlice(a, "eb-local: ");
    var shown: usize = 0;
    for (names) |n| {
        const v = env.get(n.name) orelse continue;
        if (shown > 0) try out.appendSlice(a, if (shown + 1 == set) " and " else ", ");
        try out.print(a, "{s}=", .{n.name});
        try appendQuoted(a, &out, v);
        shown += 1;
    }
    try out.appendSlice(a, if (set == 2) " are both set; " else " are all set; ");
    if (env.get("EESSI_CVMFS_INSTALL") != null) {
        try out.appendSlice(a, "EESSI-extend refuses to load with EESSI_CVMFS_INSTALL and any other install variable.\n");
    } else if (env.get("EESSI_SITE_INSTALL") != null) {
        try out.appendSlice(a, "EESSI-extend refuses to load with EESSI_SITE_INSTALL and a user or project install variable.\n");
    } else {
        try out.appendSlice(a, "EESSI-extend would make a private user install (umask 077) under ");
        try appendQuoted(a, &out, env.get("EESSI_USER_INSTALL").?);
        try out.appendSlice(a, ", not a project install under ");
        try appendQuoted(a, &out, env.get("EESSI_PROJECT_INSTALL").?);
        try out.appendSlice(a, ".\n");
    }
    try out.appendSlice(a,
        \\  Unset the one an earlier session left (a shell startup file, or eval "$(eb-local env)" for another prefix):
        \\  set at most one of EESSI_USER_INSTALL, EESSI_PROJECT_INSTALL, EESSI_SITE_INSTALL, EESSI_CVMFS_INSTALL; with none set, eb-local uses its configured prefix or project
        \\
    );
    return out.toOwnedSlice(a);
}

/// S as one shell word, as eb-local prints values elsewhere.
fn appendQuoted(a: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    const safe = s.len > 0 and for (s) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "_./:@%+,=-", ch) != null)) break false;
    } else true;
    if (safe) return out.appendSlice(a, s);
    try out.append(a, '\'');
    for (s) |ch| {
        if (ch == '\'') try out.appendSlice(a, "'\\''") else try out.append(a, ch);
    }
    try out.append(a, '\'');
}

/// Drop the launcher switch, so a build that itself runs eb-local does not
/// enter this mode again. Install variables are left as the caller set them.
pub fn apply(env: *std.process.Environ.Map) void {
    _ = env.swapRemove("EB_LOCAL_EESSI_EXTEND");
}

/// The EESSI init the script sources, with the script's defaults for an
/// unset or empty `EESSI_CVMFS_REPO` and `EESSI_VERSION`.
pub fn initPath(a: Allocator, env: *const std.process.Environ.Map) Allocator.Error![]const u8 {
    const repo = env.get("EESSI_CVMFS_REPO") orelse "";
    const ver = env.get("EESSI_VERSION") orelse "";
    var base_repo = if (repo.len > 0) repo else "/cvmfs/software.eessi.io";
    while (base_repo.len > 1 and base_repo[base_repo.len - 1] == '/') base_repo = base_repo[0 .. base_repo.len - 1];
    const prefix = if (std.mem.eql(u8, base_repo, "/")) "" else base_repo;
    return std.fmt.allocPrint(a, "{s}/versions/{s}/init/lmod/bash", .{
        prefix,
        if (ver.len > 0) ver else "2026.06",
    });
}

/// Lines that drop a host Cargo linker and point Cargo at `${CC:-gcc}`
/// when `rustc -vV` prints a host. `script` includes this file, and `dev`
/// prints the same bytes.
pub const cargo_linker = @embedFile("cargo-linker.sh");

const script_before =
    \\set -eo pipefail
    \\trap 'trap - INT; kill -s INT "$$"' INT
    \\unset EB_LOCAL_EESSI_EXTEND || true
    \\umask_bits=$1
    \\mode=$2
    \\shift 2
    \\repo=${EESSI_CVMFS_REPO:-/cvmfs/software.eessi.io}
    \\while [[ $repo == */ ]]; do repo=${repo%/}; done
    \\ver=${EESSI_VERSION:-2026.06}
    \\init=${repo}/versions/${ver}/init/lmod/bash
    \\if [[ ! -e $init ]]; then
    \\  echo "eb-local: missing ${init}, the EESSI init; eb was not run." >&2
    \\  echo "  Set EESSI_CVMFS_REPO or EESSI_VERSION if EESSI is elsewhere." >&2
    \\  exit 2
    \\elif [[ ! -f $init || ! -r $init ]]; then
    \\  echo "eb-local: cannot read ${init}, the EESSI init; eb was not run." >&2
    \\  echo "  Set EESSI_CVMFS_REPO or EESSI_VERSION if EESSI is elsewhere." >&2
    \\  exit 2
    \\fi
    \\# shellcheck disable=SC1090
    \\source "$init"
    \\# The command supplies the configured prefix's durable source directory
    \\# only when the caller did not export one. Set it after the init so an
    \\# initializer cannot send default sources back to /tmp/$USER, but never
    \\# replace an EASYBUILD_SOURCEPATH inherited from the caller.
    \\if [[ -n ${EBLOCAL_EB_SOURCEPATH:-} ]]; then
    \\  if [[ -z ${EASYBUILD_SOURCEPATH+x} ]]; then
    \\    export EASYBUILD_SOURCEPATH=$EBLOCAL_EB_SOURCEPATH
    \\  fi
    \\  unset EBLOCAL_EB_SOURCEPATH
    \\fi
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
    \\  if [[ -e $EESSI_USER_INSTALL && ! -d $EESSI_USER_INSTALL ]]; then
    \\    echo "eb-local: EESSI_USER_INSTALL=${EESSI_USER_INSTALL} is not a directory; eb was not run." >&2
    \\    exit 2
    \\  fi
    \\  if ! mkdir_err=$(mkdir -p -- "$EESSI_USER_INSTALL" 2>&1); then
    \\    echo "eb-local: cannot create EESSI_USER_INSTALL=${EESSI_USER_INSTALL} (${mkdir_err#mkdir: }); eb was not run." >&2
    \\    exit 2
    \\  fi
    \\fi
    \\
;

const script_after =
    \\_arch=$(uname -m)
    \\export PATH="${EESSI_EPREFIX:-${repo}/versions/${ver}/compat/linux/${_arch}}/usr/bin:${PATH}"
    \\# Where the module installs, read before it loads: below the tree a user
    \\# or project variable names, $HOME/eessi as Lmod's pathJoin makes it
    \\# with none set, the site tree for a site install, the EESSI tree for a
    \\# cvmfs one.
    \\case $mode in
    \\  user)
    \\    home=${HOME-}
    \\    while [[ $home == *//* ]]; do home=${home//\/\//\/}; done
    \\    root=${EESSI_USER_INSTALL:-${home%/}/eessi} from=EESSI_USER_INSTALL ;;
    \\  project) root=$EESSI_PROJECT_INSTALL from=EESSI_PROJECT_INSTALL ;;
    \\  site) root=${EESSI_SITE_SOFTWARE_PATH:-} from=EESSI_SITE_SOFTWARE_PATH ;;
    \\  *) root=${EESSI_SOFTWARE_PATH:-} from=EESSI_SOFTWARE_PATH ;;
    \\esac
    \\while [[ $root == *//* ]]; do root=${root//\/\//\/}; done
    \\[[ $root == / ]] || root=${root%/}
    \\see='See "Where EESSI-extend installs": https://stackhands.github.io/eb-local/explanation/install-variables.html'
    \\for v in EASYBUILD_INSTALLPATH_SOFTWARE EASYBUILD_INSTALLPATH_MODULES; do
    \\  if [[ -n ${!v+set} ]]; then
    \\    echo "eb-local: ${v}=${!v} is set in this shell and would put part of this install outside ${root}; nothing was built." >&2
    \\    echo "  Unset it: EasyBuild installs software and modules below the install path EESSI-extend sets. ${see}" >&2
    \\    exit 2
    \\  fi
    \\done
    \\installs=(EESSI_USER_INSTALL EESSI_PROJECT_INSTALL EESSI_SITE_INSTALL EESSI_CVMFS_INSTALL)
    \\declare -A was
    \\for v in "${installs[@]}"; do was[$v]=${!v+set:${!v}}; done
    \\if [[ -n ${EBLOCAL_EB_SITE_TOOLCHAINS:-} ]]; then
    \\  toolchains_var=EESSI_SITE_TOP_LEVEL_TOOLCHAINS_${ver//./_}
    \\  if [[ -z ${!toolchains_var+x} ]]; then
    \\    export "$toolchains_var=$EBLOCAL_EB_SITE_TOOLCHAINS"
    \\  fi
    \\  unset EBLOCAL_EB_SITE_TOOLCHAINS
    \\fi
    \\module load EESSI-extend
    \\# An install variable a load hook sets acts only on the next load, so
    \\# this install is not moved by it; a shell that keeps it is.
    \\for v in "${installs[@]}"; do
    \\  [[ ${!v+set:${!v}} == "${was[$v]}" ]] && continue
    \\  if [[ -n ${!v+set} ]]; then what="set $v=${!v}"; else what="unset $v"; fi
    \\  echo "eb-local: loading EESSI-extend ${what}; this install still goes under ${root}, but a shell that loads EESSI-extend by hand keeps the change, and its next load installs elsewhere." >&2
    \\  echo "  A site Lmod hook that sets an install variable acts only on the next load. ${see}" >&2
    \\done
    \\for v in EASYBUILD_INSTALLPATH_SOFTWARE EASYBUILD_INSTALLPATH_MODULES; do
    \\  if [[ -n ${!v+set} ]]; then
    \\    echo "eb-local: loading EESSI-extend set ${v}=${!v}, which would put part of this install outside ${root}; nothing was built." >&2
    \\    echo "  A site Lmod hook or a changed EESSI-extend set it. ${see}" >&2
    \\    exit 2
    \\  fi
    \\done
    \\if [[ -z $root ]]; then
    \\  echo "eb-local: ${from} is empty or not set, so where a ${mode} install goes cannot be checked; nothing was built." >&2
    \\  echo "  The EESSI module that ${init} loads sets it: check that EESSI_CVMFS_REPO and EESSI_VERSION name the EESSI you mean. ${see}" >&2
    \\  exit 2
    \\fi
    \\installpath=${EASYBUILD_INSTALLPATH-}
    \\while [[ $installpath == *//* ]]; do installpath=${installpath//\/\//\/}; done
    \\[[ $installpath == / ]] || installpath=${installpath%/}
    \\root_prefix=${root%/}
    \\if [[ /$installpath/ == */../* || ( $installpath != "$root" && $installpath != "${root_prefix}"/* ) ]]; then
    \\  echo "eb-local: EESSI-extend set the install path to ${installpath:-nothing}, outside ${root}, where a ${mode} install goes; nothing was built." >&2
    \\  echo "  The install variable did not choose it: a site Lmod hook, a changed EESSI-extend, or a character such as - in EESSI_CVMFS_REPO, which EESSI-extend matches as a Lua pattern, did. ${see}" >&2
    \\  exit 2
    \\fi
    \\trap - INT
    \\exec eb "$@"
;

/// `$1` is the umask, `$2` is the mode, and the rest are eb's arguments.
/// EESSI's init is not safe under `nounset`. The compat-layer `ld` goes on
/// `PATH` even when `rustc` is absent: a failing command substitution under
/// `pipefail` would exit before the module loads. `WORKING_DIR` is the
/// caller's: unset, the module's default is `/tmp/$USER`, one per user,
/// where a shared default would leave every other user's build unable to
/// write the first one's directories. Once the module has loaded, eb runs
/// only if EASYBUILD_INSTALLPATH is in the tree the install variable
/// selects and no EASYBUILD_INSTALLPATH_SOFTWARE or _MODULES moves part of
/// the install elsewhere. The Cargo linker lines are `cargo_linker`.
pub const script = script_before ++ cargo_linker ++ script_after;

/// The argument vector that runs eb through EESSI-extend for `sel`: a bash
/// with no profile and no rc file running the launcher script, with the
/// umask and the mode as its first arguments and `eb_args` after them. The
/// caller owns the slice, not the strings in it.
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

    /// A repository whose init sets the trees the EESSI module sets and
    /// defines `module`, which on load sets the hooks, the EasyBuild umask,
    /// the EasyBuild prefix and the install path the real module sets.
    /// FAKE_INSTALLPATH replaces that install path, and FAKE_SETS, NAME=VALUE,
    /// is set after it is chosen, as a site load hook would; FAKE_NO_SITE_PATH
    /// leaves the site tree unset. `eb` prints the process umask and then the
    /// environment.
    fn fake(self: *Run, version: []const u8, eprefix: ?[]const u8) !void {
        var init_text: std.ArrayList(u8) = .empty;
        errdefer init_text.deinit(self.arena.allocator());
        const a = self.arena.allocator();
        try init_text.appendSlice(a,
            \\export EESSI_SOFTWARE_PATH="$EESSI_CVMFS_REPO/versions/2026.06/software/linux/x86_64/amd/zen4"
            \\[ -n "${FAKE_NO_SITE_PATH:-}" ] ||
            \\  export EESSI_SITE_SOFTWARE_PATH="$EESSI_CVMFS_REPO/host_injections/2026.06/software/linux/x86_64/amd/zen4"
            \\module() {
            \\  if [ "$1" = load ]; then
            \\    export EASYBUILD_HOOKS=/eessi/init/easybuild/eb_hooks.py
            \\    export EASYBUILD_RPATH=1
            \\    export EASYBUILD_UMASK=from-the-module
            \\    export EASYBUILD_PREFIX="${WORKING_DIR:-/tmp/$USER}/easybuild"
            \\    if [ -n "${EESSI_CVMFS_INSTALL+set}" ]; then installpath=$EESSI_SOFTWARE_PATH
            \\    elif [ -n "${EESSI_SITE_INSTALL+set}" ]; then installpath=${EESSI_SITE_SOFTWARE_PATH-}
            \\    else installpath="${EESSI_USER_INSTALL:-${EESSI_PROJECT_INSTALL:-$HOME/eessi}}/versions/2026.06/software/linux/x86_64/amd/zen4"
            \\    fi
            \\    export EASYBUILD_INSTALLPATH="${FAKE_INSTALLPATH:-$installpath}"
            \\    [ -z "${FAKE_SETS:-}" ] || export "$FAKE_SETS"
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
                .stderr = try tooMany(a, &self.env),
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

/// The module installs into `$HOME/eessi` by default, though its help text
/// says `$HOME/EESSI`; neither is made.
fn noDefaultPrefix(r: *Run) !void {
    for ([_][]const u8{ "home/eessi", "home/EESSI" }) |rel| {
        const path = try std.fs.path.join(r.arena.allocator(), &.{ r.root, rel });
        try testing.expect(fsx.statAt(fsx.cwd, path, false) == error.NotFound);
    }
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
    try noDefaultPrefix(&r);
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

test "an empty install variable is not a user prefix" {
    const Row = struct {
        variable: []const u8,
        umask: []const u8,
        echoed: bool,
        default_tree: bool,
        keep_module: bool,
    };
    const rows = [_]Row{
        .{ .variable = "EESSI_SITE_INSTALL", .umask = "0022", .echoed = true, .default_tree = false, .keep_module = true },
        .{ .variable = "EESSI_CVMFS_INSTALL", .umask = "0022", .echoed = true, .default_tree = false, .keep_module = false },
        .{ .variable = "EESSI_USER_INSTALL", .umask = "0077", .echoed = true, .default_tree = false, .keep_module = false },
    };
    for (rows) |row| {
        var r = try Run.init();
        defer r.deinit();
        try r.fake("2026.06", null);
        try r.env.put(row.variable, "");
        const out = try r.launch(&.{});
        try ok(out);
        if (row.default_tree) return error.TestUnexpectedResult else try noDefaultPrefix(&r);
        if (!std.mem.eql(u8, row.variable, "EESSI_USER_INSTALL")) {
            try testing.expect(envVar(out.stdout, "EESSI_USER_INSTALL") == null);
        }
        if (row.echoed) {
            try testing.expectEqualStrings("", envVar(out.stdout, row.variable).?);
        } else {
            try testing.expect(envVar(out.stdout, row.variable) == null);
        }
        try testing.expectEqualStrings(row.umask, firstLine(out.stdout));
        if (row.keep_module) try kept(out.stdout);
    }
}

test "an empty site install with a user prefix is refused" {
    var r = try Run.init();
    defer r.deinit();
    try r.fake("2026.06", null);
    try r.env.put("EESSI_SITE_INSTALL", "");
    try r.env.put("EESSI_USER_INSTALL", "/x");
    const out = try r.launch(&.{});
    try testing.expectEqual(@as(u32, 3), out.term.code());
    try noDefaultPrefix(&r);
}

test "two prefixes are refused" {
    var r = try Run.init();
    defer r.deinit();
    try r.fake("2026.06", null);
    try r.env.put("EESSI_USER_INSTALL", "/x");
    try r.env.put("EESSI_PROJECT_INSTALL", "/y");
    const out = try r.launch(&.{});
    try testing.expectEqual(@as(u32, 3), out.term.code());
    try testing.expectEqualStrings("", out.stdout);
    try testing.expect(std.mem.startsWith(u8, out.stderr, "eb-local: EESSI_USER_INSTALL=/x and EESSI_PROJECT_INSTALL=/y are both set; " ++
        "EESSI-extend would make a private user install (umask 077) under /x, not a project install under /y.\n"));
}

test "the refusal of several install variables names each and what EESSI-extend does" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try put(&env, "EESSI_USER_INSTALL", "/home/alice/eessi");
    try put(&env, "EESSI_SITE_INSTALL", "");
    const site = try tooMany(testing.allocator, &env);
    defer testing.allocator.free(site);
    try testing.expectEqualStrings(
        \\eb-local: EESSI_USER_INSTALL=/home/alice/eessi and EESSI_SITE_INSTALL='' are both set; EESSI-extend refuses to load with EESSI_SITE_INSTALL and a user or project install variable.
        \\  Unset the one an earlier session left (a shell startup file, or eval "$(eb-local env)" for another prefix):
        \\  set at most one of EESSI_USER_INSTALL, EESSI_PROJECT_INSTALL, EESSI_SITE_INSTALL, EESSI_CVMFS_INSTALL; with none set, eb-local uses its configured prefix or project
        \\
    , site);

    try put(&env, "EESSI_PROJECT_INSTALL", "/projects/a b");
    try put(&env, "EESSI_CVMFS_INSTALL", "1");
    const all = try tooMany(testing.allocator, &env);
    defer testing.allocator.free(all);
    try testing.expect(std.mem.startsWith(u8, all, "eb-local: EESSI_USER_INSTALL=/home/alice/eessi, EESSI_PROJECT_INSTALL='/projects/a b', " ++
        "EESSI_SITE_INSTALL='' and EESSI_CVMFS_INSTALL=1 are all set; " ++
        "EESSI-extend refuses to load with EESSI_CVMFS_INSTALL and any other install variable.\n"));
}

test "an install path outside the selected tree stops eb" {
    var r = try Run.init();
    defer r.deinit();
    try r.fake("2026.06", null);
    const a = r.arena.allocator();
    const mine = try std.fs.path.join(a, &.{ r.root, "home/mine" });
    try r.env.put("EESSI_USER_INSTALL", mine);
    for ([_][]const u8{ "/elsewhere/software", try std.fmt.allocPrint(a, "{s}/../other/versions", .{mine}), try std.fmt.allocPrint(a, "{s}-old/versions", .{mine}) }) |moved| {
        try r.env.put("FAKE_INSTALLPATH", moved);
        const out = try r.launch(&.{});
        try testing.expectEqual(@as(u32, 2), out.term.code());
        try testing.expectEqualStrings("", out.stdout);
        const said = try std.fmt.allocPrint(a, "eb-local: EESSI-extend set the install path to {s}, outside {s}, where a user install goes; nothing was built.\n" ++
            "  The install variable did not choose it: a site Lmod hook, a changed EESSI-extend, or a character such as - in EESSI_CVMFS_REPO, " ++
            "which EESSI-extend matches as a Lua pattern, did. See \"Where EESSI-extend installs\": https://stackhands.github.io/eb-local/explanation/install-variables.html\n", .{ moved, mine });
        try testing.expectEqualStrings(said, out.stderr);
    }
    try r.env.put("FAKE_INSTALLPATH", mine);
    try ok(try r.launch(&.{}));
}

test "an EasyBuild install path for software or modules alone stops eb" {
    var r = try Run.init();
    defer r.deinit();
    try r.fake("2026.06", null);
    try r.env.put("EASYBUILD_INSTALLPATH_MODULES", "/home/alice/old-modules");
    const out = try r.launch(&.{});
    try testing.expectEqual(@as(u32, 2), out.term.code());
    try testing.expectEqualStrings("", out.stdout);
    const said = try std.fmt.allocPrint(r.arena.allocator(), "eb-local: EASYBUILD_INSTALLPATH_MODULES=/home/alice/old-modules is set in this shell " ++
        "and would put part of this install outside {s}/home/eessi; nothing was built.\n" ++
        "  Unset it: EasyBuild installs software and modules below the install path EESSI-extend sets. " ++
        "See \"Where EESSI-extend installs\": https://stackhands.github.io/eb-local/explanation/install-variables.html\n", .{r.root});
    try testing.expectEqualStrings(said, out.stderr);

    _ = r.env.swapRemove("EASYBUILD_INSTALLPATH_MODULES");
    try r.env.put("FAKE_SETS", "EASYBUILD_INSTALLPATH_SOFTWARE=/home/alice/old-software");
    const hooked = try r.launch(&.{});
    try testing.expectEqual(@as(u32, 2), hooked.term.code());
    try testing.expectEqualStrings("", hooked.stdout);
    const hook_said = try std.fmt.allocPrint(r.arena.allocator(), "eb-local: loading EESSI-extend set EASYBUILD_INSTALLPATH_SOFTWARE=/home/alice/old-software, " ++
        "which would put part of this install outside {s}/home/eessi; nothing was built.\n" ++
        "  A site Lmod hook or a changed EESSI-extend set it. See \"Where EESSI-extend installs\": https://stackhands.github.io/eb-local/explanation/install-variables.html\n", .{r.root});
    try testing.expectEqualStrings(hook_said, hooked.stderr);
}

test "an install variable set as the module loads is reported and does not move the install" {
    var r = try Run.init();
    defer r.deinit();
    try r.fake("2026.06", null);
    try r.env.put("FAKE_SETS", "EESSI_USER_INSTALL=/home/alice/.local/eessi");
    const out = try r.launch(&.{});
    try ok(out);
    const default = try std.fs.path.join(r.arena.allocator(), &.{ r.root, "home/eessi" });
    try testing.expect(std.mem.startsWith(u8, envVar(out.stdout, "EASYBUILD_INSTALLPATH").?, default));
    const said = try std.fmt.allocPrint(r.arena.allocator(), "eb-local: loading EESSI-extend set EESSI_USER_INSTALL=/home/alice/.local/eessi; " ++
        "this install still goes under {s}, but a shell that loads EESSI-extend by hand keeps the change, and its next load installs elsewhere.\n" ++
        "  A site Lmod hook that sets an install variable acts only on the next load. See \"Where EESSI-extend installs\": https://stackhands.github.io/eb-local/explanation/install-variables.html\n", .{default});
    try testing.expectEqualStrings(said, out.stderr);
}

test "a site install with no site tree cannot be checked" {
    var r = try Run.init();
    defer r.deinit();
    try r.fake("2026.06", null);
    try r.env.put("EESSI_SITE_INSTALL", "1");
    try r.env.put("FAKE_NO_SITE_PATH", "1");
    const out = try r.launch(&.{});
    try testing.expectEqual(@as(u32, 2), out.term.code());
    try testing.expect(std.mem.startsWith(u8, out.stderr, "eb-local: EESSI_SITE_SOFTWARE_PATH is empty or not set, so where a site install goes cannot be checked; nothing was built.\n" ++
        "  The EESSI module that "));
    try testing.expect(std.mem.endsWith(u8, out.stderr, "/init/lmod/bash loads sets it: check that EESSI_CVMFS_REPO and EESSI_VERSION name the EESSI you mean. " ++
        "See \"Where EESSI-extend installs\": https://stackhands.github.io/eb-local/explanation/install-variables.html\n"));
}

test "the default user tree is $HOME/eessi as Lmod joins it" {
    var r = try Run.init();
    defer r.deinit();
    try r.fake("2026.06", null);
    const a = r.arena.allocator();
    const home = r.env.get("HOME").?;
    try r.env.put("FAKE_INSTALLPATH", try std.fmt.allocPrint(a, "{s}/eessi/versions/2026.06", .{home}));
    try r.env.put("HOME", try std.fmt.allocPrint(a, "{s}//", .{home}));
    try ok(try r.launch(&.{}));
}

test "a missing version is reported" {
    var r = try Run.init();
    defer r.deinit();
    try r.fake("2026.06", null);
    try r.env.put("EESSI_VERSION", "2025.06");
    const out = try r.launch(&.{});
    try testing.expectEqual(@as(u32, 2), out.term.code());
    const init = try initPath(r.arena.allocator(), &r.env);
    try testing.expect(std.mem.endsWith(u8, init, "/versions/2025.06/init/lmod/bash"));
    const said = try std.fmt.allocPrint(r.arena.allocator(), "eb-local: missing {s}, the EESSI init; eb was not run.\n" ++
        "  Set EESSI_CVMFS_REPO or EESSI_VERSION if EESSI is elsewhere.\n", .{init});
    try testing.expectEqualStrings(said, out.stderr);
}

test "the init path has the script's defaults" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("EESSI_VERSION", "");
    const init = try initPath(testing.allocator, &env);
    defer testing.allocator.free(init);
    try testing.expectEqualStrings("/cvmfs/software.eessi.io/versions/2026.06/init/lmod/bash", init);

    try env.put("EESSI_CVMFS_REPO", "/cvmfs/software.eessi.io///");
    const trimmed = try initPath(testing.allocator, &env);
    defer testing.allocator.free(trimmed);
    try testing.expectEqualStrings("/cvmfs/software.eessi.io/versions/2026.06/init/lmod/bash", trimmed);
    try testing.expect(std.mem.indexOf(u8, script, "repo=${EESSI_CVMFS_REPO:-/cvmfs/software.eessi.io}\n") != null);
    try testing.expect(std.mem.indexOf(u8, script, "ver=${EESSI_VERSION:-2026.06}\n") != null);
    var r = try Run.init();
    defer r.deinit();
    try r.fake("2026.06", null);
    const repo_with_slash = try std.fmt.allocPrint(r.arena.allocator(), "{s}/repo///", .{r.root});
    try r.env.put("EESSI_CVMFS_REPO", repo_with_slash);
    try r.env.put("EESSI_VERSION", "2025.06");
    const out = try r.launch(&.{});
    try testing.expectEqual(@as(u32, 2), out.term.code());
    const expected_init = try initPath(r.arena.allocator(), &r.env);
    const said = try std.fmt.allocPrint(r.arena.allocator(), "eb-local: missing {s}, the EESSI init; eb was not run.\n" ++
        "  Set EESSI_CVMFS_REPO or EESSI_VERSION if EESSI is elsewhere.\n", .{expected_init});
    try testing.expectEqualStrings(said, out.stderr);
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

test "eb includes the cargo linker file once" {
    try std.testing.expect(std.mem.indexOf(u8, script_before, "CARGO_TARGET_") == null);
    try std.testing.expect(std.mem.indexOf(u8, script_after, "CARGO_TARGET_") == null);
    const at = std.mem.indexOf(u8, script, cargo_linker) orelse return error.Missing;
    try std.testing.expect(std.mem.indexOfPos(u8, script, at + cargo_linker.len, cargo_linker) == null);
    try std.testing.expect(std.mem.endsWith(u8, cargo_linker, "fi\n"));
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

test "a trailing or repeated slash in an install variable matches Lmod's normalized path" {
    var r = try Run.init();
    defer r.deinit();
    try r.fake("2026.06", null);
    const a = r.arena.allocator();
    const mine = try std.fs.path.join(a, &.{ r.root, "home/mine" });
    try r.env.put("EESSI_USER_INSTALL", try std.fmt.allocPrint(a, "{s}/", .{mine}));
    try r.env.put("FAKE_INSTALLPATH", try std.fmt.allocPrint(a, "{s}/versions/2026.06/software/linux/x86_64/amd/zen4", .{mine}));
    try ok(try r.launch(&.{}));

    _ = r.env.swapRemove("EESSI_USER_INSTALL");
    const proj = try std.fs.path.join(a, &.{ r.root, "project" });
    try r.env.put("EESSI_PROJECT_INSTALL", try std.fmt.allocPrint(a, "{s}//", .{proj}));
    try r.env.put("FAKE_INSTALLPATH", try std.fmt.allocPrint(a, "{s}/versions/2026.06/software/linux/x86_64/amd/zen4/", .{proj}));
    try ok(try r.launch(&.{}));
}
