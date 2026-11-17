//! eb-local's settings, layered lowest first: built-in defaults, the site
//! file, a site profile, the user file, a user profile, EB_LOCAL_* variables,
//! command-line options. Every value keeps where it came from. The storage
//! settings come only from the site layer: a user cannot point builds at a
//! shared file system. Secrets are named sources, never values.
const std = @import("std");
const toml = @import("toml.zig");
const storage = @import("storage.zig");
const Allocator = std.mem.Allocator;

/// What `clean` and `uninstall` do with what they remove: `rtrash` moves it
/// to the trash, and stops when rtrash is not on `PATH`; `none` removes
/// nothing without `--delete`; `auto` is `rtrash` when rtrash is on `PATH`,
/// else `none`.
pub const Trash = enum { auto, rtrash, none };

/// A value and where it came from, as `eb-local config` shows it: `default`,
/// a file and line with its layer and profile, a variable or an option.
pub fn Setting(comptime T: type) type {
    return struct {
        value: T,
        from: []const u8 = "default",
    };
}

/// A node type: a name, and the sbatch options that place a job on it.
pub const NodeType = struct {
    name: []const u8,
    /// sbatch options, words separated by spaces.
    sbatch: []const u8,
    /// The file and line that set this node type.
    from: []const u8 = "",
};

/// A node type's name: what --on names and a job name carries.
pub fn validNodeTypeName(n: []const u8) bool {
    if (n.len == 0 or n.len > 32) return false;
    for (n) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_')) return false;
    return true;
}

/// sbatch options eb-local passes as separate words, never through a shell:
/// options only, and characters that need no quoting.
pub fn validSbatchOptions(v: []const u8) bool {
    if (v.len == 0 or v.len > 512) return false;
    var words = std.mem.tokenizeScalar(u8, v, ' ');
    var any = false;
    while (words.next()) |w| {
        any = true;
        for (w) |ch| if (!(std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "-_=:,./+%@", ch) != null)) return false;
    }
    if (!any) return false;
    var first = std.mem.tokenizeScalar(u8, v, ' ');
    return first.next().?[0] == '-';
}

/// A secret: the variable eb receives, and where its value is read from.
/// The value itself is read only for a build, by `secrets.resolve`.
pub const Secret = struct {
    /// The variable eb receives.
    name: []const u8,
    /// env:VAR, file:PATH or nimvault:ENTRY.
    source: []const u8,
    from: []const u8,
};

/// An EESSI setting exported before the stack loads, such as
/// EESSI_IGNORE_LMOD_ERROR_ZEN4_GCC1220. Not a secret: config shows it.
pub const EessiVar = struct {
    name: []const u8,
    value: []const u8,
    from: []const u8,
};

/// Every setting in force, each with where it came from. The defaults here
/// are the built-in ones; `load` puts the files, variables and options on top.
pub const Settings = struct {
    profile: ?[]const u8 = null,
    /// EESSI-extend's own default, so `eb-local eb` and EESSI-extend loaded
    /// by hand install into the same tree.
    prefix: Setting([]const u8) = .{ .value = "~/eessi" },
    project: Setting(?[]const u8) = .{ .value = null },
    stack_module: Setting([]const u8) = .{ .value = "EESSI/2026.06" },
    extend_module: Setting([]const u8) = .{ .value = "EESSI-extend/2026.06-easybuild" },
    dev_buildenv: Setting([]const u8) = .{ .value = "buildenv/default-foss-2026.1" },
    /// The build environment for each compiler family other than GCC, used
    /// when dev.buildenv is left at its default; "" means none exists and
    /// eb-local's RPATH wrappers stand in.
    buildenv_for: [families.len]Setting([]const u8) = .{
        .{ .value = "buildenv/default-foss-2026.1-CUDA-13.3.0" },
        .{ .value = "buildenv/default-lfoss-2026.1" },
        .{ .value = "buildenv/default-intel-2026.1" },
        .{ .value = "" },
    },
    dev_modules: Setting([]const []const u8) = .{ .value = &.{} },
    allocation_hint: Setting([]const u8) = .{ .value = "" },
    /// NAME/VERSION toolchains the EESSI hooks accept besides foss and lfoss.
    site_toolchains: Setting([]const []const u8) = .{ .value = &.{} },
    /// Node types `eb-local submit` sends a build to: a name and the sbatch
    /// options that place a job on that node type. Site file only.
    node_types: Setting([]const NodeType) = .{ .value = &.{} },
    /// Where the site file listed them as `[build.targets]`, their name
    /// before 3.2.0, which is read until 4.0.0.
    node_types_old_key: ?[]const u8 = null,
    trash: Setting(Trash) = .{ .value = .auto },
    logs_older_than_days: Setting(u32) = .{ .value = 30 },
    node_local_root: Setting([]const u8) = .{ .value = "" },
    /// Each allocation's mount below node_local_root: %u the user, %j the job id.
    node_local_mount: Setting([]const u8) = .{ .value = storage.default_mount },
    node_local_fstype: Setting([]const u8) = .{ .value = "xfs" },
    shared_scratch: Setting([]const []const u8) = .{ .value = &.{} },
    /// The nimvault program; empty means the first on PATH.
    nimvault_program: Setting([]const u8) = .{ .value = "" },
    /// The vault nimvault reads (its --vault); empty leaves nimvault to find
    /// one from NIMVAULT_VAULT_REPO or the current directory.
    nimvault_vault: Setting([]const u8) = .{ .value = "" },
    secrets: std.ArrayList(Secret) = .empty,
    /// The secrets a build gets, by name. Null, when nothing sets
    /// build.secrets, is every secret.
    build_secrets: Setting(?[]const []const u8) = .{ .value = null },
    eessi: std.ArrayList(EessiVar) = .empty,
};

/// The compiler families dev tells apart after the modules load, each by the
/// EBROOT variable of its compiler module, in rising precedence. GCC is the
/// rest and uses dev.buildenv. The names are EasyBuild's: a hyphen in the
/// software name becomes "min", so llvm-compilers sets EBROOTLLVMMINCOMPILERS.
pub const families = [_]struct { name: []const u8, ebroot: []const u8, env: []const u8 }{
    .{ .name = "cuda", .ebroot = "EBROOTCUDA", .env = "EB_LOCAL_DEV_BUILDENV_FOR_CUDA" },
    .{ .name = "llvm", .ebroot = "EBROOTLLVMMINCOMPILERS", .env = "EB_LOCAL_DEV_BUILDENV_FOR_LLVM" },
    .{ .name = "intel", .ebroot = "EBROOTINTELMINCOMPILERS", .env = "EB_LOCAL_DEV_BUILDENV_FOR_INTEL" },
    .{ .name = "nvhpc", .ebroot = "EBROOTNVHPC", .env = "EB_LOCAL_DEV_BUILDENV_FOR_NVHPC" },
};

/// The `EBROOT` name EasyBuild writes for `software`. `convert_name` replaces
/// `+` with `plus`, `-` with `min` and drops `.`, then the result is
/// uppercased. `llvm-compilers` is `EBROOTLLVMMINCOMPILERS`.
pub fn ebRoot(a: Allocator, software: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "EBROOT");
    for (software) |ch| switch (ch) {
        '+' => try out.appendSlice(a, "PLUS"),
        '-' => try out.appendSlice(a, "MIN"),
        '.' => {},
        else => try out.append(a, std.ascii.toUpper(ch)),
    };
    return out.toOwnedSlice(a);
}

/// The EB_LOCAL_DEV_BUILDENV_FOR_* word for "no build environment".
pub const no_buildenv = "none";

/// Whose file a source is. Only the site layer may set the storage settings,
/// `build.site_toolchains` and `build.node_types`.
pub const Layer = enum { site, user };

/// EB_LOCAL_SECRET_NAME=SOURCE names where the secret NAME comes from.
pub const secret_env_prefix = "EB_LOCAL_SECRET_";

/// One configuration file, already read and trusted.
pub const Source = struct {
    path: []const u8,
    text: []const u8,
    layer: Layer,
};

/// Values from the command line, which `load` puts above every other layer.
/// The program sets `profile`, `project` and `buildenv` from `--profile`,
/// `--project` and `--buildenv`; no option sets `prefix`.
pub const Overrides = struct {
    profile: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    project: ?[]const u8 = null,
    buildenv: ?[]const u8 = null,
};

/// Why the configuration was refused, filled in when `error.Invalid` is
/// returned: one message naming the file and line, or the variable.
pub const Diagnostic = struct {
    message: []const u8 = "",
};

/// `error.Invalid` when a file, variable or option is refused, with the
/// reason in the `Diagnostic`.
pub const Error = error{Invalid} || Allocator.Error;

/// Module names as Lmod writes them. Anything else could change the meaning
/// of the lines env and dev print for eval.
pub fn validModule(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isAlphanumeric(name[0])) return false;
    var prev_slash = false;
    for (name) |c| {
        if (c == '/') {
            if (prev_slash) return false;
            prev_slash = true;
            continue;
        }
        prev_slash = false;
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '+' or c == '-')) return false;
    }
    if (prev_slash) return false;
    // ".." as a path part.
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return false;
    return true;
}

/// A variable name a secret may set: a shell name that is not one the build
/// depends on for its paths or loader.
pub fn validSecretName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    const refused = [_][]const u8{ "PATH", "HOME", "USER", "SHELL", "TMPDIR", "MODULEPATH", "PYTHONPATH", "BASH_ENV", "ENV" };
    for (refused) |r| if (std.mem.eql(u8, name, r)) return false;
    const refused_prefixes = [_][]const u8{ "LD_", "EESSI_", "EASYBUILD_", "LMOD_", "SLURM_", "EB_LOCAL_", "BASH_FUNC_" };
    for (refused_prefixes) |r| if (std.mem.startsWith(u8, name, r)) return false;
    return true;
}

/// The EESSI variables eb-local sets or clears itself: where an install
/// goes and which CPU or GPU target is used. [eessi] cannot set them.
pub const eessi_owned = [_][]const u8{
    "EESSI_CVMFS_INSTALL",               "EESSI_SITE_INSTALL",         "EESSI_USER_INSTALL",
    "EESSI_PROJECT_INSTALL",             "EESSI_SITE_SOFTWARE_PREFIX", "EESSI_SOFTWARE_SUBDIR_OVERRIDE",
    "EESSI_ACCELERATOR_TARGET_OVERRIDE", "EESSI_OVERRIDE_GPU_CHECK",
};

/// A name [eessi] may set: EESSI_ and a shell name, not one eb-local owns
/// or one build.site_toolchains sets.
pub fn validEessiName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "EESSI_") or name.len == "EESSI_".len) return false;
    if (std.mem.startsWith(u8, name, "EESSI_SITE_TOP_LEVEL_TOOLCHAINS")) return false;
    if (!validEnvName(name)) return false;
    for (eessi_owned) |o| if (std.mem.eql(u8, name, o)) return false;
    return true;
}

/// A value [eessi] may give: at most 4096 bytes, with no line break or NUL.
pub fn validEessiValue(v: []const u8) bool {
    return v.len <= 4096 and std.mem.indexOfAny(u8, v, "\n\r\x00") == null;
}

/// What `checkSecretSource` found.
pub const SourceCheck = union(enum) {
    ok,
    /// Not env:, file: or nimvault:, as when a value is written in its place.
    unknown,
    /// One of those, and what is wrong with the rest of it.
    refused: []const u8,
};

/// Whether a secret may name `source`: `env:` and a variable name, `file:`
/// and an absolute or `~/` path, or `nimvault:` and an entry that does not
/// start with `-`. None may hold a line break or NUL.
pub fn checkSecretSource(source: []const u8) SourceCheck {
    inline for (.{ "env:", "file:", "nimvault:" }) |kind| {
        if (std.mem.startsWith(u8, source, kind)) {
            const rest = source[kind.len..];
            if (std.mem.indexOfAny(u8, rest, "\n\r\x00") != null) return .{ .refused = "a source may not hold a line break or NUL" };
            if (comptime std.mem.eql(u8, kind, "env:")) {
                if (!validEnvName(rest)) return .{ .refused = "env: takes a variable name of letters, digits and _, not starting with a digit" };
            } else if (comptime std.mem.eql(u8, kind, "file:")) {
                if (!std.mem.startsWith(u8, rest, "/") and !std.mem.startsWith(u8, rest, "~/"))
                    return .{ .refused = "file: takes an absolute path or one starting ~/" };
            } else if (rest.len == 0) {
                return .{ .refused = "nimvault: takes an entry" };
            } else if (rest[0] == '-') {
                return .{ .refused = "a nimvault entry may not start with -, since nimvault would read it as an option" };
            }
            return .ok;
        }
    }
    return .unknown;
}

/// Whether a build gets the secret `name`: build.secrets names it, or
/// nothing sets build.secrets.
pub fn buildGets(s: Settings, name: []const u8) bool {
    const names = s.build_secrets.value orelse return true;
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The secrets a build gets, in the order the configuration defines them.
pub fn buildSecrets(a: Allocator, s: Settings) Allocator.Error![]Secret {
    var out: std.ArrayList(Secret) = .empty;
    errdefer out.deinit(a);
    for (s.secrets.items) |sec| if (buildGets(s, sec.name)) try out.append(a, sec);
    return out.toOwnedSlice(a);
}

fn validEnvName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

/// NAME/VERSION, each part letters, digits, '.', '_' or '-'.
pub fn validToolchain(tc: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, tc, '/') orelse return false;
    for ([_][]const u8{ tc[0..slash], tc[slash + 1 ..] }) |part| {
        if (part.len == 0) return false;
        for (part) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return false;
    }
    return true;
}

/// The JSON list the EESSI hooks read, [{"name": N, "version": V}, ...];
/// the parts were checked by validToolchain, so nothing needs escaping.
pub fn toolchainsJson(a: Allocator, tcs: []const []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '[');
    for (tcs, 0..) |tc, i| {
        const slash = std.mem.indexOfScalar(u8, tc, '/').?;
        if (i > 0) try out.appendSlice(a, ", ");
        try out.print(a, "{{\"name\": \"{s}\", \"version\": \"{s}\"}}", .{ tc[0..slash], tc[slash + 1 ..] });
    }
    try out.append(a, ']');
    return out.toOwnedSlice(a);
}

test "site toolchains" {
    try std.testing.expect(validToolchain("intel/2026.1"));
    try std.testing.expect(validToolchain("nvidia-compilers/26.3"));
    for ([_][]const u8{ "intel", "/2026.1", "intel/", "a/b/c", "intel/2026.1\"", "in tel/1" }) |bad|
        try std.testing.expect(!validToolchain(bad));
    const j = try toolchainsJson(std.testing.allocator, &.{ "intel/2026.1", "NVHPC/26.3" });
    defer std.testing.allocator.free(j);
    try std.testing.expectEqualStrings("[{\"name\": \"intel\", \"version\": \"2026.1\"}, {\"name\": \"NVHPC\", \"version\": \"26.3\"}]", j);
}

/// An absolute path, or one under HOME written ~/..., without a trailing
/// slash or a control character.
fn validHomePath(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, "~/")) {
        if (path.len < 3 or path[path.len - 1] == '/') return false;
        return std.mem.indexOfAny(u8, path, "\t\n\r\x00") == null;
    }
    return validAbsolute(path);
}

fn validAbsolute(path: []const u8) bool {
    if (path.len < 2 or path[0] != '/' or path[path.len - 1] == '/') return false;
    return std.mem.indexOfAny(u8, path, " \t\n\r\x00") == null;
}

const Loader = struct {
    a: Allocator,
    s: *Settings,
    diag: *Diagnostic,

    fn fail(l: *Loader, comptime fmt: []const u8, args: anytype) Error {
        l.diag.message = try std.fmt.allocPrint(l.a, fmt, args);
        return error.Invalid;
    }

    fn where(l: *Loader, src: Source, line: usize, profile: ?[]const u8) Error![]const u8 {
        const layer = @tagName(src.layer);
        return if (profile) |p|
            std.fmt.allocPrint(l.a, "{s} profile {s}, {s}:{d}", .{ layer, p, src.path, line })
        else
            std.fmt.allocPrint(l.a, "{s} {s}:{d}", .{ layer, src.path, line });
    }

    fn string(l: *Loader, src: Source, e: *const toml.Entry, name: []const u8) Error![]const u8 {
        return switch (e.value) {
            .string => |v| v,
            else => l.fail("{s}:{d}: {s} must be a string, not {s}", .{ src.path, e.line, name, e.value.kindName() }),
        };
    }

    fn module(l: *Loader, src: Source, e: *const toml.Entry, name: []const u8) Error![]const u8 {
        const v = try l.string(src, e, name);
        if (!validModule(v)) return l.fail("{s}:{d}: {s} '{s}' is not a module name", .{ src.path, e.line, name, v });
        return v;
    }

    fn stringList(l: *Loader, src: Source, e: *const toml.Entry, name: []const u8) Error![]const []const u8 {
        const items = switch (e.value) {
            .array => |v| v,
            else => return l.fail("{s}:{d}: {s} must be an array of strings", .{ src.path, e.line, name }),
        };
        var out: std.ArrayList([]const u8) = .empty;
        for (items) |item| switch (item) {
            .string => |v| try out.append(l.a, v),
            else => return l.fail("{s}:{d}: {s} must be an array of strings", .{ src.path, e.line, name }),
        };
        return out.items;
    }

    fn table(l: *Loader, src: Source, e: *const toml.Entry, name: []const u8) Error!*toml.Table {
        return switch (e.value) {
            .table => |t| t,
            else => l.fail("{s}:{d}: {s} must be a table", .{ src.path, e.line, name }),
        };
    }

    /// The keys a profile and a file's top level share.
    fn apply(l: *Loader, src: Source, t: *const toml.Table, profile: ?[]const u8) Error!void {
        for (t.entries.items) |*e| {
            const k = e.key;
            const from = try l.where(src, e.line, profile);
            if (std.mem.eql(u8, k, "prefix")) {
                l.s.prefix = .{ .value = try l.string(src, e, "prefix"), .from = from };
            } else if (std.mem.eql(u8, k, "project")) {
                l.s.project = .{ .value = try l.string(src, e, "project"), .from = from };
            } else if (std.mem.eql(u8, k, "stack")) {
                const sub = try l.table(src, e, "stack");
                for (sub.entries.items) |*f| {
                    const ff = try l.where(src, f.line, profile);
                    if (std.mem.eql(u8, f.key, "module")) {
                        l.s.stack_module = .{ .value = try l.module(src, f, "stack.module"), .from = ff };
                    } else if (std.mem.eql(u8, f.key, "extend")) {
                        l.s.extend_module = .{ .value = try l.module(src, f, "stack.extend"), .from = ff };
                    } else return l.fail("{s}:{d}: unknown key stack.{s}", .{ src.path, f.line, f.key });
                }
            } else if (std.mem.eql(u8, k, "dev")) {
                const sub = try l.table(src, e, "dev");
                for (sub.entries.items) |*f| {
                    const ff = try l.where(src, f.line, profile);
                    if (std.mem.eql(u8, f.key, "buildenv")) {
                        l.s.dev_buildenv = .{ .value = try l.module(src, f, "dev.buildenv"), .from = ff };
                    } else if (std.mem.eql(u8, f.key, "buildenv_for")) {
                        const per = try l.table(src, f, "dev.buildenv_for");
                        for (per.entries.items) |*g| {
                            const i = for (families, 0..) |fam, i| {
                                if (std.mem.eql(u8, fam.name, g.key)) break i;
                            } else return l.fail("{s}:{d}: unknown key dev.buildenv_for.{s} (cuda, llvm, intel or nvhpc)", .{ src.path, g.line, g.key });
                            const v = try l.string(src, g, "dev.buildenv_for");
                            if (v.len > 0 and !validModule(v)) return l.fail("{s}:{d}: dev.buildenv_for.{s} '{s}' is not a module name", .{ src.path, g.line, g.key, v });
                            l.s.buildenv_for[i] = .{ .value = v, .from = try l.where(src, g.line, profile) };
                        }
                    } else if (std.mem.eql(u8, f.key, "modules")) {
                        const mods = try l.stringList(src, f, "dev.modules");
                        for (mods) |m| if (!validModule(m)) return l.fail("{s}:{d}: dev.modules: '{s}' is not a module name", .{ src.path, f.line, m });
                        l.s.dev_modules = .{ .value = mods, .from = ff };
                    } else return l.fail("{s}:{d}: unknown key dev.{s}", .{ src.path, f.line, f.key });
                }
            } else if (std.mem.eql(u8, k, "build")) {
                const sub = try l.table(src, e, "build");
                var node_types_line: ?usize = null;
                for (sub.entries.items) |*f| {
                    if (std.mem.eql(u8, f.key, "allocation_hint")) {
                        l.s.allocation_hint = .{ .value = try l.string(src, f, "build.allocation_hint"), .from = try l.where(src, f.line, profile) };
                    } else if (std.mem.eql(u8, f.key, "site_toolchains")) {
                        if (src.layer != .site or profile != null)
                            return l.fail("{s}:{d}: build.site_toolchains is a site setting; a user file or a profile cannot change it", .{ src.path, f.line });
                        const v = try l.stringList(src, f, "build.site_toolchains");
                        for (v) |tc| if (!validToolchain(tc))
                            return l.fail("{s}:{d}: build.site_toolchains: '{s}' is not NAME/VERSION", .{ src.path, f.line, tc });
                        l.s.site_toolchains = .{ .value = v, .from = try l.where(src, f.line, null) };
                    } else if (std.mem.eql(u8, f.key, "node_types") or std.mem.eql(u8, f.key, "targets")) {
                        const old = std.mem.eql(u8, f.key, "targets");
                        const key = if (old) "build.targets" else "build.node_types";
                        if (src.layer != .site or profile != null)
                            return l.fail("{s}:{d}: {s} is a site setting; a user file or a profile cannot change it", .{ src.path, f.line, key });
                        if (node_types_line) |first|
                            return l.fail("{s}:{d}: build.targets is the old name of build.node_types, which line {d} sets; keep one", .{ src.path, f.line, first });
                        node_types_line = f.line;
                        const per = try l.table(src, f, key);
                        var list: std.ArrayList(NodeType) = .empty;
                        for (per.entries.items) |*g| {
                            if (!validNodeTypeName(g.key)) return l.fail("{s}:{d}: {s}.{s}: a node type's name is letters, digits, - and _", .{ src.path, g.line, key, g.key });
                            const v = try l.string(src, g, key);
                            if (!validSbatchOptions(v))
                                return l.fail("{s}:{d}: {s}.{s}: sbatch options, separated by spaces, with no quotes, $, ; or other shell characters", .{ src.path, g.line, key, g.key });
                            try list.append(l.a, .{ .name = g.key, .sbatch = v, .from = try l.where(src, g.line, null) });
                        }
                        l.s.node_types = .{ .value = list.items, .from = try l.where(src, f.line, null) };
                        l.s.node_types_old_key = if (old) l.s.node_types.from else null;
                    } else if (std.mem.eql(u8, f.key, "secrets")) {
                        const v = try l.stringList(src, f, "build.secrets");
                        for (v) |name| if (!validSecretName(name))
                            return l.fail("{s}:{d}: build.secrets: {s} is not a variable name a secret may set", .{ src.path, f.line, name });
                        l.s.build_secrets = .{ .value = v, .from = try l.where(src, f.line, profile) };
                    } else return l.fail("{s}:{d}: unknown key build.{s}", .{ src.path, f.line, f.key });
                }
            } else if (std.mem.eql(u8, k, "clean")) {
                const sub = try l.table(src, e, "clean");
                for (sub.entries.items) |*f| {
                    const ff = try l.where(src, f.line, profile);
                    if (std.mem.eql(u8, f.key, "trash")) {
                        const v = try l.string(src, f, "clean.trash");
                        const t2 = std.meta.stringToEnum(Trash, v) orelse return l.fail("{s}:{d}: clean.trash is auto, rtrash or none", .{ src.path, f.line });
                        l.s.trash = .{ .value = t2, .from = ff };
                    } else if (std.mem.eql(u8, f.key, "logs_older_than_days")) {
                        const v = switch (f.value) {
                            .int => |n| n,
                            else => return l.fail("{s}:{d}: clean.logs_older_than_days must be an integer", .{ src.path, f.line }),
                        };
                        if (v < 0 or v > 99999) return l.fail("{s}:{d}: clean.logs_older_than_days is out of range", .{ src.path, f.line });
                        l.s.logs_older_than_days = .{ .value = @intCast(v), .from = ff };
                    } else return l.fail("{s}:{d}: unknown key clean.{s}", .{ src.path, f.line, f.key });
                }
            } else if (std.mem.eql(u8, k, "nimvault")) {
                const sub = try l.table(src, e, "nimvault");
                for (sub.entries.items) |*f| {
                    const ff = try l.where(src, f.line, profile);
                    if (std.mem.eql(u8, f.key, "program")) {
                        const v = try l.string(src, f, "nimvault.program");
                        if (!validAbsolute(v)) return l.fail("{s}:{d}: nimvault.program must be an absolute path", .{ src.path, f.line });
                        l.s.nimvault_program = .{ .value = v, .from = ff };
                    } else if (std.mem.eql(u8, f.key, "vault")) {
                        const v = try l.string(src, f, "nimvault.vault");
                        if (!validHomePath(v)) return l.fail("{s}:{d}: nimvault.vault must be an absolute path or start with ~/", .{ src.path, f.line });
                        l.s.nimvault_vault = .{ .value = v, .from = ff };
                    } else return l.fail("{s}:{d}: unknown key nimvault.{s}", .{ src.path, f.line, f.key });
                }
            } else if (std.mem.eql(u8, k, "secrets")) {
                const sub = try l.table(src, e, "secrets");
                for (sub.entries.items) |*f| {
                    if (!validSecretName(f.key)) return l.fail("{s}:{d}: secret {s}: not a variable name a secret may set", .{ src.path, f.line, f.key });
                    const v = try l.string(src, f, "a secret");
                    switch (checkSecretSource(v)) {
                        .ok => {},
                        .unknown => return l.fail("{s}:{d}: secret {s}: a source is env:VAR, file:PATH or nimvault:ENTRY; a value is never written in a configuration file", .{ src.path, f.line, f.key }),
                        .refused => |why| return l.fail("{s}:{d}: secret {s}: {s}", .{ src.path, f.line, f.key, why }),
                    }
                    const ff = try l.where(src, f.line, profile);
                    // A later layer replaces a secret of the same name.
                    for (l.s.secrets.items, 0..) |old, i| if (std.mem.eql(u8, old.name, f.key)) {
                        _ = l.s.secrets.orderedRemove(i);
                        break;
                    };
                    try l.s.secrets.append(l.a, .{ .name = f.key, .source = v, .from = ff });
                }
            } else if (std.mem.eql(u8, k, "eessi")) {
                const sub = try l.table(src, e, "eessi");
                for (sub.entries.items) |*f| {
                    if (!validEessiName(f.key))
                        return l.fail("{s}:{d}: eessi.{s}: [eessi] sets EESSI_* variables other than the install and target ones eb-local sets and the toolchain list build.site_toolchains sets", .{ src.path, f.line, f.key });
                    const v = try l.string(src, f, "an [eessi] value");
                    if (!validEessiValue(v)) return l.fail("{s}:{d}: eessi.{s}: one line of at most 4096 bytes", .{ src.path, f.line, f.key });
                    const ff = try l.where(src, f.line, profile);
                    for (l.s.eessi.items, 0..) |old, i| if (std.mem.eql(u8, old.name, f.key)) {
                        _ = l.s.eessi.orderedRemove(i);
                        break;
                    };
                    try l.s.eessi.append(l.a, .{ .name = f.key, .value = v, .from = ff });
                }
            } else if (std.mem.eql(u8, k, "storage")) {
                if (src.layer != .site or profile != null)
                    return l.fail("{s}:{d}: [storage] is a site setting; a user file or a profile cannot change it", .{ src.path, e.line });
                const sub = try l.table(src, e, "storage");
                for (sub.entries.items) |*f| {
                    const ff = try l.where(src, f.line, null);
                    if (std.mem.eql(u8, f.key, "node_local_root")) {
                        const v = try l.string(src, f, "storage.node_local_root");
                        if (!validAbsolute(v)) return l.fail("{s}:{d}: storage.node_local_root must be one absolute path without a trailing slash", .{ src.path, f.line });
                        l.s.node_local_root = .{ .value = v, .from = ff };
                    } else if (std.mem.eql(u8, f.key, "node_local_mount")) {
                        const v = try l.string(src, f, "storage.node_local_mount");
                        if (!storage.validMountPattern(v))
                            return l.fail("{s}:{d}: storage.node_local_mount must be one file name of letters, digits, '.', '_', '-', %u (the user) and %j (the job id), with %j in it", .{ src.path, f.line });
                        l.s.node_local_mount = .{ .value = v, .from = ff };
                    } else if (std.mem.eql(u8, f.key, "node_local_fstype")) {
                        const v = try l.string(src, f, "storage.node_local_fstype");
                        for (v) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_' or c == '.'))
                            return l.fail("{s}:{d}: storage.node_local_fstype must be a file system type name", .{ src.path, f.line });
                        if (v.len == 0) return l.fail("{s}:{d}: storage.node_local_fstype is empty", .{ src.path, f.line });
                        l.s.node_local_fstype = .{ .value = v, .from = ff };
                    } else if (std.mem.eql(u8, f.key, "shared_scratch")) {
                        const v = try l.stringList(src, f, "storage.shared_scratch");
                        for (v) |p| if (!validAbsolute(p)) return l.fail("{s}:{d}: storage.shared_scratch takes absolute paths without a trailing slash", .{ src.path, f.line });
                        l.s.shared_scratch = .{ .value = v, .from = ff };
                    } else return l.fail("{s}:{d}: unknown key storage.{s}", .{ src.path, f.line, f.key });
                }
            } else if (std.mem.eql(u8, k, "default_profile") or std.mem.eql(u8, k, "profile")) {
                if (profile != null) return l.fail("{s}:{d}: {s} cannot be set inside a profile", .{ src.path, e.line, k });
            } else return l.fail("{s}:{d}: unknown key {s}", .{ src.path, e.line, k });
        }
    }
};

fn profileTable(t: *const toml.Table, name: []const u8) ?*const toml.Table {
    const profiles = t.get("profile") orelse return null;
    const pt = switch (profiles.value) {
        .table => |x| x,
        else => return null,
    };
    const e = pt.get(name) orelse return null;
    return switch (e.value) {
        .table => |x| x,
        else => null,
    };
}

/// Profile names a file defines.
pub fn profileNames(a: Allocator, t: *const toml.Table) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const profiles = t.get("profile") orelse return out.items;
    switch (profiles.value) {
        .table => |pt| for (pt.entries.items) |e| try out.append(a, e.key),
        else => {},
    }
    return out.items;
}

fn defaultProfile(l: *Loader, src: Source, t: *const toml.Table) Error!?[]const u8 {
    const e = t.get("default_profile") orelse return null;
    return try l.string(src, e, "default_profile");
}

/// The configuration in `sources` (site first, then user), with `env` and
/// `cli` on top.
pub fn load(
    a: Allocator,
    sources: []const Source,
    env: *const std.process.Environ.Map,
    cli: Overrides,
    diag: *Diagnostic,
) Error!Settings {
    var s: Settings = .{};
    var l: Loader = .{ .a = a, .s = &s, .diag = diag };
    var tables: std.ArrayList(*toml.Table) = .empty;
    for (sources) |src| {
        var td: toml.Diagnostic = .{};
        const t = toml.parse(a, src.text, &td) catch |e| switch (e) {
            error.Invalid => return l.fail("{s}:{d}: {s}", .{ src.path, td.line, td.message }),
            error.OutOfMemory => return error.OutOfMemory,
        };
        try tables.append(a, t);
    }

    // The profile: an option, then EB_LOCAL_PROFILE, then the last default_profile.
    var profile: ?[]const u8 = cli.profile orelse env.get("EB_LOCAL_PROFILE");
    if (profile == null) for (sources, tables.items) |src, t| {
        if (try defaultProfile(&l, src, t)) |p| profile = p;
    };
    if (profile) |p| {
        if (p.len == 0) profile = null;
    }

    // Every profile is checked, selected or not, so a mistake in one shows
    // the first time the file is read rather than the first time it is used.
    for (sources, tables.items) |src, t| {
        if (t.get("profile")) |pe| {
            const pt = try l.table(src, pe, "profile");
            for (pt.entries.items) |*e| {
                const body = try l.table(src, e, "a profile");
                var scratch: Settings = .{};
                var check: Loader = .{ .a = a, .s = &scratch, .diag = diag };
                try check.apply(src, body, e.key);
            }
        }
    }

    var found = profile == null;
    for (sources, tables.items) |src, t| {
        try l.apply(src, t, null);
        if (profile) |p| if (profileTable(t, p)) |pt| {
            found = true;
            try l.apply(src, pt, p);
        };
    }
    if (!found) {
        var names: std.ArrayList([]const u8) = .empty;
        for (tables.items) |t| try names.appendSlice(a, try profileNames(a, t));
        return l.fail("no profile '{s}' (defined: {s})", .{ profile.?, if (names.items.len == 0) "none" else try std.mem.join(a, ", ", names.items) });
    }
    s.profile = profile;

    // Every scalar key has an EB_LOCAL_* form; storage has none.
    if (env.get("EB_LOCAL_PREFIX")) |v| if (v.len > 0) {
        s.prefix = .{ .value = v, .from = "environment EB_LOCAL_PREFIX" };
    };
    if (env.get("EB_LOCAL_PROJECT")) |v| if (v.len > 0) {
        s.project = .{ .value = v, .from = "environment EB_LOCAL_PROJECT" };
    };
    inline for (.{
        .{ "EB_LOCAL_STACK_MODULE", "stack_module" },
        .{ "EB_LOCAL_STACK_EXTEND", "extend_module" },
        .{ "EB_LOCAL_DEV_BUILDENV", "dev_buildenv" },
    }) |pair| {
        if (env.get(pair[0])) |v| if (v.len > 0) {
            if (!validModule(v)) return l.fail("{s}: '{s}' is not a module name", .{ pair[0], v });
            @field(s, pair[1]) = .{ .value = v, .from = "environment " ++ pair[0] };
        };
    }
    inline for (families, 0..) |f, i| {
        if (env.get(f.env)) |v| if (v.len > 0) {
            const none = std.mem.eql(u8, v, no_buildenv);
            if (!none and !validModule(v)) return l.fail("{s}: '{s}' is not a module name", .{ f.env, v });
            s.buildenv_for[i] = .{ .value = if (none) "" else v, .from = "environment " ++ f.env };
        };
    }
    // An empty variable is ignored, as in 1.x, except by the settings an empty
    // value means something to (no modules, no hint, nimvault's own program
    // and vault): it empties those, so the lines config --env writes carry a
    // value a profile cleared.
    if (env.get("EB_LOCAL_DEV_MODULES")) |v| {
        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, v, " \t");
        while (it.next()) |m| {
            if (!validModule(m)) return l.fail("EB_LOCAL_DEV_MODULES: '{s}' is not a module name", .{m});
            try out.append(a, m);
        }
        s.dev_modules = .{ .value = out.items, .from = "environment EB_LOCAL_DEV_MODULES" };
    }
    if (env.get("EB_LOCAL_BUILD_ALLOCATION_HINT")) |v| {
        s.allocation_hint = .{ .value = v, .from = "environment EB_LOCAL_BUILD_ALLOCATION_HINT" };
    }
    // EB_LOCAL_TRASH is the 1.x name.
    inline for (.{ "EB_LOCAL_TRASH", "EB_LOCAL_CLEAN_TRASH" }) |name| {
        if (env.get(name)) |v| if (v.len > 0) {
            const t = std.meta.stringToEnum(Trash, v) orelse return l.fail("{s} is auto, rtrash or none", .{name});
            s.trash = .{ .value = t, .from = "environment " ++ name };
        };
    }
    if (env.get("EB_LOCAL_CLEAN_LOGS_OLDER_THAN_DAYS")) |v| if (v.len > 0) {
        const n = std.fmt.parseInt(u32, v, 10) catch return l.fail("EB_LOCAL_CLEAN_LOGS_OLDER_THAN_DAYS must be a number of days", .{});
        if (n > 99999) return l.fail("EB_LOCAL_CLEAN_LOGS_OLDER_THAN_DAYS is out of range", .{});
        s.logs_older_than_days = .{ .value = n, .from = "environment EB_LOCAL_CLEAN_LOGS_OLDER_THAN_DAYS" };
    };

    if (env.get("EB_LOCAL_NIMVAULT_PROGRAM")) |v| {
        if (v.len > 0 and !validAbsolute(v)) return l.fail("EB_LOCAL_NIMVAULT_PROGRAM must be an absolute path", .{});
        s.nimvault_program = .{ .value = v, .from = "environment EB_LOCAL_NIMVAULT_PROGRAM" };
    }
    if (env.get("EB_LOCAL_NIMVAULT_VAULT")) |v| {
        if (v.len > 0 and !validHomePath(v)) return l.fail("EB_LOCAL_NIMVAULT_VAULT must be an absolute path or start with ~/", .{});
        s.nimvault_vault = .{ .value = v, .from = "environment EB_LOCAL_NIMVAULT_VAULT" };
    }
    // EB_LOCAL_SECRET_NAME=SOURCE adds or replaces the secret NAME, in name
    // order so the result does not depend on the order of the environment.
    {
        var names: std.ArrayList([]const u8) = .empty;
        for (env.keys()) |k| if (std.mem.startsWith(u8, k, secret_env_prefix)) try names.append(a, k);
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        for (names.items) |k| {
            const name = k[secret_env_prefix.len..];
            const v = env.get(k).?;
            if (v.len == 0) continue;
            if (!validSecretName(name)) return l.fail("{s}: {s} is not a variable name a secret may set", .{ k, name });
            switch (checkSecretSource(v)) {
                .ok => {},
                .unknown => return l.fail("{s}: a source is env:VAR, file:PATH or nimvault:ENTRY; a value is never written in a variable", .{k}),
                .refused => |why| return l.fail("{s}: {s}", .{ k, why }),
            }
            for (s.secrets.items, 0..) |old, i| if (std.mem.eql(u8, old.name, name)) {
                _ = s.secrets.orderedRemove(i);
                break;
            };
            try s.secrets.append(a, .{ .name = name, .source = v, .from = try std.fmt.allocPrint(a, "environment {s}", .{k}) });
        }
    }
    // EB_LOCAL_BUILD_SECRETS="NAME ..." names the secrets a build gets;
    // empty, it names none.
    if (env.get("EB_LOCAL_BUILD_SECRETS")) |v| {
        var names: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, v, " \t");
        while (it.next()) |name| {
            if (!validSecretName(name)) return l.fail("EB_LOCAL_BUILD_SECRETS: {s} is not a variable name a secret may set", .{name});
            try names.append(a, name);
        }
        s.build_secrets = .{ .value = names.items, .from = "environment EB_LOCAL_BUILD_SECRETS" };
    }
    if (s.build_secrets.value) |names| for (names) |name| {
        for (s.secrets.items) |sec| {
            if (std.mem.eql(u8, sec.name, name)) break;
        } else return l.fail("build.secrets [{s}] names {s}, but no secret {s} is defined: add it to [secrets], or set " ++
            secret_env_prefix ++ "{s}=SOURCE", .{ s.build_secrets.from, name, name, name });
    };

    if (cli.prefix) |v| s.prefix = .{ .value = v, .from = "option" };
    if (cli.project) |v| s.project = .{ .value = v, .from = "option --project" };
    if (cli.buildenv) |v| {
        if (!validModule(v)) return l.fail("--buildenv: '{s}' is not a module name", .{v});
        s.dev_buildenv = .{ .value = v, .from = "option --buildenv" };
    }
    return s;
}

/// The 1.x site file: `key = value` lines, parsed, never sourced. Kept so a
/// site's existing eb-local.conf keeps working. Each setting becomes a
/// dotted TOML key on the line it is on, so that `eb-local config` and the
/// errors name that line.
pub fn legacyToToml(a: Allocator, text: []const u8, diag: *Diagnostic) Error![]const u8 {
    const tables = [_][]const u8{ "storage", "stack", "build", "dev", "clean" };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        if (n > 1) try out.append(a, '\n');
        const no_comment = if (std.mem.indexOfScalar(u8, raw, '#')) |i| raw[0..i] else raw;
        const line = std.mem.trim(u8, no_comment, " \t\r");
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            diag.message = try std.fmt.allocPrint(a, "line {d}: cannot read the line '{s}'", .{ n, line });
            return error.Invalid;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        // (table index, TOML key) for each 1.x setting.
        const Map = struct { k: []const u8, t: usize, name: []const u8, list: bool = false };
        const map = [_]Map{
            .{ .k = "node_local_root", .t = 0, .name = "node_local_root" },
            .{ .k = "node_local_mount", .t = 0, .name = "node_local_mount" },
            .{ .k = "node_local_fstype", .t = 0, .name = "node_local_fstype" },
            .{ .k = "shared_scratch", .t = 0, .name = "shared_scratch", .list = true },
            .{ .k = "stack_module", .t = 1, .name = "module" },
            .{ .k = "extend_module", .t = 1, .name = "extend" },
            .{ .k = "allocation_hint", .t = 2, .name = "allocation_hint" },
            .{ .k = "dev_buildenv", .t = 3, .name = "buildenv" },
            .{ .k = "trash", .t = 4, .name = "trash" },
        };
        const m = for (map) |m| {
            if (std.mem.eql(u8, m.k, key)) break m;
        } else {
            diag.message = try std.fmt.allocPrint(a, "line {d}: unknown setting '{s}'", .{ n, key });
            return error.Invalid;
        };
        try out.print(a, "{s}.{s} = ", .{ tables[m.t], m.name });
        if (m.list) {
            try out.append(a, '[');
            var it = std.mem.tokenizeAny(u8, value, " \t");
            var first = true;
            while (it.next()) |p| {
                if (!first) try out.appendSlice(a, ", ");
                first = false;
                try appendQuoted(a, &out, p);
            }
            try out.append(a, ']');
        } else {
            try appendQuoted(a, &out, value);
        }
    }
    try out.append(a, '\n');
    return out.toOwnedSlice(a);
}

fn appendQuoted(a: Allocator, buf: *std.ArrayList(u8), v: []const u8) Allocator.Error!void {
    try buf.append(a, '"');
    for (v) |c| {
        if (c == '"' or c == '\\') try buf.append(a, '\\');
        try buf.append(a, c);
    }
    try buf.append(a, '"');
}

// ---- tests ----------------------------------------------------------------

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,

    fn init() Fixture {
        return .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .env = std.process.Environ.Map.init(std.testing.allocator) };
    }
    fn deinit(t: *Fixture) void {
        t.env.deinit();
        t.arena.deinit();
    }
    fn load(t: *Fixture, sources: []const Source, cli: Overrides) !Settings {
        var d: Diagnostic = .{};
        return config_load(t.arena.allocator(), sources, &t.env, cli, &d) catch |e| {
            std.debug.print("{s}\n", .{d.message});
            return e;
        };
    }
    fn refuse(t: *Fixture, sources: []const Source, needle: []const u8) !void {
        var d: Diagnostic = .{};
        try std.testing.expectError(error.Invalid, config_load(t.arena.allocator(), sources, &t.env, .{}, &d));
        if (std.mem.indexOf(u8, d.message, needle) == null) {
            std.debug.print("message '{s}' lacks '{s}'\n", .{ d.message, needle });
            return error.TestUnexpectedResult;
        }
    }
};
const config_load = load;

const site_text =
    \\[storage]
    \\node_local_root = "/local"
    \\shared_scratch = ["/scratch", "/work"]
    \\[stack]
    \\module = "EESSI/2026.06"
    \\[profile.gpu]
    \\dev.modules = ["CUDA/13.3.0"]
    \\build.allocation_hint = "salloc -p gpu"
;
const user_text =
    \\default_profile = "mine"
    \\[profile.mine]
    \\prefix = "/home/u/eessi"
    \\dev.modules = ["FFTW/3.3.10-GCC-15.2.0"]
    \\[profile.group]
    \\project = "/path/to/project/eessi"
    \\[profile.group.secrets]
    \\LM_LICENSE_FILE = "nimvault:licences/flexlm"
    \\[secrets]
    \\SOURCE_TOKEN = "env:MY_TOKEN"
;

test "layers, profiles and where each value came from" {
    var t = Fixture.init();
    defer t.deinit();
    const sources = [_]Source{
        .{ .path = "/etc/eb-local/config.toml", .text = site_text, .layer = .site },
        .{ .path = "/home/u/.config/eb-local/config.toml", .text = user_text, .layer = .user },
    };
    const s = try t.load(&sources, .{});
    try std.testing.expectEqualStrings("mine", s.profile.?);
    try std.testing.expectEqualStrings("/home/u/eessi", s.prefix.value);
    try std.testing.expectEqualStrings("user profile mine, /home/u/.config/eb-local/config.toml:3", s.prefix.from);
    try std.testing.expectEqualStrings("FFTW/3.3.10-GCC-15.2.0", s.dev_modules.value[0]);
    try std.testing.expectEqualStrings("/local", s.node_local_root.value);
    try std.testing.expectEqual(@as(usize, 1), s.secrets.items.len);
    try std.testing.expectEqualStrings("SOURCE_TOKEN", s.secrets.items[0].name);

    const g = try t.load(&sources, .{ .profile = "group" });
    try std.testing.expectEqualStrings("/path/to/project/eessi", g.project.value.?);
    try std.testing.expectEqual(@as(usize, 2), g.secrets.items.len);

    const gpu = try t.load(&sources, .{ .profile = "gpu" });
    try std.testing.expectEqualStrings("CUDA/13.3.0", gpu.dev_modules.value[0]);
    try std.testing.expectEqualStrings("salloc -p gpu", gpu.allocation_hint.value);
}

test "the environment overrides files and options override the environment" {
    var t = Fixture.init();
    defer t.deinit();
    const sources = [_]Source{.{ .path = "u.toml", .text = user_text, .layer = .user }};
    try t.env.put("EB_LOCAL_PREFIX", "/env/prefix");
    try t.env.put("EB_LOCAL_DEV_MODULES", "GSL/2.8-GCC-15.2.0 CMake/3.31.11-GCCcore-15.2.0");
    try t.env.put("EB_LOCAL_TRASH", "none");
    var s = try t.load(&sources, .{});
    try std.testing.expectEqualStrings("/env/prefix", s.prefix.value);
    try std.testing.expectEqualStrings("environment EB_LOCAL_PREFIX", s.prefix.from);
    try std.testing.expectEqual(@as(usize, 2), s.dev_modules.value.len);
    try std.testing.expectEqual(Trash.none, s.trash.value);
    s = try t.load(&sources, .{ .prefix = "/opt/prefix", .buildenv = "buildenv/mine" });
    try std.testing.expectEqualStrings("/opt/prefix", s.prefix.value);
    try std.testing.expectEqualStrings("buildenv/mine", s.dev_buildenv.value);
    try t.env.put("EB_LOCAL_PROFILE", "group");
    s = try t.load(&sources, .{});
    try std.testing.expectEqualStrings("group", s.profile.?);
}

test "an empty variable empties a setting that may be empty and is ignored by one that may not" {
    var t = Fixture.init();
    defer t.deinit();
    const sources = [_]Source{
        .{ .path = "/etc/eb-local/config.toml", .text = site_text, .layer = .site },
        .{ .path = "u.toml", .text = "[nimvault]\nprogram = \"/opt/nimvault/bin/nimvault\"\nvault = \"~/vault\"\n", .layer = .user },
    };
    for ([_][]const u8{
        "EB_LOCAL_DEV_MODULES",    "EB_LOCAL_BUILD_ALLOCATION_HINT", "EB_LOCAL_NIMVAULT_PROGRAM",
        "EB_LOCAL_NIMVAULT_VAULT", "EB_LOCAL_PREFIX",                "EB_LOCAL_STACK_MODULE",
        "EB_LOCAL_CLEAN_TRASH",
    }) |name| try t.env.put(name, "");
    const s = try t.load(&sources, .{ .profile = "gpu" });
    try std.testing.expectEqual(@as(usize, 0), s.dev_modules.value.len);
    try std.testing.expectEqualStrings("environment EB_LOCAL_DEV_MODULES", s.dev_modules.from);
    try std.testing.expectEqualStrings("", s.allocation_hint.value);
    try std.testing.expectEqualStrings("environment EB_LOCAL_BUILD_ALLOCATION_HINT", s.allocation_hint.from);
    try std.testing.expectEqualStrings("", s.nimvault_program.value);
    try std.testing.expectEqualStrings("", s.nimvault_vault.value);
    try std.testing.expectEqualStrings("~/eessi", s.prefix.value);
    try std.testing.expectEqualStrings("EESSI/2026.06", s.stack_module.value);
    try std.testing.expectEqual(Trash.auto, s.trash.value);
}

test "refusals" {
    var t = Fixture.init();
    defer t.deinit();
    const r = struct {
        fn one(tt: *Fixture, text: []const u8, layer: Layer, needle: []const u8) !void {
            try tt.refuse(&.{.{ .path = "c.toml", .text = text, .layer = layer }}, needle);
        }
    };
    try r.one(&t, "[storage]\nnode_local_root = \"/x\"\n", .user, "site setting");
    try r.one(&t, "[profile.p.storage]\nnode_local_root = \"/x\"\n", .site, "site setting");
    try r.one(&t, "[profile.unused]\ncolour = 1\n", .user, "unknown key colour");
    try r.one(&t, "[secrets]\nTOKEN = \"hunter2\"\n", .user, "never written");
    try r.one(&t, "[secrets]\nLD_PRELOAD = \"env:X\"\n", .user, "not a variable name");
    try r.one(&t, "[secrets]\nPATH = \"env:X\"\n", .user, "not a variable name");
    try r.one(&t, "[secrets]\nT = \"file:relative\"\n", .user, "c.toml:2: secret T: file: takes an absolute path or one starting ~/");
    try r.one(&t, "[secrets]\nT = \"env:1X\"\n", .user, "c.toml:2: secret T: env: takes a variable name");
    try r.one(&t, "[secrets]\nT = \"env:\"\n", .user, "c.toml:2: secret T: env: takes a variable name");
    try r.one(&t, "[secrets]\nT = \"nimvault:\"\n", .user, "c.toml:2: secret T: nimvault: takes an entry");
    try r.one(&t, "[secrets]\nT = \"nimvault:--recipient\"\n", .user, "c.toml:2: secret T: a nimvault entry may not start with -");
    try r.one(&t, "[secrets]\nT = \"nimvault:a\\nb\"\n", .user, "c.toml:2: secret T: a source may not hold a line break or NUL");
    try r.one(&t, "[stack]\nmodule = \"EESSI;rm -rf ~\"\n", .user, "not a module name");
    try r.one(&t, "[dev]\nmodules = [\"$(id)\"]\n", .user, "not a module name");
    try r.one(&t, "[dev]\nmodules = \"GSL\"\n", .user, "array of strings");
    try r.one(&t, "[clean]\ntrash = \"bin\"\n", .user, "auto, rtrash or none");
    try r.one(&t, "[clean]\nlogs_older_than_days = -1\n", .user, "out of range");
    try r.one(&t, "colour = \"blue\"\n", .user, "unknown key colour");
    try r.one(&t, "[stack]\nmodule = 1\n", .user, "must be a string");
    try r.one(&t, "default_profile = \"nope\"\n", .user, "no profile 'nope'");
    try r.one(&t, "[storage]\nnode_local_root = \"relative\"\n", .site, "absolute");
    try r.one(&t, "x = 1\nx = 2\n", .user, "c.toml:2");
    try r.one(&t, "[build]\nsecrets = \"TOKEN\"\n", .user, "build.secrets must be an array of strings");
    try r.one(&t, "[build]\nsecrets = [\"PATH\"]\n", .user, "c.toml:2: build.secrets: PATH is not a variable name a secret may set");
    try r.one(&t, "[build]\nsecrets = [\"TOKEN\"]\n", .user, "build.secrets [user c.toml:2] names TOKEN, but no secret TOKEN is defined");
    t.env.put("EB_LOCAL_STACK_MODULE", "a b") catch unreachable;
    try r.one(&t, "", .user, "EB_LOCAL_STACK_MODULE");
}

test "a refused secret source says what is wrong with it" {
    for ([_][]const u8{ "env:MY_TOKEN", "file:/run/token", "file:~/.secrets/token", "nimvault:licences/flexlm" }) |source|
        try std.testing.expectEqual(.ok, std.meta.activeTag(checkSecretSource(source)));
    for ([_][]const u8{ "hunter2", "", "ENV:X", "vault:x" }) |source|
        try std.testing.expectEqual(.unknown, std.meta.activeTag(checkSecretSource(source)));

    var t = Fixture.init();
    defer t.deinit();
    try t.env.put("EB_LOCAL_SECRET_T", "nimvault:-x");
    try t.refuse(&.{}, "EB_LOCAL_SECRET_T: a nimvault entry may not start with -, since nimvault would read it as an option");
    try t.env.put("EB_LOCAL_SECRET_T", "file:token");
    try t.refuse(&.{}, "EB_LOCAL_SECRET_T: file: takes an absolute path or one starting ~/");
    try t.env.put("EB_LOCAL_SECRET_T", "hunter2");
    try t.refuse(&.{}, "EB_LOCAL_SECRET_T: a source is env:VAR, file:PATH or nimvault:ENTRY; a value is never written in a variable");
    try t.env.put("EB_LOCAL_SECRET_T", "env:MY_TOKEN");
    const s = try t.load(&.{}, .{});
    try std.testing.expectEqualStrings("env:MY_TOKEN", s.secrets.items[0].source);
}

test "build.secrets names the secrets a build gets" {
    var t = Fixture.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const text =
        \\[build]
        \\secrets = []
        \\[secrets]
        \\SOURCE_TOKEN = "env:MY_TOKEN"
        \\MIRROR_PASSWORD = "env:MY_MIRROR"
        \\[profile.licensed]
        \\build.secrets = ["LM_LICENSE_FILE", "SOURCE_TOKEN"]
        \\[profile.licensed.secrets]
        \\LM_LICENSE_FILE = "nimvault:licences/flexlm"
    ;
    const sources = [_]Source{.{ .path = "u.toml", .text = text, .layer = .user }};

    // With nothing setting it, a build gets every secret.
    var s = try t.load(&.{.{ .path = "u.toml", .text = user_text, .layer = .user }}, .{ .profile = "group" });
    try std.testing.expect(s.build_secrets.value == null);
    try std.testing.expectEqualStrings("default", s.build_secrets.from);
    try std.testing.expectEqual(@as(usize, 2), (try buildSecrets(a, s)).len);

    s = try t.load(&sources, .{});
    try std.testing.expectEqualStrings("user u.toml:2", s.build_secrets.from);
    try std.testing.expectEqual(@as(usize, 0), (try buildSecrets(a, s)).len);
    try std.testing.expect(!buildGets(s, "SOURCE_TOKEN"));

    s = try t.load(&sources, .{ .profile = "licensed" });
    try std.testing.expectEqualStrings("user profile licensed, u.toml:7", s.build_secrets.from);
    const got = try buildSecrets(a, s);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("SOURCE_TOKEN", got[0].name);
    try std.testing.expectEqualStrings("LM_LICENSE_FILE", got[1].name);
    try std.testing.expect(!buildGets(s, "MIRROR_PASSWORD"));

    try t.env.put("EB_LOCAL_BUILD_SECRETS", " MIRROR_PASSWORD\tSOURCE_TOKEN ");
    s = try t.load(&sources, .{ .profile = "licensed" });
    try std.testing.expectEqualStrings("environment EB_LOCAL_BUILD_SECRETS", s.build_secrets.from);
    try std.testing.expect(buildGets(s, "MIRROR_PASSWORD") and buildGets(s, "SOURCE_TOKEN") and !buildGets(s, "LM_LICENSE_FILE"));
    try t.env.put("EB_LOCAL_BUILD_SECRETS", "");
    s = try t.load(&sources, .{ .profile = "licensed" });
    try std.testing.expectEqual(@as(usize, 0), (try buildSecrets(a, s)).len);

    // Only the profile defines LM_LICENSE_FILE.
    try t.env.put("EB_LOCAL_BUILD_SECRETS", "LM_LICENSE_FILE");
    try t.refuse(&sources, "build.secrets [environment EB_LOCAL_BUILD_SECRETS] names LM_LICENSE_FILE, but no secret LM_LICENSE_FILE " ++
        "is defined: add it to [secrets], or set EB_LOCAL_SECRET_LM_LICENSE_FILE=SOURCE");
    try t.env.put("EB_LOCAL_BUILD_SECRETS", "SOURCE_TOKEN LD_PRELOAD");
    try t.refuse(&sources, "EB_LOCAL_BUILD_SECRETS: LD_PRELOAD is not a variable name a secret may set");
}

test "storage.node_local_mount" {
    var t = Fixture.init();
    defer t.deinit();
    var s = try t.load(&.{}, .{});
    try std.testing.expectEqualStrings("%u.%j", s.node_local_mount.value);
    try std.testing.expectEqualStrings("default", s.node_local_mount.from);
    s = try t.load(&.{.{ .path = "site.toml", .text = "[storage]\nnode_local_mount = \"job-%j\"\n", .layer = .site }}, .{});
    try std.testing.expectEqualStrings("job-%j", s.node_local_mount.value);
    try std.testing.expectEqualStrings("site site.toml:2", s.node_local_mount.from);
    for ([_][]const u8{ "%u", "../%j", "%u/%j", "%j;id" }) |bad| {
        const text = try std.fmt.allocPrint(t.arena.allocator(), "[storage]\nnode_local_mount = \"{s}\"\n", .{bad});
        try t.refuse(&.{.{ .path = "c.toml", .text = text, .layer = .site }}, "storage.node_local_mount must be one file name");
    }
    try t.refuse(&.{.{ .path = "c.toml", .text = "[storage]\nnode_local_mount = \"%j\"\n", .layer = .user }}, "site setting");
}

test "dev.buildenv_for from the environment" {
    var t = Fixture.init();
    defer t.deinit();
    try t.env.put("EB_LOCAL_DEV_BUILDENV_FOR_CUDA", "none");
    try t.env.put("EB_LOCAL_DEV_BUILDENV_FOR_NVHPC", "buildenv/site-nvhpc-26.7");
    const s = try t.load(&.{}, .{});
    try std.testing.expectEqualStrings("", s.buildenv_for[0].value);
    try std.testing.expectEqualStrings("environment EB_LOCAL_DEV_BUILDENV_FOR_CUDA", s.buildenv_for[0].from);
    try std.testing.expectEqualStrings("buildenv/site-nvhpc-26.7", s.buildenv_for[3].value);
    try t.env.put("EB_LOCAL_DEV_BUILDENV_FOR_LLVM", "x;y");
    try t.refuse(&.{}, "EB_LOCAL_DEV_BUILDENV_FOR_LLVM");
}

test "dev.buildenv_for per compiler family" {
    var t = Fixture.init();
    defer t.deinit();
    const text =
        \\[dev.buildenv_for]
        \\nvhpc = "buildenv/site-nvhpc-26.7"
        \\llvm = ""
    ;
    const s = try t.load(&.{.{ .path = "site.toml", .text = text, .layer = .site }}, .{});
    try std.testing.expectEqualStrings("buildenv/default-foss-2026.1-CUDA-13.3.0", s.buildenv_for[0].value);
    try std.testing.expectEqualStrings("default", s.buildenv_for[0].from);
    try std.testing.expectEqualStrings("", s.buildenv_for[1].value);
    try std.testing.expectEqualStrings("buildenv/site-nvhpc-26.7", s.buildenv_for[3].value);
    try std.testing.expectEqualStrings("site site.toml:2", s.buildenv_for[3].from);
    try t.refuse(&.{.{ .path = "c.toml", .text = "[dev.buildenv_for]\nrocm = \"x\"\n", .layer = .user }}, "unknown key dev.buildenv_for.rocm");
    try t.refuse(&.{.{ .path = "c.toml", .text = "[dev.buildenv_for]\nllvm = \"a;b\"\n", .layer = .user }}, "not a module name");
}

test "family EBROOT names are the ones EasyBuild writes" {
    const a = std.testing.allocator;
    const cases = [_]struct { software: []const u8, ebroot: []const u8 }{
        .{ .software = "CUDA", .ebroot = families[0].ebroot },
        .{ .software = "llvm-compilers", .ebroot = families[1].ebroot },
        .{ .software = "intel-compilers", .ebroot = families[2].ebroot },
        .{ .software = "NVHPC", .ebroot = families[3].ebroot },
    };
    for (cases) |c| {
        const got = try ebRoot(a, c.software);
        defer a.free(got);
        try std.testing.expectEqualStrings(c.ebroot, got);
    }
    const dotted = try ebRoot(a, "foo.bar");
    defer a.free(dotted);
    try std.testing.expectEqualStrings("EBROOTFOOBAR", dotted);
    const plus = try ebRoot(a, "C++");
    defer a.free(plus);
    try std.testing.expectEqualStrings("EBROOTCPLUSPLUS", plus);
}

test "[eessi] settings layer like secrets and refuse the ones eb-local owns" {
    var t = Fixture.init();
    defer t.deinit();
    const site =
        \\[eessi]
        \\EESSI_IGNORE_LMOD_ERROR_ZEN4_GCC1220 = '{"a": "b"}'
        \\EESSI_OVERRIDE_TOOLCHAIN_CHECK = "1"
    ;
    const user =
        \\[profile.mine.eessi]
        \\EESSI_OVERRIDE_TOOLCHAIN_CHECK = ""
    ;
    const sources = [_]Source{
        .{ .path = "site.toml", .text = site, .layer = .site },
        .{ .path = "user.toml", .text = user, .layer = .user },
    };
    var s = try t.load(&sources, .{});
    try std.testing.expectEqual(@as(usize, 2), s.eessi.items.len);
    try std.testing.expectEqualStrings("EESSI_IGNORE_LMOD_ERROR_ZEN4_GCC1220", s.eessi.items[0].name);
    try std.testing.expectEqualStrings("{\"a\": \"b\"}", s.eessi.items[0].value);
    try std.testing.expectEqualStrings("site site.toml:2", s.eessi.items[0].from);
    s = try t.load(&sources, .{ .profile = "mine" });
    try std.testing.expectEqual(@as(usize, 2), s.eessi.items.len);
    try std.testing.expectEqualStrings("", s.eessi.items[1].value);
    try std.testing.expectEqualStrings("user profile mine, user.toml:2", s.eessi.items[1].from);

    const r = struct {
        fn one(tt: *Fixture, text: []const u8, needle: []const u8) !void {
            try tt.refuse(&.{.{ .path = "c.toml", .text = text, .layer = .site }}, needle);
        }
    };
    try r.one(&t, "[eessi]\nEESSI_USER_INSTALL = \"/x\"\n", "install and target");
    try r.one(&t, "[eessi]\nEESSI_SOFTWARE_SUBDIR_OVERRIDE = \"x86_64/generic\"\n", "install and target");
    try r.one(&t, "[eessi]\nPATH = \"/x\"\n", "install and target");
    try r.one(&t, "[eessi]\nEESSI_SITE_TOP_LEVEL_TOOLCHAINS_2026_06 = \"[]\"\n", "build.site_toolchains");
    try r.one(&t, "[eessi]\nEESSI_ = \"x\"\n", "install and target");
    try r.one(&t, "[eessi]\nEESSI_X = 1\n", "must be a string");
    try r.one(&t, "[eessi]\nEESSI_X = \"a\\nb\"\n", "one line");
}

test "module names" {
    for ([_][]const u8{ "EESSI/2026.06", "buildenv/default-foss-2026.1", "R/4.6.1-gfbf-2026.1", "Python-bundle-PyPI/2025.04-GCCcore-14.2.0", "g++/1" }) |ok|
        try std.testing.expect(validModule(ok));
    for ([_][]const u8{ "", "/x", "x/", "a//b", "../x", "a/../b", "-x", "a b", "a;b", "$(id)", "a`b`", "a\nb" }) |bad|
        try std.testing.expect(!validModule(bad));
}

test "the 1.x site file" {
    var t = Fixture.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var d: Diagnostic = .{};
    const text = try legacyToToml(a,
        \\# site
        \\node_local_root = /local
        \\node_local_mount = job-%j
        \\node_local_fstype = xfs
        \\shared_scratch = /scratch /work
        \\allocation_hint = salloc -p cpu -n 16 -t 02:00:00
        \\stack_module = stack/mine
        \\extend_module = EESSI-extend/2026.06-easybuild
        \\trash = none
    , &d);
    const s = try t.load(&.{.{ .path = "eb-local.conf", .text = text, .layer = .site }}, .{});
    try std.testing.expectEqualStrings("/local", s.node_local_root.value);
    try std.testing.expectEqualStrings("job-%j", s.node_local_mount.value);
    try std.testing.expectEqual(@as(usize, 2), s.shared_scratch.value.len);
    try std.testing.expectEqualStrings("salloc -p cpu -n 16 -t 02:00:00", s.allocation_hint.value);
    try std.testing.expectEqual(Trash.none, s.trash.value);
    try std.testing.expectEqualStrings("stack/mine", s.stack_module.value);
    try std.testing.expectError(error.Invalid, legacyToToml(a, "source_me = $(touch x)\n", &d));

    // Each setting is where its own line is, whatever its table and order.
    try std.testing.expectEqualStrings("site eb-local.conf:2", s.node_local_root.from);
    try std.testing.expectEqualStrings("site eb-local.conf:6", s.allocation_hint.from);
    try std.testing.expectEqualStrings("site eb-local.conf:9", s.trash.from);
    const reordered = try legacyToToml(a,
        \\allocation_hint = salloc -n 16
        \\
        \\# the node-local disk
        \\node_local_root = /local   # each job's mount is below it
        \\node_local_mount = job-%j
    , &d);
    const r = try t.load(&.{.{ .path = "eb-local.conf", .text = reordered, .layer = .site }}, .{});
    try std.testing.expectEqualStrings("site eb-local.conf:1", r.allocation_hint.from);
    try std.testing.expectEqualStrings("site eb-local.conf:4", r.node_local_root.from);
    try std.testing.expectEqualStrings("site eb-local.conf:5", r.node_local_mount.from);
}

test "each node type is where its own line is" {
    var t = Fixture.init();
    defer t.deinit();
    const site =
        \\[build]
        \\allocation_hint = "salloc -p cpu -n 16"
        \\
        \\[build.node_types]
        \\cpu = "-p cpu -n 16 -t 02:00:00"
        \\gpu = "-p gpu -n 16 -t 02:00:00 --gpus=1"
    ;
    const s = try t.load(&.{.{ .path = "site.toml", .text = site, .layer = .site }}, .{});
    try std.testing.expectEqual(@as(usize, 2), s.node_types.value.len);
    try std.testing.expectEqualStrings("cpu", s.node_types.value[0].name);
    try std.testing.expectEqualStrings("site site.toml:5", s.node_types.value[0].from);
    try std.testing.expectEqualStrings("gpu", s.node_types.value[1].name);
    try std.testing.expectEqualStrings("site site.toml:6", s.node_types.value[1].from);
    try std.testing.expect(s.node_types_old_key == null);
}

test "build.targets is read as build.node_types until 4.0.0, and not with it" {
    var t = Fixture.init();
    defer t.deinit();
    const old =
        \\[build.targets]
        \\cpu = "-p cpu -n 16 -t 02:00:00"
    ;
    const s = try t.load(&.{.{ .path = "site.toml", .text = old, .layer = .site }}, .{});
    try std.testing.expectEqual(@as(usize, 1), s.node_types.value.len);
    try std.testing.expectEqualStrings("-p cpu -n 16 -t 02:00:00", s.node_types.value[0].sbatch);
    try std.testing.expectEqualStrings("site site.toml:1", s.node_types_old_key.?);
    const both =
        \\[build.node_types]
        \\cpu = "-p cpu"
        \\[build.targets]
        \\gpu = "-p gpu"
    ;
    try t.refuse(&.{.{ .path = "site.toml", .text = both, .layer = .site }}, "site.toml:3: build.targets is the old name of build.node_types, which line 1 sets; keep one");
    try t.refuse(&.{.{ .path = "user.toml", .text = old, .layer = .user }}, "user.toml:1: build.targets is a site setting");
}

test "build.node_types" {
    try std.testing.expect(validSbatchOptions("-p cpu -n 16 -t 02:00:00 --constraint=local-disk"));
    try std.testing.expect(!validSbatchOptions("-p cpu; rm -rf ~"));
    try std.testing.expect(!validSbatchOptions("-p '$(id)'"));
    try std.testing.expect(!validSbatchOptions("cpu"));
    try std.testing.expect(!validSbatchOptions(" "));
    try std.testing.expect(validNodeTypeName("gpu_cc90"));
    try std.testing.expect(!validNodeTypeName("a b"));
    try std.testing.expect(!validNodeTypeName(""));
}
