//! eb-local: install and build software on top of EESSI into a directory you
//! own. Configuration is layered TOML (see config.zig); secrets come from the
//! environment, owner-only files or nimvault (see secrets.zig).
const std = @import("std");
const linux = std.os.linux;
const build_options = @import("build_options");
const common = @import("zig_common");
const sys = common.sys;
const fsx = common.fsx;
const proc = common.proc;
const cli = common.cli;
/// The part of TOML the configuration files are written in.
pub const toml = @import("toml.zig");
/// The settings in force, and where each came from.
pub const config = @import("config.zig");
/// Where a secret's value comes from, and its removal from the logs.
pub const secrets = @import("secrets.zig");
/// The site file templates `eb-local site` renders.
pub const sites = @import("sites.zig");
/// Where a build may write: the allocation's node-local mount and the prefix.
pub const storage = @import("storage.zig");
/// The RPATH wrappers `dev` writes for compilers without a build environment.
pub const rpath = @import("rpath.zig");
/// `eb-local check`: what a program needs, and where it finds it.
pub const elfcheck = @import("elfcheck.zig");
/// `eb-local eb`: EasyBuild through EESSI-extend, without a site file.
pub const extend = @import("extend.zig");
const Allocator = std.mem.Allocator;

const tool = "eb-local";
/// The version `eb-local --version` prints, and the release it is.
pub const version = "3.1.0";

const usage_text =
    \\eb-local: install and build software on top of EESSI 2026.06, into a
    \\directory you own.
    \\
    \\  eb-local <easyconfig> [eb options]   build and install with EasyBuild
    \\  eb-local --explain <easyconfig> [eb options]
    \\                                       the commands that build runs, as shell lines,
    \\                                       its checks as comments; creates and runs nothing
    \\  eb-local eb [--] [eb options]        load EESSI-extend and run eb; no site file, no Slurm job.
    \\                                       At most one of EESSI_USER_INSTALL, EESSI_PROJECT_INSTALL,
    \\                                       EESSI_SITE_INSTALL, EESSI_CVMFS_INSTALL may be set, and a
    \\                                       present empty value counts as set; with none set, the
    \\                                       module uses $HOME/eessi and nothing is exported.
    \\                                       eb runs only if the module's install path is in the
    \\                                       tree that variable selects
    \\  eb-local --explain eb [--] [eb options]
    \\                                       the script eb runs, with its arguments; runs nothing
    \\  eb-local env                         lines that make your installed modules visible
    \\  eb-local dev [--buildenv MODULE] [MODULE...]
    \\                                       the same, plus MODULEs and a build environment,
    \\                                       so gcc, make, cmake and meson just work;
    \\                                       --buildenv names the build environment to load
    \\  eb-local rpath-wrappers [--for FAMILY | --unwrapped]
    \\                                       lines that put RPATH wrappers for the compilers
    \\                                       on PATH first; dev uses them when no build
    \\                                       environment exists for the loaded compilers.
    \\                                       --unwrapped: only clang, clang++, flang,
    \\                                       flang-new and ld.lld, where no wrapper comes
    \\                                       first; dev adds them after a build environment
    \\  eb-local check FILE...               whether a program or library built here runs here:
    \\                                       its architecture, loader, run paths and libraries
    \\  eb-local submit [--on NAME,...] [--print] <easyconfig> [eb options]
    \\                                       one batch job per node type the site file lists
    \\                                       in build.node_types, each building the recipe for
    \\                                       its CPU target; --print shows the jobs instead.
    \\                                       Deprecated, and removed in 4.0.0: --explain
    \\                                       prints an sbatch line for each node type
    \\  eb-local list [NAME[/VERSION]...]    what you installed, for which CPU targets, and
    \\                                       what this node's target lacks
    \\  eb-local doctor                      what in this shell, node or configuration would
    \\                                       stop a build or a module load; changes nothing
    \\  eb-local clean [--logs-older-than DAYS] [--no-logs] [--sources] [--workspaces]
    \\                 [--dry-run] [--delete]
    \\                                       remove what eb-local left behind; --no-logs
    \\                                       leaves the logs
    \\  eb-local config [--check | --env]    the settings in force and where each came from;
    \\                                       --check also reads every secret (values not shown);
    \\                                       --env prints them as EB_LOCAL_* lines for export
    \\  eb-local profiles                    the profiles the configuration defines
    \\  eb-local uninstall NAME/VERSION... [--dry-run] [--delete]
    \\                                       remove an installation and its module file, for
    \\                                       every CPU target, to the trash with rtrash
    \\  eb-local restore NAME/VERSION... [--dry-run]
    \\                                       bring them back from the trash, read-only again
    \\  eb-local site [list | show NAME | install NAME] [--set KEY=VALUE]... [--to FILE] [--force]
    \\                                       a site file from a template built in, or from a
    \\                                       template file (a NAME with a slash); install
    \\                                       writes config.toml beside this program, mode 644
    \\  eb-local help | --version
    \\
    \\Every command but eb takes --profile NAME, --project DIR (a shared project
    \\directory instead of $HOME/eessi) and --config FILE. Use env and dev with eval:
    \\
    \\  eval "$(eb-local env)"
    \\  eval "$(eb-local dev FFTW/3.3.10-GCC-15.2.0)"
    \\
    \\Configuration: the site file (the first of config.toml beside this program,
    \\/etc/eb-local/config.toml, eb-local.conf beside this program and
    \\/etc/eb-local.conf), then ~/.config/eb-local/config.toml,
    \\then EB_LOCAL_* variables (EB_LOCAL_SECRET_NAME=SOURCE for a secret),
    \\then options. Builds use the allocation's own
    \\node-local mount; a successful build removes its workspace unless
    \\EB_LOCAL_KEEP_WORK=1. Secrets reach eb's environment only, and logs
    \\written during a build are cleaned of them. A build gets every secret,
    \\unless build.secrets or EB_LOCAL_BUILD_SECRETS names the ones it gets.
    \\
    \\--config FILE, or EB_LOCAL_CONFIG=FILE without it, is read in place of the
    \\site file when root or this program's owner owns it, otherwise in place of
    \\your ~/.config/eb-local/config.toml when you own it; the other file is
    \\still read, and only a site file may set the storage settings.
    \\
;

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    cli.die(tool, fmt, args);
}

fn oom() noreturn {
    die("out of memory", .{});
}

fn warn(comptime fmt: []const u8, args: anytype) void {
    cli.err(tool ++ ": " ++ fmt ++ "\n", args);
}

fn say(comptime fmt: []const u8, args: anytype) void {
    cli.out(fmt ++ "\n", args);
}

const Ctx = struct {
    a: Allocator,
    env: *const std.process.Environ.Map,
    envp: proc.Envp,
    cwd: []const u8,
};

// ---- shell output ---------------------------------------------------------

/// A word the shell reads back as exactly `s`: as it is when it holds only
/// safe characters, single-quoted otherwise.
fn shellQuote(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var safe = s.len > 0;
    for (s) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "_./:@%+,=-", ch) != null)) {
            safe = false;
            break;
        }
    }
    if (safe) return s;
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '\'');
    for (s) |ch| {
        if (ch == '\'') try out.appendSlice(a, "'\\''") else try out.append(a, ch);
    }
    try out.append(a, '\'');
    return out.items;
}

fn q(a: Allocator, s: []const u8) []const u8 {
    return shellQuote(a, s) catch oom();
}

fn str(a: Allocator, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(a, f, args) catch oom();
}

const install_vars = [_][]const u8{
    "EESSI_CVMFS_INSTALL",               "EESSI_SITE_INSTALL",            "EESSI_USER_INSTALL",
    "EESSI_PROJECT_INSTALL",             "EESSI_SITE_SOFTWARE_PREFIX",    "EESSI_SOFTWARE_SUBDIR_OVERRIDE",
    "EESSI_ACCELERATOR_TARGET_OVERRIDE", "EESSI_OVERRIDE_GPU_CHECK",      "EASYBUILD_INSTALLPATH",
    "EASYBUILD_INSTALLPATH_SOFTWARE",    "EASYBUILD_INSTALLPATH_MODULES", "EASYBUILD_PREFIX",
};

/// What, left in a shell, sends a later load of EESSI-extend, or eb after
/// it, somewhere else: EESSI-extend sets the other install variables itself.
const leftover_vars = [_][]const u8{
    "EESSI_USER_INSTALL",             "EESSI_PROJECT_INSTALL",         "EESSI_SITE_INSTALL", "EESSI_CVMFS_INSTALL",
    "EASYBUILD_INSTALLPATH_SOFTWARE", "EASYBUILD_INSTALLPATH_MODULES",
};

const Place = struct {
    prefix: []const u8,
    project: bool,
};

/// What `eb-local env` set, if NAME=VALUE is that: its install variable,
/// naming P's prefix, or, when the extension env loads for a prefix that
/// exists is loaded, the install path it chose in the prefix's versions
/// tree, or the EasyBuild prefix it sets beside that path.
fn ownInstallVar(c: Ctx, s: config.Settings, p: Place, name: []const u8, value: []const u8) ?[]const u8 {
    const mine = if (p.project) "EESSI_PROJECT_INSTALL" else "EESSI_USER_INSTALL";
    if (std.mem.eql(u8, name, mine)) {
        return if (std.mem.eql(u8, storage.canonical(c.a, value, c.cwd) catch oom(), p.prefix)) "names your prefix, as eb-local env sets it" else null;
    }
    const is_path = std.mem.eql(u8, name, "EASYBUILD_INSTALLPATH");
    if (!is_path and !std.mem.eql(u8, name, "EASYBUILD_PREFIX")) return null;
    if (!moduleLoaded(c, s.extend_module.value)) return null;
    const installpath = nonEmpty(c.env.get("EASYBUILD_INSTALLPATH")) orelse return null;
    const versions = std.fs.path.join(c.a, &.{ p.prefix, "versions" }) catch oom();
    const path = storage.canonical(c.a, installpath, c.cwd) catch oom();
    if (!storage.under(path, versions) or std.mem.eql(u8, path, versions)) return null;
    return if (is_path) "is in your prefix, as EESSI-extend sets it when eb-local env loads it" else "is EESSI-extend's own, set when eb-local env loads it";
}

/// Whether Lmod lists MODULE, a name or a name and version, as loaded.
fn moduleLoaded(c: Ctx, module: []const u8) bool {
    var it = std.mem.splitScalar(u8, c.env.get("LOADEDMODULES") orelse "", ':');
    while (it.next()) |m| {
        if (std.mem.eql(u8, m, module)) return true;
        if (std.mem.startsWith(u8, m, module) and m.len > module.len and m[module.len] == '/') return true;
    }
    return false;
}

fn environmentLines(c: Ctx, s: config.Settings, p: Place) []const u8 {
    const a = c.a;
    var out: std.ArrayList(u8) = .empty;
    const add = struct {
        fn f(al: Allocator, o: *std.ArrayList(u8), text: []const u8) void {
            o.appendSlice(al, text) catch oom();
        }
    }.f;
    add(a, &out, lmod_init);
    add(a, &out, str(a, "module unload {s} >/dev/null 2>&1 || true\n", .{q(a, s.extend_module.value)}));
    add(a, &out,
        \\unset EESSI_CVMFS_INSTALL EESSI_SITE_INSTALL EESSI_USER_INSTALL EESSI_PROJECT_INSTALL
        \\unset EESSI_SITE_SOFTWARE_PREFIX
        \\unset EESSI_SOFTWARE_SUBDIR_OVERRIDE EESSI_ACCELERATOR_TARGET_OVERRIDE EESSI_OVERRIDE_GPU_CHECK
        \\unset EASYBUILD_INSTALLPATH EASYBUILD_INSTALLPATH_SOFTWARE EASYBUILD_INSTALLPATH_MODULES EASYBUILD_PREFIX
        \\
    );
    add(a, &out, str(a, "export {s}={s}\n", .{ if (p.project) "EESSI_PROJECT_INSTALL" else "EESSI_USER_INSTALL", q(a, p.prefix) }));
    // [eessi] settings before the stack loads: the EESSI module and its
    // hooks read them then.
    for (s.eessi.items) |v| add(a, &out, str(a, "export {s}={s}\n", .{ v.name, q(a, v.value) }));
    // Lmod finds every module of a load before it loads any, and the
    // extension is on MODULEPATH only once the stack is loaded, so each has
    // a load of its own. EESSI-extend refuses an install directory that does
    // not exist; before the first install there are no modules of yours to
    // show, so the stack is loaded alone.
    add(a, &out, str(a, "module load {s}\n", .{q(a, s.stack_module.value)}));
    // Tasks run with the CPU target eessi-arch-guard selects, which can be
    // below the one EESSI detects; where the guard is installed, it moves the
    // stack there before EESSI-extend reads its install path.
    add(a, &out, "if command -v eessi-arch-guard >/dev/null 2>&1; then eval \"$(eessi-arch-guard --shell)\"; fi\n");
    const exists_dir = if (fsx.statAt(fsx.cwd, p.prefix, true)) |st| st.isDir() else |_| false;
    if (exists_dir) add(a, &out, str(a, "module load {s}\n", .{q(a, s.extend_module.value)}));
    // build.site_toolchains under the version the stack set, as a build
    // exports it, so eb run by hand after env or dev accepts them too.
    if (s.site_toolchains.value.len > 0) {
        const json = config.toolchainsJson(a, s.site_toolchains.value) catch oom();
        add(a, &out, str(a,
            \\if [ -n "${{EESSI_VERSION-}}" ]; then
            \\    export "EESSI_SITE_TOP_LEVEL_TOOLCHAINS_$(printf %s "$EESSI_VERSION" | tr . _)="{s}
            \\fi
            \\
        , .{q(a, json)}));
    }
    return out.items;
}

fn nowSecs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

fn isTerminal(fd: sys.fd_t) bool {
    var t: linux.termios = undefined;
    return linux.errno(linux.ioctl(fd, linux.T.CGETS, @intFromPtr(&t))) == .SUCCESS;
}

fn evalHint(words: []const u8) void {
    if (isTerminal(1)) {
        warn("these lines change nothing until the shell runs them:", .{});
        cli.err("  eval \"$(eb-local {s})\"\n", .{words});
    }
}

/// The command that reproduces this environment: the config file, profile,
/// project and (for dev) buildenv that selected it, shell-quoted, options
/// before the command. A hint that drops them tells the reader to eval a
/// different environment.
fn replay(a: Allocator, command: []const u8, s: config.Settings, g: Global, canonical_prefix: []const u8, extra: []const []const u8) []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    if (g.config_file) |p| parts.appendSlice(a, &.{ "--config", q(a, p) }) catch oom();
    if (s.profile) |p| parts.appendSlice(a, &.{ "--profile", q(a, p) }) catch oom();
    if (s.project.value != null) parts.appendSlice(a, &.{ "--project", q(a, canonical_prefix) }) catch oom();
    parts.append(a, command) catch oom();
    if (std.mem.eql(u8, command, "dev")) {
        if (g.buildenv) |p| parts.appendSlice(a, &.{ "--buildenv", q(a, p) }) catch oom();
        for (extra) |m| parts.append(a, q(a, m)) catch oom();
    }
    return std.mem.join(a, " ", parts.items) catch oom();
}

// ---- configuration files --------------------------------------------------

fn selfExe(buf: *[sys.path_max]u8) ?[]const u8 {
    const n = linux.readlinkat(linux.AT.FDCWD, "/proc/self/exe", buf, buf.len);
    if (linux.errno(n) != .SUCCESS or n == 0 or n >= buf.len) return null;
    return buf[0..n];
}

fn selfDir(a: Allocator) []const u8 {
    var buf: [sys.path_max]u8 = undefined;
    const exe = selfExe(&buf) orelse return "/";
    return a.dupe(u8, std.fs.path.dirname(exe) orelse "/") catch oom();
}

/// Set in main from EB_LOCAL_TEST_SELF_OWNER, only in the test artifact,
/// so a test can make this program look installed by another account.
var test_self_owner: ?linux.uid_t = null;

fn selfOwner() linux.uid_t {
    if (comptime build_options.test_ops) {
        if (test_self_owner) |u| return u;
    }
    var buf: [sys.path_max]u8 = undefined;
    const exe = selfExe(&buf) orelse return 0;
    const st = fsx.statAt(fsx.cwd, exe, true) catch return 0;
    return st.uid;
}

const Trust = enum { site, user };

/// Read a configuration file that may steer builds: a regular file, not a
/// symbolic link, not writable by group or others, owned by root or this
/// program's owner (a site file) or by the caller (a user file). A site
/// file the caller owns is refused unless the caller owns the program too:
/// only the site file sets the storage settings and build.site_toolchains.
/// A file that fails is an error, never skipped.
fn readTrusted(c: Ctx, path: []const u8, kind: Trust) []const u8 {
    const opened = openConfig(path);
    defer sys.close(opened.fd);
    const uid = opened.stat.uid;
    switch (kind) {
        .site => {
            const owner = selfOwner();
            if (uid != 0 and uid != owner)
                die("{s} is owned by uid {d} and is not used: a site file belongs to root or to this program's owner (uid {d})", .{ path, uid, owner });
        },
        .user => if (uid != linux.getuid())
            die("{s} is owned by uid {d} and is not used: your configuration file belongs to you (uid {d})", .{ path, uid, linux.getuid() }),
    }
    return fsx.readAll(c.a, opened.fd, 1 << 20) catch |e| die("cannot read {s} ({s})", .{ path, @errorName(e) });
}

const Opened = struct { fd: sys.fd_t, stat: fsx.Stat };

/// A configuration file: a regular file, not a symbolic link, not writable
/// by group or others. A file that fails is an error, never skipped.
fn openConfig(path: []const u8) Opened {
    const lst = fsx.statAt(fsx.cwd, path, false) catch |e| die("cannot open {s} ({s})", .{ path, @errorName(e) });
    if (lst.isLink()) die("{s} is a symbolic link; a configuration file must be a regular file", .{path});
    const opened = fsx.openRegular(fsx.cwd, path, false) catch |e| die("cannot open {s} ({s})", .{ path, @errorName(e) });
    if (opened.stat.mode & 0o022 != 0) die("{s} is writable by group or others and is not used; chmod go-w it", .{path});
    return .{ .fd = opened.fd, .stat = opened.stat };
}

/// The layer a file named with --config or EB_LOCAL_CONFIG belongs to: a
/// site file when root or this program's owner owns it, a user file when
/// the caller does. Only a site file may set [storage], so a user cannot
/// point builds at a shared file system by naming a file of their own.
fn explicitTrust(path: []const u8) Trust {
    const opened = openConfig(path);
    defer sys.close(opened.fd);
    const uid = opened.stat.uid;
    if (uid == 0 or uid == selfOwner()) return .site;
    if (uid == linux.getuid()) return .user;
    die("{s} is owned by uid {d} and is not used", .{ path, uid });
}

fn exists(path: []const u8) bool {
    _ = fsx.statAt(fsx.cwd, path, false) catch return false;
    return true;
}

fn sourceFrom(c: Ctx, path: []const u8, kind: Trust) config.Source {
    const raw = readTrusted(c, path, kind);
    const layer: config.Layer = if (kind == .site) .site else .user;
    if (std.mem.endsWith(u8, path, ".toml")) return .{ .path = path, .text = raw, .layer = layer };
    var d: config.Diagnostic = .{};
    const text = config.legacyToToml(c.a, raw, &d) catch |e| switch (e) {
        error.Invalid => die("{s}: {s}", .{ path, d.message }),
        error.OutOfMemory => oom(),
    };
    return .{ .path = path, .text = text, .layer = layer };
}

const Global = struct {
    profile: ?[]const u8 = null,
    project: ?[]const u8 = null,
    config_file: ?[]const u8 = null,
    buildenv: ?[]const u8 = null,
    /// Print what a build would run, as shell commands, and run nothing.
    explain: bool = false,
};

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const x = v orelse return null;
    return if (x.len > 0) x else null;
}

/// The configuration files in force, site first.
fn configSources(c: Ctx, g: Global) []const config.Source {
    var sources: std.ArrayList(config.Source) = .empty;
    const explicit = g.config_file orelse nonEmpty(c.env.get("EB_LOCAL_CONFIG"));
    const explicit_trust: ?Trust = if (explicit) |path| blk: {
        if (!exists(path)) die("the configuration file {s} does not exist", .{path});
        break :blk explicitTrust(path);
    } else null;
    // The site file: a named one the site owns replaces the installed one.
    if (explicit_trust == .site) {
        sources.append(c.a, sourceFrom(c, explicit.?, .site)) catch oom();
    } else {
        const dir = selfDir(c.a);
        const candidates = [_][]const u8{
            std.fs.path.join(c.a, &.{ dir, "config.toml" }) catch oom(),
            "/etc/eb-local/config.toml",
            std.fs.path.join(c.a, &.{ dir, "eb-local.conf" }) catch oom(),
            "/etc/eb-local.conf",
        };
        for (candidates) |p| if (exists(p)) {
            sources.append(c.a, sourceFrom(c, p, .site)) catch oom();
            break;
        };
    }
    // The user file: a named one the caller owns replaces the usual one.
    if (explicit_trust == .user) {
        sources.append(c.a, sourceFrom(c, explicit.?, .user)) catch oom();
    } else {
        const user_file: ?[]const u8 = if (nonEmpty(c.env.get("XDG_CONFIG_HOME"))) |x|
            std.fs.path.join(c.a, &.{ x, "eb-local", "config.toml" }) catch oom()
        else if (nonEmpty(c.env.get("HOME"))) |h|
            std.fs.path.join(c.a, &.{ h, ".config", "eb-local", "config.toml" }) catch oom()
        else
            null;
        if (user_file) |p| if (exists(p)) sources.append(c.a, sourceFrom(c, p, .user)) catch oom();
    }
    return sources.items;
}

fn loadSettings(c: Ctx, g: Global) config.Settings {
    var d: config.Diagnostic = .{};
    return config.load(c.a, configSources(c, g), c.env, .{ .profile = g.profile, .project = g.project, .buildenv = g.buildenv }, &d) catch |e| switch (e) {
        error.Invalid => die("{s}", .{d.message}),
        error.OutOfMemory => oom(),
    };
}

/// The installation directory, absolute even before it exists. A project
/// directory that cannot be used stops eb-local.
fn place(c: Ctx, s: config.Settings) Place {
    if (s.project.value) |p| if (!projectUsable(c, p)) std.process.exit(2);
    return locate(c, s);
}

/// Whether the project directory p can be used; what is wrong with it goes
/// to stderr.
fn projectUsable(c: Ctx, p: []const u8) bool {
    const st = fsx.statAt(fsx.cwd, p, true) catch {
        warn("project directory {s} does not exist.", .{p});
        cli.err("  The project owner creates it once, with the project group and g+s:\n", .{});
        const qp = q(c.a, p);
        cli.err("  mkdir -p {s} && chgrp <group> {s} && chmod 2770 {s}\n", .{ qp, qp, qp });
        return false;
    };
    if (!st.isDir()) {
        warn("project directory {s} is not a directory", .{p});
        return false;
    }
    // Anyone could then put module files there that the group loads.
    if (st.mode & 0o002 != 0) {
        warn("project directory {s} is writable by others and is not used; chmod o-w it", .{p});
        return false;
    }
    // Without it, each member's installs carry that member's own group.
    if (st.mode & 0o2000 == 0) warn("project directory {s} has no setgid bit, so installs keep the installer's group; chmod g+s it", .{p});
    return true;
}

/// The installation directory place gives, without checking a project
/// directory.
fn locate(c: Ctx, s: config.Settings) Place {
    if (s.project.value) |p| return .{ .prefix = storage.canonical(c.a, p, c.cwd) catch oom(), .project = true };
    var raw = s.prefix.value;
    if (std.mem.startsWith(u8, raw, "~/") or std.mem.eql(u8, raw, "~")) {
        const home = nonEmpty(c.env.get("HOME")) orelse die("prefix {s} needs HOME", .{raw});
        raw = std.mem.concat(c.a, u8, &.{ home, raw[1..] }) catch oom();
        if (std.mem.eql(u8, s.prefix.from, "default")) {
            if (legacyPrefix(c, home, raw)) |old| return .{ .prefix = old, .project = false };
        }
    }
    return .{ .prefix = storage.canonical(c.a, raw, c.cwd) catch oom(), .project = false };
}

/// eb-local 2.x installed into ~/.local/eessi by default. Where
/// that tree exists and the new default does not, it stays in use, so
/// installed modules do not disappear; set `prefix` to choose for good.
fn legacyPrefix(c: Ctx, home: []const u8, default_prefix: []const u8) ?[]const u8 {
    const isDir = struct {
        fn f(path: []const u8) bool {
            return if (fsx.statAt(fsx.cwd, path, true)) |st| st.isDir() else |_| false;
        }
    }.f;
    if (isDir(default_prefix)) return null;
    const old = std.fs.path.join(c.a, &.{ home, ".local", "eessi" }) catch oom();
    if (!isDir(old)) return null;
    warn("using {s}, the default before eb-local 3.0; EESSI-extend and `eb-local eb` use {s}.", .{ old, default_prefix });
    cli.err("  Keep it with prefix = \"~/.local/eessi\" in ~/.config/eb-local/config.toml, or move it to {s}.\n", .{default_prefix});
    return storage.canonical(c.a, old, c.cwd) catch oom();
}

// ---- env, dev, config, profiles -------------------------------------------

fn cmdEnv(c: Ctx, s: config.Settings, g: Global) u8 {
    const p = place(c, s);
    evalHint(replay(c.a, "env", s, g, p.prefix, &.{}));
    cli.put(1, environmentLines(c, s, p));
    return 0;
}

fn cmdDev(c: Ctx, s: config.Settings, g: Global, extra: []const []const u8) u8 {
    const a = c.a;
    // A module is loaded once, where it is first named; a chosen build
    // environment only last. Left at the default, the build environment that
    // comes last depends on the compilers, so one named here stays.
    const chosen = !std.mem.eql(u8, s.dev_buildenv.from, "default");
    var mods: std.ArrayList([]const u8) = .empty;
    for ([_][]const []const u8{ s.dev_modules.value, extra }) |names| for (names) |m| {
        if (chosen and std.mem.eql(u8, m, s.dev_buildenv.value)) continue;
        for (mods.items) |seen| {
            if (std.mem.eql(u8, seen, m)) break;
        } else mods.append(a, m) catch oom();
    };
    const installed = place(c, s);
    evalHint(replay(a, "dev", s, g, installed.prefix, extra));
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, environmentLines(c, s, installed)) catch oom();
    // The modules the program uses first, the build environment last, so
    // its wrappers come first on PATH. When the program links, they record
    // a run path for each directory on LIBRARY_PATH, which the modules set
    // in either order, so the program runs without LD_LIBRARY_PATH.
    if (mods.items.len > 0) {
        out.appendSlice(a, "module load") catch oom();
        for (mods.items) |m| out.appendSlice(a, str(a, " {s}", .{q(a, m)})) catch oom();
        out.append(a, '\n') catch oom();
    }
    // A previous dev may have put RPATH wrappers first on PATH. Drop that
    // directory before this dev chooses again, or a later build environment
    // stays hidden behind the wrappers.
    out.appendSlice(a, drop_rpath_wrappers) catch oom();
    out.appendSlice(a, buildenvLines(c, s)) catch oom();
    // A program linked here belongs to this shell's CPU (and GPU) target, so
    // its install directory names them; the shell fills them in once EESSI
    // has picked them.
    const dev_root = std.fs.path.join(a, &.{ installed.prefix, "dev" }) catch oom();
    out.appendSlice(a, str(a, "export EB_LOCAL_DEV_PREFIX={s}\"/$EESSI_VERSION/$EESSI_SOFTWARE_SUBDIR${{EESSI_ACCELERATOR_TARGET:+/$EESSI_ACCELERATOR_TARGET}}\"\n", .{q(a, dev_root)})) catch oom();
    cli.put(1, out.items);
    if (nonEmpty(c.env.get("LD_LIBRARY_PATH")) != null) {
        warn("LD_LIBRARY_PATH is set in this shell; programs built here do not need it,", .{});
        cli.err("  and it can mix host libraries into EESSI's. Unset it unless you know you need it.\n", .{});
    }
    // Only the GCC build environment is known to lack LLVM wrappers; a site's
    // own buildenv may wrap clang under any name.
    // With the default, buildenvLines picks the build environment for the
    // compilers; a chosen GCC one is loaded as it is, so say what it misses.
    if (!std.mem.eql(u8, s.dev_buildenv.from, "default") and gccBuildenv(s.dev_buildenv.value)) {
        for (mods.items) |m| if (llvmToolchain(m)) |tc| {
            warn("{s} belongs to the {s} toolchain, but {s} wraps only the GCC compilers;", .{ m, tc, s.dev_buildenv.value });
            cli.err("  clang and flang get no run paths for its libraries. Name an lfoss build environment with --buildenv.\n", .{});
            break;
        };
    }
    return 0;
}

/// A build environment of the GCC toolchains, as EasyBuild names them.
fn gccBuildenv(module: []const u8) bool {
    if (llvmToolchain(module) != null) return false;
    for ([_][]const u8{ "-foss-", "-gompi-", "-gfbf-", "-GCC-", "-GCCcore-" }) |tc| {
        if (std.mem.indexOf(u8, module, tc) != null or std.mem.endsWith(u8, module, tc[0 .. tc.len - 1])) return true;
    }
    return false;
}

/// The LLVM toolchain of the lfoss hierarchy a module name belongs to, as
/// EasyBuild names it in the module's version suffix, if any.
fn llvmToolchain(module: []const u8) ?[]const u8 {
    for ([_][]const u8{ "llvm-compilers", "lompi", "lfbf", "lfoss", "lmpflf" }) |tc| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, module, from, tc)) |at| {
            const end = at + tc.len;
            const before_ok = at == 0 or module[at - 1] == '/' or module[at - 1] == '-';
            const after_ok = end == module.len or module[end] == '/' or module[end] == '-';
            if (before_ok and after_ok) return tc;
            from = at + 1;
        }
    }
    return null;
}

test "llvmToolchain names the lfoss hierarchy and nothing else" {
    try std.testing.expectEqualStrings("lfoss", llvmToolchain("ScaLAPACK/2.2.2-lfoss-2026.1-fb").?);
    try std.testing.expectEqualStrings("lompi", llvmToolchain("FFTW.MPI/3.3.10-lompi-2026.1").?);
    try std.testing.expectEqualStrings("llvm-compilers", llvmToolchain("llvm-compilers/21.1.8").?);
    try std.testing.expectEqualStrings("lfbf", llvmToolchain("lfbf/2026.1").?);
    try std.testing.expect(llvmToolchain("FFTW/3.3.10-GCC-15.2.0") == null);
    try std.testing.expect(llvmToolchain("buildenv/default-foss-2026.1") == null);
    try std.testing.expect(llvmToolchain("Xlfossy/1.0") == null);
    try std.testing.expectEqualStrings("lmpflf", llvmToolchain("X/1.0-lmpflf-2026.1").?);
}

test "gccBuildenv names the GCC build environments only" {
    try std.testing.expect(gccBuildenv("buildenv/default-foss-2026.1"));
    try std.testing.expect(gccBuildenv("buildenv/default-foss-2026.1-CUDA-13.3.0"));
    try std.testing.expect(gccBuildenv("buildenv/default-GCC-15.2.0"));
    try std.testing.expect(!gccBuildenv("buildenv/default-lfoss-2026.1"));
    try std.testing.expect(!gccBuildenv("buildenv/site-llvm"));
    try std.testing.expect(!gccBuildenv("buildenv/default-intel-2026.1"));
}

/// Remove the wrapper directory a previous `dev` prepended. The new dev
/// adds its own afterwards when it still needs wrappers.
const drop_rpath_wrappers =
    \\if [ -n "${EB_LOCAL_RPATH_WRAPPERS-}" ]; then
    \\    _eb_local_path=
    \\    _eb_local_rest=$PATH
    \\    while [ -n "$_eb_local_rest" ]; do
    \\        case $_eb_local_rest in
    \\            *:*) _eb_local_ent=${_eb_local_rest%%:*}; _eb_local_rest=${_eb_local_rest#*:} ;;
    \\            *) _eb_local_ent=$_eb_local_rest; _eb_local_rest= ;;
    \\        esac
    \\        if [ "$_eb_local_ent" != "$EB_LOCAL_RPATH_WRAPPERS" ]; then
    \\            _eb_local_path=${_eb_local_path:+$_eb_local_path:}$_eb_local_ent
    \\        fi
    \\    done
    \\    PATH=$_eb_local_path
    \\    export PATH
    \\    unset EB_LOCAL_RPATH_WRAPPERS _eb_local_path _eb_local_rest _eb_local_ent
    \\fi
    \\
;

/// The lines that load the build environment. A dev.buildenv the caller
/// chose is loaded as it is. The default depends on the compilers the
/// modules brought in, which only the shell knows after it loads them: the
/// family's buildenv when Lmod has it, else the GCC one for CUDA (nvcc
/// links through gcc), else eb-local's RPATH wrappers, so nothing links
/// without run paths. Whichever loads, a clang that no wrapper covers then
/// gets one: the LLVM module sets EBROOTLLVM, not llvm-compilers' variable,
/// so its clang comes with the GCC build environment, which does not wrap it.
fn buildenvLines(c: Ctx, s: config.Settings) []const u8 {
    const a = c.a;
    const gcc = q(a, s.dev_buildenv.value);
    var exe_buf: [sys.path_max]u8 = undefined;
    const exe = q(a, selfExe(&exe_buf) orelse tool);
    const unwrapped = str(a, "eval \"$({s} rpath-wrappers --unwrapped)\"\n", .{exe});
    if (!std.mem.eql(u8, s.dev_buildenv.from, "default")) return str(a, "module load {s}\n{s}", .{ gcc, unwrapped });
    var out: std.ArrayList(u8) = .empty;
    const add = struct {
        fn f(al: Allocator, o: *std.ArrayList(u8), text: []const u8) void {
            o.appendSlice(al, text) catch oom();
        }
    }.f;
    add(a, &out, "eb_local_family=gcc\n");
    for (config.families) |f|
        add(a, &out, str(a, "if [ -n \"${{{s}-}}\" ]; then eb_local_family={s}; fi\n", .{ f.ebroot, f.name }));
    add(a, &out, "case $eb_local_family in\n");
    for (config.families, s.buildenv_for) |f, b|
        add(a, &out, str(a, "    {s}) eb_local_buildenv={s} ;;\n", .{ f.name, if (b.value.len == 0) "''" else q(a, b.value) }));
    add(a, &out, "    *) eb_local_buildenv= ;;\nesac\n");
    add(a, &out, str(a,
        \\if [ "$eb_local_family" = gcc ]; then
        \\    module load {s}
        \\elif [ -n "$eb_local_buildenv" ] && module is-avail "$eb_local_buildenv" >/dev/null 2>&1; then
        \\    module load "$eb_local_buildenv"
        \\elif [ "$eb_local_family" = cuda ]; then
        \\    module load {s}
        \\else
        \\    eval "$({s} rpath-wrappers --for "$eb_local_family")"
        \\fi
        \\unset eb_local_family eb_local_buildenv
        \\
    , .{ gcc, gcc, exe }));
    add(a, &out, unwrapped);
    return out.items;
}

/// With `only_unwrapped`, the wrappers are for the compilers that find
/// their linker themselves, where no wrapper of eb-local's or of a build
/// environment's comes first on PATH, and none at all is fine.
fn cmdRpathWrappers(c: Ctx, family: []const u8, only_unwrapped: bool) u8 {
    const a = c.a;
    const path = c.env.get("PATH") orelse "";
    const found = (if (only_unwrapped) rpath.unwrapped(a, path, &rpath.self_linking) else rpath.present(a, path)) catch oom();
    if (found.len == 0) {
        if (only_unwrapped) return 0;
        warn("no compiler or linker on PATH to wrap", .{});
        return 1;
    }
    const dir = rpath.directory(a, c.env, found) catch |e| switch (e) {
        error.NoCacheDir => die("rpath-wrappers needs an absolute XDG_CACHE_HOME or HOME", .{}),
        else => die("cannot work out the wrapper directory ({s})", .{@errorName(e)}),
    };
    rpath.write(a, dir, found) catch |e| die("cannot write RPATH wrappers in {s} ({s})", .{ dir, @errorName(e) });
    const names = std.mem.join(a, " ", found) catch oom();
    if (only_unwrapped) {
        warn("the build environment does not wrap {s};", .{names});
        cli.err("  RPATH wrappers for it come first ({s}), so what it links has run paths.\n", .{dir});
    } else if (family.len > 0) {
        warn("no build environment module for the {s} compilers is available;", .{family});
        cli.err("  RPATH wrappers for {s} stand in for it ({s}).\n", .{ names, dir });
    }
    cli.put(1, str(a, "export PATH={s}:\"$PATH\"\nexport EB_LOCAL_RPATH_WRAPPERS={s}\n", .{ q(a, dir), q(a, dir) }));
    return 0;
}

// ---- check ----------------------------------------------------------------

const Check = struct {
    problems: usize = 0,

    fn problem(k: *Check, comptime fmt: []const u8, args: anytype) void {
        say("  problem: " ++ fmt, args);
        k.problems += 1;
    }
};

/// Where the loader looks for a library named without a slash, in its order.
const Search = struct {
    dirs: std.ArrayList([]const u8) = .empty,
    /// Which list each directory came from, for the report.
    whence: std.ArrayList([]const u8) = .empty,

    const Hit = struct { path: []const u8, why: []const u8 };

    /// The first directory holding `name`, skipping LD_LIBRARY_PATH unless
    /// `env` is set.
    fn find(sr: Search, a: Allocator, name: []const u8, env: bool) ?Hit {
        for (sr.dirs.items, sr.whence.items) |d, why| {
            if (!env and std.mem.eql(u8, why, "LD_LIBRARY_PATH")) continue;
            const p = std.fs.path.join(a, &.{ d, name }) catch oom();
            if (isFile(p)) return .{ .path = p, .why = why };
        }
        return null;
    }

    fn add(sr: *Search, a: Allocator, list: ?[]const u8, origin: []const u8, why: []const u8) void {
        var it = std.mem.splitScalar(u8, list orelse return, ':');
        while (it.next()) |d| if (d.len > 0) {
            sr.dirs.append(a, elfcheck.expandOrigin(a, d, origin) catch oom()) catch oom();
            sr.whence.append(a, why) catch oom();
        };
    }
};

fn isFile(path: []const u8) bool {
    const st = fsx.statAt(fsx.cwd, path, true) catch return false;
    return st.isReg();
}

/// The directories the loader under `root` searches last: those its
/// ld.so.conf names, one level of `include DIR/*.conf` deep, then its
/// built-in ones. The loader reads a cache built from the same list.
fn loaderDirs(a: Allocator, root: []const u8) []const []const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    var includes: std.ArrayList([]const u8) = .empty;
    const conf = std.fs.path.join(a, &.{ root, "etc/ld.so.conf" }) catch oom();
    if (readSmall(a, conf)) |text| elfcheck.parseLdSoConf(a, text, &dirs, &includes) catch oom();
    for (includes.items) |pat| {
        // Only the DIR/*.SUFFIX form; anything else is skipped.
        const slash = std.mem.lastIndexOfScalar(u8, pat, '/') orelse continue;
        const base = pat[slash + 1 ..];
        if (!std.mem.startsWith(u8, base, "*") or std.mem.indexOfAny(u8, base[1..], "*?[") != null) continue;
        const dir = if (slash == 0) "/" else pat[0..slash];
        const fd = fsx.openDir(fsx.cwd, dir, true) catch continue;
        defer sys.close(fd);
        var names: std.ArrayList([]const u8) = .empty;
        var it = fsx.DirIter.init(a, fd) catch oom();
        while (it.next() catch null) |e| if (std.mem.endsWith(u8, e.name, base[1..]))
            names.append(a, a.dupe(u8, e.name) catch oom()) catch oom();
        std.mem.sort([]const u8, names.items, {}, lessThanStr);
        var none: std.ArrayList([]const u8) = .empty;
        for (names.items) |n| {
            const p = std.fs.path.join(a, &.{ dir, n }) catch oom();
            if (readSmall(a, p)) |text| elfcheck.parseLdSoConf(a, text, &dirs, &none) catch oom();
        }
    }
    for ([_][]const u8{ "lib64", "usr/lib64", "lib", "usr/lib" }) |sub|
        dirs.append(a, std.fs.path.join(a, &.{ root, sub }) catch oom()) catch oom();
    return dirs.items;
}

fn lessThanStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn readSmall(a: Allocator, path: []const u8) ?[]const u8 {
    const f = fsx.openRegular(fsx.cwd, path, true) catch return null;
    defer sys.close(f.fd);
    return fsx.readAll(a, f.fd, 64 * 1024) catch null;
}

fn cmdCheck(c: Ctx, files: []const []const u8) u8 {
    const a = c.a;
    if (files.len == 0) die("check needs one or more programs or libraries", .{});
    const target = nonEmpty(c.env.get("EESSI_SOFTWARE_SUBDIR"));
    const eprefix = nonEmpty(c.env.get("EESSI_EPREFIX"));
    var k: Check = .{};
    var unreadable = false;
    for (files) |f| {
        const opened = fsx.openRegular(fsx.cwd, f, true) catch |e| {
            warn("cannot open {s} ({s})", .{ f, @errorName(e) });
            unreadable = true;
            continue;
        };
        defer sys.close(opened.fd);
        const elf = elfcheck.parse(a, opened.fd) catch |e| {
            switch (e) {
                error.NotElf64, error.Unsupported => warn("{s} is not a 64-bit little-endian ELF file", .{f}),
                else => warn("cannot read {s} as ELF ({s})", .{ f, @errorName(e) }),
            }
            unreadable = true;
            continue;
        };
        say("{s}: {s}", .{ f, elfcheck.machineName(elf.machine) });
        if (elf.machine != elfcheck.hostMachine())
            k.problem("built for {s}; this node is {s}", .{ elfcheck.machineName(elf.machine), elfcheck.machineName(elfcheck.hostMachine()) });
        var buf: [sys.path_max]u8 = undefined;
        const real = fsx.realpath(fsx.cwd, f, &buf) catch f;
        const origin = a.dupe(u8, std.fs.path.dirname(real) orelse "/") catch oom();
        if (elf.interp) |interp| {
            say("  loader   {s}", .{interp});
            if (eprefix) |ep| if (!storage.under(interp, ep))
                k.problem("the loader is the host's, not the compatibility layer's under {s}", .{ep});
        }
        if (elf.rpath) |r| say("  RPATH    {s}", .{r});
        if (elf.runpath) |r| {
            say("  RUNPATH  {s}", .{r});
            k.problem("RUNPATH, which LD_LIBRARY_PATH overrides and the libraries' own dependencies ignore; link with --disable-new-dtags for RPATH", .{});
        }
        if (elf.interp == null and elf.needed.len == 0) {
            say("  static: no loader and no libraries", .{});
            continue;
        }

        var sr: Search = .{};
        if (elf.runpath == null) sr.add(a, elf.rpath, origin, "RPATH");
        sr.add(a, c.env.get("LD_LIBRARY_PATH"), origin, "LD_LIBRARY_PATH");
        sr.add(a, elf.runpath, origin, "RUNPATH");
        // The loader's own directories: <root>/lib64 and the rest, where
        // <root> is the compatibility layer for its loader, / for the host's.
        const root = if (elf.interp) |i| (std.fs.path.dirname(std.fs.path.dirname(i) orelse "/") orelse "/") else "/";
        for (loaderDirs(a, root)) |d| {
            sr.dirs.append(a, d) catch oom();
            sr.whence.append(a, "the loader's directories") catch oom();
        }

        var seen_targets: std.ArrayList([]const u8) = .empty;
        for (sr.dirs.items, sr.whence.items) |d, why| {
            if (std.mem.eql(u8, why, "the loader's directories")) continue;
            const t = elfcheck.targetOf(d) orelse continue;
            const want = target orelse continue;
            if (std.mem.eql(u8, t, want)) continue;
            for (seen_targets.items) |s0| {
                if (std.mem.eql(u8, s0, t)) break;
            } else {
                seen_targets.append(a, t) catch oom();
                k.problem("run paths into the {s} software tree; this shell is {s}: build it again on this node type", .{ t, want });
            }
        }

        for (elf.needed) |n| {
            if (std.mem.indexOfScalar(u8, n, '/') != null) {
                say("  needs    {s}", .{n});
                if (!isFile(n)) k.problem("{s} does not exist", .{n});
                continue;
            }
            // The job may run without this shell's LD_LIBRARY_PATH, so the
            // pick without it is the one that counts.
            const clean = sr.find(a, n, false);
            const with = sr.find(a, n, true);
            const h = clean orelse {
                if (with) |w| {
                    say("  needs    {s} => {s}   [LD_LIBRARY_PATH]", .{ n, w.path });
                    k.problem("{s} is found only through LD_LIBRARY_PATH", .{n});
                } else {
                    say("  needs    {s} => not found", .{n});
                    k.problem("{s} is not found", .{n});
                }
                continue;
            };
            say("  needs    {s} => {s}   [{s}]", .{ n, h.path, h.why });
            if (with) |w| if (!std.mem.eql(u8, w.path, h.path))
                say("           LD_LIBRARY_PATH in this shell picks {s} instead", .{w.path});
            if (eprefix != null and elfcheck.isHostPath(h.path))
                k.problem("{s} comes from the host, not from EESSI", .{n});
        }
    }
    if (k.problems > 0) {
        say("eb-local check: {d} problem(s)", .{k.problems});
        return 1;
    }
    if (unreadable) return 2;
    say("eb-local check: no problems", .{});
    return 0;
}

fn cmdConfig(c: Ctx, s: config.Settings, check: bool) u8 {
    const a = c.a;
    const p = locate(c, s);
    const row = struct {
        fn f(key: []const u8, value: []const u8, from: []const u8) void {
            say("{s: <28} {s}   [{s}]", .{ key, value, from });
        }
    }.f;
    say("{s: <28} {s}", .{ "profile", s.profile orelse "(none)" });
    if (p.project) row("project", p.prefix, s.project.from) else row("prefix", p.prefix, s.prefix.from);
    row("stack.module", s.stack_module.value, s.stack_module.from);
    row("stack.extend", s.extend_module.value, s.extend_module.from);
    row("dev.buildenv", s.dev_buildenv.value, s.dev_buildenv.from);
    for (config.families, s.buildenv_for) |f, b|
        row(str(a, "dev.buildenv_for.{s}", .{f.name}), if (b.value.len == 0) "(none: RPATH wrappers)" else b.value, b.from);
    const mods = std.mem.join(a, " ", s.dev_modules.value) catch oom();
    row("dev.modules", if (mods.len == 0) "(none)" else mods, s.dev_modules.from);
    row("build.allocation_hint", if (s.allocation_hint.value.len == 0) "(none)" else s.allocation_hint.value, s.allocation_hint.from);
    const tcs = std.mem.join(a, " ", s.site_toolchains.value) catch oom();
    row("build.site_toolchains", if (tcs.len == 0) "(none)" else tcs, s.site_toolchains.from);
    const types = nodeTypes(s);
    if (types.len == 0) row("build.node_types", "(none)", s.node_types.from);
    for (types) |t| row(str(a, "build.node_types.{s}", .{t.name}), t.sbatch, t.from);
    if (s.build_secrets.value) |names| {
        row("build.secrets", if (names.len == 0) "(none)" else std.mem.join(a, " ", names) catch oom(), s.build_secrets.from);
    } else row("build.secrets", "(every secret)", s.build_secrets.from);
    row("clean.trash", @tagName(s.trash.value), s.trash.from);
    row("clean.logs_older_than_days", str(a, "{d}", .{s.logs_older_than_days.value}), s.logs_older_than_days.from);
    row("nimvault.program", if (s.nimvault_program.value.len == 0) "(nimvault on PATH)" else s.nimvault_program.value, s.nimvault_program.from);
    row("nimvault.vault", if (s.nimvault_vault.value.len == 0) "(nimvault finds it)" else s.nimvault_vault.value, s.nimvault_vault.from);
    row("storage.node_local_root", if (s.node_local_root.value.len == 0) "(not set)" else s.node_local_root.value, s.node_local_root.from);
    row("storage.node_local_mount", s.node_local_mount.value, s.node_local_mount.from);
    row("storage.node_local_fstype", s.node_local_fstype.value, s.node_local_fstype.from);
    const scratch = std.mem.join(a, " ", s.shared_scratch.value) catch oom();
    row("storage.shared_scratch", if (scratch.len == 0) "(none)" else scratch, s.shared_scratch.from);
    if (s.eessi.items.len == 0) {
        say("{s: <28} (none)", .{"eessi"});
    } else for (s.eessi.items) |v| row(str(a, "eessi.{s}", .{v.name}), q(a, v.value), v.from);
    var failed = false;
    if (s.secrets.items.len == 0) say("{s: <28} (none)", .{"secrets"}) else say("secrets (values are never shown)", .{});
    for (s.secrets.items) |sec| {
        if (!check) {
            say("  {s: <26} {s}   [{s}]", .{ sec.name, sec.source, sec.from });
            continue;
        }
        var f: secrets.Failure = .{};
        if (secrets.resolve(a, &.{sec}, c.env, c.envp, nimvaultOf(s), &f)) |_| {
            say("  {s: <26} {s}   ok", .{ sec.name, sec.source });
        } else |e| switch (e) {
            error.Unavailable => {
                say("  {s: <26} {s}   FAILED: {s}", .{ sec.name, sec.source, f.message });
                failed = true;
            },
            error.OutOfMemory => oom(),
        }
    }
    // Every other command stops on a project directory it cannot use; config
    // shows the settings first, so the profile that names it can be read.
    if (s.project.value) |dir| {
        if (!projectUsable(c, dir) and check) failed = true;
    }
    return if (failed) 1 else 0;
}

fn nimvaultOf(s: config.Settings) secrets.Nimvault {
    return .{ .program = s.nimvault_program.value, .vault = s.nimvault_vault.value };
}

/// The settings in force as EB_LOCAL_* lines, empty ones included, so the
/// same configuration can travel in the environment of a job, a container or
/// CI. Storage and build.site_toolchains have no variable: only the site file
/// sets them. A profile sets nothing else, so the lines hold all of the
/// profile in force and select none: in a job that still has the files, the
/// default profile would otherwise apply beneath them, and where the profile
/// is not defined, naming it would stop eb-local.
fn cmdConfigEnv(c: Ctx, s: config.Settings) u8 {
    const a = c.a;
    var out: std.ArrayList(u8) = .empty;
    const line = struct {
        fn f(al: Allocator, o: *std.ArrayList(u8), name: []const u8, v: []const u8) void {
            o.appendSlice(al, str(al, "export {s}={s}\n", .{ name, q(al, v) })) catch oom();
        }
    }.f;
    out.appendSlice(a, "# eb-local configuration; storage and build.site_toolchains come only from the site file\n") catch oom();
    out.appendSlice(a, "# every setting of the profile in force is below, so no profile is selected beneath them\n") catch oom();
    line(a, &out, "EB_LOCAL_PROFILE", "");
    // The same absolute path `eb-local env` would use. A relative prefix, a
    // ~/ prefix and a symbolic link must not be re-resolved from another
    // directory, or followed onto a different tree, when the lines are sourced.
    const p = place(c, s);
    if (p.project) line(a, &out, "EB_LOCAL_PROJECT", p.prefix) else line(a, &out, "EB_LOCAL_PREFIX", p.prefix);
    line(a, &out, "EB_LOCAL_STACK_MODULE", s.stack_module.value);
    line(a, &out, "EB_LOCAL_STACK_EXTEND", s.extend_module.value);
    // Left at its default, dev.buildenv lets dev choose by compiler family;
    // exporting the default would turn that choice off.
    if (!std.mem.eql(u8, s.dev_buildenv.from, "default")) line(a, &out, "EB_LOCAL_DEV_BUILDENV", s.dev_buildenv.value);
    for (config.families, s.buildenv_for) |f, b| if (!std.mem.eql(u8, b.from, "default"))
        line(a, &out, f.env, if (b.value.len == 0) config.no_buildenv else b.value);
    line(a, &out, "EB_LOCAL_DEV_MODULES", std.mem.join(a, " ", s.dev_modules.value) catch oom());
    line(a, &out, "EB_LOCAL_BUILD_ALLOCATION_HINT", s.allocation_hint.value);
    line(a, &out, "EB_LOCAL_CLEAN_TRASH", @tagName(s.trash.value));
    line(a, &out, "EB_LOCAL_CLEAN_LOGS_OLDER_THAN_DAYS", str(a, "{d}", .{s.logs_older_than_days.value}));
    line(a, &out, "EB_LOCAL_NIMVAULT_PROGRAM", s.nimvault_program.value);
    line(a, &out, "EB_LOCAL_NIMVAULT_VAULT", s.nimvault_vault.value);
    for (s.secrets.items) |sec| line(a, &out, str(a, "{s}{s}", .{ config.secret_env_prefix, sec.name }), sec.source);
    if (s.build_secrets.value) |names| line(a, &out, "EB_LOCAL_BUILD_SECRETS", std.mem.join(a, " ", names) catch oom());
    // [eessi] settings are environment for EESSI already; they travel as
    // themselves. An empty one is a profile clearing a site setting; the
    // clear has to be exported or the site value stays in the job.
    for (s.eessi.items) |e| line(a, &out, e.name, e.value);
    cli.put(1, out.items);
    return 0;
}

const SiteOpts = struct {
    words: std.ArrayList([]const u8) = .empty,
    sets: std.ArrayList(sites.Set) = .empty,
    to: ?[]const u8 = null,
    force: bool = false,
};

/// The template `eb-local site` renders: one built in, or a site's own
/// template file, named with a slash so that it is never taken for a
/// built-in name. The file is read as a configuration file is.
fn siteTemplate(c: Ctx, name: []const u8) sites.Template {
    if (std.mem.indexOfScalar(u8, name, '/') == null)
        return sites.find(name) orelse die("no site template '{s}' (eb-local site list shows them; a template file is named with a slash, as ./{s})", .{ name, name });
    const opened = openConfig(name);
    defer sys.close(opened.fd);
    const text = fsx.readAll(c.a, opened.fd, 1 << 20) catch |e| die("cannot read {s} ({s})", .{ name, @errorName(e) });
    return .{ .name = name, .text = text };
}

fn cmdSite(c: Ctx, o: SiteOpts) u8 {
    const a = c.a;
    const w = o.words.items;
    const action = if (w.len > 0) w[0] else "list";
    if (std.mem.eql(u8, action, "list")) {
        if (w.len > 1 or o.sets.items.len > 0 or o.to != null or o.force) die("site list takes nothing else", .{});
        for (sites.all) |t| {
            const names = sites.placeholders(a, t.text) catch oom();
            say("{s: <12} placeholders: {s}", .{ t.name, if (names.len == 0) "none" else std.mem.join(a, ", ", names) catch oom() });
        }
        return 0;
    }
    const show = std.mem.eql(u8, action, "show");
    if (!show and !std.mem.eql(u8, action, "install")) die("site takes list, show NAME or install NAME; got '{s}'", .{action});
    if (w.len != 2) die("site {s} takes one template, a name (eb-local site list shows them) or a file", .{action});
    if (show and (o.to != null or o.force)) die("site show prints the file; --to and --force are for install", .{});
    const t = siteTemplate(c, w[1]);
    var d: sites.Diagnostic = .{};
    const text = sites.render(a, t, o.sets.items, &d) catch |e| switch (e) {
        error.Invalid => die("{s}", .{d.message}),
        error.OutOfMemory => oom(),
    };
    const target = o.to orelse std.fs.path.join(a, &.{ selfDir(a), "config.toml" }) catch oom();
    // The file must load as the site file it is about to become.
    var empty = std.process.Environ.Map.init(a);
    var cd: config.Diagnostic = .{};
    _ = config.load(a, &.{.{ .path = target, .text = text, .layer = .site }}, &empty, .{}, &cd) catch |e| switch (e) {
        error.Invalid => die("template {s}: {s}", .{ t.name, cd.message }),
        error.OutOfMemory => oom(),
    };
    if (show) {
        cli.put(1, text);
        return 0;
    }
    if (exists(target) and !o.force) die("{s} exists; --force replaces it", .{target});
    var why: common.atomic.Why = .{};
    defer why.deinit(a);
    common.atomic.atomicWrite(a, target, text, .{ .mode = 0o644 }, &why) catch |e|
        die("cannot write {s}: {s}", .{ target, if (why.msg.len > 0) why.msg else @errorName(e) });
    say("wrote {s} from template {s}; eb-local config shows what it sets", .{ target, t.name });
    return 0;
}

fn cmdProfiles(c: Ctx, g: Global) u8 {
    const sources = configSources(c, g);
    // Loading checks every profile in every file.
    var d: config.Diagnostic = .{};
    _ = config.load(c.a, sources, c.env, .{}, &d) catch |e| switch (e) {
        error.Invalid => die("{s}", .{d.message}),
        error.OutOfMemory => oom(),
    };
    var shown = false;
    for (sources) |src| {
        var td: toml.Diagnostic = .{};
        const t = toml.parse(c.a, src.text, &td) catch continue;
        for (config.profileNames(c.a, t) catch oom()) |name| {
            say("{s: <20} {s} {s}", .{ name, @tagName(src.layer), src.path });
            shown = true;
        }
    }
    if (!shown) say("no profiles are defined", .{});
    return 0;
}

// ---- running programs -----------------------------------------------------

const Run = union(enum) {
    exit: u8,
    signal: linux.SIG,
};

/// An exit code as it is. A signal is raised again, with the disposition this
/// process was started with: the default kills the process, so a shell and
/// Slurm see the signal rather than exit 128+n and carry on, and an ignored
/// signal (nohup) stays ignored.
fn stop(run: Run) u8 {
    switch (run) {
        .exit => |c| return c,
        .signal => |sig| {
            var cur: linux.Sigaction = undefined;
            _ = linux.sigaction(sig, null, &cur);
            const ignored = cur.handler.handler == linux.SIG.IGN;
            if (!ignored) {
                const dfl: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
                _ = linux.sigaction(sig, &dfl, null);
                var set = linux.sigemptyset();
                linux.sigaddset(&set, sig);
                _ = linux.sigprocmask(linux.SIG.UNBLOCK, &set, null);
                _ = linux.kill(linux.getpid(), sig);
            }
            return @intCast(@min(255, 128 + @as(u32, @backingInt(sig))));
        },
    }
}

/// The signals that stop a program run on a terminal or in a job, and that
/// eb-local passes on to the program it waits for.
const passed_on = [_]linux.SIG{ .INT, .TERM, .HUP, .QUIT };

/// The `si_code` of a signal the kernel sent itself, as the terminal does
/// for Ctrl-C to the whole foreground process group.
const si_kernel: i32 = 0x80;

/// The program being waited for, 0 for none, and the first signal of
/// `passed_on` received while a `Guard` was held. Atomics only: the handler
/// can run between any two instructions.
var waited_pid = std.atomic.Value(linux.pid_t).init(0);
var first_signal = std.atomic.Value(u32).init(0);

fn passOn(sig: linux.SIG, info: *const linux.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    _ = first_signal.cmpxchgStrong(0, @backingInt(sig), .seq_cst, .seq_cst);
    // From the terminal, the signal reached the program too.
    if (info.code == si_kernel) return;
    const pid = waited_pid.load(.seq_cst);
    if (pid > 0) _ = linux.kill(pid, sig);
}

/// While a guard is held, a signal of `passed_on` does not stop eb-local.
/// One another process sent, as `kill PID` does, is passed on to the program
/// eb-local waits for; one from the terminal is not, as it reached that
/// program too, which shares the foreground process group. The first is
/// remembered, so that the caller can finish with what the program left
/// behind, release the guard and raise it again with `stop`.
const Guard = struct {
    old: [passed_on.len]linux.Sigaction,

    fn hold() Guard {
        var g: Guard = .{ .old = undefined };
        var during = linux.sigemptyset();
        for (passed_on) |sig| linux.sigaddset(&during, sig);
        const act: linux.Sigaction = .{ .handler = .{ .sigaction = passOn }, .mask = during, .flags = linux.SA.SIGINFO | linux.SA.RESTART };
        first_signal.store(0, .seq_cst);
        for (passed_on, 0..) |sig, i| {
            _ = linux.sigaction(sig, null, &g.old[i]);
            // One ignored, as nohup ignores SIGHUP, stays ignored, here and
            // in the program.
            if (g.old[i].handler.handler != linux.SIG.IGN) _ = linux.sigaction(sig, &act, null);
        }
        return g;
    }

    fn release(g: *const Guard) void {
        for (passed_on, 0..) |sig, i| _ = linux.sigaction(sig, &g.old[i], null);
    }

    fn received(_: *const Guard) ?linux.SIG {
        const v = first_signal.load(.seq_cst);
        return if (v == 0) null else @fromBackingInt(@intCast(v));
    }

    /// Run a program on this terminal and wait for it to exit.
    fn run(g: *const Guard, a: Allocator, argv: []const []const u8, envp: proc.Envp) Run {
        const zargv = a.allocSentinel(?[*:0]const u8, argv.len, null) catch oom();
        for (argv, 0..) |x, i| zargv[i] = (a.dupeSentinel(u8, x, 0) catch oom()).ptr;
        // Blocked until this process knows the child, and the child has the
        // dispositions this process started with (nohup's, an ignored
        // SIGINT), so that the handler never runs in the child.
        var block = linux.sigemptyset();
        for (passed_on) |sig| linux.sigaddset(&block, sig);
        var mask: linux.sigset_t = undefined;
        _ = linux.sigprocmask(linux.SIG.BLOCK, &block, &mask);
        const pid: isize = @bitCast(linux.fork());
        if (pid == 0) {
            for (passed_on, 0..) |sig, i| _ = linux.sigaction(sig, &g.old[i], null);
            _ = linux.sigprocmask(linux.SIG.SETMASK, &mask, null);
            const rc = linux.execve(zargv[0].?, zargv.ptr, envp);
            cli.err("eb-local: cannot run {s} ({s})\n", .{ argv[0], sys.describeErrno(linux.errno(rc)) });
            linux.exit_group(127);
        }
        if (pid > 0) waited_pid.store(@intCast(pid), .seq_cst);
        _ = linux.sigprocmask(linux.SIG.SETMASK, &mask, null);
        if (pid < 0) die("cannot start {s}", .{argv[0]});
        // Waited for without reaping, so that its pid cannot be reused
        // before the handler forgets it.
        var info: linux.siginfo_t = undefined;
        while (true) {
            const rc = linux.waitid(.PID, @intCast(pid), &info, linux.W.EXITED | linux.W.NOWAIT, null);
            switch (linux.errno(rc)) {
                .SUCCESS => break,
                .INTR => continue,
                else => break,
            }
        }
        waited_pid.store(0, .seq_cst);
        var raw: i32 = 0;
        while (true) {
            const rc = linux.wait4(@intCast(pid), &raw, 0, null);
            switch (linux.errno(rc)) {
                .SUCCESS => break,
                .INTR => continue,
                else => return .{ .exit = 1 },
            }
        }
        const status: u32 = @bitCast(raw);
        if (linux.W.IFEXITED(status)) return .{ .exit = linux.W.EXITSTATUS(status) };
        if (linux.W.IFSIGNALED(status)) return .{ .signal = linux.W.TERMSIG(status) };
        return .{ .exit = 1 };
    }
};

/// Run a program on this terminal and wait for it, holding a `Guard`. A
/// signal eb-local received is the result, whatever the program did with
/// it, so that the caller cleans up and raises it again.
fn runAttached(a: Allocator, argv: []const []const u8, envp: proc.Envp) Run {
    const guard = Guard.hold();
    defer guard.release();
    const ran = guard.run(a, argv, envp);
    return if (guard.received()) |sig| .{ .signal = sig } else ran;
}

fn envpOf(a: Allocator, map: *const std.process.Environ.Map) proc.Envp {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    var it = map.iterator();
    while (it.next()) |kv| {
        const line = std.fmt.allocPrintSentinel(a, "{s}={s}", .{ kv.key_ptr.*, kv.value_ptr.* }, 0) catch oom();
        list.append(a, line.ptr) catch oom();
    }
    list.append(a, null) catch oom();
    return @ptrCast(list.items.ptr);
}

/// The line for eessi-arch-guard, whose target builds, env and dev load
/// EESSI for. Inside a job with EESSI loaded the guard is asked as a build
/// asks it, strictly, with a private directory that is removed after.
fn noteGuard(c: Ctx, out: *std.ArrayList(u8)) void {
    const a = c.a;
    const guard = (proc.which(a, "eessi-arch-guard", c.env.get("PATH") orelse "") catch null) orelse
        return note(a, out, "info", "eessi-arch-guard is not on PATH; builds, env and dev load EESSI for the target EESSI detects", .{});
    if (std.mem.eql(u8, c.env.get("EESSI_ARCH_GUARD") orelse "", "0"))
        return note(a, out, "info", "eessi-arch-guard is on PATH, and EESSI_ARCH_GUARD=0 turns it off", .{});
    const loaded = nonEmpty(c.env.get("EESSI_SOFTWARE_SUBDIR")) orelse "";
    if (nonEmpty(c.env.get("SLURM_JOB_ID")) == null or loaded.len == 0)
        return note(a, out, "info", "eessi-arch-guard is on PATH; builds, env and dev load EESSI for the target it selects, which doctor shows inside a job with EESSI loaded", .{});
    const tmp = nonEmpty(c.env.get("TMPDIR")) orelse "/tmp";
    const base = if (fsx.statAt(fsx.cwd, tmp, true)) |st| (if (st.isDir()) tmp else "/tmp") else |_| "/tmp";
    const dir = storage.makeWorkspace(a, base) catch
        return note(a, out, "warn", "eessi-arch-guard was not asked: doctor could not make a private directory in {s}", .{base});
    defer fsx.deleteTree(a, fsx.cwd, dir) catch {};
    var env = c.env.clone(a) catch oom();
    env.put("EESSI_ARCH_GUARD_WORKDIR", dir) catch oom();
    const r = proc.run(a, guard, &.{ guard, "--strict", "--shell" }, envpOf(a, &env), .{ .stdout_limit = 1 << 20, .stderr_limit = 64 << 10, .timeout_ms = 120_000 }) catch |e|
        return note(a, out, "warn", "eessi-arch-guard could not be run: {s}", .{@errorName(e)});
    if (r.term.code() != 0) {
        var lines = std.mem.splitScalar(u8, std.mem.trim(u8, r.stderr, " \n"), '\n');
        const why = lines.first();
        return note(a, out, "warn", "eessi-arch-guard cannot select a target here (exit {d}{s}{s}); builds stop when it cannot, and EESSI_ARCH_GUARD=0 turns it off", .{ r.term.code(), if (why.len > 0) ": " else "", why });
    }
    const chosen = shellExport(a, r.stdout, "EESSI_SOFTWARE_SUBDIR") orelse loaded;
    if (std.mem.eql(u8, chosen, loaded)) {
        note(a, out, "ok  ", "eessi-arch-guard selects {s}, the target EESSI is loaded for", .{chosen});
    } else note(a, out, "ok  ", "eessi-arch-guard selects {s} here, not {s}, which EESSI is loaded for; builds, env and dev use {s}", .{ chosen, loaded, chosen });
}

/// The value `export NAME=VALUE` gives NAME in the output of
/// eessi-arch-guard --shell, without the quotes Python's shlex.quote adds.
fn shellExport(a: Allocator, text: []const u8, name: []const u8) ?[]const u8 {
    const head = str(a, "export {s}=", .{name});
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, head)) continue;
        const v = line[head.len..];
        if (v.len >= 2 and v[0] == '\'' and v[v.len - 1] == '\'')
            return std.mem.replaceOwned(u8, a, v[1 .. v.len - 1], "'\"'\"'", "'") catch oom();
        return v;
    }
    return null;
}

test "the value eessi-arch-guard --shell gives a variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "export EESSI_ARCH_GUARD_RELOADED='x86_64/amd/zen4->x86_64/amd/zen2'\nexport EESSI_SOFTWARE_SUBDIR=x86_64/amd/zen2\nunset EESSI_ARCHDETECT_OPTIONS\n";
    try std.testing.expectEqualStrings("x86_64/amd/zen2", shellExport(a, text, "EESSI_SOFTWARE_SUBDIR").?);
    try std.testing.expectEqualStrings("x86_64/amd/zen4->x86_64/amd/zen2", shellExport(a, text, "EESSI_ARCH_GUARD_RELOADED").?);
    try std.testing.expectEqualStrings("it's", shellExport(a, "export X='it'\"'\"'s'\n", "X").?);
    try std.testing.expect(shellExport(a, text, "EESSI_ARCHDETECT_OPTIONS") == null);
    try std.testing.expect(shellExport(a, text, "EESSI_SOFTWARE") == null);
}

/// Your user name, for %u in storage.node_local_mount. `undone` is what the
/// command does not do when there is none.
fn userName(c: Ctx, s: config.Settings, undone: []const u8) []const u8 {
    // A static binary has no NSS; id(1) asks the system's.
    const id = (proc.which(c.a, "id", c.env.get("PATH") orelse "/usr/bin:/bin") catch null) orelse "/usr/bin/id";
    const failed = "cannot tell your user name: {s} -un {s}; {s}.\n" ++
        "  eb-local puts it for %u in storage.node_local_mount, {s} [{s}]; run eb-local where id -un prints your user name.";
    const r = proc.run(c.a, id, &.{ id, "-un" }, c.envp, .{ .stdout_limit = 4096, .timeout_ms = 10_000 }) catch |e|
        die(failed, .{ id, str(c.a, "could not run ({s})", .{@errorName(e)}), undone, s.node_local_mount.value, s.node_local_mount.from });
    if (r.term.code() != 0) die(failed, .{ id, str(c.a, "failed with status {d}", .{r.term.code()}), undone, s.node_local_mount.value, s.node_local_mount.from });
    return std.mem.trim(u8, r.stdout, " \n");
}

fn mountinfoText(c: Ctx) []const u8 {
    var path: []const u8 = "/proc/self/mountinfo";
    if (comptime build_options.test_ops) {
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_MOUNTINFO"))) |p| path = p;
    }
    const fd = sys.openat(fsx.cwd, path, .{}, 0) catch die("cannot read {s}", .{path});
    defer sys.close(fd);
    return fsx.readAll(c.a, fd, 8 << 20) catch die("cannot read {s}", .{path});
}

/// The caller's uid. Only the test artifact lets EB_LOCAL_TEST_UID stand in,
/// so that a test can make its own directory look like another user's.
fn callerUid(c: Ctx) linux.uid_t {
    if (comptime build_options.test_ops) {
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_UID"))) |v| return std.fmt.parseInt(linux.uid_t, v, 10) catch linux.getuid();
    }
    return linux.getuid();
}

fn nodeLocal(s: config.Settings) storage.NodeLocal {
    return .{
        .root = s.node_local_root.value,
        .root_from = s.node_local_root.from,
        .mount = s.node_local_mount.value,
        .mount_from = s.node_local_mount.from,
        .fstype = s.node_local_fstype.value,
        .fstype_from = s.node_local_fstype.from,
    };
}

/// The allocation's node-local mount. A refusal says what was refused and
/// why, then what to change; `undone` is what the command then did not do.
fn checkedJobRoot(c: Ctx, s: config.Settings, undone: []const u8) []const u8 {
    if (s.node_local_root.value.len == 0)
        die("no site file sets storage.node_local_root, the directory that holds each job's node-local mount; {s}.\n" ++
            "  Set it in the site file, which eb-local site install slurm --set node_local_root=DIR writes, or name a site file " ++
            "that root or this program's owner owns with --config FILE or EB_LOCAL_CONFIG=FILE. eb-local eb needs no site file.", .{undone});
    var r: storage.Refusal = .{};
    const job_id = c.env.get("SLURM_JOB_ID") orelse "";
    const jr = storage.jobRoot(c.a, nodeLocal(s), job_id, userName(c, s, undone), mountinfoText(c), callerUid(c), &r) catch |e| switch (e) {
        error.Refused => die("{s}; {s}.\n  {s}.", .{ r.message, undone, r.fix }),
        error.OutOfMemory => oom(),
    };
    return jr.path;
}

/// Where the prefix in force was set, as `eb-local config` shows it.
fn prefixFrom(s: config.Settings, p: Place) []const u8 {
    return if (p.project) s.project.from else s.prefix.from;
}

/// What to change when a prefix is refused.
const prefix_fix = "set a prefix on durable storage you own with prefix in your eb-local configuration, EB_LOCAL_PREFIX, or --project DIR for a project";

/// Why a prefix is refused when it, or a tree below it, is on refused storage.
const outlive = "Installs, sources and logs must outlive the job and not be on shared scratch";

/// A tree a build writes nothing to, with the setting that names it.
const RefusedTree = struct { path: []const u8, what: []const u8 };

/// Shared scratch and the node-local root, as configured and, when
/// `resolved`, as the kernel resolves them, so that an alias (a symbolic
/// link to shared scratch) is refused as the tree itself is.
fn refusedTrees(c: Ctx, s: config.Settings, resolved: bool) []const RefusedTree {
    const a = c.a;
    const scratch = str(a, "shared scratch in storage.shared_scratch [{s}]", .{s.shared_scratch.from});
    const local = str(a, "node-local storage below storage.node_local_root [{s}]", .{s.node_local_root.from});
    var configured: std.ArrayList(RefusedTree) = .empty;
    for (s.shared_scratch.value) |r| configured.append(a, .{ .path = r, .what = scratch }) catch oom();
    if (s.node_local_root.value.len > 0) configured.append(a, .{ .path = s.node_local_root.value, .what = local }) catch oom();
    if (!resolved) return configured.items;
    var out: std.ArrayList(RefusedTree) = .empty;
    for (configured.items) |t| {
        out.append(a, t) catch oom();
        out.append(a, .{ .path = storage.canonical(a, t.path, c.cwd) catch oom(), .what = t.what }) catch oom();
    }
    return out.items;
}

const Durable = struct {
    sources: []const u8,
    logs: []const u8,
};

/// Sources and logs live beside the installation, and must stay there.
/// `undone` is what the command does not do when one leads elsewhere.
fn durableDirs(c: Ctx, prefix: []const u8, undone: []const u8) Durable {
    const root = std.fs.path.join(c.a, &.{ prefix, ".eb-local" }) catch oom();
    const d: Durable = .{
        .sources = std.fs.path.join(c.a, &.{ root, "sources" }) catch oom(),
        .logs = std.fs.path.join(c.a, &.{ root, "logs" }) catch oom(),
    };
    for ([_][]const u8{ d.sources, d.logs }) |p| {
        const resolved = storage.canonical(c.a, p, c.cwd) catch oom();
        if (!storage.under(resolved, prefix) or std.mem.eql(u8, resolved, prefix))
            die("{s} leads to {s}, not to a directory inside the install prefix {s}; {s}.\n" ++
                "  Sources and logs stay in the durable prefix, beside the installs: replace the symbolic link in {s} with a directory, or " ++ prefix_fix ++ ".", .{ p, resolved, prefix, undone, p });
    }
    return d;
}

/// The stop when the checked node-local mount takes no workspace.
fn workspaceFailed(a: Allocator, job_root: []const u8, e: anyerror) noreturn {
    if (e == error.OutOfMemory) oom();
    die("cannot make a build workspace in the node-local mount {s} ({s}); nothing was built.\n" ++
        "  The mount passed eb-local's checks, so it may be full or have changed since; df {s} shows its free space.", .{ job_root, @errorName(e), q(a, job_root) });
}

// ---- clean ----------------------------------------------------------------

const CleanOpts = struct {
    logs: bool = true,
    logs_days: ?u32 = null,
    sources: bool = false,
    workspaces: bool = false,
    dry_run: bool = false,
    delete: bool = false,
};

const Target = struct { path: []const u8, dir: bool = false };

const Collect = struct {
    c: Ctx,
    out: std.ArrayList(Target) = .empty,

    /// The directory `path` to collect from, never reached through a
    /// symbolic link; null when there is none.
    fn top(path: []const u8) ?fsx.Stat {
        const st = fsx.statAt(fsx.cwd, path, false) catch return null;
        if (st.isLink()) die("{s} is reached through a symbolic link; clean leaves it alone.", .{path});
        if (!st.isDir()) return null;
        var buf: [sys.path_max]u8 = undefined;
        const real = fsx.realpath(fsx.cwd, path, &buf) catch return null;
        if (!std.mem.eql(u8, real, path)) die("{s} is reached through a symbolic link; clean leaves it alone.", .{path});
        return st;
    }

    /// Regular files below `path`, on its file system, never through a
    /// symbolic link.
    fn files(self: *Collect, path: []const u8) void {
        const st = top(path) orelse return;
        self.walk(path, st.dev, 0);
    }

    fn walk(self: *Collect, path: []const u8, dev: u64, depth: usize) void {
        if (depth > 16) return;
        const fd = fsx.openDir(fsx.cwd, path, false) catch return;
        defer sys.close(fd);
        var it = fsx.DirIter.init(self.c.a, fd) catch return;
        while (it.next() catch null) |e| {
            const st = fsx.statAt(fd, e.name, false) catch continue;
            if (st.dev != dev) continue;
            const child = std.fs.path.join(self.c.a, &.{ path, e.name }) catch oom();
            if (st.isDir()) {
                self.walk(child, dev, depth + 1);
            } else if (st.isReg()) {
                self.out.append(self.c.a, .{ .path = child }) catch oom();
            }
        }
    }

    /// The files and directories in `path` with nothing in them modified
    /// since `cutoff`, each whole: EasyBuild copies a build's easyconfig,
    /// easyblocks and hooks into reprod_<time>_<pid>/ with their own older
    /// times, so a file's age is not its build's. A directory holding
    /// another file system, or one clean cannot read through, stays.
    fn aged(self: *Collect, path: []const u8, cutoff: i64) void {
        const st = top(path) orelse return;
        const fd = fsx.openDir(fsx.cwd, path, false) catch return;
        defer sys.close(fd);
        var it = fsx.DirIter.init(self.c.a, fd) catch return;
        while (it.next() catch null) |e| {
            const est = fsx.statAt(fd, e.name, false) catch continue;
            if (est.dev != st.dev or !(est.isDir() or est.isReg())) continue;
            const child = std.fs.path.join(self.c.a, &.{ path, e.name }) catch oom();
            var newest = est.mtime.sec;
            if (est.isDir() and !newestBelow(self.c, child, st.dev, &newest, 0)) continue;
            if (newest >= cutoff) continue;
            self.out.append(self.c.a, .{ .path = child, .dir = est.isDir() }) catch oom();
        }
    }
};

/// Raises `newest` to the latest modification below `path`; false when
/// something there is on another file system or cannot be read.
fn newestBelow(c: Ctx, path: []const u8, dev: u64, newest: *i64, depth: usize) bool {
    if (depth > 16) return false;
    const fd = fsx.openDir(fsx.cwd, path, false) catch return false;
    defer sys.close(fd);
    var it = fsx.DirIter.init(c.a, fd) catch return false;
    while (it.next() catch return false) |e| {
        const st = fsx.statAt(fd, e.name, false) catch return false;
        if (st.dev != dev) return false;
        newest.* = @max(newest.*, st.mtime.sec);
        if (st.isDir() and !newestBelow(c, std.fs.path.join(c.a, &.{ path, e.name }) catch oom(), dev, newest, depth + 1)) return false;
    }
    return true;
}

fn removeEmptyDirs(c: Ctx, path: []const u8, dev: u64, depth: usize) void {
    if (depth > 16) return;
    const here = fsx.statAt(fsx.cwd, path, false) catch return;
    if (here.dev != dev or !here.isDir()) return;
    const fd = fsx.openDir(fsx.cwd, path, false) catch return;
    defer sys.close(fd);
    var it = fsx.DirIter.init(c.a, fd) catch return;
    while (it.next() catch null) |e| {
        const st = fsx.statAt(fd, e.name, false) catch continue;
        if (st.dev != dev or !st.isDir()) continue;
        removeEmptyDirs(c, std.fs.path.join(c.a, &.{ path, e.name }) catch oom(), dev, depth + 1);
        sys.unlinkat(fd, e.name, linux.AT.REMOVEDIR) catch {};
    }
}

fn cmdClean(c: Ctx, s: config.Settings, o: CleanOpts) u8 {
    const a = c.a;
    var job_root: ?[]const u8 = null;
    if (o.workspaces) {
        if (nonEmpty(c.env.get("SLURM_JOB_ID")) == null)
            die("clean --workspaces works only inside the Slurm job that made the workspaces, and SLURM_JOB_ID is unset or empty; nothing was removed.\n" ++
                "  A build workspace is in its job's node-local mount, which goes when the job ends; run eb-local clean --workspaces inside that job, " ++
                "in its batch script or with srun --jobid=JOBID --overlap.", .{});
        job_root = checkedJobRoot(c, s, "nothing was removed");
    }
    const p = place(c, s);
    const d = durableDirs(c, p.prefix, "nothing was removed");
    var trash = s.trash.value;
    const rtrash = proc.which(a, "rtrash", c.env.get("PATH") orelse "") catch null;
    switch (trash) {
        .auto => trash = if (rtrash != null) .rtrash else .none,
        .rtrash => if (rtrash == null) die("clean.trash is rtrash, but rtrash is not on PATH.", .{}),
        .none => {},
    }
    // find -mtime +N: more than N whole days old.
    const days: i64 = o.logs_days orelse s.logs_older_than_days.value;
    const now: i64 = nowSecs();
    var collect: Collect = .{ .c = c };
    if (o.logs) collect.aged(d.logs, now - (days + 1) * 86400 + 1);
    if (o.sources) collect.files(d.sources);
    var spaces: std.ArrayList([]const u8) = .empty;
    if (job_root) |jr| {
        const fd = fsx.openDir(fsx.cwd, jr, false) catch die("cannot read {s}", .{jr});
        defer sys.close(fd);
        var it = fsx.DirIter.init(a, fd) catch die("cannot read {s}", .{jr});
        while (it.next() catch null) |e| {
            const full = std.fs.path.join(a, &.{ jr, e.name }) catch oom();
            if (storage.ownWorkspace(jr, full, callerUid(c))) spaces.append(a, full) catch oom();
        }
    }
    const targets = collect.out.items;
    if (targets.len == 0 and spaces.items.len == 0) {
        say("eb-local: nothing to clean in {s}", .{p.prefix});
        return 0;
    }
    for (targets) |t| say("  {s}{s}", .{ t.path, if (t.dir) "/" else "" });
    for (spaces.items) |w| say("  {s}/ (build workspace)", .{w});
    if (o.dry_run) {
        say("eb-local: dry run, nothing removed ({d} item(s), {d} workspace(s))", .{ targets.len, spaces.items.len });
        return 0;
    }
    if (targets.len > 0 and trash != .rtrash and !o.delete) {
        warn("rtrash is not installed; nothing removed. Install rtrash, or pass --delete to delete for good.", .{});
        return 1;
    }
    // Build workspaces are node-local scratch the scheduler removes anyway;
    // they are deleted, not trashed.
    for (spaces.items) |w| storage.removeTree(a, w) catch |e| warn("cannot remove {s} ({s})", .{ w, @errorName(e) });
    if (spaces.items.len > 0) say("eb-local: removed {d} build workspace(s)", .{spaces.items.len});
    if (targets.len > 0) {
        if (trash == .rtrash) {
            var argv: std.ArrayList([]const u8) = .empty;
            argv.appendSlice(a, &.{ rtrash.?, "put" }) catch oom();
            for (targets) |t| if (t.dir) {
                argv.append(a, "-r") catch oom();
                break;
            };
            argv.append(a, "--") catch oom();
            for (targets) |t| argv.append(a, t.path) catch oom();
            const run = runAttached(a, argv.items, c.envp);
            switch (run) {
                .exit => |rc| if (rc != 0) die("rtrash put exited {d}", .{rc}),
                .signal => return stop(run),
            }
            say("eb-local: moved {d} item(s) to the trash (rtrash list, rtrash restore)", .{targets.len});
        } else {
            for (targets) |t| {
                if (t.dir) {
                    storage.removeTree(a, t.path) catch |e| warn("cannot remove {s} ({s})", .{ t.path, @errorName(e) });
                } else {
                    sys.unlinkat(fsx.cwd, t.path, 0) catch |e| warn("cannot remove {s} ({s})", .{ t.path, @errorName(e) });
                }
            }
            say("eb-local: deleted {d} item(s)", .{targets.len});
        }
        for ([_][]const u8{ d.logs, d.sources }) |dir| {
            const st = fsx.statAt(fsx.cwd, dir, false) catch continue;
            removeEmptyDirs(c, dir, st.dev, 0);
        }
    }
    return 0;
}

// ---- build ----------------------------------------------------------------

/// The part of a build that needs Lmod runs in bash. The stack, extension,
/// install variable, prefix and mode come as arguments and the easyconfig
/// arguments after them, so nothing a user typed is part of the script.
const test_prelude =
    \\if [ -n "${EB_LOCAL_TEST_PRELUDE:-}" ]; then
    \\    # The test artifact's stand-in for BASH_ENV. A release build has no
    \\    # such seam: bash would run BASH_ENV before this script.
    \\    source "$EB_LOCAL_TEST_PRELUDE"
    \\    unset EB_LOCAL_TEST_PRELUDE
    \\fi
    \\
;

/// What a shell without a module command sources for one, in this order:
/// the host's Lmod, then EESSI's own, from the init `eb-local eb` sources,
/// for a host whose only Lmod is EESSI's. `lmodInits` names the same files.
const lmod_init =
    \\if ! type module >/dev/null 2>&1; then
    \\    for eb_local_init in "${LMOD_PKG:-/usr/share/lmod/lmod}/init/bash" /etc/profile.d/lmod.sh \
    \\        "${EESSI_CVMFS_REPO:-/cvmfs/software.eessi.io}/versions/${EESSI_VERSION:-2026.06}/init/lmod/bash"; do
    \\        [ -r "$eb_local_init" ] && { . "$eb_local_init" >/dev/null; break; }
    \\    done
    \\    unset eb_local_init
    \\fi
    \\
;

/// The files `lmod_init` tries, in its order.
fn lmodInits(a: Allocator, env: *const std.process.Environ.Map) [3][]const u8 {
    const pkg = nonEmpty(env.get("LMOD_PKG")) orelse "/usr/share/lmod/lmod";
    return .{
        std.fs.path.join(a, &.{ pkg, "init", "bash" }) catch oom(),
        "/etc/profile.d/lmod.sh",
        extend.initPath(a, env) catch oom(),
    };
}

fn readable(path: []const u8) bool {
    var zb: [sys.path_max:0]u8 = undefined;
    const zp = sys.z(&zb, path) catch return false;
    return linux.errno(linux.faccessat(linux.AT.FDCWD, zp.ptr, linux.R_OK, 0)) == .SUCCESS;
}

const build_script = "set -eo pipefail\n" ++ (if (build_options.test_ops) test_prelude else "") ++
    \\stack=$1 extend=$2 install_var=$3 prefix=$4 mode=$5
    \\shift 5
    \\keep=(WORKING_DIR TMPDIR TMP TEMP EASYBUILD_BUILDPATH EASYBUILD_TMPDIR XDG_CACHE_HOME CARGO_HOME EASYBUILD_SOURCEPATH EASYBUILD_TMP_LOGDIR)
    \\declare -A saved
    \\for v in "${keep[@]}"; do saved[$v]=${!v}; done
    \\restore() { for v in "${keep[@]}"; do export "$v=${saved[$v]}"; done; }
    \\# A load that works fills stderr with the modules' own messages; one that
    \\# fails leaves Lmod's reason there, so only a failed load shows it.
    \\load() {
    \\    local err="${saved[TMPDIR]}/module-load.err" line
    \\    module load "$1" >/dev/null 2>"$err" && return
    \\    echo "eb-local: could not load $1:" >&2
    \\    while IFS= read -r line; do echo "${line:+  $line}" >&2; done < "$err"
    \\    exit 1
    \\}
    \\
++ lmod_init ++
    \\type module >/dev/null 2>&1 || {
    \\    echo "eb-local: no module command found; none of ${LMOD_PKG:-/usr/share/lmod/lmod}/init/bash, /etc/profile.d/lmod.sh or ${EESSI_CVMFS_REPO:-/cvmfs/software.eessi.io}/versions/${EESSI_VERSION:-2026.06}/init/lmod/bash defined one" >&2
    \\    exit 1
    \\}
    \\# EESSI-extend reads the variables when it loads, so it is loaded fresh.
    \\module unload "$extend" >/dev/null 2>&1 || true
    \\unset EESSI_CVMFS_INSTALL EESSI_SITE_INSTALL EESSI_USER_INSTALL EESSI_PROJECT_INSTALL
    \\unset EESSI_SITE_SOFTWARE_PREFIX
    \\unset EESSI_SOFTWARE_SUBDIR_OVERRIDE EESSI_ACCELERATOR_TARGET_OVERRIDE EESSI_OVERRIDE_GPU_CHECK
    \\unset EASYBUILD_INSTALLPATH EASYBUILD_INSTALLPATH_SOFTWARE EASYBUILD_INSTALLPATH_MODULES EASYBUILD_PREFIX
    \\restore
    \\export "$install_var=$prefix"
    \\# Lmod finds every module of a load before it loads any; the extension
    \\# is on MODULEPATH only once the stack is loaded. The extension reads
    \\# WORKING_DIR and EASYBUILD_SOURCEPATH as it loads, so whatever the
    \\# stack module set, the paths go back first.
    \\load "$stack"
    \\restore
    \\# Tasks run with the CPU target eessi-arch-guard selects, which can be
    \\# below the one EESSI detects: on a CPU without a flag GCC enables for the
    \\# detected target, the guard takes the next one. Where the guard is
    \\# installed, the build installs for its target, and a guard that cannot
    \\# select one stops the build. --strict restores in a private directory,
    \\# which the workspace is.
    \\if command -v eessi-arch-guard >/dev/null 2>&1; then
    \\    delta=$(EESSI_ARCH_GUARD_WORKDIR="${saved[EASYBUILD_BUILDPATH]%/build}" eessi-arch-guard --strict --shell) || {
    \\        echo "eb-local: eessi-arch-guard could not select this node's target; nothing was built" >&2
    \\        exit 1
    \\    }
    \\    eval "$delta"
    \\    restore
    \\fi
    \\load "$extend"
    \\restore
    \\# EESSI-extend chose the install path as it loaded. eb-local checked the
    \\# prefix's versions tree, lists it and cleans its logs of secrets, so an
    \\# install path anything else chose stops the build. An install variable
    \\# a load hook sets acts only on the next load.
    \\see='See "Where EESSI-extend installs": https://stackhands.github.io/eb-local/explanation/install-variables.html'
    \\for v in EESSI_USER_INSTALL EESSI_PROJECT_INSTALL EESSI_SITE_INSTALL EESSI_CVMFS_INSTALL; do
    \\    if [ "$v" = "$install_var" ]; then want=set:$prefix; else want=; fi
    \\    [ "${!v+set:${!v}}" = "$want" ] && continue
    \\    if [ -n "${!v+set}" ]; then what="set $v=${!v}"; else what="unset $v"; fi
    \\    echo "eb-local: loading $extend $what; this build still installs into $prefix, but a shell that loads EESSI-extend by hand keeps the change, and its next load installs elsewhere." >&2
    \\    echo "  A site Lmod hook that sets an install variable acts only on the next load. $see" >&2
    \\done
    \\for v in EASYBUILD_INSTALLPATH_SOFTWARE EASYBUILD_INSTALLPATH_MODULES; do
    \\    if [ -n "${!v+set}" ]; then
    \\        echo "eb-local: loading $extend set $v=${!v}, which would put part of the install outside $prefix/versions, the tree eb-local checked; nothing was built." >&2
    \\        echo "  A site Lmod hook or a changed EESSI-extend set it. $see" >&2
    \\        exit 2
    \\    fi
    \\done
    \\installpath=${EASYBUILD_INSTALLPATH-}
    \\if [[ $installpath != "$prefix"/versions/?* || /$installpath/ == */../* ]]; then
    \\    echo "eb-local: loading $extend set the install path to ${installpath:-nothing}, outside $prefix/versions, the tree eb-local checked; nothing was built." >&2
    \\    echo "  $install_var did not choose it: a site Lmod hook, a changed EESSI-extend, or a character such as - in EESSI_CVMFS_REPO, which EESSI-extend matches as a Lua pattern, did. $see" >&2
    \\    exit 2
    \\fi
    \\# The hooks of EESSI $EESSI_VERSION accept these toolchains besides foss and lfoss.
    \\if [ -n "${EB_LOCAL_SITE_TOOLCHAINS:-}" ]; then
    \\    [ -n "${EESSI_VERSION:-}" ] || { echo "eb-local: $stack set no EESSI_VERSION; cannot apply build.site_toolchains" >&2; exit 1; }
    \\    export "EESSI_SITE_TOP_LEVEL_TOOLCHAINS_${EESSI_VERSION//./_}=$EB_LOCAL_SITE_TOOLCHAINS"
    \\fi
    \\unset EB_LOCAL_SITE_TOOLCHAINS
    \\echo "eb-local: installing into $prefix ($mode)"
    \\echo "eb-local: target $EESSI_SOFTWARE_SUBDIR${EESSI_ACCELERATOR_TARGET:+ + $EESSI_ACCELERATOR_TARGET}, build space ${saved[EASYBUILD_BUILDPATH]%/build}"
    \\# EasyBuild keeps the umask EESSI-extend sets for the install, 077 and the
    \\# sticky bit for a user one, 002 and the setgid bit for a project.
    \\# eb replaces this shell, so the program eb-local waits for, and passes
    \\# a signal on to, is EasyBuild, which writes the logs it then cleans.
    \\exec eb "$@"
;

/// What bash would run before the script could unset it: bash runs BASH_ENV
/// first, and SHELLOPTS=xtrace prints the commands into the job log.
const shell_startup = [_][]const u8{ "BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS" };

/// Host loader settings, which select libraries ahead of the toolchain's
/// RPATH.
const host_loader = [_][]const u8{ "LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT" };

/// The variables a build sets for its script: build and temporary space in
/// the workspace `work`, sources and logs beside the install.
fn buildVariables(a: Allocator, work: []const u8, d: Durable) [11][2][]const u8 {
    const tmp = std.fs.path.join(a, &.{ work, "tmp" }) catch oom();
    return .{
        .{ "WORKING_DIR", std.fs.path.join(a, &.{ work, "source-index" }) catch oom() },
        .{ "TMPDIR", tmp },
        .{ "TMP", tmp },
        .{ "TEMP", tmp },
        .{ "EASYBUILD_BUILDPATH", std.fs.path.join(a, &.{ work, "build" }) catch oom() },
        .{ "EASYBUILD_TMPDIR", tmp },
        .{ "XDG_CACHE_HOME", std.fs.path.join(a, &.{ work, "cache" }) catch oom() },
        .{ "CARGO_HOME", std.fs.path.join(a, &.{ work, "cargo" }) catch oom() },
        .{ "EASYBUILD_SOURCEPATH", d.sources },
        .{ "EASYBUILD_TMP_LOGDIR", d.logs },
        .{ "LMOD_EXACT_MATCH", "no" },
    };
}

fn buildUmask(p: Place) u32 {
    return if (p.project) 0o002 else 0o077;
}

/// The command a build runs: `build_script` in a clean bash, with the stack,
/// the extension, the install variable, the prefix and the mode as its first
/// five arguments, and eb's after them.
fn buildCommand(a: Allocator, c: Ctx, s: config.Settings, p: Place, args: []const []const u8) []const []const u8 {
    const bash = (proc.which(a, "bash", c.env.get("PATH") orelse "/usr/bin:/bin") catch null) orelse "/bin/bash";
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(a, &.{
        bash,                 "--noprofile",         "--norc",                                                         "-c",     build_script,                         "eb-local",
        s.stack_module.value, s.extend_module.value, if (p.project) "EESSI_PROJECT_INSTALL" else "EESSI_USER_INSTALL", p.prefix, if (p.project) "project" else "user",
    }) catch oom();
    argv.appendSlice(a, args) catch oom();
    return argv.items;
}

/// What a build runs: its script, after the variables eb-local sets for it
/// and a `set --` line with its arguments, and the checks eb-local makes
/// first as comments. Nothing is created and nothing runs, so it also works
/// outside an allocation. $W stands for the workspace a build makes in the
/// allocation's node-local mount.
fn explainBuild(c: Ctx, s: config.Settings, g: Global, args: []const []const u8) u8 {
    const a = c.a;
    const p = place(c, s);
    const d = durableDirs(c, p.prefix, "a build would stop here");
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, "# eb-local --explain: the script a build runs, with its environment and arguments. Nothing was created or run.\n") catch oom();
    out.print(a, "# Installs as a {s} install into {s} (prefix from {s}).\n", .{
        if (p.project) "project" else "user", p.prefix, if (p.project) s.project.from else s.prefix.from,
    }) catch oom();
    if (nonEmpty(c.env.get("SLURM_JOB_ID"))) |job| {
        out.print(a, "# Checks first: Slurm job {s}, its own node-local {s} mount under {s},\n", .{ job, s.node_local_fstype.value, s.node_local_root.value }) catch oom();
    } else {
        out.appendSlice(a, "# Checks first: a Slurm job (there is none here, so a build would stop now),\n") catch oom();
        if (s.allocation_hint.value.len > 0) out.print(a, "#   for example: {s}\n", .{s.allocation_hint.value}) catch oom();
        out.print(a, "#   then its own node-local {s} mount under {s},\n", .{ s.node_local_fstype.value, s.node_local_root.value }) catch oom();
    }
    out.appendSlice(a, "#   and a prefix, sources and logs that are not on shared or node-local scratch.\n") catch oom();
    const jobs = batchLines(c, s, g, p, args);
    if (jobs.len > 0) {
        out.appendSlice(a, "# On each node type the site file lists in [build.node_types], the same build as a batch job:\n") catch oom();
        for (jobs) |line| out.print(a, "#   {s}\n", .{line}) catch oom();
    }
    out.appendSlice(a, "# W is a new workspace eb-local makes in that mount; it is removed after a good build.\n") catch oom();
    for (s.secrets.items) |sec| {
        if (config.buildGets(s, sec.name)) {
            out.print(a, "# {s} reaches eb's environment from {s}; logs are cleaned of it afterwards.\n", .{ sec.name, sec.source }) catch oom();
        } else out.print(a, "# {s} stays out of eb's environment and is not read: build.secrets [{s}] does not name it.\n", .{ sec.name, s.build_secrets.from }) catch oom();
    }
    out.appendSlice(a, "# The script gets this environment without the install variables and") catch oom();
    for (shell_startup ++ host_loader) |name| out.print(a, " {s}", .{name}) catch oom();
    out.appendSlice(a, ",\n# and with these:\n") catch oom();
    for (buildVariables(a, "$W", d)) |kv| {
        if (std.mem.startsWith(u8, kv[1], "$W/")) {
            out.print(a, "export {s}=\"{s}\"\n", .{ kv[0], kv[1] }) catch oom();
        } else {
            out.print(a, "export {s}={s}\n", .{ kv[0], q(a, kv[1]) }) catch oom();
        }
    }
    for (s.eessi.items) |v| out.print(a, "export {s}={s}\n", .{ v.name, q(a, v.value) }) catch oom();
    if (s.site_toolchains.value.len > 0)
        out.print(a, "export EB_LOCAL_SITE_TOOLCHAINS={s}\n", .{q(a, config.toolchainsJson(a, s.site_toolchains.value) catch oom())}) catch oom();
    out.print(a, "umask {o:0>3}\n", .{buildUmask(p)}) catch oom();
    const argv = buildCommand(a, c, s, p, args);
    out.appendSlice(a, "# It runs in a clean bash (no profile, no rc file):\n#  ") catch oom();
    for (argv[0..4]) |x| out.print(a, " {s}", .{x}) catch oom();
    out.appendSlice(a, " \"$SCRIPT\"") catch oom();
    for (argv[5..]) |x| out.print(a, " {s}", .{q(a, x)}) catch oom();
    out.appendSlice(a, "\n# where SCRIPT is everything after the next line.\nset --") catch oom();
    for (argv[6..]) |x| out.print(a, " {s}", .{q(a, x)}) catch oom();
    out.print(a, "\n{s}\n", .{build_script}) catch oom();
    cli.put(1, out.items);
    return 0;
}

fn cmdBuild(c: Ctx, s: config.Settings, g: Global, args: []const []const u8) u8 {
    const a = c.a;
    if (args.len == 0) {
        cli.err("{s}", .{usage_text});
        return 2;
    }
    if (g.explain) return explainBuild(c, s, g, args);
    if (nonEmpty(c.env.get("SLURM_JOB_ID")) == null) {
        warn("not inside a Slurm job: SLURM_JOB_ID is unset or empty; nothing was built.", .{});
        cli.err("  Software is built for the CPU of the node that runs eb-local, so build\n", .{});
        cli.err("  inside an allocation on the node type that will run it{s}\n", .{if (s.allocation_hint.value.len > 0) ", for example:" else ""});
        if (s.allocation_hint.value.len > 0) cli.err("  {s}\n", .{s.allocation_hint.value});
        const jobs = batchLines(c, s, g, place(c, s), args);
        if (jobs.len > 0) cli.err("  or as a batch job, on each node type the site file lists:\n", .{});
        for (jobs) |line| cli.err("  {s}\n", .{line});
        return 2;
    }
    const job_root = checkedJobRoot(c, s, "nothing was built");
    var p = place(c, s);
    // The process umask EESSI-extend gives the install, as `eb-local eb`
    // sets it: 002 for a project, so that every member can write the
    // directories builds share, and 077 for a user. What eb-local makes
    // there takes it too.
    _ = linux.syscall1(.umask, buildUmask(p));
    const refused = refusedTrees(c, s, true);
    for (refused) |t| if (storage.under(p.prefix, t.path))
        die("the install prefix {s} [{s}] is under {s}, {s}; nothing was built.\n  " ++ outlive ++ "; " ++ prefix_fix ++ ".", .{ p.prefix, prefixFrom(s, p), t.path, t.what });
    common.atomic.makedirs(p.prefix) catch die("installation prefix is not writable.", .{});
    {
        var zb: [sys.path_max:0]u8 = undefined;
        const zp = sys.z(&zb, p.prefix) catch die("installation prefix is not writable.", .{});
        if (linux.errno(linux.faccessat(linux.AT.FDCWD, zp.ptr, linux.W_OK | linux.X_OK, 0)) != .SUCCESS)
            die("installation prefix is not writable.", .{});
        var buf: [sys.path_max]u8 = undefined;
        p.prefix = a.dupe(u8, fsx.realpath(fsx.cwd, p.prefix, &buf) catch die("cannot resolve installation prefix.", .{})) catch oom();
    }
    const d = durableDirs(c, p.prefix, "nothing was built");
    // The trees a build writes below the prefix must not lead onto refused
    // storage either, through a symbolic link made later.
    for ([_][]const u8{ "versions", ".eb-local" }) |sub| {
        const path = std.fs.path.join(a, &.{ p.prefix, sub }) catch oom();
        const resolved = storage.canonical(a, path, c.cwd) catch oom();
        for (refused) |t| if (storage.under(resolved, t.path))
            die("{s} leads to {s}, under {s}, {s}; nothing was built.\n  " ++ outlive ++ ": replace the symbolic link in {s} with a directory, or " ++ prefix_fix ++ ".", .{ path, resolved, t.path, t.what, path });
    }

    {
        var shown: std.ArrayList(u8) = .empty;
        shown.appendSlice(a, replay(a, "--explain", s, g, p.prefix, &.{})) catch oom();
        for (args) |x| shown.print(a, " {s}", .{q(a, x)}) catch oom();
        say("eb-local: what this runs: eb-local {s}", .{shown.items});
    }

    // Secrets before the workspace and the build, so a missing one stops
    // the build with nothing but the installation directory made.
    var failure: secrets.Failure = .{};
    const wanted = config.buildSecrets(a, s) catch oom();
    const values = secrets.resolve(a, wanted, c.env, c.envp, nimvaultOf(s), &failure) catch |e| switch (e) {
        error.Unavailable => die("{s}", .{failure.message}),
        error.OutOfMemory => oom(),
    };
    for (values) |v| if (v.value.len < secrets.min_redacted_len)
        warn("secret {s} is shorter than {d} bytes and is not removed from logs", .{ v.name, secrets.min_redacted_len });

    const work = storage.makeWorkspace(a, job_root) catch |e| workspaceFailed(a, job_root, e);
    for ([_][]const u8{ "build", "tmp", "cache", "cargo", "source-index" }) |sub|
        common.atomic.makedirs(std.fs.path.join(a, &.{ work, sub }) catch oom()) catch |e| workspaceFailed(a, job_root, e);
    common.atomic.makedirs(d.sources) catch die("cannot create {s}", .{d.sources});
    common.atomic.makedirs(d.logs) catch die("cannot create {s}", .{d.logs});
    if (values.len > 0) {
        // Logs may hold a secret until they are cleaned after the build.
        var zb: [sys.path_max:0]u8 = undefined;
        const zl = sys.z(&zb, d.logs) catch die("cannot use {s}", .{d.logs});
        if (linux.errno(linux.fchmodat(linux.AT.FDCWD, zl.ptr, 0o700)) != .SUCCESS)
            die("cannot make {s} private before a build with secrets", .{d.logs});
    }
    const started: i64 = nowSecs();

    for (leftover_vars) |v| if (c.env.get(v)) |val| {
        if (ownInstallVar(c, s, p, v, val) == null)
            warn("{s}={s} is set in this shell; this build clears it, but EESSI-extend or eb run by hand would use it", .{ v, q(a, val) });
    };
    var env = c.env.clone(a) catch oom();
    for (install_vars) |v| _ = env.swapRemove(v);
    _ = env.swapRemove("EB_LOCAL_SITE_TOOLCHAINS");
    for (shell_startup) |name| _ = env.swapRemove(name);
    var dropped_loader = false;
    for (host_loader) |name| {
        if (env.swapRemove(name)) dropped_loader = true;
    }
    if (dropped_loader) {
        warn("LD_LIBRARY_PATH, LD_PRELOAD or LD_AUDIT was set; a build does not pass them to eb,", .{});
        cli.err("  because they mix host libraries into the toolchain.\n", .{});
    }
    if (s.site_toolchains.value.len > 0)
        env.put("EB_LOCAL_SITE_TOOLCHAINS", config.toolchainsJson(a, s.site_toolchains.value) catch oom()) catch oom();
    for (buildVariables(a, work, d)) |kv| env.put(kv[0], kv[1]) catch oom();
    for (s.eessi.items) |v| env.put(v.name, v.value) catch oom();
    for (values) |v| env.put(v.name, v.value) catch oom();

    // The guard stays until the logs are clean: a signal stops the build, but
    // eb-local first waits for EasyBuild, which writes them, to exit.
    const guard = Guard.hold();
    const ran = guard.run(a, buildCommand(a, c, s, p, args), envpOf(a, &env));
    const rc: u8 = if (guard.received() != null) 1 else switch (ran) {
        .exit => |code| code,
        .signal => 1,
    };

    if (values.len > 0) {
        var report: secrets.RedactReport = .{};
        const tools: secrets.Tools = .{ .path = c.env.get("PATH") orelse "/usr/bin:/bin", .envp = c.envp };
        secrets.redactTree(a, d.logs, started, values, .all, tools, &report) catch |e| warn("cannot check the logs for secrets ({s})", .{@errorName(e)});
        // EasyBuild keeps a copy of its log in each installation's easybuild/.
        const versions = std.fs.path.join(a, &.{ p.prefix, "versions" }) catch oom();
        secrets.redactTree(a, versions, started, values, .easybuild_dirs, tools, &report) catch |e| warn("cannot check the installation logs for secrets ({s})", .{@errorName(e)});
        for (report.too_deep.items) |f| warn("{s} is too deep to check for secret values; inspect it before sharing", .{f});
        if (report.files > 0) say("eb-local: removed secret values from {d} log file(s)", .{report.files});
        for (report.too_large.items) |f| warn("{s} is too large to check for secret values; inspect it before sharing", .{f});
        for (report.unchecked.items) |f| warn("cannot check {s} for secret values ({s}); inspect it before sharing", .{ f.path, f.why });
        for (report.unchanged.items) |f| warn("cannot remove secret values from {s} ({s}); remove them before sharing", .{ f.path, f.why });
    }

    const keep = std.mem.eql(u8, c.env.get("EB_LOCAL_KEEP_WORK") orelse "", "1");
    if (rc == 0 and !keep) {
        if (storage.ownWorkspace(job_root, work, callerUid(c))) storage.removeTree(a, work) catch |e|
            warn("cannot remove {s} ({s}); it goes when the allocation ends", .{ work, @errorName(e) });
    } else {
        warn("build workspace kept at {s}; it goes when the allocation ends,", .{work});
        cli.err("  or now with: eb-local clean --workspaces --no-logs\n", .{});
    }
    if (rc == 0) {
        say("", .{});
        say("eb-local: done. To use the modules in a new shell or job:", .{});
        say("  eval \"$(eb-local {s})\"", .{replay(a, "env", s, g, p.prefix, &.{})});
    }
    const ended: Run = if (guard.received()) |sig| .{ .signal = sig } else ran;
    guard.release();
    return stop(ended);
}

// ---- list -----------------------------------------------------------------

/// Each installation tree EESSI-extend made below PATH: one per EESSI version
/// and CPU target, holding software/ and modules/all/. Symbolic links are not
/// followed.
fn findTrees(c: Ctx, path: []const u8, out: *std.ArrayList([]const u8), depth: usize) void {
    if (depth > 12) return;
    const fd = fsx.openDir(fsx.cwd, path, false) catch return;
    defer sys.close(fd);
    if (isDirAt(fd, "software") and isDirAt(fd, "modules")) {
        out.append(c.a, path) catch oom();
        return;
    }
    var it = fsx.DirIter.init(c.a, fd) catch return;
    while (it.next() catch null) |e| {
        if (!isDirAt(fd, e.name)) continue;
        findTrees(c, std.fs.path.join(c.a, &.{ path, e.name }) catch oom(), out, depth + 1);
    }
}

/// The CPU target a tree is for: what follows software/linux/ in its path.
fn treeTarget(tree: []const u8) []const u8 {
    const key = "/software/linux/";
    const i = std.mem.lastIndexOf(u8, tree, key) orelse return tree;
    return tree[i + key.len ..];
}

/// The EESSI version a tree is for: the directory below versions/.
fn treeVersion(versions: []const u8, tree: []const u8) []const u8 {
    if (tree.len <= versions.len + 1) return "";
    const rest = tree[versions.len + 1 ..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
}

/// NAME/VERSION of every module file in a tree's modules/all.
fn treeModules(c: Ctx, tree: []const u8, out: *std.ArrayList([]const u8)) void {
    const all = std.fs.path.join(c.a, &.{ tree, "modules", "all" }) catch oom();
    const fd = fsx.openDir(fsx.cwd, all, false) catch return;
    defer sys.close(fd);
    var names = fsx.DirIter.init(c.a, fd) catch return;
    while (names.next() catch null) |n| {
        if (n.name.len == 0 or n.name[0] == '.' or !isDirAt(fd, n.name)) continue;
        const name = c.a.dupe(u8, n.name) catch oom();
        const nfd = fsx.openDir(fd, name, false) catch continue;
        defer sys.close(nfd);
        var files = fsx.DirIter.init(c.a, nfd) catch continue;
        while (files.next() catch null) |f| {
            if (f.name.len == 0 or f.name[0] == '.' or !std.mem.endsWith(u8, f.name, ".lua")) continue;
            const st = fsx.statAt(nfd, f.name, false) catch continue;
            if (!st.isReg()) continue;
            out.append(c.a, str(c.a, "{s}/{s}", .{ name, f.name[0 .. f.name.len - 4] })) catch oom();
        }
    }
}

const Listed = struct {
    module: []const u8,
    at: std.ArrayList(usize) = .empty,
};

fn listedLess(_: void, x: Listed, y: Listed) bool {
    return std.mem.lessThan(u8, x.module, y.module);
}

fn matchesFilter(module: []const u8, filters: []const []const u8) bool {
    if (filters.len == 0) return true;
    for (filters) |f| {
        if (std.mem.eql(u8, module, f)) return true;
        if (module.len > f.len and std.mem.startsWith(u8, module, f) and module[f.len] == '/') return true;
    }
    return false;
}

/// What is installed in the prefix, for which CPU targets, and what the
/// target of this node lacks.
fn cmdList(c: Ctx, s: config.Settings, filters: []const []const u8) u8 {
    const a = c.a;
    const p = place(c, s);
    const versions = std.fs.path.join(a, &.{ p.prefix, "versions" }) catch oom();
    var trees: std.ArrayList([]const u8) = .empty;
    if (literalPath(c, versions)) findTrees(c, versions, &trees, 0);
    std.mem.sort([]const u8, trees.items, {}, lessThanStr);

    var several_versions = false;
    for (trees.items) |t| {
        if (!std.mem.eql(u8, treeVersion(versions, t), treeVersion(versions, trees.items[0]))) several_versions = true;
    }
    // A column for each tree, named by the last part of its target unless
    // two trees would share that name.
    var labels: std.ArrayList([]const u8) = .empty;
    for (trees.items) |t| {
        const target = treeTarget(t);
        const short = std.fs.path.basename(target);
        var clash = false;
        for (trees.items) |u| {
            if (u.ptr != t.ptr and std.mem.eql(u8, std.fs.path.basename(treeTarget(u)), short)) clash = true;
        }
        const base = if (clash) target else short;
        labels.append(a, if (several_versions) str(a, "{s}:{s}", .{ treeVersion(versions, t), base }) else base) catch oom();
    }

    var rows: std.ArrayList(Listed) = .empty;
    for (trees.items, 0..) |t, ti| {
        var mods: std.ArrayList([]const u8) = .empty;
        treeModules(c, t, &mods);
        for (mods.items) |m| {
            if (!matchesFilter(m, filters)) continue;
            const row = for (rows.items) |*r| {
                if (std.mem.eql(u8, r.module, m)) break r;
            } else blk: {
                rows.append(a, .{ .module = m }) catch oom();
                break :blk &rows.items[rows.items.len - 1];
            };
            row.at.append(a, ti) catch oom();
        }
    }
    std.mem.sort(Listed, rows.items, {}, listedLess);

    var out: std.ArrayList(u8) = .empty;
    const add = struct {
        fn f(al: Allocator, o: *std.ArrayList(u8), text: []const u8) void {
            o.appendSlice(al, text) catch oom();
        }
    }.f;
    if (trees.items.len == 0 or rows.items.len == 0) {
        add(a, &out, str(a, "Nothing{s} is installed in {s}.\n", .{ if (filters.len > 0) " that matches" else "", p.prefix }));
        cli.put(1, out.items);
        return 0;
    }
    // This node's target, when EESSI is loaded.
    const here_target = nonEmpty(c.env.get("EESSI_SOFTWARE_SUBDIR"));
    const here_version = nonEmpty(c.env.get("EESSI_VERSION"));
    var here: ?usize = null;
    if (here_target) |ht| for (trees.items, 0..) |t, ti| {
        if (!std.mem.eql(u8, treeTarget(t), ht)) continue;
        if (here_version) |hv| if (!std.mem.eql(u8, treeVersion(versions, t), hv)) continue;
        here = ti;
    };

    var width: usize = "MODULE".len;
    for (rows.items) |r| width = @max(width, r.module.len);
    add(a, &out, str(a, "{s}: {d} module(s) for {d} CPU target(s)\n", .{ p.prefix, rows.items.len, trees.items.len }));
    add(a, &out, "MODULE");
    for (0..width - "MODULE".len + 2) |_| add(a, &out, " ");
    for (labels.items, 0..) |l, li| add(a, &out, str(a, "{s}{s}  ", .{ l, if (here != null and here.? == li) "*" else "" }));
    while (out.items[out.items.len - 1] == ' ') out.items.len -= 1;
    add(a, &out, "\n");
    for (rows.items) |r| {
        add(a, &out, r.module);
        for (0..width - r.module.len + 2) |_| add(a, &out, " ");
        for (labels.items, 0..) |l, li| {
            const has = std.mem.indexOfScalar(usize, r.at.items, li) != null;
            add(a, &out, if (has) "x" else "-");
            const cell = l.len + @as(usize, if (here != null and here.? == li) 1 else 0);
            for (0..cell + 1) |_| add(a, &out, " ");
        }
        // No trailing blanks on a row.
        while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
        add(a, &out, "\n");
    }
    if (here) |hi| {
        var missing: std.ArrayList([]const u8) = .empty;
        for (rows.items) |r| if (std.mem.indexOfScalar(usize, r.at.items, hi) == null) missing.append(a, r.module) catch oom();
        if (missing.items.len == 0) {
            add(a, &out, str(a, "Every module listed is built for this node's target, {s} (*).\n", .{here_target.?}));
        } else {
            add(a, &out, str(a, "Not built for this node's target, {s} (*): {s}.\n", .{ here_target.?, std.mem.join(a, ", ", missing.items) catch oom() }));
            add(a, &out, "Build them in an allocation on this node type; each target needs its own build.\n");
        }
    } else if (here_target) |ht| {
        add(a, &out, str(a, "Nothing is built for this node's target, {s}, yet; build in an allocation on this node type.\n", .{ht}));
    } else {
        add(a, &out, "Load EESSI (eval \"$(eb-local env)\") to see what this node's CPU target lacks.\n");
    }
    cli.put(1, out.items);
    return 0;
}

// ---- doctor ---------------------------------------------------------------

fn note(a: Allocator, out: *std.ArrayList(u8), kind: []const u8, comptime fmt: []const u8, args: anytype) void {
    out.appendSlice(a, kind) catch oom();
    out.appendSlice(a, " ") catch oom();
    out.appendSlice(a, str(a, fmt, args)) catch oom();
    out.appendSlice(a, "\n") catch oom();
}

/// Everything about this shell, this node and the configuration that would
/// make a build, `eb-local eb` or a module load go wrong, one line each: ok,
/// info, warn or FAIL. Changes nothing; exits 1 when a line says FAIL. A
/// build needs a site file and `eb-local eb` does not, so without one what
/// stops `eb-local eb` is a FAIL, and with one what stops a build is.
fn cmdDoctor(c: Ctx, s: config.Settings, g: Global) u8 {
    const a = c.a;
    var out: std.ArrayList(u8) = .empty;
    var failed = false;
    note(a, &out, "ok  ", "eb-local {s}", .{version});

    // Configuration.
    const sources = configSources(c, g);
    for (sources) |src| note(a, &out, "ok  ", "{s} file {s}", .{ @tagName(src.layer), src.path });
    const site = s.node_local_root.value.len > 0;
    if (site) {
        note(a, &out, "ok  ", "builds use the allocation's own {s} mount {s}/{s}", .{ s.node_local_fstype.value, s.node_local_root.value, s.node_local_mount.value });
    } else {
        note(a, &out, "info", "no site file sets storage.node_local_root: `eb-local RECIPE` needs a site file; `eb-local eb` does not. `eb-local site install` writes one beside the program", .{});
    }

    // A build reads each secret it gets before it starts, so one of those
    // that cannot be read stops it, whether or not eb uses it. The values
    // are read as a build reads them and never shown.
    for (s.secrets.items) |sec| {
        const gets = config.buildGets(s, sec.name);
        var f: secrets.Failure = .{};
        if (secrets.resolve(a, &.{sec}, c.env, c.envp, nimvaultOf(s), &f)) |values| {
            if (values[0].value.len < secrets.min_redacted_len) {
                note(a, &out, "warn", "secret {s} from {s} is shorter than {d} bytes and is not removed from logs", .{ sec.name, sec.source, secrets.min_redacted_len });
            } else if (gets) {
                note(a, &out, "ok  ", "secret {s} can be read from {s}", .{ sec.name, sec.source });
            } else note(a, &out, "info", "secret {s} can be read from {s}; builds do not get it, as build.secrets [{s}] does not name it", .{ sec.name, sec.source, s.build_secrets.from });
        } else |e| switch (e) {
            error.Unavailable => if (!gets) {
                note(a, &out, "warn", "{s} [{s}]; builds do not read it, as build.secrets [{s}] does not name it, but one that names it stops there", .{ f.message, sec.from, s.build_secrets.from });
            } else {
                if (s.build_secrets.value == null) {
                    note(a, &out, if (site) "FAIL" else "warn", "{s} [{s}]; every build stops there, whether or not it uses {s}. " ++
                        "Name in build.secrets the secrets builds need, or in EB_LOCAL_BUILD_SECRETS those one build needs", .{ f.message, sec.from, sec.name });
                } else note(a, &out, if (site) "FAIL" else "warn", "{s} [{s}]; every build stops there, as build.secrets [{s}] names {s}", .{ f.message, sec.from, s.build_secrets.from, sec.name });
                if (site) failed = true;
            },
            error.OutOfMemory => oom(),
        }
    }

    // Where installs go.
    const p = locate(c, s);
    note(a, &out, "ok  ", "installs go to {s}: a {s} install, prefix from {s}", .{ p.prefix, if (p.project) "project" else "user", if (p.project) s.project.from else s.prefix.from });
    for (refusedTrees(c, s, false)) |t| if (t.path.len > 0 and storage.under(p.prefix, t.path)) {
        note(a, &out, "FAIL", "the install prefix {s} [{s}] is under {s}, {s}; builds refuse it. " ++ outlive ++ "; " ++ prefix_fix, .{ p.prefix, prefixFrom(s, p), t.path, t.what });
        failed = true;
    };
    if (fsx.statAt(fsx.cwd, p.prefix, true)) |st| {
        var zb: [sys.path_max:0]u8 = undefined;
        const writable = if (sys.z(&zb, p.prefix)) |zp|
            linux.errno(linux.faccessat(linux.AT.FDCWD, zp.ptr, linux.W_OK | linux.X_OK, 0)) == .SUCCESS
        else |_|
            false;
        if (!st.isDir()) {
            note(a, &out, "FAIL", "{s} is not a directory", .{p.prefix});
            failed = true;
        } else if (!writable) {
            note(a, &out, "FAIL", "you cannot write to {s}", .{p.prefix});
            failed = true;
        }
        if (p.project and st.isDir()) {
            if (st.mode & 0o002 != 0) {
                note(a, &out, "FAIL", "project directory {s} is writable by others; anyone could add modules the group loads. chmod o-w it", .{p.prefix});
                failed = true;
            }
            if (st.mode & 0o2000 == 0) note(a, &out, "warn", "project directory {s} has no setgid bit, so installs keep the installer's group; chmod g+s it", .{p.prefix});
        }
    } else |_| {
        if (p.project) {
            note(a, &out, "FAIL", "project directory {s} does not exist; the project owner creates it with the project group and chmod 2770", .{p.prefix});
            failed = true;
        } else note(a, &out, "info", "{s} does not exist yet; the first build creates it", .{p.prefix});
    }

    // What this shell carries.
    var leftovers: usize = 0;
    for (install_vars) |v| if (c.env.get(v)) |val| {
        if (ownInstallVar(c, s, p, v, val)) |why| {
            note(a, &out, "ok  ", "{s} {s}", .{ v, why });
            continue;
        }
        leftovers += 1;
        note(a, &out, "warn", "{s}={s} is set in this shell; eb-local builds clear it, but EESSI-extend or eb run by hand would use it", .{ v, val });
    };
    if (leftovers == 0) note(a, &out, "ok  ", "no other EESSI or EasyBuild install variable is set in this shell", .{});

    // What eb-local eb needs: the EESSI init, and at most one install variable.
    const eb_stop = if (site) "warn" else "FAIL";
    const init = extend.initPath(a, c.env) catch oom();
    if (fsx.statAt(fsx.cwd, init, true)) |_| {
        note(a, &out, "ok  ", "`eb-local eb` sources {s}", .{init});
    } else |_| {
        note(a, &out, eb_stop, "{s} is missing, so `eb-local eb` stops; set EESSI_CVMFS_REPO or EESSI_VERSION if EESSI is elsewhere", .{init});
        if (!site) failed = true;
    }
    if (extend.select(c.env)) |sel| {
        const name = extend.variable(sel.mode);
        if (c.env.get(name)) |v| {
            note(a, &out, "ok  ", "`eb-local eb` makes a {s} install: {s}={s}", .{ @tagName(sel.mode), name, q(a, v) });
        } else note(a, &out, "ok  ", "`eb-local eb` makes a user install into the module's default, $HOME/eessi", .{});
    } else |_| {
        note(a, &out, eb_stop, "more than one of EESSI_USER_INSTALL, EESSI_PROJECT_INSTALL, EESSI_SITE_INSTALL, EESSI_CVMFS_INSTALL is set, so `eb-local eb` refuses to run", .{});
        if (!site) failed = true;
    }
    for ([_][]const u8{ "LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT" }) |v| if (nonEmpty(c.env.get(v)) != null)
        note(a, &out, "warn", "{s} is set; programs built with eb-local dev do not need it, and it can mix host libraries into EESSI's", .{v});

    // The allocation.
    if (nonEmpty(c.env.get("SLURM_JOB_ID"))) |job| {
        if (s.node_local_root.value.len > 0) {
            var r: storage.Refusal = .{};
            if (storage.jobRoot(a, nodeLocal(s), job, userName(c, s, "doctor checks no further"), mountinfoText(c), callerUid(c), &r)) |jr| {
                note(a, &out, "ok  ", "Slurm job {s}: build space {s}", .{ job, jr.path });
            } else |e| switch (e) {
                error.Refused => {
                    note(a, &out, "FAIL", "Slurm job {s}: {s}; builds refuse it. {s}", .{ job, r.message, r.fix });
                    failed = true;
                },
                error.OutOfMemory => oom(),
            }
        }
    } else {
        note(a, &out, "info", "not in a Slurm job; builds need one on the node type that will run the software{s}{s}", .{ if (s.allocation_hint.value.len > 0) ", for example: " else "", s.allocation_hint.value });
    }

    // Modules and the stack.
    if (nonEmpty(c.env.get("EESSI_SOFTWARE_SUBDIR"))) |sub| {
        note(a, &out, "ok  ", "EESSI {s} is loaded for {s}", .{ c.env.get("EESSI_VERSION") orelse "?", sub });
    } else note(a, &out, "info", "EESSI is not loaded in this shell; eval \"$(eb-local env)\" loads it with your modules", .{});
    noteGuard(c, &out);
    const versions = std.fs.path.join(a, &.{ p.prefix, "versions" }) catch oom();
    if (fsx.statAt(fsx.cwd, versions, false)) |_| {
        const mp = c.env.get("MODULEPATH") orelse "";
        var seen = false;
        var it = std.mem.splitScalar(u8, mp, ':');
        while (it.next()) |d| if (storage.under(d, p.prefix)) {
            seen = true;
        };
        if (seen) note(a, &out, "ok  ", "your modules are on MODULEPATH", .{}) else note(a, &out, "warn", "your modules are not on MODULEPATH in this shell; eval \"$(eb-local env)\"", .{});
    } else |_| {}
    if (nonEmpty(c.env.get("LMOD_CMD")) == null and nonEmpty(c.env.get("MODULESHOME")) == null) {
        const inits = lmodInits(a, c.env);
        for (inits) |file| {
            if (readable(file)) {
                note(a, &out, "info", "no module command in this shell; builds, env and dev source {s}", .{file});
                break;
            }
        } else {
            note(a, &out, if (site) "FAIL" else "warn", "no module command in this shell, and none of {s}, {s} or {s} can be read; builds stop there, and the module commands env and dev print do not run", .{ inits[0], inits[1], inits[2] });
            if (site) failed = true;
        }
    }
    if (proc.which(a, "rtrash", c.env.get("PATH") orelse "") catch null) |_| {
        note(a, &out, "ok  ", "rtrash is on PATH: clean and uninstall move files to the trash", .{});
    } else note(a, &out, "warn", "rtrash is not on PATH: clean and uninstall remove nothing unless given --delete", .{});

    out.appendSlice(a, if (site)
        (if (failed) "\nSomething above says FAIL; builds stop there.\n" else "\nNothing above stops a build.\n")
    else if (failed)
        "\nSomething above says FAIL; `eb-local eb` stops there, and `eb-local RECIPE` needs a site file.\n"
    else
        "\nNothing above stops `eb-local eb`; `eb-local RECIPE` needs a site file.\n") catch oom();
    cli.put(1, out.items);
    return if (failed) 1 else 0;
}

// ---- submit ---------------------------------------------------------------

const SubmitOpts = struct {
    /// Comma-separated target names; empty means every configured target.
    on: []const u8 = "",
    /// Print the scripts and sbatch commands; create and submit nothing.
    print: bool = false,
};

/// A job name part: letters, digits, '.', '-' and '_' kept, the rest '_'.
fn jobNamePart(a: Allocator, s: []const u8) []const u8 {
    const out = a.dupe(u8, s[0..@min(s.len, 64)]) catch oom();
    for (out) |*ch| if (!(std.ascii.isAlphanumeric(ch.*) or ch.* == '.' or ch.* == '-' or ch.* == '_')) {
        ch.* = '_';
    };
    return out;
}

/// The command a batch job runs to build: this program, the options that
/// chose this configuration, and the recipe with its eb options as given.
fn jobCommand(c: Ctx, s: config.Settings, g: Global, p: Place, args: []const []const u8) []const u8 {
    const a = c.a;
    var self_buf: [sys.path_max]u8 = undefined;
    const self = selfExe(&self_buf) orelse die("cannot find this program's own path", .{});
    var line: std.ArrayList([]const u8) = .empty;
    line.appendSlice(a, &.{ "exec", q(a, self) }) catch oom();
    if (g.config_file) |f| line.appendSlice(a, &.{ "--config", q(a, storage.canonical(a, f, c.cwd) catch oom()) }) catch oom();
    if (s.profile) |pr| line.appendSlice(a, &.{ "--profile", q(a, pr) }) catch oom();
    if (p.project) line.appendSlice(a, &.{ "--project", q(a, p.prefix) }) catch oom();
    for (args) |x| line.append(a, q(a, x)) catch oom();
    return std.mem.join(a, " ", line.items) catch oom();
}

/// An sbatch line for each node type the site file lists, which runs the
/// build as a batch job there. The job runs, and writes its output as
/// JOBNAME-JOBID.out, in the directory eb-local runs in, as a job of submit
/// runs there.
fn batchLines(c: Ctx, s: config.Settings, g: Global, p: Place, args: []const []const u8) []const []const u8 {
    const a = c.a;
    const types = nodeTypes(s);
    if (types.len == 0) return &.{};
    const wrap = q(a, jobCommand(c, s, g, p, args));
    const recipe = jobNamePart(a, std.fs.path.basename(args[0]));
    var lines: std.ArrayList([]const u8) = .empty;
    const dir = q(a, c.cwd);
    for (types) |t| lines.append(a, str(a, "sbatch {s} --job-name=eb-local-{s}-{s} --chdir={s} --output=%x-%j.out --wrap={s}", .{ t.sbatch, t.name, recipe, dir, wrap })) catch oom();
    return lines.items;
}

/// The node types the site file lists, with a warning where it lists them
/// under their old name.
fn nodeTypes(s: config.Settings) []const config.NodeType {
    if (s.node_types_old_key) |where|
        warn("{s}: [build.targets] is now [build.node_types]; eb-local reads the old name until 4.0.0", .{where});
    return s.node_types.value;
}

/// One batch job per configured node type, each running this eb-local with
/// the same recipe, options and configuration inside its own allocation, so
/// a module is built for every CPU target the site has.
fn cmdSubmit(c: Ctx, s: config.Settings, g: Global, args: []const []const u8, o: SubmitOpts) u8 {
    const a = c.a;
    warn("submit is deprecated and is removed in 4.0.0; eb-local --explain RECIPE prints an sbatch line for each node type", .{});
    if (args.len == 0) die("submit needs an easyconfig: eb-local submit [--on NAME,...] [--print] RECIPE [eb options]", .{});
    const all = nodeTypes(s);
    if (all.len == 0) die("no build.node_types in the site file, so there is nothing to submit to; build inside an allocation with eb-local RECIPE", .{});
    var chosen: std.ArrayList(config.NodeType) = .empty;
    if (o.on.len == 0) {
        chosen.appendSlice(a, all) catch oom();
    } else {
        var names = std.mem.splitScalar(u8, o.on, ',');
        while (names.next()) |n| {
            const t = for (all) |cand| {
                if (std.mem.eql(u8, cand.name, n)) break cand;
            } else {
                var known: std.ArrayList([]const u8) = .empty;
                for (all) |k| known.append(a, k.name) catch oom();
                die("--on {s}: no such node type; the site has {s}", .{ n, std.mem.join(a, ", ", known.items) catch oom() });
            };
            chosen.append(a, t) catch oom();
        }
    }
    const p = place(c, s);
    const sbatch = (proc.which(a, "sbatch", c.env.get("PATH") orelse "") catch null) orelse
        if (o.print) "sbatch" else die("sbatch is not on PATH", .{});
    const command = jobCommand(c, s, g, p, args);

    const root = std.fs.path.join(a, &.{ p.prefix, ".eb-local" }) catch oom();
    const jobs = std.fs.path.join(a, &.{ root, "jobs" }) catch oom();
    const logs = std.fs.path.join(a, &.{ root, "logs" }) catch oom();
    if (!o.print) {
        common.atomic.makedirs(jobs) catch die("cannot create {s}", .{jobs});
        common.atomic.makedirs(logs) catch die("cannot create {s}", .{logs});
    }
    const recipe = jobNamePart(a, std.fs.path.basename(args[0]));
    const stamp = nowSecs();
    var failed = false;
    for (chosen.items) |t| {
        const script = str(a,
            \\#!/bin/bash
            \\#SBATCH --job-name=eb-local-{s}-{s}
            \\#SBATCH --output={s}/submit-{s}-%j.out
            \\#SBATCH --chdir={s}
            \\{s}
            \\
        , .{ t.name, recipe, logs, t.name, c.cwd, command });
        const path = std.fs.path.join(a, &.{ jobs, str(a, "{d}-{s}-{s}.sh", .{ stamp, t.name, recipe }) }) catch oom();
        var argv: std.ArrayList([]const u8) = .empty;
        argv.append(a, sbatch) catch oom();
        var words = std.mem.tokenizeScalar(u8, t.sbatch, ' ');
        while (words.next()) |w| argv.append(a, w) catch oom();
        argv.append(a, path) catch oom();
        if (o.print) {
            say("# {s}: {s}", .{ t.name, std.mem.join(a, " ", argv.items) catch oom() });
            cli.put(1, script);
            continue;
        }
        var why: common.atomic.Why = .{};
        defer why.deinit(a);
        common.atomic.atomicWrite(a, path, script, .{ .mode = 0o700 }, &why) catch die("cannot write {s}", .{path});
        say("eb-local: {s}:", .{t.name});
        switch (runAttached(a, argv.items, c.envp)) {
            .exit => |code| if (code != 0) {
                warn("sbatch refused the {s} job (exit {d})", .{ t.name, code });
                failed = true;
            },
            .signal => failed = true,
        }
    }
    if (o.print) return 0;
    say("", .{});
    say("eb-local: each job writes {s}/submit-TARGET-JOBID.out; eb-local list shows the result per target.", .{logs});
    return if (failed) 1 else 0;
}

// ---- uninstall ------------------------------------------------------------

const UninstallOpts = struct {
    dry_run: bool = false,
    delete: bool = false,
};

const Found = struct {
    installs: std.ArrayList([]const u8) = .empty,
    modules: std.ArrayList([]const u8) = .empty,
};

fn isDirAt(dir: sys.fd_t, name: []const u8) bool {
    const st = fsx.statAt(dir, name, false) catch return false;
    return st.isDir();
}

/// The path names itself: no component is a symbolic link.
fn literalPath(c: Ctx, path: []const u8) bool {
    var buf: [sys.path_max]u8 = undefined;
    const real = fsx.realpath(fsx.cwd, path, &buf) catch return false;
    _ = c;
    return std.mem.eql(u8, real, path);
}

/// Below `path`, never through a symbolic link, the target roots (a
/// directory holding both software/ and modules/, one per CPU target as
/// EESSI-extend lays them out), and in each, software/NAME/VERSION,
/// modules/all/NAME/VERSION.lua and the links to it from the other
/// modules/ directories. Installed software is never searched.
fn findInstalls(c: Ctx, path: []const u8, name: []const u8, ver: []const u8, found: *Found, depth: usize) void {
    if (depth > 12) return;
    const fd = fsx.openDir(fsx.cwd, path, false) catch return;
    defer sys.close(fd);
    if (isDirAt(fd, "software") and isDirAt(fd, "modules")) {
        const dir = std.fs.path.join(c.a, &.{ path, "software", name, ver }) catch oom();
        if (fsx.statAt(fsx.cwd, dir, false)) |st| {
            if (st.isDir() and literalPath(c, dir)) found.installs.append(c.a, dir) catch oom();
        } else |_| {}
        const file = std.fs.path.join(c.a, &.{ path, "modules", "all", name, str(c.a, "{s}.lua", .{ver}) }) catch oom();
        if (fsx.statAt(fsx.cwd, file, false)) |st| {
            if (st.isReg() and literalPath(c, file)) found.modules.append(c.a, file) catch oom();
        } else |_| {}
        findClassLinks(c, path, name, ver, file, found);
        return;
    }
    var it = fsx.DirIter.init(c.a, fd) catch return;
    while (it.next() catch null) |e| {
        const st = fsx.statAt(fd, e.name, false) catch continue;
        if (!st.isDir()) continue;
        findInstalls(c, std.fs.path.join(c.a, &.{ path, e.name }) catch oom(), name, ver, found, depth + 1);
    }
}

/// EasyBuild links modules/<class>/NAME/VERSION.lua to `file`, the module
/// file in modules/all, by its absolute path. A link whose target names
/// `file`, or that leads to it, goes with it, and so does one an earlier
/// uninstall left dangling; a link to anything else stays.
fn findClassLinks(c: Ctx, root: []const u8, name: []const u8, ver: []const u8, file: []const u8, found: *Found) void {
    const modules = std.fs.path.join(c.a, &.{ root, "modules" }) catch oom();
    const fd = fsx.openDir(fsx.cwd, modules, false) catch return;
    defer sys.close(fd);
    var it = fsx.DirIter.init(c.a, fd) catch return;
    while (it.next() catch null) |e| {
        if (std.mem.eql(u8, e.name, "all") or !isDirAt(fd, e.name)) continue;
        const parent = std.fs.path.join(c.a, &.{ modules, e.name, name }) catch oom();
        const link = std.fs.path.join(c.a, &.{ parent, str(c.a, "{s}.lua", .{ver}) }) catch oom();
        const st = fsx.statAt(fsx.cwd, link, false) catch continue;
        if (!st.isLink() or !literalPath(c, parent)) continue;
        var zb: [sys.path_max:0]u8 = undefined;
        var buf: [sys.path_max]u8 = undefined;
        const n: isize = @bitCast(linux.readlinkat(linux.AT.FDCWD, (sys.z(&zb, link) catch continue).ptr, &buf, buf.len));
        if (n <= 0 or n >= buf.len) continue;
        const named = std.fs.path.resolveAllocPosix(c.a, &.{ parent, buf[0..@intCast(n)] }) catch oom();
        var real: [sys.path_max]u8 = undefined;
        const leads = fsx.realpath(fsx.cwd, link, &real) catch "";
        if (std.mem.eql(u8, named, file) or std.mem.eql(u8, leads, file)) found.modules.append(c.a, link) catch oom();
    }
}

/// Below `path`, in each target root's modules/all, the module files that
/// load one of `wanted` (NAME/VERSION), other than those in `skip`. A file
/// reached through a symbolic link is not read.
fn findDependents(c: Ctx, path: []const u8, wanted: []const []const u8, skip: []const []const u8, out: *std.ArrayList([]const u8), depth: usize) void {
    if (depth > 12) return;
    const fd = fsx.openDir(fsx.cwd, path, false) catch return;
    defer sys.close(fd);
    if (isDirAt(fd, "software") and isDirAt(fd, "modules")) {
        const all = std.fs.path.join(c.a, &.{ path, "modules", "all" }) catch oom();
        const afd = fsx.openDir(fsx.cwd, all, false) catch return;
        defer sys.close(afd);
        var names = fsx.DirIter.init(c.a, afd) catch return;
        while (names.next() catch null) |n| {
            const name = c.a.dupe(u8, n.name) catch oom();
            const nfd = fsx.openDir(afd, name, false) catch continue;
            defer sys.close(nfd);
            var files = fsx.DirIter.init(c.a, nfd) catch continue;
            while (files.next() catch null) |f| {
                if (!std.mem.endsWith(u8, f.name, ".lua")) continue;
                const file = std.fs.path.join(c.a, &.{ all, name, f.name }) catch oom();
                if (listed(skip, file)) continue;
                const opened = fsx.openRegular(nfd, f.name, false) catch continue;
                defer sys.close(opened.fd);
                const text = fsx.readAll(c.a, opened.fd, 1 << 20) catch continue;
                if (loadsAny(text, wanted)) out.append(c.a, file) catch oom();
            }
        }
        return;
    }
    var it = fsx.DirIter.init(c.a, fd) catch return;
    while (it.next() catch null) |e| {
        const st = fsx.statAt(fd, e.name, false) catch continue;
        if (!st.isDir()) continue;
        findDependents(c, std.fs.path.join(c.a, &.{ path, e.name }) catch oom(), wanted, skip, out, depth + 1);
    }
}

fn listed(xs: []const []const u8, x: []const u8) bool {
    for (xs) |y| if (std.mem.eql(u8, x, y)) return true;
    return false;
}

/// Whether a Lua module file loads one of `wanted`. EasyBuild writes a
/// dependency as depends_on("NAME/VERSION") or, guarded by isloaded,
/// load("NAME/VERSION"), one call to a line.
fn loadsAny(text: []const u8, wanted: []const []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        for ([_][]const u8{ "depends_on(\"", "load(\"" }) |call| {
            if (!std.mem.startsWith(u8, line, call)) continue;
            const rest = line[call.len..];
            const end = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
            if (listed(wanted, rest[0..end])) return true;
        }
    }
    return false;
}

test "loadsAny reads the dependency lines EasyBuild writes" {
    const lua =
        \\help([==[ load("GSL/2.8-GCC-15.2.0") in the help text ]==])
        \\depends_on("FFTW/3.3.10-GCC-15.2.0")
        \\if not ( isloaded("pigz/2.8-GCCcore-15.2.0") ) then
        \\    load("pigz/2.8-GCCcore-15.2.0")
        \\end
    ;
    try std.testing.expect(loadsAny(lua, &.{"FFTW/3.3.10-GCC-15.2.0"}));
    try std.testing.expect(loadsAny(lua, &.{"pigz/2.8-GCCcore-15.2.0"}));
    try std.testing.expect(!loadsAny(lua, &.{"GSL/2.8-GCC-15.2.0"}));
    try std.testing.expect(!loadsAny(lua, &.{"FFTW/3.3.10"}));
}

/// EasyBuild installs are read-only; the owner may make them writable again.
/// Only the directories, which rtrash needs writable to move a directory
/// and to empty the trash; the files keep their read-only modes, in the
/// trash too.
fn makeWritable(c: Ctx, path: []const u8, depth: usize) void {
    if (depth > 64) return;
    const st = fsx.statAt(fsx.cwd, path, false) catch return;
    if (!st.isDir() or st.uid != linux.getuid()) return;
    var zb: [sys.path_max:0]u8 = undefined;
    const zp = sys.z(&zb, path) catch return;
    _ = linux.fchmodat(linux.AT.FDCWD, zp.ptr, @intCast((st.mode & 0o7777) | 0o200));
    const fd = fsx.openDir(fsx.cwd, path, false) catch return;
    defer sys.close(fd);
    var it = fsx.DirIter.init(c.a, fd) catch return;
    while (it.next() catch null) |e| makeWritable(c, std.fs.path.join(c.a, &.{ path, e.name }) catch oom(), depth + 1);
}

/// Takes write permission from everyone, as EasyBuild does to an
/// installation (EESSI-extend sets EASYBUILD_READ_ONLY_INSTALLDIR); a
/// symbolic link is not followed.
fn makeReadOnly(c: Ctx, path: []const u8, depth: usize) void {
    if (depth > 64) return;
    const st = fsx.statAt(fsx.cwd, path, false) catch return;
    if (st.isLink() or st.uid != linux.getuid()) return;
    if (st.isDir()) {
        const fd = fsx.openDir(fsx.cwd, path, false) catch return;
        defer sys.close(fd);
        var it = fsx.DirIter.init(c.a, fd) catch return;
        while (it.next() catch null) |e| makeReadOnly(c, std.fs.path.join(c.a, &.{ path, e.name }) catch oom(), depth + 1);
    }
    var zb: [sys.path_max:0]u8 = undefined;
    const zp = sys.z(&zb, path) catch return;
    _ = linux.fchmodat(linux.AT.FDCWD, zp.ptr, @intCast(st.mode & 0o7555));
}

fn cmdUninstall(c: Ctx, s: config.Settings, modules: []const []const u8, o: UninstallOpts) u8 {
    const a = c.a;
    if (modules.len == 0) die("uninstall needs NAME/VERSION, as module avail shows it", .{});
    const p = place(c, s);
    const versions = std.fs.path.join(a, &.{ p.prefix, "versions" }) catch oom();
    if (fsx.statAt(fsx.cwd, versions, false)) |st| {
        if (st.isLink() or !literalPath(c, versions)) die("{s} is reached through a symbolic link; uninstall leaves it alone.", .{versions});
    } else |_| die("nothing is installed in {s}", .{p.prefix});
    var found: Found = .{};
    for (modules) |m| {
        var parts = std.mem.splitScalar(u8, m, '/');
        const name = parts.next().?;
        const ver = parts.next() orelse die("uninstall needs NAME/VERSION; '{s}' has no version", .{m});
        if (parts.next() != null) die("uninstall needs NAME/VERSION; '{s}' has more parts", .{m});
        const before = found.installs.items.len + found.modules.items.len;
        findInstalls(c, versions, name, ver, &found, 0);
        if (found.installs.items.len + found.modules.items.len == before) die("{s} is not installed in {s}", .{ m, p.prefix });
    }
    // A module another installed module loads stays, unless that one goes
    // in the same command; Lmod would otherwise fail to load the dependent.
    var dependents: std.ArrayList([]const u8) = .empty;
    findDependents(c, versions, modules, found.modules.items, &dependents, 0);
    if (dependents.items.len > 0) {
        warn("these installed modules load what you named; uninstall them in the same command, or keep it:", .{});
        for (dependents.items) |f| warn("  {s}", .{f});
        return 2;
    }
    for (found.installs.items) |d| {
        if (!storage.under(d, versions)) die("{s} is outside {s}", .{ d, versions });
        say("  {s}/", .{d});
    }
    for (found.modules.items) |f| say("  {s}", .{f});
    if (o.dry_run) {
        say("eb-local: dry run, nothing removed", .{});
        return 0;
    }
    var trash = s.trash.value;
    const rtrash = proc.which(a, "rtrash", c.env.get("PATH") orelse "") catch null;
    switch (trash) {
        .auto => trash = if (rtrash != null) .rtrash else .none,
        .rtrash => if (rtrash == null) die("clean.trash is rtrash, but rtrash is not on PATH.", .{}),
        .none => {},
    }
    if (trash != .rtrash and !o.delete) {
        warn("rtrash is not installed; nothing removed. Install rtrash, or pass --delete to delete for good.", .{});
        return 1;
    }
    for (found.installs.items) |d| makeWritable(c, d, 0);
    if (trash == .rtrash) {
        // rtrash put follows rm(1): a directory needs -r. The installations
        // go first, so a refusal leaves every module file in place.
        for ([_][]const []const u8{ found.installs.items, found.modules.items }) |list| {
            if (list.len == 0) continue;
            var argv: std.ArrayList([]const u8) = .empty;
            argv.appendSlice(a, &.{ rtrash.?, "put", "-r", "--" }) catch oom();
            argv.appendSlice(a, list) catch oom();
            const run = runAttached(a, argv.items, c.envp);
            switch (run) {
                .exit => |rc| if (rc != 0) die("rtrash put exited {d}; nothing after it was moved", .{rc}),
                .signal => return stop(run),
            }
        }
        say("eb-local: moved {d} installation(s) and {d} module file(s) to the trash (eb-local restore brings them back)", .{ found.installs.items.len, found.modules.items.len });
    } else {
        for (found.installs.items) |d| fsx.deleteTree(a, fsx.cwd, d) catch |e| die("cannot remove {s} ({s})", .{ d, @errorName(e) });
        for (found.modules.items) |f| sys.unlinkat(fsx.cwd, f, 0) catch |e| die("cannot remove {s} ({s})", .{ f, @errorName(e) });
        say("eb-local: deleted {d} installation(s) and {d} module file(s)", .{ found.installs.items.len, found.modules.items.len });
    }
    // The NAME directories they leave empty.
    for ([_][]const []const u8{ found.installs.items, found.modules.items }) |list| for (list) |x| {
        const parent = std.fs.path.dirname(x) orelse continue;
        sys.unlinkat(fsx.cwd, parent, linux.AT.REMOVEDIR) catch {};
    };
    return 0;
}

// ---- restore --------------------------------------------------------------

/// An entry of `rtrash list --json`.
const Trashed = struct { original: []const u8, trash_dir: []const u8 };

fn trashList(c: Ctx, rtrash: []const u8) []Trashed {
    const r = proc.run(c.a, rtrash, &.{ rtrash, "list", "--json" }, c.envp, .{ .stdout_limit = 64 << 20, .stderr_limit = 4096, .timeout_ms = 120_000 }) catch |e|
        die("cannot run rtrash list ({s})", .{@errorName(e)});
    if (r.term.code() != 0) die("rtrash list --json exited {d}: {s}", .{ r.term.code(), std.mem.trim(u8, r.stderr, " \n") });
    return std.json.parseFromSliceLeaky([]Trashed, c.a, r.stdout, .{ .ignore_unknown_fields = true }) catch
        die("cannot read what rtrash list --json printed", .{});
}

/// A directory holding both software/ and modules/, as findInstalls takes
/// a target root, named without a symbolic link.
fn targetRoot(c: Ctx, path: []const u8) bool {
    if (!literalPath(c, path)) return false;
    const fd = fsx.openDir(fsx.cwd, path, false) catch return false;
    defer sys.close(fd);
    return isDirAt(fd, "software") and isDirAt(fd, "modules");
}

/// Brings back from the trash what uninstall moved there, for every CPU
/// target, and makes each installation read-only again: rtrash restore
/// alone brings one back with the writable directories rtrash needs.
fn cmdRestore(c: Ctx, s: config.Settings, modules: []const []const u8, dry_run: bool) u8 {
    const a = c.a;
    if (modules.len == 0) die("restore needs NAME/VERSION, as uninstall took it", .{});
    const p = place(c, s);
    const versions = std.fs.path.join(a, &.{ p.prefix, "versions" }) catch oom();
    if (fsx.statAt(fsx.cwd, versions, false)) |st| {
        if (st.isLink() or !literalPath(c, versions)) die("{s} is reached through a symbolic link; restore leaves it alone.", .{versions});
    } else |_| die("nothing was installed in {s}", .{p.prefix});
    const rtrash = (proc.which(a, "rtrash", c.env.get("PATH") orelse "") catch null) orelse
        die("restore brings back what uninstall moved to the trash with rtrash, and rtrash is not on PATH.", .{});
    const entries = trashList(c, rtrash);
    // Installations, the module files in modules/all, and EasyBuild's links
    // to them from modules/<class>/, in the order they come back: nothing
    // is back before what it needs.
    var found = [_]std.ArrayList(Trashed){ .empty, .empty, .empty };
    for (modules, 0..) |m, idx| {
        if (listed(modules[0..idx], m)) continue;
        var parts = std.mem.splitScalar(u8, m, '/');
        const name = parts.next().?;
        const ver = parts.next() orelse die("restore needs NAME/VERSION; '{s}' has no version", .{m});
        if (parts.next() != null) die("restore needs NAME/VERSION; '{s}' has more parts", .{m});
        const install_tail = str(a, "/software/{s}/{s}", .{ name, ver });
        const module_tail = str(a, "/{s}/{s}.lua", .{ name, ver });
        const before = found[0].items.len + found[1].items.len + found[2].items.len;
        for (entries) |e| {
            var root: []const u8 = undefined;
            var kind: usize = 0;
            if (std.mem.endsWith(u8, e.original, install_tail)) {
                root = e.original[0 .. e.original.len - install_tail.len];
            } else if (std.mem.endsWith(u8, e.original, module_tail)) {
                const class = e.original[0 .. e.original.len - module_tail.len];
                const dir = std.fs.path.dirname(class) orelse continue;
                if (!std.mem.eql(u8, std.fs.path.basename(dir), "modules")) continue;
                root = std.fs.path.dirname(dir) orelse continue;
                kind = if (std.mem.eql(u8, std.fs.path.basename(class), "all")) 1 else 2;
            } else continue;
            if (storage.under(root, versions) and targetRoot(c, root)) found[kind].append(a, e) catch oom();
        }
        if (found[0].items.len + found[1].items.len + found[2].items.len == before) die("{s} is not in the trash for {s}", .{ m, p.prefix });
    }
    for (found) |list| for (list.items, 0..) |e, i| {
        for (list.items[i + 1 ..]) |o| if (std.mem.eql(u8, e.original, o.original))
            die("{s} is in the trash more than once; restore the one you want with: rtrash restore {s}", .{ e.original, q(a, e.original) });
        if (fsx.statAt(fsx.cwd, e.original, false)) |_| {
            die("{s} exists; restore replaces nothing, so nothing was restored", .{e.original});
        } else |_| {}
    };
    for (found, 0..) |list, kind| for (list.items) |e| say("  {s}{s}", .{ e.original, if (kind == 0) "/" else "" });
    if (dry_run) {
        say("eb-local: dry run, nothing restored", .{});
        return 0;
    }
    // rtrash restore takes no --; every path is absolute.
    for (found, 0..) |list, kind| for (list.items) |e| {
        const run = runAttached(a, &.{ rtrash, "restore", str(a, "--trash-dir={s}", .{e.trash_dir}), e.original }, c.envp);
        switch (run) {
            .exit => |rc| if (rc != 0) die("rtrash restore exited {d}; nothing after {s} was restored", .{ rc, e.original }),
            .signal => return stop(run),
        }
        if (kind == 0 and literalPath(c, e.original)) makeReadOnly(c, e.original, 0);
    };
    say("eb-local: restored {d} installation(s), read-only again, and {d} module file(s)", .{ found[0].items.len, found[1].items.len + found[2].items.len });
    return 0;
}

// ---- entry ----------------------------------------------------------------

const Command = enum { build, eb, env, dev, clean, config, profiles, uninstall, restore, site, @"rpath-wrappers", check, list, doctor, submit };

/// The command a word names, other than the default build.
fn subcommand(word: []const u8) ?Command {
    const cmd = std.meta.stringToEnum(Command, word) orelse return null;
    return if (cmd == .build) null else cmd;
}

/// Run the command the arguments name, and return its exit status. With
/// `EB_LOCAL_EESSI_EXTEND` set, not empty and not `0`, every argument is
/// eb's, as for `eb-local eb --`.
pub fn main(init: std.process.Init) u8 {
    const a = init.arena.allocator();
    const argv_all = init.minimal.args.toSlice(a) catch die("cannot read the arguments", .{});
    var cwd_buf: [sys.path_max]u8 = undefined;
    const cwd = a.dupe(u8, fsx.realpath(fsx.cwd, ".", &cwd_buf) catch "/") catch oom();
    const c: Ctx = .{ .a = a, .env = init.environ_map, .envp = init.minimal.environ.block.slice.ptr, .cwd = cwd };
    if (comptime build_options.test_ops) {
        if (nonEmpty(c.env.get("EB_LOCAL_TEST_SELF_OWNER"))) |v| test_self_owner = std.fmt.parseInt(linux.uid_t, v, 10) catch null;
    }
    // A single program name, then eb's own arguments: an eb-stack target.
    if (extend.engaged(c.env)) {
        const raw = argv_all[1..];
        const forwarded = a.alloc([]const u8, raw.len) catch oom();
        for (raw, 0..) |arg, n| forwarded[n] = arg;
        return cmdExtend(c, forwarded);
    }

    var args: []const [:0]const u8 = argv_all[1..];
    var command: Command = .build;
    if (args.len > 0) {
        const first: []const u8 = args[0];
        if (std.mem.eql(u8, first, "help") or std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help")) {
            cli.put(1, usage_text);
            return 0;
        }
        if (std.mem.eql(u8, first, "--version")) {
            cli.put(1, comptime cli.versionLine(tool, version, build_options.commit));
            return 0;
        }
        if (std.meta.stringToEnum(Command, first)) |cmd| {
            if (cmd != .build) {
                command = cmd;
                args = args[1..];
            }
        } else if (std.mem.eql(u8, first, "--env")) {
            command = .env;
            args = args[1..];
        }
    }

    var g: Global = .{};
    var rest: std.ArrayList([]const u8) = .empty;
    var clean: CleanOpts = .{};
    var uninstall: UninstallOpts = .{};
    var submit: SubmitOpts = .{};
    var check = false;
    var as_env = false;
    var site: SiteOpts = .{};
    var family: []const u8 = "";
    var only_unwrapped = false;
    var i: usize = 0;
    const value = struct {
        fn get(xs: []const [:0]const u8, idx: *usize, opt: []const u8) []const u8 {
            if (idx.* + 1 >= xs.len or xs[idx.* + 1].len == 0) die("{s} needs a value", .{opt});
            idx.* += 1;
            return xs[idx.*];
        }
    }.get;
    const joined = struct {
        /// The value of OPT=VALUE when X is that; empty, as after a space, it is refused.
        fn get(x: []const u8, opt: []const u8) ?[]const u8 {
            if (!std.mem.startsWith(u8, x, opt) or x.len == opt.len or x[opt.len] != '=') return null;
            if (x.len == opt.len + 1) die("{s} needs a value", .{opt});
            return x[opt.len + 1 ..];
        }
    }.get;
    while (i < args.len) : (i += 1) {
        const x: []const u8 = args[i];
        if (command == .eb and std.mem.eql(u8, x, "--")) {
            // eb's own --help, and any option eb-local also knows, is eb's.
            for (args[i..]) |arg| rest.append(a, arg) catch oom();
            break;
        }
        if (std.mem.eql(u8, x, "-h") or std.mem.eql(u8, x, "--help")) {
            cli.put(1, usage_text);
            return 0;
        } else if (std.mem.eql(u8, x, "--project")) {
            g.project = value(args, &i, "--project");
        } else if (joined(x, "--project")) |v| {
            g.project = v;
        } else if (std.mem.eql(u8, x, "--profile")) {
            g.profile = value(args, &i, "--profile");
        } else if (joined(x, "--profile")) |v| {
            g.profile = v;
        } else if (std.mem.eql(u8, x, "--config")) {
            g.config_file = value(args, &i, "--config");
        } else if (joined(x, "--config")) |v| {
            g.config_file = v;
        } else if (std.mem.eql(u8, x, "--env") and command == .build and rest.items.len == 0) {
            command = .env;
        } else if (std.mem.eql(u8, x, "--explain") and command == .build and rest.items.len == 0) {
            g.explain = true;
        } else if (command == .build and rest.items.len == 0 and subcommand(x) != null) {
            // Global options may come first: eb-local --profile gpu dev.
            command = subcommand(x).?;
        } else switch (command) {
            .build, .eb => rest.append(a, x) catch oom(),
            .@"rpath-wrappers" => {
                if (std.mem.eql(u8, x, "--for")) {
                    family = value(args, &i, "--for");
                    for (family) |ch| if (!std.ascii.isAlphanumeric(ch)) die("--for takes a compiler family name", .{});
                } else if (std.mem.eql(u8, x, "--unwrapped")) {
                    only_unwrapped = true;
                } else die("rpath-wrappers takes only --for FAMILY or --unwrapped; got '{s}'", .{x});
            },
            .check => rest.append(a, x) catch oom(),
            .env, .profiles, .doctor => die("{s} takes only --project, --profile and --config; got '{s}'", .{ @tagName(command), x }),
            .submit => {
                if (rest.items.len == 0 and std.mem.eql(u8, x, "--on")) {
                    submit.on = value(args, &i, "--on");
                } else if (rest.items.len == 0 and joined(x, "--on") != null) {
                    submit.on = joined(x, "--on").?;
                } else if (rest.items.len == 0 and std.mem.eql(u8, x, "--print")) {
                    submit.print = true;
                } else rest.append(a, x) catch oom();
            },
            .list => {
                if (x.len > 0 and x[0] == '-') die("list does not know '{s}'", .{x});
                if (std.mem.indexOfAny(u8, x, " \t\n;$`\\") != null) die("'{s}' is not a module name", .{x});
                rest.append(a, x) catch oom();
            },
            .config => {
                if (std.mem.eql(u8, x, "--check")) {
                    check = true;
                } else if (std.mem.eql(u8, x, "--env")) {
                    as_env = true;
                } else die("config does not know '{s}'", .{x});
                if (check and as_env) die("config takes --check or --env, not both", .{});
            },
            .site => {
                if (std.mem.eql(u8, x, "--set")) {
                    var d: sites.Diagnostic = .{};
                    const set = sites.parseSet(a, value(args, &i, "--set"), &d) catch |e| switch (e) {
                        error.Invalid => die("{s}", .{d.message}),
                        error.OutOfMemory => oom(),
                    };
                    site.sets.append(a, set) catch oom();
                } else if (std.mem.eql(u8, x, "--to")) {
                    site.to = value(args, &i, "--to");
                } else if (std.mem.eql(u8, x, "--force")) {
                    site.force = true;
                } else if (x.len > 0 and x[0] == '-') {
                    die("site does not know '{s}'", .{x});
                } else site.words.append(a, x) catch oom();
            },
            .dev => {
                if (std.mem.eql(u8, x, "--buildenv")) {
                    g.buildenv = value(args, &i, "--buildenv");
                } else if (joined(x, "--buildenv")) |v| {
                    g.buildenv = v;
                } else if (x.len > 0 and x[0] == '-') {
                    die("dev does not know the option '{s}'", .{x});
                } else if (!config.validModule(x)) {
                    die("'{s}' is not a module name", .{x});
                } else rest.append(a, x) catch oom();
            },
            .clean => {
                if (std.mem.eql(u8, x, "--logs-older-than")) {
                    const v = value(args, &i, "--logs-older-than");
                    const n = std.fmt.parseInt(u32, v, 10) catch die("--logs-older-than needs a number of days", .{});
                    if (n > 99999) die("--logs-older-than needs a number of days", .{});
                    clean.logs_days = n;
                } else if (std.mem.eql(u8, x, "--no-logs")) {
                    clean.logs = false;
                } else if (std.mem.eql(u8, x, "--sources")) {
                    clean.sources = true;
                } else if (std.mem.eql(u8, x, "--workspaces")) {
                    clean.workspaces = true;
                } else if (std.mem.eql(u8, x, "--dry-run")) {
                    clean.dry_run = true;
                } else if (std.mem.eql(u8, x, "--delete")) {
                    clean.delete = true;
                } else die("clean does not know '{s}'", .{x});
            },
            .uninstall, .restore => {
                if (std.mem.eql(u8, x, "--dry-run")) {
                    uninstall.dry_run = true;
                } else if (command == .uninstall and std.mem.eql(u8, x, "--delete")) {
                    uninstall.delete = true;
                } else if (x.len > 0 and x[0] == '-') {
                    die("{s} does not know '{s}'", .{ @tagName(command), x });
                } else if (!config.validModule(x)) {
                    die("'{s}' is not a module name", .{x});
                } else rest.append(a, x) catch oom();
            },
        }
    }

    // --explain promises that nothing runs; a command it does not explain
    // would run as if it were not there.
    if (g.explain and command != .build and command != .eb)
        die("--explain goes with a recipe or with eb, not with {s}", .{@tagName(command)});
    if (command == .profiles) return cmdProfiles(c, g);
    // A site file can be written while the configuration in force is broken.
    if (command == .site) return cmdSite(c, site);
    if (command == .@"rpath-wrappers") {
        if (only_unwrapped and family.len > 0) die("rpath-wrappers takes --for FAMILY or --unwrapped, not both", .{});
        return cmdRpathWrappers(c, family, only_unwrapped);
    }
    if (command == .check) return cmdCheck(c, rest.items);
    // The install mode is the four EESSI variables, not the site file.
    if (command == .eb) {
        if (g.profile != null or g.project != null or g.config_file != null)
            die("eb reads the install mode from the environment, not from --profile, --project or --config", .{});
        return if (g.explain) explainExtend(c, rest.items) else cmdExtend(c, rest.items);
    }
    const s = loadSettings(c, g);
    return switch (command) {
        .env => cmdEnv(c, s, g),
        .dev => cmdDev(c, s, g, rest.items),
        .config => if (as_env) cmdConfigEnv(c, s) else cmdConfig(c, s, check),
        .clean => cmdClean(c, s, clean),
        .build => cmdBuild(c, s, g, rest.items),
        .uninstall => cmdUninstall(c, s, rest.items, uninstall),
        .restore => cmdRestore(c, s, rest.items, uninstall.dry_run),
        .list => cmdList(c, s, rest.items),
        .doctor => cmdDoctor(c, s, g),
        .submit => cmdSubmit(c, s, g, rest.items, submit),
        .eb, .profiles, .site, .@"rpath-wrappers", .check => unreachable,
    };
}

test {
    _ = toml;
    _ = config;
    _ = secrets;
    _ = sites;
    _ = storage;
    _ = rpath;
    _ = elfcheck;
    _ = extend;
}

fn cmdExtend(c: Ctx, args: []const []const u8) u8 {
    const eb_args = if (args.len > 0 and std.mem.eql(u8, args[0], "--")) args[1..] else args;
    const sel = extend.select(c.env) catch |err| switch (err) {
        error.TooMany => {
            cli.err("{s}", .{extend.tooMany(c.a, c.env) catch oom()});
            return 3;
        },
    };
    var env = c.env.clone(c.a) catch oom();
    defer env.deinit();
    extend.apply(&env);
    const argv = extend.commandLine(c.a, sel, eb_args) catch oom();
    return stop(runAttached(c.a, argv, envpOf(c.a, &env)));
}

/// What eb-local eb would run: the launcher's own script after a `set --`
/// line with the arguments it would get, so the text runs as the launcher
/// does. Nothing runs and nothing is created.
fn explainExtend(c: Ctx, args: []const []const u8) u8 {
    const a = c.a;
    const eb_args = if (args.len > 0 and std.mem.eql(u8, args[0], "--")) args[1..] else args;
    const sel = extend.select(c.env) catch |err| switch (err) {
        error.TooMany => {
            cli.err("{s}", .{extend.tooMany(a, c.env) catch oom()});
            return 3;
        },
    };
    const argv = extend.commandLine(a, sel, eb_args) catch oom();
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, "# eb-local --explain eb: the script eb-local eb runs, with its arguments. Nothing was run.\n") catch oom();
    const name = extend.variable(sel.mode);
    if (c.env.get(name)) |v| {
        out.print(a, "# {s}={s} selects a {s} install; the process umask is {s}.\n", .{ name, q(a, v), @tagName(sel.mode), sel.umask }) catch oom();
    } else {
        out.print(a, "# No install variable is set: a user install into the module's default, $HOME/eessi; the process umask is {s}.\n", .{sel.umask}) catch oom();
    }
    out.appendSlice(a, "# It runs in a clean bash (no profile, no rc file):\n#  ") catch oom();
    for (argv[0..4]) |x| out.print(a, " {s}", .{x}) catch oom();
    out.appendSlice(a, " \"$SCRIPT\"") catch oom();
    for (argv[5..]) |x| out.print(a, " {s}", .{q(a, x)}) catch oom();
    out.appendSlice(a, "\n# where SCRIPT is everything after the next line.\nset --") catch oom();
    for (argv[6..]) |x| out.print(a, " {s}", .{q(a, x)}) catch oom();
    out.print(a, "\n{s}\n", .{extend.script}) catch oom();
    cli.put(1, out.items);
    return 0;
}

test "a build has the process umask eb-local eb has for the same install" {
    for ([_]Place{ .{ .prefix = "/x", .project = false }, .{ .prefix = "/x", .project = true } }) |p| {
        var env = std.process.Environ.Map.init(std.testing.allocator);
        defer env.deinit();
        try env.put(if (p.project) "EESSI_PROJECT_INSTALL" else "EESSI_USER_INSTALL", p.prefix);
        const sel = try extend.select(&env);
        try std.testing.expectEqual(try std.fmt.parseInt(u32, sel.umask, 8), buildUmask(p));
    }
}

test "eb is the EESSI-extend command" {
    try std.testing.expectEqual(Command.eb, subcommand("eb").?);
    try std.testing.expect(subcommand("build") == null);
    try std.testing.expect(subcommand("env") != null);
}

test "the replay line repeats the options that selected this environment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: config.Settings = .{};
    s.profile = "gpu";
    s.project = .{ .value = "/proj/my group" };
    const g: Global = .{ .config_file = "/etc/x.toml", .buildenv = "buildenv/lfoss" };
    try std.testing.expectEqualStrings("--config /etc/x.toml --profile gpu --project '/proj/my group' dev --buildenv buildenv/lfoss FFTW/1", replay(a, "dev", s, g, "/proj/my group", &.{"FFTW/1"}));
    try std.testing.expectEqualStrings("env", replay(a, "env", .{}, .{}, "/home/u/.local/eessi", &.{}));
}

test "a signal that killed the child kills this process, and an ignored one does not" {
    const pid: isize = @bitCast(linux.fork());
    if (pid < 0) return error.TestUnexpectedResult;
    if (pid == 0) {
        _ = stop(.{ .signal = .TERM });
        linux.exit_group(42);
    }
    var raw: i32 = 0;
    while (true) {
        const wr = linux.wait4(@intCast(pid), &raw, 0, null);
        switch (linux.errno(wr)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.TestUnexpectedResult,
        }
    }
    const status: u32 = @bitCast(raw);
    try std.testing.expect(linux.W.IFSIGNALED(status));
    try std.testing.expectEqual(linux.SIG.TERM, linux.W.TERMSIG(status));

    const pid2: isize = @bitCast(linux.fork());
    if (pid2 < 0) return error.TestUnexpectedResult;
    if (pid2 == 0) {
        const ign: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
        _ = linux.sigaction(.HUP, &ign, null);
        const code = stop(.{ .signal = .HUP });
        linux.exit_group(code);
    }
    raw = 0;
    while (true) {
        const wr = linux.wait4(@intCast(pid2), &raw, 0, null);
        switch (linux.errno(wr)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.TestUnexpectedResult,
        }
    }
    const status2: u32 = @bitCast(raw);
    try std.testing.expect(linux.W.IFEXITED(status2));
    try std.testing.expectEqual(@as(u8, 129), linux.W.EXITSTATUS(status2));
}

test "shell quoting reads back as the same word" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("EESSI/2026.06", try shellQuote(a, "EESSI/2026.06"));
    try std.testing.expectEqualStrings("/home/u/eessi", try shellQuote(a, "/home/u/eessi"));
    try std.testing.expectEqualStrings("'owned space'", try shellQuote(a, "owned space"));
    try std.testing.expectEqualStrings("'a'\\''b $(x)'", try shellQuote(a, "a'b $(x)"));
    try std.testing.expectEqualStrings("''", try shellQuote(a, ""));
}
