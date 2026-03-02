//! CPU software renderer MVP scaffolding.
//!
//! This module intentionally keeps rendering behavior identical to the
//! transitional software route today while introducing reusable CPU-side frame
//! primitives for incremental migration.

const std = @import("std");
const builtin = @import("builtin");
const Backend = @import("backend.zig").Backend;
const OpenGL = @import("OpenGL.zig").OpenGL;
const Metal = @import("Metal.zig").Metal;
const apprt = @import("../apprt.zig");

/// Transitional routing for the MVP stage.
pub const routed_backend = Backend.softwareRouteForOsTag(builtin.os.tag);

/// Runtime API shim used by renderer.GenericRenderer while CPU internals
/// are developed in parallel.
pub const CPU = switch (routed_backend) {
    .opengl => OpenGL,
    .metal => Metal,
    else => unreachable,
};

pub const PixelFormat = apprt.surface.Message.SoftwareFramePixelFormat;
pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// CPU-owned framebuffer primitive for staging software-rendered output.
pub const FrameBuffer = struct {
    width_px: u32,
    height_px: u32,
    stride_bytes: u32,
    pixel_format: PixelFormat,
    bytes: []u8,

    pub fn init(
        alloc: std.mem.Allocator,
        width_px: u32,
        height_px: u32,
        pixel_format: PixelFormat,
    ) !FrameBuffer {
        const stride_bytes = std.math.mul(
            u32,
            width_px,
            bytesPerPixel(pixel_format),
        ) catch return error.OutOfMemory;

        const len = requiredLen(
            width_px,
            height_px,
            stride_bytes,
            pixel_format,
        ) catch return error.OutOfMemory;

        return .{
            .width_px = width_px,
            .height_px = height_px,
            .stride_bytes = stride_bytes,
            .pixel_format = pixel_format,
            .bytes = try alloc.alloc(u8, len),
        };
    }

    pub fn deinit(self: *FrameBuffer, alloc: std.mem.Allocator) void {
        alloc.free(self.bytes);
        self.* = undefined;
    }

    pub fn requiredLen(
        width_px: u32,
        height_px: u32,
        stride_bytes: u32,
        pixel_format: PixelFormat,
    ) error{ InvalidFrameSize, InvalidStride, Overflow }!usize {
        if (width_px == 0 or height_px == 0) return error.InvalidFrameSize;

        const min_stride = std.math.mul(
            u64,
            width_px,
            bytesPerPixel(pixel_format),
        ) catch return error.Overflow;

        if (stride_bytes < min_stride) return error.InvalidStride;

        const len_u64 = std.math.mul(
            u64,
            stride_bytes,
            height_px,
        ) catch return error.Overflow;

        return std.math.cast(usize, len_u64) orelse return error.Overflow;
    }

    pub fn clear(self: *FrameBuffer, color: [4]u8) void {
        self.fillRect(.{
            .x = 0,
            .y = 0,
            .width = self.width_px,
            .height = self.height_px,
        }, color);
    }

    pub fn fillRect(self: *FrameBuffer, rect: Rect, color: [4]u8) void {
        const clipped = self.clippedRect(rect) orelse return;
        const stride = @as(usize, @intCast(self.stride_bytes));

        for (clipped.y0..clipped.y1) |row| {
            const row_start = row * stride;
            var x: usize = clipped.x0;
            while (x < clipped.x1) : (x += 1) {
                const off = row_start + (x * 4);
                std.mem.copyForwards(u8, self.bytes[off .. off + 4], &color);
            }
        }
    }

    const ClippedRect = struct {
        x0: usize,
        y0: usize,
        x1: usize,
        y1: usize,
    };

    fn clippedRect(self: *const FrameBuffer, rect: Rect) ?ClippedRect {
        if (rect.width == 0 or rect.height == 0) return null;

        const fb_width = @as(usize, @intCast(self.width_px));
        const fb_height = @as(usize, @intCast(self.height_px));
        const x0 = @min(fb_width, @as(usize, @intCast(rect.x)));
        const y0 = @min(fb_height, @as(usize, @intCast(rect.y)));

        const x1_u64 = @as(u64, rect.x) + @as(u64, rect.width);
        const y1_u64 = @as(u64, rect.y) + @as(u64, rect.height);
        const x1 = @min(fb_width, std.math.cast(usize, x1_u64) orelse fb_width);
        const y1 = @min(fb_height, std.math.cast(usize, y1_u64) orelse fb_height);

        if (x0 >= x1 or y0 >= y1) return null;
        return .{
            .x0 = x0,
            .y0 = y0,
            .x1 = x1,
            .y1 = y1,
        };
    }

    pub fn asSoftwareFrame(
        self: *const FrameBuffer,
        generation: u64,
    ) apprt.surface.Message.SoftwareFrameReady {
        return .{
            .width_px = self.width_px,
            .height_px = self.height_px,
            .stride_bytes = self.stride_bytes,
            .generation = generation,
            .pixel_format = self.pixel_format,
            .storage = .shared_cpu_bytes,
            .data = self.bytes.ptr,
            .data_len = self.bytes.len,
            .handle = null,
            .release_ctx = null,
            .release_fn = null,
        };
    }
};

fn bytesPerPixel(_: PixelFormat) u32 {
    return 4;
}

test "FrameBuffer requiredLen validates stride and dimensions" {
    try std.testing.expectError(
        error.InvalidFrameSize,
        FrameBuffer.requiredLen(0, 1, 4, .bgra8_premul),
    );
    try std.testing.expectError(
        error.InvalidStride,
        FrameBuffer.requiredLen(2, 1, 7, .bgra8_premul),
    );
    try std.testing.expectEqual(
        @as(usize, 16),
        try FrameBuffer.requiredLen(2, 2, 8, .bgra8_premul),
    );
}

test "FrameBuffer clear fills bytes and exports software frame view" {
    const alloc = std.testing.allocator;
    var fb = try FrameBuffer.init(alloc, 2, 1, .bgra8_premul);
    defer fb.deinit(alloc);

    fb.clear(.{ 1, 2, 3, 4 });
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 1, 2, 3, 4, 1, 2, 3, 4 },
        fb.bytes,
    );

    const frame = fb.asSoftwareFrame(42);
    try std.testing.expectEqual(@as(u64, 42), frame.generation);
    try std.testing.expectEqual(
        apprt.surface.Message.SoftwareFrameStorage.shared_cpu_bytes,
        frame.storage,
    );
    try std.testing.expectEqual(fb.bytes.len, frame.data_len);
}

test "FrameBuffer fillRect clips to framebuffer bounds" {
    const alloc = std.testing.allocator;
    var fb = try FrameBuffer.init(alloc, 3, 2, .bgra8_premul);
    defer fb.deinit(alloc);

    fb.clear(.{ 0, 0, 0, 0 });
    fb.fillRect(.{
        .x = 1,
        .y = 0,
        .width = 3,
        .height = 2,
    }, .{ 9, 8, 7, 6 });

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            0, 0, 0, 0, 9, 8, 7, 6, 9, 8, 7, 6,
            0, 0, 0, 0, 9, 8, 7, 6, 9, 8, 7, 6,
        },
        fb.bytes,
    );
}

test "FrameBuffer fillRect ignores empty and out-of-bounds regions" {
    const alloc = std.testing.allocator;
    var fb = try FrameBuffer.init(alloc, 2, 1, .bgra8_premul);
    defer fb.deinit(alloc);

    fb.clear(.{ 1, 2, 3, 4 });
    const before = try alloc.dupe(u8, fb.bytes);
    defer alloc.free(before);

    fb.fillRect(.{ .x = 2, .y = 0, .width = 1, .height = 1 }, .{ 9, 9, 9, 9 });
    fb.fillRect(.{ .x = 0, .y = 0, .width = 0, .height = 1 }, .{ 9, 9, 9, 9 });
    fb.fillRect(.{ .x = 0, .y = 1, .width = 1, .height = 1 }, .{ 9, 9, 9, 9 });

    try std.testing.expectEqualSlices(u8, before, fb.bytes);
}
