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

    /// Copy a rectangle to a destination position with memmove-like overlap semantics.
    pub fn copyRect(
        self: *FrameBuffer,
        src: Rect,
        dst_x: u32,
        dst_y: u32,
    ) void {
        if (src.width == 0 or src.height == 0) return;

        const fb_width = @as(usize, @intCast(self.width_px));
        const fb_height = @as(usize, @intCast(self.height_px));
        const src_x = @as(usize, @intCast(src.x));
        const src_y = @as(usize, @intCast(src.y));
        const dst_x_usize = @as(usize, @intCast(dst_x));
        const dst_y_usize = @as(usize, @intCast(dst_y));
        if (src_x >= fb_width or src_y >= fb_height) return;
        if (dst_x_usize >= fb_width or dst_y_usize >= fb_height) return;

        const src_width = @as(usize, @intCast(src.width));
        const src_height = @as(usize, @intCast(src.height));
        const copy_width = @min(src_width, @min(fb_width - src_x, fb_width - dst_x_usize));
        const copy_height = @min(src_height, @min(fb_height - src_y, fb_height - dst_y_usize));
        if (copy_width == 0 or copy_height == 0) return;

        const stride = @as(usize, @intCast(self.stride_bytes));
        const row_len = copy_width * 4;
        const rows_overlap = dst_y_usize > src_y and dst_y_usize < src_y + copy_height;

        if (rows_overlap) {
            var row: usize = copy_height;
            while (row > 0) {
                row -= 1;
                self.copyRectRow(
                    stride,
                    src_x,
                    dst_x_usize,
                    src_y + row,
                    dst_y_usize + row,
                    copy_width,
                    row_len,
                );
            }
            return;
        }

        var row: usize = 0;
        while (row < copy_height) : (row += 1) {
            self.copyRectRow(
                stride,
                src_x,
                dst_x_usize,
                src_y + row,
                dst_y_usize + row,
                copy_width,
                row_len,
            );
        }
    }

    /// Blend a premultiplied RGBA color over the destination rectangle.
    ///
    /// `color` is interpreted in framebuffer storage channel order and must be
    /// premultiplied by alpha.
    pub fn blendRectPremul(self: *FrameBuffer, rect: Rect, color: [4]u8) void {
        const clipped = self.clippedRect(rect) orelse return;
        const stride = @as(usize, @intCast(self.stride_bytes));
        const src = color;
        const src_a = src[3];

        if (src_a == 0) return;
        if (src_a == 255) return self.fillRect(rect, color);

        for (clipped.y0..clipped.y1) |row| {
            const row_start = row * stride;
            var x: usize = clipped.x0;
            while (x < clipped.x1) : (x += 1) {
                const off = row_start + (x * 4);
                var px = self.bytes[off .. off + 4];
                px[0] = overPremul(src[0], px[0], src_a);
                px[1] = overPremul(src[1], px[1], src_a);
                px[2] = overPremul(src[2], px[2], src_a);
                px[3] = overPremul(src[3], px[3], src_a);
            }
        }
    }

    /// Blend an alpha mask at the destination position using a premultiplied color.
    ///
    /// `color` is interpreted in framebuffer storage channel order and must be
    /// premultiplied by alpha. `mask_alpha` is a single-channel alpha bitmap.
    pub fn blendAlphaMaskPremul(
        self: *FrameBuffer,
        dst_x: u32,
        dst_y: u32,
        mask_width: u32,
        mask_height: u32,
        mask_stride_bytes: u32,
        mask_alpha: []const u8,
        color: [4]u8,
    ) void {
        if (mask_width == 0 or mask_height == 0) return;
        if (mask_stride_bytes < mask_width) return;
        if (color[3] == 0) return;

        const required_len_u64 = std.math.mul(
            u64,
            mask_stride_bytes,
            mask_height,
        ) catch return;
        const required_len = std.math.cast(usize, required_len_u64) orelse return;
        if (mask_alpha.len < required_len) return;

        const clipped = self.clippedRect(.{
            .x = dst_x,
            .y = dst_y,
            .width = mask_width,
            .height = mask_height,
        }) orelse return;

        const dst_stride = @as(usize, @intCast(self.stride_bytes));
        const src_stride = @as(usize, @intCast(mask_stride_bytes));
        const dst_x0 = @as(usize, @intCast(dst_x));
        const dst_y0 = @as(usize, @intCast(dst_y));

        var dst_row: usize = clipped.y0;
        var src_row: usize = clipped.y0 - dst_y0;
        while (dst_row < clipped.y1) : ({
            dst_row += 1;
            src_row += 1;
        }) {
            const dst_row_start = dst_row * dst_stride;
            const src_row_start = src_row * src_stride;

            var dst_col: usize = clipped.x0;
            var src_col: usize = clipped.x0 - dst_x0;
            while (dst_col < clipped.x1) : ({
                dst_col += 1;
                src_col += 1;
            }) {
                const mask_a = mask_alpha[src_row_start + src_col];
                if (mask_a == 0) continue;

                const src: [4]u8 = if (mask_a == 255)
                    color
                else
                    .{
                        scaleByAlpha(color[0], mask_a),
                        scaleByAlpha(color[1], mask_a),
                        scaleByAlpha(color[2], mask_a),
                        scaleByAlpha(color[3], mask_a),
                    };

                const src_a = src[3];
                if (src_a == 0) continue;

                const off = dst_row_start + (dst_col * 4);
                if (src_a == 255) {
                    std.mem.copyForwards(u8, self.bytes[off .. off + 4], &src);
                    continue;
                }

                var px = self.bytes[off .. off + 4];
                px[0] = overPremul(src[0], px[0], src_a);
                px[1] = overPremul(src[1], px[1], src_a);
                px[2] = overPremul(src[2], px[2], src_a);
                px[3] = overPremul(src[3], px[3], src_a);
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

    fn copyRectRow(
        self: *FrameBuffer,
        stride: usize,
        src_x: usize,
        dst_x: usize,
        src_row: usize,
        dst_row: usize,
        copy_width: usize,
        row_len: usize,
    ) void {
        const src_off = src_row * stride + (src_x * 4);
        const dst_off = dst_row * stride + (dst_x * 4);

        const same_row = src_row == dst_row;
        const overlap_x = dst_x > src_x and dst_x < src_x + copy_width;
        if (same_row and overlap_x) {
            std.mem.copyBackwards(
                u8,
                self.bytes[dst_off .. dst_off + row_len],
                self.bytes[src_off .. src_off + row_len],
            );
            return;
        }

        std.mem.copyForwards(
            u8,
            self.bytes[dst_off .. dst_off + row_len],
            self.bytes[src_off .. src_off + row_len],
        );
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

fn overPremul(src: u8, dst: u8, src_a: u8) u8 {
    const inv = @as(u16, 255) - @as(u16, src_a);
    const blend = (@as(u16, dst) * inv + 127) / 255;
    const out = @as(u16, src) + blend;
    return @intCast(@min(out, 255));
}

fn scaleByAlpha(value: u8, alpha: u8) u8 {
    if (alpha == 0) return 0;
    if (alpha == 255) return value;
    return @intCast((@as(u16, value) * @as(u16, alpha) + 127) / 255);
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

test "FrameBuffer copyRect copies a non-overlapping region" {
    const alloc = std.testing.allocator;
    var fb = try FrameBuffer.init(alloc, 4, 2, .bgra8_premul);
    defer fb.deinit(alloc);

    fb.clear(.{ 0, 0, 0, 0 });
    fb.fillRect(.{ .x = 0, .y = 0, .width = 1, .height = 1 }, .{ 1, 0, 0, 255 });
    fb.fillRect(.{ .x = 1, .y = 0, .width = 1, .height = 1 }, .{ 2, 0, 0, 255 });
    fb.fillRect(.{ .x = 0, .y = 1, .width = 1, .height = 1 }, .{ 3, 0, 0, 255 });
    fb.fillRect(.{ .x = 1, .y = 1, .width = 1, .height = 1 }, .{ 4, 0, 0, 255 });

    fb.copyRect(.{ .x = 0, .y = 0, .width = 2, .height = 1 }, 2, 1);

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            1, 0, 0, 255, 2, 0, 0, 255, 0, 0, 0, 0,   0, 0, 0, 0,
            3, 0, 0, 255, 4, 0, 0, 255, 1, 0, 0, 255, 2, 0, 0, 255,
        },
        fb.bytes,
    );
}

test "FrameBuffer copyRect handles horizontal overlap with memmove semantics" {
    const alloc = std.testing.allocator;
    var fb = try FrameBuffer.init(alloc, 4, 1, .bgra8_premul);
    defer fb.deinit(alloc);

    fb.clear(.{ 0, 0, 0, 0 });
    fb.fillRect(.{ .x = 0, .y = 0, .width = 1, .height = 1 }, .{ 1, 0, 0, 255 });
    fb.fillRect(.{ .x = 1, .y = 0, .width = 1, .height = 1 }, .{ 2, 0, 0, 255 });
    fb.fillRect(.{ .x = 2, .y = 0, .width = 1, .height = 1 }, .{ 3, 0, 0, 255 });
    fb.fillRect(.{ .x = 3, .y = 0, .width = 1, .height = 1 }, .{ 4, 0, 0, 255 });

    fb.copyRect(.{ .x = 0, .y = 0, .width = 3, .height = 1 }, 1, 0);

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            1, 0, 0, 255, 1, 0, 0, 255,
            2, 0, 0, 255, 3, 0, 0, 255,
        },
        fb.bytes,
    );
}

test "FrameBuffer copyRect handles vertical overlap with memmove semantics" {
    const alloc = std.testing.allocator;
    var fb = try FrameBuffer.init(alloc, 2, 3, .bgra8_premul);
    defer fb.deinit(alloc);

    fb.clear(.{ 0, 0, 0, 0 });
    fb.fillRect(.{ .x = 0, .y = 0, .width = 1, .height = 1 }, .{ 1, 0, 0, 255 });
    fb.fillRect(.{ .x = 1, .y = 0, .width = 1, .height = 1 }, .{ 2, 0, 0, 255 });
    fb.fillRect(.{ .x = 0, .y = 1, .width = 1, .height = 1 }, .{ 3, 0, 0, 255 });
    fb.fillRect(.{ .x = 1, .y = 1, .width = 1, .height = 1 }, .{ 4, 0, 0, 255 });
    fb.fillRect(.{ .x = 0, .y = 2, .width = 1, .height = 1 }, .{ 5, 0, 0, 255 });
    fb.fillRect(.{ .x = 1, .y = 2, .width = 1, .height = 1 }, .{ 6, 0, 0, 255 });

    fb.copyRect(.{ .x = 0, .y = 0, .width = 2, .height = 2 }, 0, 1);

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            1, 0, 0, 255, 2, 0, 0, 255,
            1, 0, 0, 255, 2, 0, 0, 255,
            3, 0, 0, 255, 4, 0, 0, 255,
        },
        fb.bytes,
    );
}

test "FrameBuffer blendRectPremul blends over BGRA storage" {
    const alloc = std.testing.allocator;
    var fb = try FrameBuffer.init(alloc, 1, 1, .bgra8_premul);
    defer fb.deinit(alloc);

    fb.clear(.{ 10, 20, 30, 40 });
    fb.blendRectPremul(
        .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .{ 128, 0, 0, 128 },
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 133, 10, 15, 148 },
        fb.bytes,
    );
}

test "FrameBuffer blendRectPremul blends over RGBA storage" {
    const alloc = std.testing.allocator;
    var fb = try FrameBuffer.init(alloc, 1, 1, .rgba8_premul);
    defer fb.deinit(alloc);

    fb.clear(.{ 10, 20, 30, 40 });
    fb.blendRectPremul(
        .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .{ 128, 0, 0, 128 },
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 133, 10, 15, 148 },
        fb.bytes,
    );
}

test "FrameBuffer blendAlphaMaskPremul clips to framebuffer bounds" {
    const alloc = std.testing.allocator;
    var fb = try FrameBuffer.init(alloc, 3, 2, .bgra8_premul);
    defer fb.deinit(alloc);

    fb.clear(.{ 0, 0, 0, 0 });
    const mask = [_]u8{
        64,  255, 13,  99,
        200, 201, 202, 88,
    };
    fb.blendAlphaMaskPremul(
        1,
        1,
        3,
        2,
        4,
        &mask,
        .{ 8, 18, 28, 255 },
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            0, 0, 0, 0, 0, 0, 0, 0,  0, 0,  0,  0,
            0, 0, 0, 0, 2, 5, 7, 64, 8, 18, 28, 255,
        },
        fb.bytes,
    );
}

test "FrameBuffer blendAlphaMaskPremul handles alpha 0 and 255" {
    const alloc = std.testing.allocator;
    var fb = try FrameBuffer.init(alloc, 2, 1, .bgra8_premul);
    defer fb.deinit(alloc);

    fb.clear(.{ 10, 11, 12, 13 });
    fb.fillRect(
        .{ .x = 1, .y = 0, .width = 1, .height = 1 },
        .{ 20, 21, 22, 23 },
    );

    fb.blendAlphaMaskPremul(
        0,
        0,
        2,
        1,
        2,
        &[_]u8{ 0, 255 },
        .{ 90, 80, 70, 255 },
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 10, 11, 12, 13, 90, 80, 70, 255 },
        fb.bytes,
    );
}

test "FrameBuffer blendAlphaMaskPremul blends partial coverage" {
    const alloc = std.testing.allocator;
    var fb = try FrameBuffer.init(alloc, 1, 1, .bgra8_premul);
    defer fb.deinit(alloc);

    fb.clear(.{ 10, 20, 30, 40 });
    fb.blendAlphaMaskPremul(
        0,
        0,
        1,
        1,
        1,
        &[_]u8{128},
        .{ 200, 100, 50, 255 },
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 105, 60, 40, 148 },
        fb.bytes,
    );
}
