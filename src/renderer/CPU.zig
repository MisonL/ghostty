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
const ArrayList = std.ArrayListUnmanaged;

/// Transitional routing for the MVP stage.
pub const routed_backend = Backend.softwareRouteForOsTag(builtin.os.tag);

/// Effective-route helper for transitional software routing.
///
/// `software_renderer_cpu_effective` is the authoritative build-config route
/// switch. `software_renderer_cpu_mvp` records whether MVP was explicitly
/// requested. When either is false, MVP isn't the active software route.
pub fn isMvpEffective(
    software_renderer_cpu_effective: bool,
    software_renderer_cpu_mvp: bool,
) bool {
    return software_renderer_cpu_effective and software_renderer_cpu_mvp;
}

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

/// A fixed-size reusable pool of shared CPU frame buffers.
///
/// Each acquired slot is released through `SoftwareFrameReady.release_fn`,
/// avoiding per-frame heap allocations in the hot path.
pub const FramePool = struct {
    const Slot = struct {
        bytes: []u8,
        in_use: std.atomic.Value(u8) = .{ .raw = 0 },
    };

    pub const Acquired = struct {
        slot: *Slot,
        framebuffer: FrameBuffer,
    };

    alloc: std.mem.Allocator,
    slots: []Slot,
    width_px: u32,
    height_px: u32,
    stride_bytes: u32,
    pixel_format: PixelFormat,
    next_slot: usize = 0,

    pub fn init(
        alloc: std.mem.Allocator,
        slot_count: usize,
        width_px: u32,
        height_px: u32,
        pixel_format: PixelFormat,
    ) !FramePool {
        if (slot_count == 0) return error.InvalidFrameSize;

        const stride_bytes = std.math.mul(
            u32,
            width_px,
            bytesPerPixel(pixel_format),
        ) catch return error.OutOfMemory;

        const len = try FrameBuffer.requiredLen(
            width_px,
            height_px,
            stride_bytes,
            pixel_format,
        );

        var slots = try alloc.alloc(Slot, slot_count);

        var i: usize = 0;
        errdefer {
            for (slots[0..i]) |slot| alloc.free(slot.bytes);
            alloc.free(slots);
        }
        while (i < slot_count) : (i += 1) {
            slots[i] = .{
                .bytes = try alloc.alloc(u8, len),
            };
        }

        return .{
            .alloc = alloc,
            .slots = slots,
            .width_px = width_px,
            .height_px = height_px,
            .stride_bytes = stride_bytes,
            .pixel_format = pixel_format,
        };
    }

    pub fn isIdle(self: *const FramePool) bool {
        for (self.slots) |slot| {
            if (slot.in_use.load(.acquire) != 0) {
                return false;
            }
        }
        return true;
    }

    pub fn deinitIdle(self: *FramePool) void {
        std.debug.assert(self.isIdle());
        for (self.slots) |slot| self.alloc.free(slot.bytes);
        self.alloc.free(self.slots);
        self.* = undefined;
    }

    pub fn dimensionsMatch(
        self: *const FramePool,
        width_px: u32,
        height_px: u32,
        pixel_format: PixelFormat,
    ) bool {
        return self.width_px == width_px and
            self.height_px == height_px and
            self.pixel_format == pixel_format;
    }

    pub fn acquire(self: *FramePool) ?Acquired {
        const count = self.slots.len;
        if (count == 0) return null;

        var checked: usize = 0;
        while (checked < count) : (checked += 1) {
            const idx = (self.next_slot + checked) % count;
            const slot = &self.slots[idx];
            if (@cmpxchgStrong(
                u8,
                &slot.in_use.raw,
                0,
                1,
                .acq_rel,
                .acquire,
            ) == null) {
                self.next_slot = (idx + 1) % count;
                return .{
                    .slot = slot,
                    .framebuffer = .{
                        .width_px = self.width_px,
                        .height_px = self.height_px,
                        .stride_bytes = self.stride_bytes,
                        .pixel_format = self.pixel_format,
                        .bytes = slot.bytes,
                    },
                };
            }
        }

        return null;
    }

    pub fn publish(
        _: *const FramePool,
        acquired: Acquired,
        generation: u64,
    ) apprt.surface.Message.SoftwareFrameReady {
        return .{
            .width_px = acquired.framebuffer.width_px,
            .height_px = acquired.framebuffer.height_px,
            .stride_bytes = acquired.framebuffer.stride_bytes,
            .generation = generation,
            .pixel_format = acquired.framebuffer.pixel_format,
            .storage = .shared_cpu_bytes,
            .data = acquired.framebuffer.bytes.ptr,
            .data_len = acquired.framebuffer.bytes.len,
            .handle = null,
            .release_ctx = @ptrCast(acquired.slot),
            .release_fn = &releaseFramePoolSlot,
        };
    }

    fn releaseFramePoolSlot(
        ctx: ?*anyopaque,
        data: ?[*]const u8,
        data_len: usize,
        handle: ?*anyopaque,
    ) callconv(.c) void {
        _ = data;
        _ = data_len;
        _ = handle;
        const ptr = ctx orelse return;
        const slot: *Slot = @ptrCast(@alignCast(ptr));
        slot.in_use.store(0, .release);
    }
};

pub const Layout = struct {
    padding_left_px: u32,
    padding_top_px: u32,
    cell_width_px: u32,
    cell_height_px: u32,
    grid_columns: u32,
    grid_rows: u32,
};

pub const Atlas = struct {
    data: []const u8,
    size: u32,
};

/// Compose a software frame from the renderer CPU-side cell representation.
///
/// This intentionally covers the main text/background path first and keeps
/// semantics conservative (premultiplied BGRA output).
pub fn composeSoftwareFrame(
    comptime CellText: type,
    framebuffer: *FrameBuffer,
    layout: Layout,
    global_bg_rgba: [4]u8,
    bg_cells_rgba: []const [4]u8,
    fg_rows: []const ArrayList(CellText),
    atlas_grayscale: Atlas,
    atlas_color: Atlas,
) void {
    if (framebuffer.pixel_format != .bgra8_premul) return;

    framebuffer.clear(rgbaToPremulBgra(global_bg_rgba));
    drawCellBackgrounds(
        framebuffer,
        layout,
        bg_cells_rgba,
    );
    drawGlyphRows(
        CellText,
        framebuffer,
        layout,
        fg_rows,
        atlas_grayscale,
        atlas_color,
    );
}

fn drawCellBackgrounds(
    framebuffer: *FrameBuffer,
    layout: Layout,
    bg_cells_rgba: []const [4]u8,
) void {
    const cols = @as(usize, @intCast(layout.grid_columns));
    const rows = @as(usize, @intCast(layout.grid_rows));
    if (cols == 0 or rows == 0) return;
    if (bg_cells_rgba.len < cols * rows) return;

    const cell_w = layout.cell_width_px;
    const cell_h = layout.cell_height_px;
    if (cell_w == 0 or cell_h == 0) return;

    for (0..rows) |y| {
        for (0..cols) |x| {
            const idx = y * cols + x;
            const cell = bg_cells_rgba[idx];
            if (cell[3] == 0) continue;

            framebuffer.fillRect(
                .{
                    .x = layout.padding_left_px + @as(u32, @intCast(x)) * cell_w,
                    .y = layout.padding_top_px + @as(u32, @intCast(y)) * cell_h,
                    .width = cell_w,
                    .height = cell_h,
                },
                rgbaToPremulBgra(cell),
            );
        }
    }
}

fn drawGlyphRows(
    comptime CellText: type,
    framebuffer: *FrameBuffer,
    layout: Layout,
    fg_rows: []const ArrayList(CellText),
    atlas_grayscale: Atlas,
    atlas_color: Atlas,
) void {
    for (fg_rows) |row| {
        for (row.items) |glyph| {
            drawGlyph(
                CellText,
                framebuffer,
                layout,
                glyph,
                atlas_grayscale,
                atlas_color,
            );
        }
    }
}

fn drawGlyph(
    comptime CellText: type,
    framebuffer: *FrameBuffer,
    layout: Layout,
    glyph: CellText,
    atlas_grayscale: Atlas,
    atlas_color: Atlas,
) void {
    const glyph_w = @as(usize, @intCast(glyph.glyph_size[0]));
    const glyph_h = @as(usize, @intCast(glyph.glyph_size[1]));
    if (glyph_w == 0 or glyph_h == 0) return;

    const atlas_x = @as(usize, @intCast(glyph.glyph_pos[0]));
    const atlas_y = @as(usize, @intCast(glyph.glyph_pos[1]));

    const base_x = @as(i64, layout.padding_left_px) +
        @as(i64, glyph.grid_pos[0]) * @as(i64, layout.cell_width_px) +
        @as(i64, glyph.bearings[0]);
    const base_y = @as(i64, layout.padding_top_px) +
        @as(i64, glyph.grid_pos[1]) * @as(i64, layout.cell_height_px) +
        (@as(i64, layout.cell_height_px) - @as(i64, glyph.bearings[1]));

    var src_x: usize = 0;
    var src_y: usize = 0;
    var dst_x: i64 = base_x;
    var dst_y: i64 = base_y;
    var width: usize = glyph_w;
    var height: usize = glyph_h;

    clipToFrame(
        framebuffer,
        &dst_x,
        &dst_y,
        &src_x,
        &src_y,
        &width,
        &height,
    );
    if (width == 0 or height == 0) return;

    switch (glyph.atlas) {
        .grayscale => drawGrayscaleGlyph(
            framebuffer,
            glyph,
            atlas_grayscale,
            atlas_x,
            atlas_y,
            src_x,
            src_y,
            @intCast(dst_x),
            @intCast(dst_y),
            width,
            height,
        ),

        .color => drawColorGlyph(
            framebuffer,
            atlas_color,
            atlas_x,
            atlas_y,
            src_x,
            src_y,
            @intCast(dst_x),
            @intCast(dst_y),
            width,
            height,
        ),
    }
}

fn drawGrayscaleGlyph(
    framebuffer: *FrameBuffer,
    glyph: anytype,
    atlas: Atlas,
    atlas_x: usize,
    atlas_y: usize,
    src_x: usize,
    src_y: usize,
    dst_x: usize,
    dst_y: usize,
    width: usize,
    height: usize,
) void {
    if (atlas.size == 0) return;
    const atlas_size = @as(usize, @intCast(atlas.size));
    if (atlas.data.len < atlas_size * atlas_size) return;
    if (atlas_x >= atlas_size or atlas_y >= atlas_size) return;

    const max_w = atlas_size - (atlas_x + src_x);
    const max_h = atlas_size - (atlas_y + src_y);
    const draw_w = @min(width, max_w);
    const draw_h = @min(height, max_h);
    if (draw_w == 0 or draw_h == 0) return;

    const base = rgbaToPremulBgra(glyph.color);
    if (base[3] == 0) return;

    const stride = @as(usize, @intCast(framebuffer.stride_bytes));
    for (0..draw_h) |row| {
        const src_row = (atlas_y + src_y + row) * atlas_size + atlas_x + src_x;
        const dst_row = (dst_y + row) * stride + dst_x * 4;
        for (0..draw_w) |col| {
            const mask = atlas.data[src_row + col];
            if (mask == 0) continue;

            const src: [4]u8 = if (mask == 255)
                base
            else
                .{
                    scaleByAlpha(base[0], mask),
                    scaleByAlpha(base[1], mask),
                    scaleByAlpha(base[2], mask),
                    scaleByAlpha(base[3], mask),
                };
            blendPremulBgra(
                framebuffer.bytes[dst_row + col * 4 ..][0..4],
                src,
            );
        }
    }
}

fn drawColorGlyph(
    framebuffer: *FrameBuffer,
    atlas: Atlas,
    atlas_x: usize,
    atlas_y: usize,
    src_x: usize,
    src_y: usize,
    dst_x: usize,
    dst_y: usize,
    width: usize,
    height: usize,
) void {
    if (atlas.size == 0) return;
    const atlas_size = @as(usize, @intCast(atlas.size));
    if (atlas.data.len < atlas_size * atlas_size * 4) return;
    if (atlas_x >= atlas_size or atlas_y >= atlas_size) return;

    const max_w = atlas_size - (atlas_x + src_x);
    const max_h = atlas_size - (atlas_y + src_y);
    const draw_w = @min(width, max_w);
    const draw_h = @min(height, max_h);
    if (draw_w == 0 or draw_h == 0) return;

    const stride = @as(usize, @intCast(framebuffer.stride_bytes));
    for (0..draw_h) |row| {
        const src_row = (atlas_y + src_y + row) * atlas_size + atlas_x + src_x;
        const dst_row = (dst_y + row) * stride + dst_x * 4;
        for (0..draw_w) |col| {
            const src_off = (src_row + col) * 4;
            const src: [4]u8 = .{
                atlas.data[src_off + 0],
                atlas.data[src_off + 1],
                atlas.data[src_off + 2],
                atlas.data[src_off + 3],
            };
            blendPremulBgra(
                framebuffer.bytes[dst_row + col * 4 ..][0..4],
                src,
            );
        }
    }
}

fn clipToFrame(
    framebuffer: *const FrameBuffer,
    dst_x: *i64,
    dst_y: *i64,
    src_x: *usize,
    src_y: *usize,
    width: *usize,
    height: *usize,
) void {
    const fb_width = @as(i64, @intCast(framebuffer.width_px));
    const fb_height = @as(i64, @intCast(framebuffer.height_px));
    if (fb_width <= 0 or fb_height <= 0) {
        width.* = 0;
        height.* = 0;
        return;
    }

    if (dst_x.* < 0) {
        const shift = @as(usize, @intCast(@min(-dst_x.*, @as(i64, @intCast(width.*)))));
        src_x.* += shift;
        width.* -= shift;
        dst_x.* = 0;
    }
    if (dst_y.* < 0) {
        const shift = @as(usize, @intCast(@min(-dst_y.*, @as(i64, @intCast(height.*)))));
        src_y.* += shift;
        height.* -= shift;
        dst_y.* = 0;
    }

    if (width.* == 0 or height.* == 0) return;
    if (dst_x.* >= fb_width or dst_y.* >= fb_height) {
        width.* = 0;
        height.* = 0;
        return;
    }

    const remaining_w = @as(usize, @intCast(fb_width - dst_x.*));
    const remaining_h = @as(usize, @intCast(fb_height - dst_y.*));
    width.* = @min(width.*, remaining_w);
    height.* = @min(height.*, remaining_h);
}

fn blendPremulBgra(dst: []u8, src: [4]u8) void {
    const src_a = src[3];
    if (src_a == 0) return;
    if (src_a == 255) {
        std.mem.copyForwards(u8, dst[0..4], &src);
        return;
    }

    dst[0] = overPremul(src[0], dst[0], src_a);
    dst[1] = overPremul(src[1], dst[1], src_a);
    dst[2] = overPremul(src[2], dst[2], src_a);
    dst[3] = overPremul(src[3], dst[3], src_a);
}

fn rgbaToPremulBgra(rgba: [4]u8) [4]u8 {
    const a = rgba[3];
    return .{
        scaleByAlpha(rgba[2], a),
        scaleByAlpha(rgba[1], a),
        scaleByAlpha(rgba[0], a),
        a,
    };
}

const TestCellText = struct {
    glyph_pos: [2]u32 = .{ 0, 0 },
    glyph_size: [2]u32 = .{ 0, 0 },
    bearings: [2]i16 = .{ 0, 0 },
    grid_pos: [2]u16 = .{ 0, 0 },
    color: [4]u8 = .{ 0, 0, 0, 0 },
    atlas: AtlasKind = .grayscale,

    const AtlasKind = enum {
        grayscale,
        color,
    };
};

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

test "FrameBuffer blendAlphaMaskPremul uses mask stride and clips right edge" {
    const alloc = std.testing.allocator;
    var fb = try FrameBuffer.init(alloc, 3, 2, .bgra8_premul);
    defer fb.deinit(alloc);

    fb.clear(.{ 0, 0, 0, 0 });
    const mask = [_]u8{
        64,  255, 13, 99, 98,
        128, 32,  77, 88, 87,
    };

    fb.blendAlphaMaskPremul(
        1,
        0,
        3,
        2,
        5,
        &mask,
        .{ 200, 100, 50, 255 },
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            0, 0, 0, 0, 50,  25, 13, 64,  200, 100, 50, 255,
            0, 0, 0, 0, 100, 50, 25, 128, 25,  13,  6,  32,
        },
        fb.bytes,
    );
}

test "FrameBuffer blendAlphaMaskPremul no-ops when mask data is truncated" {
    const alloc = std.testing.allocator;
    var fb = try FrameBuffer.init(alloc, 2, 2, .bgra8_premul);
    defer fb.deinit(alloc);

    fb.clear(.{ 11, 22, 33, 44 });
    const before = try alloc.dupe(u8, fb.bytes);
    defer alloc.free(before);

    fb.blendAlphaMaskPremul(
        0,
        0,
        2,
        2,
        3,
        &[_]u8{ 255, 255, 255, 255, 255 },
        .{ 200, 100, 50, 255 },
    );

    try std.testing.expectEqualSlices(u8, before, fb.bytes);
}

test "isMvpEffective requires both effective route and MVP opt-in" {
    try std.testing.expect(isMvpEffective(true, true));
    try std.testing.expect(!isMvpEffective(true, false));
    try std.testing.expect(!isMvpEffective(false, true));
    try std.testing.expect(!isMvpEffective(false, false));
}

test "FramePool publish uses caller generation and release returns slot to idle" {
    const alloc = std.testing.allocator;
    var pool = try FramePool.init(alloc, 1, 1, 1, .bgra8_premul);
    defer if (pool.isIdle()) pool.deinitIdle();

    try std.testing.expect(pool.isIdle());

    const acquired = pool.acquire() orelse return error.TestUnexpectedResult;
    try std.testing.expect(!pool.isIdle());

    const frame = pool.publish(acquired, 99);
    try std.testing.expectEqual(@as(u64, 99), frame.generation);
    try std.testing.expectEqual(@as(usize, 4), frame.data_len);
    try std.testing.expect(frame.release_fn != null);

    frame.release();
    try std.testing.expect(pool.isIdle());
}

test "composeSoftwareFrame draws grayscale glyph over global background" {
    const alloc = std.testing.allocator;

    var fb = try FrameBuffer.init(alloc, 2, 2, .bgra8_premul);
    defer fb.deinit(alloc);

    var rows: [1]ArrayList(TestCellText) = .{.{}};
    defer rows[0].deinit(alloc);
    try rows[0].append(alloc, .{
        .glyph_pos = .{ 0, 0 },
        .glyph_size = .{ 1, 1 },
        .bearings = .{ 0, 2 },
        .grid_pos = .{ 0, 0 },
        .color = .{ 255, 0, 0, 255 },
        .atlas = .grayscale,
    });

    const bg_cells = [_][4]u8{
        .{ 0, 0, 0, 0 },
    };
    const atlas_gray = [_]u8{255};
    const empty_color: [0]u8 = .{};

    composeSoftwareFrame(
        TestCellText,
        &fb,
        .{
            .padding_left_px = 0,
            .padding_top_px = 0,
            .cell_width_px = 2,
            .cell_height_px = 2,
            .grid_columns = 1,
            .grid_rows = 1,
        },
        .{ 10, 20, 30, 255 },
        bg_cells[0..],
        rows[0..],
        .{ .data = atlas_gray[0..], .size = 1 },
        .{ .data = empty_color[0..], .size = 0 },
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            0,  0,  255, 255, 30, 20, 10, 255,
            30, 20, 10,  255, 30, 20, 10, 255,
        },
        fb.bytes,
    );
}

test "composeSoftwareFrame blends color glyph atlas directly in BGRA" {
    const alloc = std.testing.allocator;

    var fb = try FrameBuffer.init(alloc, 1, 1, .bgra8_premul);
    defer fb.deinit(alloc);

    var rows: [1]ArrayList(TestCellText) = .{.{}};
    defer rows[0].deinit(alloc);
    try rows[0].append(alloc, .{
        .glyph_pos = .{ 0, 0 },
        .glyph_size = .{ 1, 1 },
        .bearings = .{ 0, 1 },
        .grid_pos = .{ 0, 0 },
        .color = .{ 255, 255, 255, 255 },
        .atlas = .color,
    });

    const bg_cells = [_][4]u8{
        .{ 0, 0, 0, 0 },
    };
    const empty_gray: [0]u8 = .{};
    const atlas_color = [_]u8{ 100, 50, 25, 128 };

    composeSoftwareFrame(
        TestCellText,
        &fb,
        .{
            .padding_left_px = 0,
            .padding_top_px = 0,
            .cell_width_px = 1,
            .cell_height_px = 1,
            .grid_columns = 1,
            .grid_rows = 1,
        },
        .{ 0, 0, 0, 0 },
        bg_cells[0..],
        rows[0..],
        .{ .data = empty_gray[0..], .size = 0 },
        .{ .data = atlas_color[0..], .size = 1 },
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 100, 50, 25, 128 },
        fb.bytes,
    );
}

test "composeSoftwareFrame clips glyph with negative bearing and samples correct source column" {
    const alloc = std.testing.allocator;

    var fb = try FrameBuffer.init(alloc, 2, 1, .bgra8_premul);
    defer fb.deinit(alloc);

    var rows: [1]ArrayList(TestCellText) = .{.{}};
    defer rows[0].deinit(alloc);
    try rows[0].append(alloc, .{
        .glyph_pos = .{ 0, 0 },
        .glyph_size = .{ 2, 1 },
        .bearings = .{ -1, 1 },
        .grid_pos = .{ 0, 0 },
        .color = .{ 0, 255, 0, 255 },
        .atlas = .grayscale,
    });

    const bg_cells = [_][4]u8{
        .{ 0, 0, 0, 0 },
    };
    const atlas_gray = [_]u8{
        64, 255,
        0,  0,
    };
    const empty_color: [0]u8 = .{};

    composeSoftwareFrame(
        TestCellText,
        &fb,
        .{
            .padding_left_px = 0,
            .padding_top_px = 0,
            .cell_width_px = 1,
            .cell_height_px = 1,
            .grid_columns = 1,
            .grid_rows = 1,
        },
        .{ 0, 0, 0, 255 },
        bg_cells[0..],
        rows[0..],
        .{ .data = atlas_gray[0..], .size = 2 },
        .{ .data = empty_color[0..], .size = 0 },
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            0, 255, 0, 255,
            0, 0,   0, 255,
        },
        fb.bytes,
    );
}
