//! `eb-local check`: what a program built by hand on EESSI depends on, and
//! whether it can run here. It reads the ELF file's loader (PT_INTERP), run
//! paths (DT_RPATH, DT_RUNPATH) and needed libraries (DT_NEEDED), finds each
//! library as the loader would, and reports what breaks the "no
//! LD_LIBRARY_PATH, one CPU target" rule: a foreign architecture, the host's
//! loader or libraries under an EESSI stack, RUNPATH, a library not found,
//! and run paths into another CPU target's software tree.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const common = @import("zig_common");
const sys = common.sys;
const fsx = common.fsx;
const Allocator = std.mem.Allocator;

const pt_load = 1;
const pt_dynamic = 2;
const pt_interp = 3;
const dt_null = 0;
const dt_needed = 1;
const dt_strtab = 5;
const dt_strsz = 10;
const dt_rpath = 15;
const dt_runpath = 29;

/// Header fields beyond these sizes mean a damaged or hostile file.
const max_phnum = 4096;
const max_dynamic = 64 * 1024;
const max_strtab = 16 * 1024 * 1024;

/// What an ELF file says about its dynamic linking: its machine, its
/// program interpreter (the loader), the libraries it names as `DT_NEEDED`,
/// and its `DT_RPATH` and `DT_RUNPATH`; null where it has none.
pub const Elf = struct {
    machine: u16,
    interp: ?[]const u8 = null,
    needed: []const []const u8 = &.{},
    rpath: ?[]const u8 = null,
    runpath: ?[]const u8 = null,
};

/// Why `parse` read nothing: `NotElf64` for a file too short for an ELF
/// header or without the ELF magic, `Unsupported` for a 32-bit or
/// big-endian one, `Truncated` when the file ends before a part its headers
/// name, and `Damaged` for a header field out of bounds, a string with no
/// end, or a read that fails.
pub const ParseError = error{ NotElf64, Unsupported, Truncated, Damaged } || sys.Error || Allocator.Error;

const Phdr = struct { type: u32, offset: u64, vaddr: u64, filesz: u64 };

fn readAt(fd: sys.fd_t, buf: []u8, off: u64) ParseError!void {
    // Offsets come from the file, so they are checked before use.
    if (off > std.math.maxInt(i64) - buf.len) return error.Damaged;
    var done: usize = 0;
    while (done < buf.len) {
        const rc = linux.pread(fd, buf[done..].ptr, buf.len - done, @intCast(off + done));
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.Damaged,
        }
        if (rc == 0) return error.Truncated;
        done += rc;
    }
}

fn le(comptime T: type, b: []const u8) T {
    return std.mem.readInt(T, b[0..@sizeOf(T)], .little);
}

/// The dynamic-linking facts of the 64-bit little-endian ELF file open as
/// `fd`; every string is copied into `a`.
pub fn parse(a: Allocator, fd: sys.fd_t) ParseError!Elf {
    var eh: [64]u8 = undefined;
    readAt(fd, &eh, 0) catch |e| return if (e == error.Truncated) error.NotElf64 else e;
    if (!std.mem.eql(u8, eh[0..4], "\x7fELF")) return error.NotElf64;
    if (eh[4] != 2 or eh[5] != 1) return error.Unsupported; // ELFCLASS64, little-endian
    var elf: Elf = .{ .machine = le(u16, eh[18..]) };
    const phoff = le(u64, eh[32..]);
    const phentsize = le(u16, eh[54..]);
    const phnum = le(u16, eh[56..]);
    if (phentsize < 56 or phnum > max_phnum) return error.Damaged;

    var phdrs: std.ArrayList(Phdr) = .empty;
    defer phdrs.deinit(a);
    var ph: [56]u8 = undefined;
    for (0..phnum) |i| {
        try readAt(fd, &ph, phoff +| i * phentsize);
        try phdrs.append(a, .{ .type = le(u32, ph[0..]), .offset = le(u64, ph[8..]), .vaddr = le(u64, ph[16..]), .filesz = le(u64, ph[32..]) });
    }
    var dyn: ?Phdr = null;
    for (phdrs.items) |p| switch (p.type) {
        pt_interp => {
            if (p.filesz == 0 or p.filesz > 4096) return error.Damaged;
            const buf = try a.alloc(u8, p.filesz);
            errdefer a.free(buf);
            try readAt(fd, buf, p.offset);
            elf.interp = std.mem.sliceTo(buf, 0);
        },
        pt_dynamic => dyn = p,
        else => {},
    };
    const d = dyn orelse return elf; // a static program
    if (d.filesz > max_dynamic) return error.Damaged;
    const raw = try a.alloc(u8, d.filesz);
    defer a.free(raw);
    try readAt(fd, raw, d.offset);

    var strtab_vaddr: ?u64 = null;
    var strsz: u64 = 0;
    var needed_offs: std.ArrayList(u64) = .empty;
    defer needed_offs.deinit(a);
    var rpath_off: ?u64 = null;
    var runpath_off: ?u64 = null;
    var i: usize = 0;
    while (i + 16 <= raw.len) : (i += 16) {
        const tag = le(i64, raw[i..]);
        const val = le(u64, raw[i + 8 ..]);
        switch (tag) {
            dt_null => break,
            dt_needed => try needed_offs.append(a, val),
            dt_strtab => strtab_vaddr = val,
            dt_strsz => strsz = val,
            dt_rpath => rpath_off = val,
            dt_runpath => runpath_off = val,
            else => {},
        }
    }
    const sv = strtab_vaddr orelse return elf;
    if (strsz == 0 or strsz > max_strtab) return error.Damaged;
    // DT_STRTAB is an address; the PT_LOAD segment holding it gives the offset.
    const str_end = std.math.add(u64, sv, strsz) catch return error.Damaged;
    const file_off = for (phdrs.items) |p| {
        const load_end = std.math.add(u64, p.vaddr, p.filesz) catch continue;
        if (p.type == pt_load and sv >= p.vaddr and str_end <= load_end) {
            break std.math.add(u64, p.offset, sv - p.vaddr) catch return error.Damaged;
        }
    } else return error.Damaged;
    const strtab = try a.alloc(u8, strsz);
    defer a.free(strtab);
    try readAt(fd, strtab, file_off);
    const str = struct {
        fn at(al: Allocator, t: []const u8, off: u64) ParseError![]const u8 {
            if (off >= t.len) return error.Damaged;
            const s = std.mem.sliceTo(t[off..], 0);
            if (s.len == t.len - off) return error.Damaged; // no terminating NUL
            return al.dupe(u8, s);
        }
    }.at;
    var needed: std.ArrayList([]const u8) = .empty;
    errdefer needed.deinit(a);
    for (needed_offs.items) |o| try needed.append(a, try str(a, strtab, o));
    elf.needed = try needed.toOwnedSlice(a);
    if (rpath_off) |o| elf.rpath = try str(a, strtab, o);
    if (runpath_off) |o| elf.runpath = try str(a, strtab, o);
    return elf;
}

/// The ELF machine of this build, which is the node's.
pub fn hostMachine() u16 {
    return switch (builtin.cpu.arch) {
        .x86_64 => 62,
        .aarch64 => 183,
        .riscv64 => 243,
        else => 0,
    };
}

/// The name `check` prints for the ELF machine `m`: `x86_64`, `aarch64`,
/// `riscv64`, `i386`, `arm`, or "another architecture".
pub fn machineName(m: u16) []const u8 {
    return switch (m) {
        62 => "x86_64",
        183 => "aarch64",
        243 => "riscv64",
        3 => "i386",
        40 => "arm",
        else => "another architecture",
    };
}

/// `dir` with $ORIGIN and ${ORIGIN} replaced by `origin`.
pub fn expandOrigin(a: Allocator, dir: []const u8, origin: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < dir.len) {
        if (std.mem.startsWith(u8, dir[i..], "${ORIGIN}")) {
            try out.appendSlice(a, origin);
            i += "${ORIGIN}".len;
        } else if (std.mem.startsWith(u8, dir[i..], "$ORIGIN")) {
            try out.appendSlice(a, origin);
            i += "$ORIGIN".len;
        } else {
            try out.append(a, dir[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(a);
}

/// The CPU target of an EESSI software tree a path lies in: the parts
/// after `/software/linux/` up to the next `software`, `modules` or `accel`,
/// as EESSI and EESSI-extend lay out their trees; null outside one.
pub fn targetOf(path: []const u8) ?[]const u8 {
    const key = "/software/linux/";
    const at = std.mem.indexOf(u8, path, key) orelse return null;
    const rest = path[at + key.len ..];
    var end: usize = 0;
    var it = std.mem.splitScalar(u8, rest, '/');
    var parts: usize = 0;
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "software") or std.mem.eql(u8, part, "modules") or std.mem.eql(u8, part, "accel")) break;
        if (part.len == 0) return null;
        end += part.len + @intFromBool(parts > 0);
        parts += 1;
        if (parts > 3) return null;
    } else return null;
    if (parts < 2) return null;
    return rest[0..end];
}

/// A host directory the EESSI compatibility layer replaces.
pub fn isHostPath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    var rest = path;
    while (rest.len > 0 and rest[0] == '/') rest = rest[1..];
    const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const first = rest[0..end];
    return std.mem.eql(u8, first, "lib") or std.mem.eql(u8, first, "lib64") or std.mem.eql(u8, first, "usr");
}

/// One ld.so.conf file: the directories it names go to `dirs` and the
/// patterns of its `include` lines to `includes`, in file order.
pub fn parseLdSoConf(a: Allocator, text: []const u8, dirs: *std.ArrayList([]const u8), includes: *std.ArrayList([]const u8)) Allocator.Error!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len], " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "include") and line.len > 7 and (line[7] == ' ' or line[7] == '\t')) {
            try includes.append(a, std.mem.trim(u8, line[7..], " \t"));
        } else if (line[0] == '/') {
            try dirs.append(a, line);
        }
    }
}

test "parseLdSoConf" {
    const a = std.testing.allocator;
    var dirs: std.ArrayList([]const u8) = .empty;
    defer dirs.deinit(a);
    var inc: std.ArrayList([]const u8) = .empty;
    defer inc.deinit(a);
    try parseLdSoConf(a, "include /etc/ld.so.conf.d/*.conf\n# c\n/usr/local/lib  # x\n\nhwcap 1 nosegneg\n", &dirs, &inc);
    try std.testing.expectEqual(@as(usize, 1), dirs.items.len);
    try std.testing.expectEqualStrings("/usr/local/lib", dirs.items[0]);
    try std.testing.expectEqualStrings("/etc/ld.so.conf.d/*.conf", inc.items[0]);
}

test "targetOf reads EESSI and EESSI-extend trees" {
    try std.testing.expectEqualStrings("x86_64/amd/zen4", targetOf("/cvmfs/software.eessi.io/versions/2026.06/software/linux/x86_64/amd/zen4/software/FFTW/3.3.10-GCC-15.2.0/lib").?);
    try std.testing.expectEqualStrings("aarch64/neoverse_v1", targetOf("/home/u/.local/eessi/versions/2026.06/software/linux/aarch64/neoverse_v1/software/GSL/2.8/lib").?);
    try std.testing.expectEqualStrings("x86_64/amd/zen4", targetOf("/x/software/linux/x86_64/amd/zen4/accel/nvidia/cc90/software/CUDA/lib64").?);
    try std.testing.expect(targetOf("/usr/lib64") == null);
    try std.testing.expect(targetOf("/x/software/linux/x86_64") == null);
    try std.testing.expect(targetOf("/x/software/linux/a/b/c/d/software/y") == null);
}

test "expandOrigin" {
    const a = std.testing.allocator;
    const x = try expandOrigin(a, "$ORIGIN/../lib:${ORIGIN}", "/opt/p/bin");
    defer a.free(x);
    try std.testing.expectEqualStrings("/opt/p/bin/../lib:/opt/p/bin", x);
}

test "host paths" {
    try std.testing.expect(isHostPath("/usr/lib64"));
    try std.testing.expect(isHostPath("/lib"));
    try std.testing.expect(isHostPath("//usr/lib64"));
    try std.testing.expect(isHostPath("///lib//x86_64-linux-gnu"));
    try std.testing.expect(!isHostPath("/library"));
    try std.testing.expect(!isHostPath("/cvmfs/software.eessi.io/versions/2026.06/compat/linux/x86_64/usr/lib64"));
}

test "parse reads this test binary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fd = try sys.openat(fsx.cwd, "/proc/self/exe", .{}, 0);
    defer sys.close(fd);
    const elf = try parse(arena.allocator(), fd);
    try std.testing.expectEqual(hostMachine(), elf.machine);
}

test "parse rejects wrapping DT_STRTAB bounds instead of saturating" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf = std.mem.zeroes([256]u8);
    @memcpy(buf[0..4], "\x7fELF");
    buf[4] = 2; // ELFCLASS64
    buf[5] = 1; // ELFDATA2LSB
    std.mem.writeInt(u16, buf[18..20], 62, .little); // x86_64
    std.mem.writeInt(u64, buf[32..40], 64, .little); // phoff
    std.mem.writeInt(u16, buf[54..56], 56, .little); // phentsize
    std.mem.writeInt(u16, buf[56..58], 2, .little); // phnum

    // PHDR 0: PT_LOAD covering [max-8, max], file offset 0, filesz 8
    std.mem.writeInt(u32, buf[64..68], pt_load, .little);
    std.mem.writeInt(u64, buf[64 + 8 ..][0..8], 0, .little);
    std.mem.writeInt(u64, buf[64 + 16 ..][0..8], std.math.maxInt(u64) - 8, .little);
    std.mem.writeInt(u64, buf[64 + 32 ..][0..8], 8, .little);

    // PHDR 1: PT_DYNAMIC at offset 176, filesz 48
    std.mem.writeInt(u32, buf[120..124], pt_dynamic, .little);
    std.mem.writeInt(u64, buf[120 + 8 ..][0..8], 176, .little);
    std.mem.writeInt(u64, buf[120 + 32 ..][0..8], 48, .little);

    // Dynamic entries: DT_STRTAB = max-4, DT_STRSZ = 16 (overflows u64!), DT_NULL
    std.mem.writeInt(i64, buf[176..184], dt_strtab, .little);
    std.mem.writeInt(u64, buf[184..192], std.math.maxInt(u64) - 4, .little);
    std.mem.writeInt(i64, buf[192..200], dt_strsz, .little);
    std.mem.writeInt(u64, buf[200..208], 16, .little);
    std.mem.writeInt(i64, buf[208..216], dt_null, .little);

    const tmp_path = try std.fmt.allocPrint(a, ".zig-cache/elf-wrap-{d}.bin", .{linux.getpid()});
    {
        const wfd = try sys.openat(fsx.cwd, tmp_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
        defer sys.close(wfd);
        try sys.writeAll(wfd, &buf);
    }
    var zb: [sys.path_max:0]u8 = undefined;
    const ztmp = try sys.z(&zb, tmp_path);
    defer _ = linux.unlinkat(linux.AT.FDCWD, ztmp.ptr, 0);
    const fd = try sys.openat(fsx.cwd, tmp_path, .{}, 0);
    defer sys.close(fd);
    try std.testing.expectError(error.Damaged, parse(a, fd));
}
