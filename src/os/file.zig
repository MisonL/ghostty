const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const log = std.log.scoped(.os);

pub const rlimit = if (@hasDecl(posix.system, "rlimit")) posix.rlimit else struct {};

/// This maximizes the number of file descriptors we can have open. We
/// need to do this because each window consumes at least a handful of fds.
/// This is extracted from the Zig compiler source code.
pub fn fixMaxFiles() ?rlimit {
    if (!@hasDecl(posix.system, "rlimit") or
        posix.system.rlimit == void) return null;

    const old = posix.getrlimit(.NOFILE) catch {
        log.warn("failed to query file handle limit, may limit max windows", .{});
        return null; // Oh well; we tried.
    };

    // If we're already at the max, we're done.
    if (old.cur >= old.max) {
        log.debug("file handle limit already maximized value={}", .{old.cur});
        return old;
    }

    // Do a binary search for the limit.
    var lim = old;
    var min: posix.rlim_t = lim.cur;
    var max: posix.rlim_t = 1 << 20;
    // But if there's a defined upper bound, don't search, just set it.
    if (lim.max != posix.RLIM.INFINITY) {
        min = lim.max;
        max = lim.max;
    }

    while (true) {
        lim.cur = min + @divTrunc(max - min, 2); // on freebsd rlim_t is signed
        if (posix.setrlimit(.NOFILE, lim)) |_| {
            min = lim.cur;
        } else |_| {
            max = lim.cur;
        }
        if (min + 1 >= max) break;
    }

    log.debug("file handle limit raised value={}", .{lim.cur});
    return old;
}

pub fn restoreMaxFiles(lim: rlimit) void {
    if (!@hasDecl(posix.system, "rlimit")) return;
    posix.setrlimit(.NOFILE, lim) catch {};
}

/// Return the recommended path for temporary files.
/// This may not actually allocate memory, use freeTmpDir to properly
/// free the memory when applicable.
pub fn allocTmpDir(allocator: std.mem.Allocator) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        // Prefer the well-known environment variables (TMP/TEMP). If unset, fall
        // back to LOCALAPPDATA\\Temp.
        const tmp = std.process.getenvW(std.unicode.utf8ToUtf16LeStringLiteral("TMP"));
        if (tmp) |v| if (v.len > 0) {
            return std.unicode.utf16LeToUtf8Alloc(allocator, v) catch |e| {
                log.warn("failed to convert temp dir path from windows string: {}", .{e});
                return null;
            };
        };

        const temp = std.process.getenvW(std.unicode.utf8ToUtf16LeStringLiteral("TEMP"));
        if (temp) |v| if (v.len > 0) {
            return std.unicode.utf16LeToUtf8Alloc(allocator, v) catch |e| {
                log.warn("failed to convert temp dir path from windows string: {}", .{e});
                return null;
            };
        };

        const local = std.process.getenvW(std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA")) orelse return null;
        if (local.len == 0) return null;
        const base = std.unicode.utf16LeToUtf8Alloc(allocator, local) catch |e| {
            log.warn("failed to convert temp dir path from windows string: {}", .{e});
            return null;
        };
        defer allocator.free(base);

        const suffix = "Temp";
        const needs_sep = !(std.mem.endsWith(u8, base, "\\") or std.mem.endsWith(u8, base, "/"));
        const extra: usize = if (needs_sep) 1 + suffix.len else suffix.len;
        const out = allocator.alloc(u8, base.len + extra) catch {
            log.warn("failed to allocate temp dir path", .{});
            return null;
        };
        @memcpy(out[0..base.len], base);
        var i: usize = base.len;
        if (needs_sep) {
            out[i] = '\\';
            i += 1;
        }
        @memcpy(out[i .. i + suffix.len], suffix);
        return out;
    }
    if (posix.getenv("TMPDIR")) |v| return v;
    if (posix.getenv("TMP")) |v| return v;
    return "/tmp";
}

/// Free a path returned by tmpDir if it allocated memory.
/// This is a "no-op" for all platforms except windows.
pub fn freeTmpDir(allocator: std.mem.Allocator, dir: []const u8) void {
    if (builtin.os.tag == .windows) {
        allocator.free(dir);
    }
}

fn allocTmpDirWindowsFromEnvUtf8(
    allocator: std.mem.Allocator,
    tmp: ?[]const u8,
    temp: ?[]const u8,
    localappdata: ?[]const u8,
) ?[]const u8 {
    const suffix = "Temp";
    if (tmp) |v| if (v.len > 0) return allocator.dupe(u8, v) catch return null;
    if (temp) |v| if (v.len > 0) return allocator.dupe(u8, v) catch return null;
    if (localappdata) |v| if (v.len > 0) {
        const needs_sep = !(std.mem.endsWith(u8, v, "\\") or std.mem.endsWith(u8, v, "/"));
        const extra: usize = if (needs_sep) 1 + suffix.len else suffix.len;
        const out = allocator.alloc(u8, v.len + extra) catch return null;
        @memcpy(out[0..v.len], v);
        var i: usize = v.len;
        if (needs_sep) {
            out[i] = '\\';
            i += 1;
        }
        @memcpy(out[i .. i + suffix.len], suffix);
        return out;
    };

    return null;
}

test "allocTmpDirWindowsFromEnvUtf8 preference order" {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        const dir = allocTmpDirWindowsFromEnvUtf8(alloc, "C:\\Tmp", "C:\\Temp", "C:\\Users\\me\\AppData\\Local").?;
        defer alloc.free(dir);
        try testing.expectEqualStrings("C:\\Tmp", dir);
    }

    {
        const dir = allocTmpDirWindowsFromEnvUtf8(alloc, null, "C:\\Temp", "C:\\Users\\me\\AppData\\Local").?;
        defer alloc.free(dir);
        try testing.expectEqualStrings("C:\\Temp", dir);
    }

    {
        const dir = allocTmpDirWindowsFromEnvUtf8(alloc, "", "C:\\Temp", "C:\\Users\\me\\AppData\\Local").?;
        defer alloc.free(dir);
        try testing.expectEqualStrings("C:\\Temp", dir);
    }

    {
        const dir = allocTmpDirWindowsFromEnvUtf8(alloc, null, null, "C:\\Users\\me\\AppData\\Local").?;
        defer alloc.free(dir);
        try testing.expectEqualStrings("C:\\Users\\me\\AppData\\Local\\Temp", dir);
    }

    try testing.expect(allocTmpDirWindowsFromEnvUtf8(alloc, null, null, null) == null);
}
