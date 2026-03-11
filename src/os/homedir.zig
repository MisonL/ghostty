const std = @import("std");
const builtin = @import("builtin");
const passwd = @import("passwd.zig");
const posix = std.posix;
const objc = @import("objc");

const Error = error{
    /// The buffer used for output is not large enough to store the value.
    BufferTooSmall,
};

/// Determine the home directory for the currently executing user. This
/// is generally an expensive process so the value should be cached.
pub inline fn home(buf: []u8) !?[]const u8 {
    return switch (builtin.os.tag) {
        inline .linux, .freebsd, .macos => try homeUnix(buf),
        .windows => try homeWindows(buf),

        // iOS doesn't have a user-writable home directory
        .ios => null,

        else => @compileError("unimplemented"),
    };
}

fn homeUnix(buf: []u8) !?[]const u8 {
    // First: if we have a HOME env var, then we use that.
    if (posix.getenv("HOME")) |result| {
        if (buf.len < result.len) return Error.BufferTooSmall;
        @memcpy(buf[0..result.len], result);
        return buf[0..result.len];
    }

    // On macOS: [NSFileManager defaultManager].homeDirectoryForCurrentUser.path
    if (builtin.os.tag == .macos) {
        const NSFileManager = objc.getClass("NSFileManager").?;
        const manager = NSFileManager.msgSend(objc.Object, objc.sel("defaultManager"), .{});
        const homeURL = manager.getProperty(objc.Object, "homeDirectoryForCurrentUser");
        const homePath = homeURL.getProperty(objc.Object, "path");

        const c_str = homePath.getProperty([*:0]const u8, "UTF8String");
        const result = std.mem.sliceTo(c_str, 0);

        if (buf.len < result.len) return Error.BufferTooSmall;
        @memcpy(buf[0..result.len], result);
        return buf[0..result.len];
    }

    // Everything below here will require some allocation
    var tempBuf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&tempBuf);

    // We try passwd. This doesn't work on multi-user mac but we try it anyways.
    const pw = try passwd.get(fba.allocator());
    if (pw.home) |result| {
        if (buf.len < result.len) return Error.BufferTooSmall;
        @memcpy(buf[0..result.len], result);
        return buf[0..result.len];
    }

    // If all else fails, have the shell tell us...
    fba.reset();
    const run = try std.process.Child.run(.{
        .allocator = fba.allocator(),
        .argv = &[_][]const u8{ "/bin/sh", "-c", "cd && pwd" },
        .max_output_bytes = fba.buffer.len / 2,
    });

    if (run.term == .Exited and run.term.Exited == 0) {
        const result = trimSpace(run.stdout);
        if (buf.len < result.len) return Error.BufferTooSmall;
        @memcpy(buf[0..result.len], result);
        return buf[0..result.len];
    }

    return null;
}

fn homeWindows(buf: []u8) !?[]const u8 {
    // Preserve existing behavior: prefer HOMEDRIVE + HOMEPATH.
    // If either variable is missing, fall back to USERPROFILE.
    var fba_instance = std.heap.FixedBufferAllocator.init(buf);
    const fba = fba_instance.allocator();

    const drive = std.process.getEnvVarOwned(fba, "HOMEDRIVE") catch |err| switch (err) {
        error.OutOfMemory => return Error.BufferTooSmall,
        error.InvalidWtf8 => return null,
        error.EnvironmentVariableNotFound => return homeWindowsUserProfile(buf),
    };
    // could shift the contents if this ever happens
    if (drive.ptr != buf.ptr) @panic("codebug");
    const drive_len = drive.len;

    const homepath = std.process.getEnvVarOwned(fba, "HOMEPATH") catch |err| switch (err) {
        error.OutOfMemory => return Error.BufferTooSmall,
        error.InvalidWtf8 => return null,
        error.EnvironmentVariableNotFound => return homeWindowsUserProfile(buf),
    };
    // could shift the contents if this ever happens
    if (homepath.ptr != buf[drive_len..].ptr) @panic("codebug");

    return buf[0 .. drive_len + homepath.len];
}

fn homeWindowsUserProfile(buf: []u8) !?[]const u8 {
    var fba_instance = std.heap.FixedBufferAllocator.init(buf);
    const fba = fba_instance.allocator();
    const userprofile = std.process.getEnvVarOwned(fba, "USERPROFILE") catch |err| switch (err) {
        error.OutOfMemory => return Error.BufferTooSmall,
        error.InvalidWtf8, error.EnvironmentVariableNotFound => return null,
    };
    // could shift the contents if this ever happens
    if (userprofile.ptr != buf.ptr) @panic("codebug");
    return userprofile;
}

fn homeWindowsFromEnvUtf8(
    buf: []u8,
    homedrive: ?[]const u8,
    homepath: ?[]const u8,
    userprofile: ?[]const u8,
) Error!?[]const u8 {
    // Preserve the same preference order as homeWindows: HOMEDRIVE+HOMEPATH,
    // then USERPROFILE.
    if (homedrive != null and homepath != null) {
        const drive = homedrive.?;
        const path = homepath.?;
        const total_len = drive.len + path.len;
        if (buf.len < total_len) return Error.BufferTooSmall;
        @memcpy(buf[0..drive.len], drive);
        @memcpy(buf[drive.len..total_len], path);
        return buf[0..total_len];
    }

    if (userprofile) |up| {
        if (buf.len < up.len) return Error.BufferTooSmall;
        @memcpy(buf[0..up.len], up);
        return buf[0..up.len];
    }

    return null;
}

fn trimSpace(input: []const u8) []const u8 {
    return std.mem.trim(u8, input, " \n\t");
}

pub const ExpandError = error{
    HomeDetectionFailed,
    BufferTooSmall,
};

/// Expands a path that starts with a tilde (~) to the home directory of
/// the current user.
///
/// Errors if `home` fails or if the size of the expanded path is larger
/// than `buf.len`.
pub fn expandHome(path: []const u8, buf: []u8) ExpandError![]const u8 {
    return switch (builtin.os.tag) {
        .linux, .freebsd, .macos, .windows => try expandHomeAny(path, buf),
        .ios => return path,
        else => @compileError("unimplemented"),
    };
}

fn expandHomeAny(path: []const u8, buf: []u8) ExpandError![]const u8 {
    if (!std.mem.startsWith(u8, path, "~/")) return path;
    const home_dir: []const u8 = if (home(buf)) |home_|
        home_ orelse return error.HomeDetectionFailed
    else |_|
        return error.HomeDetectionFailed;
    const rest = path[1..]; // Skip the ~
    const expanded_len = home_dir.len + rest.len;

    if (expanded_len > buf.len) return Error.BufferTooSmall;
    @memcpy(buf[home_dir.len..expanded_len], rest);
    if (builtin.os.tag == .windows) {
        for (buf[home_dir.len..expanded_len]) |*c| {
            if (c.* == '/') c.* = '\\';
        }
    }

    return buf[0..expanded_len];
}

test "expandHomeAny" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home_dir = try expandHomeAny("~/", &buf);
    // Joining the home directory `~` with the path `/`
    // the result should end with a separator here. (e.g. `/home/user/`)
    try testing.expect(home_dir[home_dir.len - 1] == std.fs.path.sep);

    const downloads = try expandHomeAny("~/Downloads/shader.glsl", &buf);
    const expected_downloads = try std.mem.concat(allocator, u8, &[_][]const u8{ home_dir, "Downloads/shader.glsl" });
    defer allocator.free(expected_downloads);
    if (builtin.os.tag == .windows) {
        const expected_windows = try std.mem.dupe(allocator, u8, expected_downloads);
        defer allocator.free(expected_windows);
        for (expected_windows[home_dir.len..]) |*c| {
            if (c.* == '/') c.* = '\\';
        }
        try testing.expectEqualStrings(expected_windows, downloads);
    } else {
        try testing.expectEqualStrings(expected_downloads, downloads);
    }

    try testing.expectEqualStrings("~", try expandHomeAny("~", &buf));
    try testing.expectEqualStrings("~abc/", try expandHomeAny("~abc/", &buf));
    try testing.expectEqualStrings("/home/user", try expandHomeAny("/home/user", &buf));
    try testing.expectEqualStrings("", try expandHomeAny("", &buf));

    // Expect an error if the buffer is large enough to hold the home directory,
    // but not the expanded path
    var small_buf = try allocator.alloc(u8, home_dir.len);
    defer allocator.free(small_buf);
    try testing.expectError(error.BufferTooSmall, expandHomeAny(
        "~/Downloads",
        small_buf[0..],
    ));
}

test {
    const testing = std.testing;

    var buf: [1024]u8 = undefined;
    const result = try home(&buf);
    try testing.expect(result != null);
    try testing.expect(result.?.len > 0);
}

test "homeWindows USERPROFILE fallback (env selection logic)" {
    const testing = std.testing;

    var buf: [128]u8 = undefined;

    const prefer = try homeWindowsFromEnvUtf8(
        &buf,
        "C:",
        "\\Users\\Alice",
        "C:\\Users\\Bob",
    );
    try testing.expectEqualStrings("C:\\Users\\Alice", prefer.?);

    const fallback = try homeWindowsFromEnvUtf8(
        &buf,
        null,
        null,
        "C:\\Users\\Bob",
    );
    try testing.expectEqualStrings("C:\\Users\\Bob", fallback.?);

    try testing.expect(try homeWindowsFromEnvUtf8(&buf, null, null, null) == null);
}
