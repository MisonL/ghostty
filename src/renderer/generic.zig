const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const wuffs = @import("wuffs");
const build_config = @import("../build_config.zig");
const apprt = @import("../apprt.zig");
const App = @import("../App.zig");
const configpkg = @import("../config.zig");
const font = @import("../font/main.zig");
const inputpkg = @import("../input.zig");
const os = @import("../os/main.zig");
const terminal = @import("../terminal/main.zig");
const renderer = @import("../renderer.zig");
const cpu_renderer = @import("CPU.zig");
const math = @import("../math.zig");
const Surface = @import("../Surface.zig");
const link = @import("link.zig");
const cellmod = @import("cell.zig");
const noMinContrast = cellmod.noMinContrast;
const constraintWidth = cellmod.constraintWidth;
const isCovering = cellmod.isCovering;
const rowNeverExtendBg = @import("row.zig").neverExtendBg;
const Overlay = @import("Overlay.zig").Overlay;
const shadertoy = @import("shadertoy.zig");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Terminal = terminal.Terminal;
const Health = renderer.Health;

const getConstraint = @import("../font/nerd_font_attributes.zig").getConstraint;

const FileType = @import("../file_type.zig").FileType;

const macos = switch (builtin.os.tag) {
    .macos => @import("macos"),
    else => void,
};

const DisplayLink = switch (builtin.os.tag) {
    .macos => *macos.video.DisplayLink,
    else => void,
};

const log = std.log.scoped(.generic_renderer);
const software_renderer_cpu_effective =
    if (build_config.renderer == .software)
        (if (@hasDecl(build_config, "software_renderer_cpu_effective"))
            build_config.software_renderer_cpu_effective
        else
            build_config.software_renderer_cpu_mvp)
    else
        false;
const software_renderer_cpu_frame_damage_mode: cpu_renderer.FrameDamageMode =
    if (@hasDecl(build_config, "software_renderer_cpu_frame_damage_mode"))
        switch (build_config.software_renderer_cpu_frame_damage_mode) {
            .off => .off,
            .rects => .rects,
        }
    else
        .off;
const software_renderer_cpu_damage_rect_cap_configured: u16 =
    if (@hasDecl(build_config, "software_renderer_cpu_damage_rect_cap"))
        build_config.software_renderer_cpu_damage_rect_cap
    else
        0;
const software_renderer_cpu_damage_rect_cap: u16 = effectiveCpuDamageRectCap(
    software_renderer_cpu_frame_damage_mode,
    software_renderer_cpu_damage_rect_cap_configured,
);
const software_renderer_cpu_damage_rect_pool_capacity: usize =
    @max(@as(usize, 1), @as(usize, software_renderer_cpu_damage_rect_cap));
const max_retired_cpu_frame_pools: usize = 4;
const cpu_frame_pool_deinit_wait_ms: u64 = 25;
const cpu_damage_row_span_vertical_overscan_divisor: u32 = 4;
const cpu_frame_publish_warning_threshold_ms: u64 =
    if (@hasDecl(build_config, "software_renderer_cpu_publish_warning_threshold_ms"))
        @as(u64, @intCast(build_config.software_renderer_cpu_publish_warning_threshold_ms))
    else
        40;
const cpu_frame_publish_warning_consecutive_limit: u8 = @max(
    @as(u8, 1),
    if (@hasDecl(build_config, "software_renderer_cpu_publish_warning_consecutive_limit"))
        @as(u8, @intCast(build_config.software_renderer_cpu_publish_warning_consecutive_limit))
    else
        3,
);
const cpu_custom_shader_capability_reprobe_interval_frames: u32 =
    if (@hasDecl(build_config, "software_renderer_cpu_shader_reprobe_interval_frames"))
        @as(u32, @intCast(build_config.software_renderer_cpu_shader_reprobe_interval_frames))
    else
        120;

const CpuFramePublishWarningState = struct {
    consecutive_over_threshold: u8 = 0,
    warned: bool = false,
};

fn effectiveCpuDamageRectCap(
    frame_damage_mode: cpu_renderer.FrameDamageMode,
    configured_cap: u16,
) u16 {
    return switch (frame_damage_mode) {
        .off => configured_cap,
        .rects => @max(@as(u16, 1), configured_cap),
    };
}

fn cpuDamageRectForRowSpan(
    width_px: u32,
    height_px: u32,
    padding_top_px: u32,
    cell_height_px: u32,
    row_min: u32,
    row_max_exclusive: u32,
    row_count: u32,
) ?cpu_renderer.Rect {
    if (width_px == 0 or height_px == 0) return null;
    if (row_max_exclusive <= row_min) return null;
    if (cell_height_px == 0) return null;

    const expanded_min = if (row_min > 0) row_min - 1 else 0;
    const expanded_max = @min(row_count, row_max_exclusive + 1);
    if (expanded_max <= expanded_min) return null;

    const y0_u64 = @as(u64, padding_top_px) +
        @as(u64, expanded_min) * @as(u64, cell_height_px);
    const y1_u64 = @as(u64, padding_top_px) +
        @as(u64, expanded_max) * @as(u64, cell_height_px);
    const overscan_px = @max(
        @as(u32, 1),
        cell_height_px / cpu_damage_row_span_vertical_overscan_divisor,
    );
    const overscan_u64 = @as(u64, overscan_px);
    const bound_h_u64 = @as(u64, height_px);
    const y0 = @min(y0_u64 -| overscan_u64, bound_h_u64);
    const y1 = @min(
        std.math.add(u64, y1_u64, overscan_u64) catch std.math.maxInt(u64),
        bound_h_u64,
    );
    if (y1 <= y0) return null;

    return .{
        .x = 0,
        .y = @intCast(y0),
        .width = width_px,
        .height = @intCast(y1 - y0),
    };
}

fn cpuCellGridCount(cols: usize, rows: usize) ?usize {
    return std.math.mul(usize, cols, rows) catch null;
}

fn cpuCellPixelOrigin(base_px: u32, cell_px: u32, index: usize) ?u32 {
    const index_px = std.math.cast(u32, index) orelse return null;
    const offset_px = std.math.mul(u32, index_px, cell_px) catch return null;
    return std.math.add(u32, base_px, offset_px) catch return null;
}

fn needsFrameBgImageBuffer(bg_image: anytype) bool {
    const image = bg_image orelse return false;
    return switch (image) {
        .ready => true,
        else => false,
    };
}

fn applyPreparedBackgroundImage(
    alloc: Allocator,
    bg_image: anytype,
    image: anytype,
) void {
    if (bg_image.*) |*current| {
        current.markForReplace(alloc, image);
    } else {
        bg_image.* = image;
    }
}

fn clearConfiguredBackgroundImage(bg_image: anytype) void {
    if (bg_image.*) |*image| image.markForUnload();
}

fn bgImageRequiresConservativeFullCpuDamage(
    bg_image: anytype,
    config_has_bg_image: bool,
) bool {
    const image = bg_image orelse return false;
    return config_has_bg_image or image.isUnloading();
}

fn finalizeUnloadingBgImage(
    alloc: Allocator,
    bg_image: anytype,
) bool {
    if (bg_image.*) |*image| {
        if (!image.isUnloading()) return false;
        image.deinit(alloc);
        bg_image.* = null;
        return true;
    }

    return false;
}

fn discardStaleUnloadingBackgroundImageAfterPrepareFailure(
    alloc: Allocator,
    bg_image: anytype,
) bool {
    // A config flip from "no background" to a broken path can leave the old
    // slot parked in unload_* forever unless we clear it explicitly.
    return finalizeUnloadingBgImage(alloc, bg_image);
}

fn clearCpuRouteTransientStateForPlatformRoute(
    cpu_publish_pending: *bool,
    cpu_frame_publish_warning: *CpuFramePublishWarningState,
) void {
    cpu_publish_pending.* = false;
    cpu_frame_publish_warning.* = .{};
}

fn applyCpuPublishResultState(
    alloc: Allocator,
    bg_image: anytype,
    config_has_bg_image: bool,
    cpu_publish_pending: *bool,
    cells_rebuilt: *bool,
    result: CpuPublishResult,
) bool {
    switch (result) {
        .retry => {
            cpu_publish_pending.* = true;
            cells_rebuilt.* = true;
            return false;
        },
        .published => {
            cpu_publish_pending.* = false;
            if (!config_has_bg_image) {
                return finalizeUnloadingBgImage(alloc, bg_image);
            }
            return false;
        },
    }
}

const CpuImagePixels = struct {
    width: u32,
    height: u32,
    stride_bytes: u32,
    data: []const u8,
};

const CpuBackgroundImageFit = enum {
    contain,
    cover,
    stretch,
    none,
};

const CpuBackgroundImagePosition = enum {
    tl,
    tc,
    tr,
    ml,
    mc,
    mr,
    bl,
    bc,
    br,
};

const CpuBackgroundImageConfig = struct {
    opacity: f32,
    fit: CpuBackgroundImageFit,
    position: CpuBackgroundImagePosition,
    repeat: bool,
};

fn scaleByAlpha(channel: u8, alpha: u8) u8 {
    return @intCast((@as(u16, channel) * @as(u16, alpha) + 127) / 255);
}

fn overPremul(src: u8, dst: u8, src_a: u8) u8 {
    const inv = @as(u16, 255) - src_a;
    const blend = (@as(u16, dst) * inv + 127) / 255;
    const out = @as(u16, src) + blend;
    return @intCast(@min(out, 255));
}

fn float01ToByte(value: f32) u8 {
    const clamped = @max(@as(f32, 0.0), @min(value, 1.0));
    return @intFromFloat(@round(clamped * 255.0));
}

fn premulStorageColor(
    pixel_format: cpu_renderer.PixelFormat,
    rgba: [4]u8,
) [4]u8 {
    const alpha = rgba[3];
    const r = scaleByAlpha(rgba[0], alpha);
    const g = scaleByAlpha(rgba[1], alpha);
    const b = scaleByAlpha(rgba[2], alpha);
    return switch (pixel_format) {
        .bgra8_premul => .{ b, g, r, alpha },
        .rgba8_premul => .{ r, g, b, alpha },
    };
}

fn wrapRepeatCoord(coord: f32, size: f32) f32 {
    return @mod(@mod(coord, size) + size, size);
}

fn composeCpuBackgroundImageLegacy(
    alloc: Allocator,
    framebuffer: *cpu_renderer.FrameBuffer,
    bg_color_rgba: [4]u8,
    config: CpuBackgroundImageConfig,
    pixels: CpuImagePixels,
) !void {
    const bg_color = premulStorageColor(
        framebuffer.pixel_format,
        bg_color_rgba,
    );
    if (pixels.width == 0 or pixels.height == 0) {
        framebuffer.clear(bg_color);
        return;
    }

    const row_stride = try std.math.mul(
        u32,
        framebuffer.width_px,
        4,
    );
    const row_rgba = try alloc.alloc(
        u8,
        @as(usize, @intCast(row_stride)),
    );
    defer alloc.free(row_rgba);

    const screen_width = @as(f32, @floatFromInt(framebuffer.width_px));
    const screen_height = @as(f32, @floatFromInt(framebuffer.height_px));
    const tex_width = @as(f32, @floatFromInt(pixels.width));
    const tex_height = @as(f32, @floatFromInt(pixels.height));
    if (screen_width <= 0 or screen_height <= 0 or tex_width <= 0 or tex_height <= 0) {
        framebuffer.clear(bg_color);
        return;
    }

    var dest_width = tex_width;
    var dest_height = tex_height;
    switch (config.fit) {
        .contain => {
            const scale = @min(
                screen_width / tex_width,
                screen_height / tex_height,
            );
            dest_width = tex_width * scale;
            dest_height = tex_height * scale;
        },
        .cover => {
            const scale = @max(
                screen_width / tex_width,
                screen_height / tex_height,
            );
            dest_width = tex_width * scale;
            dest_height = tex_height * scale;
        },
        .stretch => {
            dest_width = screen_width;
            dest_height = screen_height;
        },
        .none => {},
    }
    if (dest_width <= 0 or dest_height <= 0) {
        framebuffer.clear(bg_color);
        return;
    }

    const start_x: f32 = 0;
    const start_y: f32 = 0;
    const mid_x = (screen_width - dest_width) / 2.0;
    const mid_y = (screen_height - dest_height) / 2.0;
    const end_x = screen_width - dest_width;
    const end_y = screen_height - dest_height;

    var offset_x = mid_x;
    var offset_y = mid_y;
    switch (config.position) {
        .tl => {
            offset_x = start_x;
            offset_y = start_y;
        },
        .tc => {
            offset_x = mid_x;
            offset_y = start_y;
        },
        .tr => {
            offset_x = end_x;
            offset_y = start_y;
        },
        .ml => {
            offset_x = start_x;
            offset_y = mid_y;
        },
        .mc => {
            offset_x = mid_x;
            offset_y = mid_y;
        },
        .mr => {
            offset_x = end_x;
            offset_y = mid_y;
        },
        .bl => {
            offset_x = start_x;
            offset_y = end_y;
        },
        .bc => {
            offset_x = mid_x;
            offset_y = end_y;
        },
        .br => {
            offset_x = end_x;
            offset_y = end_y;
        },
    }

    const scale_x = tex_width / dest_width;
    const scale_y = tex_height / dest_height;
    const bg_r = @as(f32, @floatFromInt(bg_color_rgba[0])) / 255.0;
    const bg_g = @as(f32, @floatFromInt(bg_color_rgba[1])) / 255.0;
    const bg_b = @as(f32, @floatFromInt(bg_color_rgba[2])) / 255.0;
    const bg_a = @as(f32, @floatFromInt(bg_color_rgba[3])) / 255.0;
    const image_opacity = @max(@as(f32, 0), @min(config.opacity, 1));
    const opacity = if (bg_a > 0)
        @min(image_opacity, 1.0 / bg_a)
    else
        image_opacity;

    framebuffer.clear(.{ 0, 0, 0, 0 });
    for (0..framebuffer.height_px) |yi| {
        const y_u32: u32 = @intCast(yi);
        const frag_y = @as(f32, @floatFromInt(y_u32)) + 0.5;
        for (0..framebuffer.width_px) |xi| {
            const x_u32: u32 = @intCast(xi);
            const frag_x = @as(f32, @floatFromInt(x_u32)) + 0.5;

            var tex_x = (frag_x - offset_x) * scale_x;
            var tex_y = (frag_y - offset_y) * scale_y;
            if (config.repeat) {
                tex_x = wrapRepeatCoord(tex_x, tex_width);
                tex_y = wrapRepeatCoord(tex_y, tex_height);
            }

            var src_r_premul: f32 = 0;
            var src_g_premul: f32 = 0;
            var src_b_premul: f32 = 0;
            var src_alpha: f32 = 0;
            if (tex_x >= 0 and tex_y >= 0 and tex_x <= tex_width and tex_y <= tex_height) {
                const sx = @min(
                    pixels.width - 1,
                    @as(u32, @intFromFloat(@floor(tex_x))),
                );
                const sy = @min(
                    pixels.height - 1,
                    @as(u32, @intFromFloat(@floor(tex_y))),
                );
                const off =
                    @as(usize, @intCast(sy)) * @as(usize, @intCast(pixels.stride_bytes)) +
                    @as(usize, @intCast(sx)) * 4;
                const r = pixels.data[off];
                const g = pixels.data[off + 1];
                const b = pixels.data[off + 2];
                const a = pixels.data[off + 3];
                src_alpha = @as(f32, @floatFromInt(a)) / 255.0;
                src_r_premul = (@as(f32, @floatFromInt(r)) / 255.0) * src_alpha;
                src_g_premul = (@as(f32, @floatFromInt(g)) / 255.0) * src_alpha;
                src_b_premul = (@as(f32, @floatFromInt(b)) / 255.0) * src_alpha;
            }

            const src_alpha_scaled = src_alpha * opacity;
            const src_r_scaled = src_r_premul * opacity;
            const src_g_scaled = src_g_premul * opacity;
            const src_b_scaled = src_b_premul * opacity;
            const bg_mix = 1.0 - src_alpha_scaled;
            const out_r = (src_r_scaled + bg_r * bg_mix) * bg_a;
            const out_g = (src_g_scaled + bg_g * bg_mix) * bg_a;
            const out_b = (src_b_scaled + bg_b * bg_mix) * bg_a;

            const row_off = @as(usize, @intCast(x_u32)) * 4;
            row_rgba[row_off] = float01ToByte(out_r);
            row_rgba[row_off + 1] = float01ToByte(out_g);
            row_rgba[row_off + 2] = float01ToByte(out_b);
            row_rgba[row_off + 3] = float01ToByte(bg_a);
        }

        framebuffer.blendPremulRgbaImage(
            0,
            y_u32,
            framebuffer.width_px,
            1,
            row_stride,
            row_rgba,
        );
    }
}

const SoftwareCpuRouteDisableReason = enum {
    build_cpu_route_unavailable,
    build_renderer_not_software,
    runtime_publishing_disabled,
    config_experimental_disabled,
    config_presenter_legacy_gl,
    custom_shaders_mode_off,
    custom_shaders_capability_unobserved,
    custom_shaders_unsupported,
    custom_shaders_safe_timeout_invalid,
    transport_native,
};

const BuildCpuRouteAvailabilitySource = enum {
    effective,
    mvp_not_requested,
    target_platform_unsupported,
    target_version_below_minimum,
};

fn buildCpuRouteTargetOsSupported(target_os: std.Target.Os.Tag) bool {
    return switch (target_os) {
        .macos, .linux => true,
        else => false,
    };
}

fn buildCpuRouteAvailabilitySource(
    cpu_route_effective: bool,
    cpu_route_mvp_requested: bool,
    cpu_route_target_os_supported: bool,
) BuildCpuRouteAvailabilitySource {
    if (cpu_route_effective) return .effective;
    if (!cpu_route_mvp_requested) return .mvp_not_requested;
    if (!cpu_route_target_os_supported) return .target_platform_unsupported;
    return .target_version_below_minimum;
}

fn buildCpuRouteAvailabilitySourceForCurrentBuild() BuildCpuRouteAvailabilitySource {
    return buildCpuRouteAvailabilitySource(
        software_renderer_cpu_effective,
        build_config.software_renderer_cpu_mvp,
        buildCpuRouteTargetOsSupported(builtin.target.os.tag),
    );
}

const SoftwareCpuRouteDecisionInput = struct {
    cpu_route_build_effective: bool,
    cpu_route_mvp_requested: bool,
    cpu_route_build_source: BuildCpuRouteAvailabilitySource,
    cpu_route_target_os_supported: bool,
    cpu_route_allow_legacy_os: bool,
    renderer_is_software: bool,
    software_frame_publishing: bool,
    software_renderer_experimental: bool,
    software_renderer_presenter: configpkg.Config.SoftwareRendererPresenter,
    custom_shaders_active: bool,
    custom_shader_execution_capability_observed: bool,
    custom_shader_execution_available: bool,
    custom_shader_execution_unavailable_reason: ?cpu_renderer.RuntimeCapabilityUnavailableReason,
    custom_shader_execution_hint_source: ?cpu_renderer.VulkanDriverHintSource,
    custom_shader_execution_hint_path: ?[]const u8,
    custom_shader_execution_hint_readable: bool,
    custom_shader_probe_minimal_runtime_enabled: bool,
    cpu_shader_mode: build_config.SoftwareRendererCpuShaderMode,
    cpu_shader_timeout_ms: u32,
    transport_mode_native: bool,
};

const SoftwareCpuRouteDecision = struct {
    enabled: bool,
    reason: ?SoftwareCpuRouteDisableReason = null,
    custom_shader_unavailable_reason: ?cpu_renderer.RuntimeCapabilityUnavailableReason = null,
    custom_shader_unavailable_hint_source: ?cpu_renderer.VulkanDriverHintSource = null,
    custom_shader_unavailable_hint_path: ?[]const u8 = null,
    custom_shader_unavailable_hint_readable: bool = false,
};

const CpuPublishRetryReason = enum {
    invalid_surface,
    pool_retired_pressure,
    frame_pool_exhausted,
    mailbox_backpressure,
};

const CpuPublishResult = union(enum) {
    published: void,
    retry: CpuPublishRetryReason,
};

const CpuFramePoolWarningReason = enum {
    retired_pool_pressure,
    frame_pool_exhausted,
};

const CpuRouteDiagnosticsSnapshot = struct {
    custom_shader_fallback_count: u64,
    custom_shader_bypass_count: u64,
    cpu_shader_capability_reprobe_count: u64,
    cpu_shader_reprobe_interval_frames: u32,
    publish_retry_count: u64,
    cpu_damage_rect_count: u64,
    cpu_damage_rect_overflow_count: u64,
    cpu_frame_damage_mode: []const u8,
    cpu_damage_rect_cap: u16,
    cpu_publish_skipped_no_damage_count: u64,
    cpu_publish_latency_warning_count: u64,
    last_cpu_publish_latency_warning_frame_ms: ?u64,
    last_cpu_publish_latency_warning_consecutive_count: u8,
    cpu_publish_warning_threshold_ms: u64,
    cpu_publish_warning_consecutive_limit: u8,
    cpu_publish_retry_invalid_surface_count: u64,
    cpu_publish_retry_pool_pressure_count: u64,
    cpu_publish_retry_pool_exhausted_count: u64,
    cpu_publish_retry_mailbox_backpressure_count: u64,
    cpu_retired_pool_pressure_warning_count: u64,
    cpu_frame_pool_exhausted_warning_count: u64,
    last_cpu_publish_retry_reason: []const u8,
    last_cpu_frame_pool_warning_reason: []const u8,
    last_cpu_frame_ms: ?u64,
    last_fallback_reason: ?SoftwareCpuRouteDisableReason,
    last_fallback_scope: []const u8,
    build_cpu_route_effective: bool,
    build_cpu_route_mvp_requested: bool,
    build_cpu_route_source: []const u8,
    build_cpu_route_target_os_supported: bool,
    build_cpu_route_allow_legacy_os: bool,
    shader_capability_observed: bool,
    shader_capability_available: bool,
    shader_minimal_runtime_enabled: bool,
    cpu_shader_backend: build_config.SoftwareRendererCpuShaderBackend,
    shader_capability_reason: []const u8,
    shader_capability_hint_source: []const u8,
    shader_capability_hint_path: []const u8,
    shader_capability_hint_readable: bool,
};

const CpuRouteDiagnosticsState = struct {
    custom_shader_fallback_count: u64 = 0,
    custom_shader_bypass_count: u64 = 0,
    cpu_shader_capability_reprobe_count: u64 = 0,
    publish_retry_count: u64 = 0,
    cpu_damage_rect_count: u64 = 0,
    cpu_damage_rect_overflow_count: u64 = 0,
    cpu_publish_skipped_no_damage_count: u64 = 0,
    cpu_publish_latency_warning_count: u64 = 0,
    last_cpu_publish_latency_warning_frame_ms: ?u64 = null,
    last_cpu_publish_latency_warning_consecutive_count: u8 = 0,
    cpu_publish_retry_invalid_surface_count: u64 = 0,
    cpu_publish_retry_pool_pressure_count: u64 = 0,
    cpu_publish_retry_pool_exhausted_count: u64 = 0,
    cpu_publish_retry_mailbox_backpressure_count: u64 = 0,
    cpu_retired_pool_pressure_warning_count: u64 = 0,
    cpu_frame_pool_exhausted_warning_count: u64 = 0,
    last_cpu_publish_retry_reason: ?CpuPublishRetryReason = null,
    last_cpu_frame_pool_warning_reason: ?CpuFramePoolWarningReason = null,
    last_cpu_frame_ms: ?u64 = null,
    last_fallback_reason: ?SoftwareCpuRouteDisableReason = null,
    last_shader_capability_observed: bool = false,
    last_shader_capability_available: bool = false,
    last_shader_minimal_runtime_enabled: bool = false,
    last_shader_capability_reason: ?cpu_renderer.RuntimeCapabilityUnavailableReason = null,
    last_shader_capability_hint_source: ?cpu_renderer.VulkanDriverHintSource = null,
    last_shader_capability_hint_path: ?[]const u8 = null,
    last_shader_capability_hint_readable: bool = false,

    fn recordCapabilityObservation(
        self: *CpuRouteDiagnosticsState,
        input: SoftwareCpuRouteDecisionInput,
    ) void {
        const observed = input.custom_shader_execution_capability_observed;
        self.last_shader_capability_observed = observed;
        self.last_shader_capability_available = observed and input.custom_shader_execution_available;
        self.last_shader_minimal_runtime_enabled = input.custom_shader_probe_minimal_runtime_enabled;

        if (!observed) {
            self.last_shader_capability_reason = null;
            self.last_shader_capability_hint_source = null;
            self.last_shader_capability_hint_path = null;
            self.last_shader_capability_hint_readable = false;
            return;
        }

        self.last_shader_capability_reason = input.custom_shader_execution_unavailable_reason;
        self.last_shader_capability_hint_source = input.custom_shader_execution_hint_source;
        self.last_shader_capability_hint_path = input.custom_shader_execution_hint_path;
        self.last_shader_capability_hint_readable = input.custom_shader_execution_hint_readable;
    }

    fn recordRouteDecision(
        self: *CpuRouteDiagnosticsState,
        input: SoftwareCpuRouteDecisionInput,
        decision: SoftwareCpuRouteDecision,
    ) void {
        if (decision.enabled) {
            self.last_fallback_reason = null;
            if (input.custom_shaders_active) {
                self.custom_shader_bypass_count +%= 1;
            }
            return;
        }
        const reason = decision.reason orelse return;

        self.last_fallback_reason = reason;
        if (reason == .custom_shaders_mode_off or
            reason == .custom_shaders_capability_unobserved or
            reason == .custom_shaders_unsupported or
            reason == .custom_shaders_safe_timeout_invalid)
        {
            self.custom_shader_fallback_count +%= 1;
        }
    }

    fn recordPublishRetry(self: *CpuRouteDiagnosticsState) void {
        self.publish_retry_count +%= 1;
    }

    fn recordPublishRetryReason(
        self: *CpuRouteDiagnosticsState,
        reason: CpuPublishRetryReason,
    ) void {
        self.recordPublishRetry();
        self.last_cpu_publish_retry_reason = reason;
        switch (reason) {
            .invalid_surface => self.cpu_publish_retry_invalid_surface_count +%= 1,
            .pool_retired_pressure => self.cpu_publish_retry_pool_pressure_count +%= 1,
            .frame_pool_exhausted => self.cpu_publish_retry_pool_exhausted_count +%= 1,
            .mailbox_backpressure => self.cpu_publish_retry_mailbox_backpressure_count +%= 1,
        }
    }

    fn recordCpuFramePublished(self: *CpuRouteDiagnosticsState, duration_ns: u64) void {
        self.last_cpu_frame_ms = duration_ns / std.time.ns_per_ms;
    }

    fn recordDamageStats(
        self: *CpuRouteDiagnosticsState,
        rect_count: usize,
        overflow_count: u64,
    ) void {
        self.cpu_damage_rect_count = @intCast(rect_count);
        self.cpu_damage_rect_overflow_count = overflow_count;
    }

    fn recordPublishSkippedNoDamage(self: *CpuRouteDiagnosticsState) void {
        self.cpu_publish_skipped_no_damage_count +%= 1;
    }

    fn recordCpuPublishLatencyWarning(
        self: *CpuRouteDiagnosticsState,
        frame_ms: u64,
        consecutive_count: u8,
    ) void {
        self.cpu_publish_latency_warning_count +%= 1;
        self.last_cpu_publish_latency_warning_frame_ms = frame_ms;
        self.last_cpu_publish_latency_warning_consecutive_count = consecutive_count;
    }

    fn recordFramePoolWarning(
        self: *CpuRouteDiagnosticsState,
        reason: CpuFramePoolWarningReason,
    ) void {
        self.last_cpu_frame_pool_warning_reason = reason;
        switch (reason) {
            .retired_pool_pressure => self.cpu_retired_pool_pressure_warning_count +%= 1,
            .frame_pool_exhausted => self.cpu_frame_pool_exhausted_warning_count +%= 1,
        }
    }

    fn recordCpuShaderCapabilityReprobe(self: *CpuRouteDiagnosticsState) void {
        self.cpu_shader_capability_reprobe_count +%= 1;
    }

    fn snapshot(self: *const CpuRouteDiagnosticsState) CpuRouteDiagnosticsSnapshot {
        const build_cpu_route_source = buildCpuRouteAvailabilitySourceForCurrentBuild();
        return .{
            .custom_shader_fallback_count = self.custom_shader_fallback_count,
            .custom_shader_bypass_count = self.custom_shader_bypass_count,
            .cpu_shader_capability_reprobe_count = self.cpu_shader_capability_reprobe_count,
            .cpu_shader_reprobe_interval_frames = cpu_custom_shader_capability_reprobe_interval_frames,
            .publish_retry_count = self.publish_retry_count,
            .cpu_damage_rect_count = self.cpu_damage_rect_count,
            .cpu_damage_rect_overflow_count = self.cpu_damage_rect_overflow_count,
            .cpu_frame_damage_mode = @tagName(software_renderer_cpu_frame_damage_mode),
            .cpu_damage_rect_cap = software_renderer_cpu_damage_rect_cap,
            .cpu_publish_skipped_no_damage_count = self.cpu_publish_skipped_no_damage_count,
            .cpu_publish_latency_warning_count = self.cpu_publish_latency_warning_count,
            .last_cpu_publish_latency_warning_frame_ms = self.last_cpu_publish_latency_warning_frame_ms,
            .last_cpu_publish_latency_warning_consecutive_count = self.last_cpu_publish_latency_warning_consecutive_count,
            .cpu_publish_warning_threshold_ms = cpu_frame_publish_warning_threshold_ms,
            .cpu_publish_warning_consecutive_limit = cpu_frame_publish_warning_consecutive_limit,
            .cpu_publish_retry_invalid_surface_count = self.cpu_publish_retry_invalid_surface_count,
            .cpu_publish_retry_pool_pressure_count = self.cpu_publish_retry_pool_pressure_count,
            .cpu_publish_retry_pool_exhausted_count = self.cpu_publish_retry_pool_exhausted_count,
            .cpu_publish_retry_mailbox_backpressure_count = self.cpu_publish_retry_mailbox_backpressure_count,
            .cpu_retired_pool_pressure_warning_count = self.cpu_retired_pool_pressure_warning_count,
            .cpu_frame_pool_exhausted_warning_count = self.cpu_frame_pool_exhausted_warning_count,
            .last_cpu_publish_retry_reason = if (self.last_cpu_publish_retry_reason) |reason|
                @tagName(reason)
            else
                "n/a",
            .last_cpu_frame_pool_warning_reason = if (self.last_cpu_frame_pool_warning_reason) |reason|
                @tagName(reason)
            else
                "n/a",
            .last_cpu_frame_ms = self.last_cpu_frame_ms,
            .last_fallback_reason = self.last_fallback_reason,
            .last_fallback_scope = softwareCpuRouteFallbackScope(self.last_fallback_reason),
            .build_cpu_route_effective = software_renderer_cpu_effective,
            .build_cpu_route_mvp_requested = build_config.software_renderer_cpu_mvp,
            .build_cpu_route_source = @tagName(build_cpu_route_source),
            .build_cpu_route_target_os_supported = buildCpuRouteTargetOsSupported(builtin.target.os.tag),
            .build_cpu_route_allow_legacy_os = build_config.software_renderer_cpu_allow_legacy_os,
            .shader_capability_observed = self.last_shader_capability_observed,
            .shader_capability_available = self.last_shader_capability_available,
            .shader_minimal_runtime_enabled = self.last_shader_minimal_runtime_enabled,
            .cpu_shader_backend = build_config.software_renderer_cpu_shader_backend,
            .shader_capability_reason = shaderCapabilityReasonForObservation(
                self.last_shader_capability_observed,
                self.last_shader_capability_available,
                self.last_shader_capability_reason,
            ),
            .shader_capability_hint_source = shaderCapabilityHintSourceForObservation(
                self.last_shader_capability_observed,
                self.last_shader_capability_available,
                self.last_shader_capability_hint_source,
            ),
            .shader_capability_hint_path = shaderCapabilityHintPathForObservation(
                self.last_shader_capability_observed,
                self.last_shader_capability_available,
                self.last_shader_capability_hint_path,
            ),
            .shader_capability_hint_readable = shaderCapabilityHintReadableForObservation(
                self.last_shader_capability_observed,
                self.last_shader_capability_available,
                self.last_shader_capability_hint_readable,
            ),
        };
    }
};

fn collectRetiredCpuFramePoolsForDiagnostics(
    retired_cpu_frame_pools: *std.ArrayListUnmanaged(cpu_renderer.FramePool),
    retired_pool_pressure_warned: *bool,
) void {
    var i: usize = 0;
    while (i < retired_cpu_frame_pools.items.len) {
        if (!retired_cpu_frame_pools.items[i].isIdle()) {
            i += 1;
            continue;
        }

        var retired = retired_cpu_frame_pools.swapRemove(i);
        retired.deinitIdle();
    }

    if (retired_cpu_frame_pools.items.len < max_retired_cpu_frame_pools) {
        retired_pool_pressure_warned.* = false;
    }
}

fn retireCpuFramePoolWithDiagnostics(
    alloc: Allocator,
    retired_cpu_frame_pools: *std.ArrayListUnmanaged(cpu_renderer.FramePool),
    retired_pool_pressure_warned: *bool,
    diagnostics: *CpuRouteDiagnosticsState,
    pool: cpu_renderer.FramePool,
) !void {
    collectRetiredCpuFramePoolsForDiagnostics(
        retired_cpu_frame_pools,
        retired_pool_pressure_warned,
    );
    if (retired_cpu_frame_pools.items.len >= max_retired_cpu_frame_pools) {
        if (!retired_pool_pressure_warned.*) {
            retired_pool_pressure_warned.* = true;
            diagnostics.recordFramePoolWarning(.retired_pool_pressure);
            const snapshot = diagnostics.snapshot();
            log.warn(
                "software renderer cpu retired pool pressure; delaying resize until in-flight frames retire count={} warning_count={} last_reason={s}",
                .{
                    retired_cpu_frame_pools.items.len,
                    snapshot.cpu_retired_pool_pressure_warning_count,
                    snapshot.last_cpu_frame_pool_warning_reason,
                },
            );
        }
        return error.CpuFramePoolRetiredPressure;
    }
    try retired_cpu_frame_pools.append(alloc, pool);
}

fn acquireCpuFramePoolSlotWithDiagnostics(
    pool: *cpu_renderer.FramePool,
    frame_pool_exhausted_warned: *bool,
    diagnostics: *CpuRouteDiagnosticsState,
) ?cpu_renderer.FramePool.Acquired {
    const acquired = pool.acquire() orelse {
        if (!frame_pool_exhausted_warned.*) {
            frame_pool_exhausted_warned.* = true;
            diagnostics.recordFramePoolWarning(.frame_pool_exhausted);
            const snapshot = diagnostics.snapshot();
            log.warn(
                "software renderer cpu frame pool exhausted; dropping frame warning_count={} last_reason={s}",
                .{
                    snapshot.cpu_frame_pool_exhausted_warning_count,
                    snapshot.last_cpu_frame_pool_warning_reason,
                },
            );
        }
        return null;
    };

    frame_pool_exhausted_warned.* = false;
    return acquired;
}

fn logCpuDamageOverflowKv(snapshot: CpuRouteDiagnosticsSnapshot) void {
    if (snapshot.cpu_damage_rect_overflow_count == 0) return;
    log.warn(
        "software renderer cpu damage kv frame_damage_mode={s} rect_count={} overflow_count={} damage_rect_cap={}",
        .{
            snapshot.cpu_frame_damage_mode,
            snapshot.cpu_damage_rect_count,
            snapshot.cpu_damage_rect_overflow_count,
            snapshot.cpu_damage_rect_cap,
        },
    );
}

fn logCpuPublishRetryKv(
    snapshot: CpuRouteDiagnosticsSnapshot,
    publish_pending: bool,
) void {
    log.warn(
        "software renderer cpu publish retry kv reason={s} retry_count={} invalid_surface_count={} pool_retired_pressure_count={} frame_pool_exhausted_count={} mailbox_backpressure_count={} publish_pending={}",
        .{
            snapshot.last_cpu_publish_retry_reason,
            snapshot.publish_retry_count,
            snapshot.cpu_publish_retry_invalid_surface_count,
            snapshot.cpu_publish_retry_pool_pressure_count,
            snapshot.cpu_publish_retry_pool_exhausted_count,
            snapshot.cpu_publish_retry_mailbox_backpressure_count,
            publish_pending,
        },
    );
}

fn logCpuPublishWarningKv(snapshot: CpuRouteDiagnosticsSnapshot) void {
    const last_cpu_frame_ms = snapshot.last_cpu_publish_latency_warning_frame_ms orelse return;
    log.warn(
        "software renderer cpu publish warning kv last_cpu_frame_ms={} threshold_ms={} consecutive={} warning_count={} shader_capability_observed={} shader_capability_available={} shader_minimal_runtime_enabled={}",
        .{
            last_cpu_frame_ms,
            snapshot.cpu_publish_warning_threshold_ms,
            snapshot.last_cpu_publish_latency_warning_consecutive_count,
            snapshot.cpu_publish_latency_warning_count,
            snapshot.shader_capability_observed,
            snapshot.shader_capability_available,
            snapshot.shader_minimal_runtime_enabled,
        },
    );
}

fn logCpuPublishSuccessKv(
    snapshot: CpuRouteDiagnosticsSnapshot,
    publish_pending: bool,
) void {
    const last_cpu_frame_ms = snapshot.last_cpu_frame_ms orelse return;
    log.warn(
        "software renderer cpu publish success kv last_cpu_frame_ms={} retry_count={} publish_pending={} shader_capability_observed={} shader_capability_available={} shader_minimal_runtime_enabled={}",
        .{
            last_cpu_frame_ms,
            snapshot.publish_retry_count,
            publish_pending,
            snapshot.shader_capability_observed,
            snapshot.shader_capability_available,
            snapshot.shader_minimal_runtime_enabled,
        },
    );
}

fn softwareCpuRouteDisableScope(reason: SoftwareCpuRouteDisableReason) []const u8 {
    return switch (reason) {
        .build_cpu_route_unavailable, .build_renderer_not_software => "build",
        .runtime_publishing_disabled,
        .config_experimental_disabled,
        .config_presenter_legacy_gl,
        .custom_shaders_mode_off,
        .custom_shaders_capability_unobserved,
        .custom_shaders_unsupported,
        .custom_shaders_safe_timeout_invalid,
        .transport_native,
        => "runtime",
    };
}

fn softwareCpuRouteFallbackScope(reason: ?SoftwareCpuRouteDisableReason) []const u8 {
    const fallback_reason = reason orelse return "none";
    return softwareCpuRouteDisableScope(fallback_reason);
}

fn shaderCapabilityReasonForObservation(
    observed: bool,
    available: bool,
    custom_shader_unavailable_reason: ?cpu_renderer.RuntimeCapabilityUnavailableReason,
) []const u8 {
    if (!observed) return "n/a";
    if (available) return "n/a";
    return if (custom_shader_unavailable_reason) |reason|
        @tagName(reason)
    else
        "unknown";
}

fn shaderCapabilityHintSourceForObservation(
    observed: bool,
    available: bool,
    custom_shader_hint_source: ?cpu_renderer.VulkanDriverHintSource,
) []const u8 {
    if (!observed) return "n/a";
    if (available) return "n/a";
    return if (custom_shader_hint_source) |source|
        @tagName(source)
    else
        "none";
}

fn shaderCapabilityHintPathForObservation(
    observed: bool,
    available: bool,
    custom_shader_hint_path: ?[]const u8,
) []const u8 {
    if (!observed) return "n/a";
    if (available) return "n/a";
    return custom_shader_hint_path orelse "none";
}

fn shaderCapabilityHintReadableForObservation(
    observed: bool,
    available: bool,
    custom_shader_hint_readable: bool,
) bool {
    if (!observed) return false;
    if (available) return false;
    return custom_shader_hint_readable;
}

fn shaderCapabilityReasonForDisableReason(
    reason: SoftwareCpuRouteDisableReason,
    custom_shader_unavailable_reason: ?cpu_renderer.RuntimeCapabilityUnavailableReason,
) []const u8 {
    return switch (reason) {
        .custom_shaders_capability_unobserved => "capability-unobserved",
        .custom_shaders_safe_timeout_invalid => "timeout-budget-zero",
        .custom_shaders_unsupported => if (custom_shader_unavailable_reason) |capability_reason|
            @tagName(capability_reason)
        else
            "unknown",
        else => "n/a",
    };
}

fn shaderCapabilityHintSourceForDisableReason(
    reason: SoftwareCpuRouteDisableReason,
    custom_shader_hint_source: ?cpu_renderer.VulkanDriverHintSource,
) []const u8 {
    return switch (reason) {
        .custom_shaders_unsupported => if (custom_shader_hint_source) |source|
            @tagName(source)
        else
            "none",
        else => "n/a",
    };
}

fn shaderCapabilityHintPathForDisableReason(
    reason: SoftwareCpuRouteDisableReason,
    custom_shader_hint_path: ?[]const u8,
) []const u8 {
    return switch (reason) {
        .custom_shaders_unsupported => custom_shader_hint_path orelse "none",
        else => "n/a",
    };
}

fn shaderCapabilityHintReadableForDisableReason(
    reason: SoftwareCpuRouteDisableReason,
    custom_shader_hint_readable: bool,
) bool {
    return switch (reason) {
        .custom_shaders_unsupported => custom_shader_hint_readable,
        else => false,
    };
}

fn cpuShaderMinimalRuntimeEnabledDefault() bool {
    return if (@hasDecl(build_config, "software_renderer_cpu_shader_enable_minimal_runtime"))
        build_config.software_renderer_cpu_shader_enable_minimal_runtime
    else
        false;
}

fn customShaderProbeMinimalRuntimeEnabled(probe: cpu_renderer.CustomShaderExecutionProbe) bool {
    return if (@hasField(cpu_renderer.CustomShaderExecutionProbe, "enable_minimal_runtime"))
        @field(probe, "enable_minimal_runtime")
    else
        cpuShaderMinimalRuntimeEnabledDefault();
}

fn cpuCustomShaderCapabilityReasonCanReprobe(
    reason: cpu_renderer.RuntimeCapabilityUnavailableReason,
) bool {
    if (@hasDecl(cpu_renderer, "runtimeCapabilityUnavailableReasonAllowsReprobe")) {
        return cpu_renderer.runtimeCapabilityUnavailableReasonAllowsReprobe(reason);
    }

    return switch (reason) {
        .backend_disabled,
        .backend_unavailable,
        .minimal_runtime_disabled,
        => false,
        .runtime_init_failed,
        .pipeline_compile_failed,
        .execution_timeout,
        .device_lost,
        => true,
    };
}

fn invalidateCpuCustomShaderProbeCache() void {
    if (@hasDecl(cpu_renderer, "invalidateCustomShaderExecutionProbeStatusCache")) {
        @field(cpu_renderer, "invalidateCustomShaderExecutionProbeStatusCache")();
        return;
    }
    if (@hasDecl(cpu_renderer, "invalidateCustomShaderExecutionProbeCache")) {
        @field(cpu_renderer, "invalidateCustomShaderExecutionProbeCache")();
        return;
    }
    if (@hasDecl(cpu_renderer, "invalidateCustomShaderExecutionProbeCaches")) {
        @field(cpu_renderer, "invalidateCustomShaderExecutionProbeCaches")();
        return;
    }
    if (@hasDecl(cpu_renderer, "clearCustomShaderExecutionProbeCache")) {
        @field(cpu_renderer, "clearCustomShaderExecutionProbeCache")();
        return;
    }
    if (@hasDecl(cpu_renderer, "clearCustomShaderExecutionProbeCaches")) {
        @field(cpu_renderer, "clearCustomShaderExecutionProbeCaches")();
        return;
    }
    if (@hasDecl(cpu_renderer, "invalidateCustomShaderProbeCache")) {
        @field(cpu_renderer, "invalidateCustomShaderProbeCache")();
        return;
    }
    if (@hasDecl(cpu_renderer, "invalidateCapabilityProbeCache")) {
        @field(cpu_renderer, "invalidateCapabilityProbeCache")();
        return;
    }
    if (@hasDecl(cpu_renderer, "invalidateCapabilityProbeCaches")) {
        @field(cpu_renderer, "invalidateCapabilityProbeCaches")();
        return;
    }
    if (@hasDecl(cpu_renderer, "clearCapabilityProbeCompileCache")) {
        @field(cpu_renderer, "clearCapabilityProbeCompileCache")();
        return;
    }
    if (@hasDecl(cpu_renderer, "resetCustomShaderExecutionProbeCache")) {
        @field(cpu_renderer, "resetCustomShaderExecutionProbeCache")();
        return;
    }
}

fn updateCpuFramePublishWarningState(
    state: *CpuFramePublishWarningState,
    snapshot: CpuRouteDiagnosticsSnapshot,
) bool {
    const frame_ms = snapshot.last_cpu_frame_ms orelse {
        state.* = .{};
        return false;
    };

    const capability_ready = snapshot.shader_capability_observed and
        snapshot.shader_capability_available and
        snapshot.shader_minimal_runtime_enabled;
    if (!capability_ready or frame_ms <= cpu_frame_publish_warning_threshold_ms) {
        state.* = .{};
        return false;
    }

    state.consecutive_over_threshold = std.math.add(
        u8,
        state.consecutive_over_threshold,
        1,
    ) catch std.math.maxInt(u8);
    if (state.consecutive_over_threshold < cpu_frame_publish_warning_consecutive_limit) {
        return false;
    }
    if (state.warned) return false;

    state.warned = true;
    return true;
}

fn decideSoftwareCpuRoute(input: SoftwareCpuRouteDecisionInput) SoftwareCpuRouteDecision {
    if (!input.cpu_route_build_effective) return .{
        .enabled = false,
        .reason = .build_cpu_route_unavailable,
    };
    if (!input.renderer_is_software) return .{
        .enabled = false,
        .reason = .build_renderer_not_software,
    };
    if (!input.software_frame_publishing) return .{
        .enabled = false,
        .reason = .runtime_publishing_disabled,
    };
    if (!input.software_renderer_experimental) return .{
        .enabled = false,
        .reason = .config_experimental_disabled,
    };
    if (input.software_renderer_presenter == .@"legacy-gl") return .{
        .enabled = false,
        .reason = .config_presenter_legacy_gl,
    };
    if (input.custom_shaders_active) switch (input.cpu_shader_mode) {
        .off => return .{
            .enabled = false,
            .reason = .custom_shaders_mode_off,
        },
        .safe => {
            if (!input.custom_shader_execution_capability_observed) return .{
                .enabled = false,
                .reason = .custom_shaders_capability_unobserved,
            };
            if (!input.custom_shader_execution_available) return .{
                .enabled = false,
                .reason = .custom_shaders_unsupported,
                .custom_shader_unavailable_reason = input.custom_shader_execution_unavailable_reason,
                .custom_shader_unavailable_hint_source = input.custom_shader_execution_hint_source,
                .custom_shader_unavailable_hint_path = input.custom_shader_execution_hint_path,
                .custom_shader_unavailable_hint_readable = input.custom_shader_execution_hint_readable,
            };
            if (input.cpu_shader_timeout_ms == 0) return .{
                .enabled = false,
                .reason = .custom_shaders_safe_timeout_invalid,
            };
        },
        .full => {
            if (!input.custom_shader_execution_capability_observed) return .{
                .enabled = false,
                .reason = .custom_shaders_capability_unobserved,
            };
            if (!input.custom_shader_execution_available) return .{
                .enabled = false,
                .reason = .custom_shaders_unsupported,
                .custom_shader_unavailable_reason = input.custom_shader_execution_unavailable_reason,
                .custom_shader_unavailable_hint_source = input.custom_shader_execution_hint_source,
                .custom_shader_unavailable_hint_path = input.custom_shader_execution_hint_path,
                .custom_shader_unavailable_hint_readable = input.custom_shader_execution_hint_readable,
            };
        },
    };
    if (input.transport_mode_native) return .{
        .enabled = false,
        .reason = .transport_native,
    };
    return .{ .enabled = true };
}

/// Create a renderer type with the provided graphics API wrapper.
///
/// The graphics API wrapper must provide the interface outlined below.
/// Specific details for the interfaces are documented on the existing
/// implementations (`Metal` and `OpenGL`).
///
/// Hierarchy of graphics abstractions:
///
/// [ GraphicsAPI ] - Responsible for configuring the runtime surface
///    |     |        and providing render `Target`s that draw to it,
///    |     |        as well as `Frame`s and `Pipeline`s.
///    |     V
///    | [ Target ] - Represents an abstract target for rendering, which
///    |              could be a surface directly but is also used as an
///    |              abstraction for off-screen frame buffers.
///    V
/// [ Frame ] - Represents the context for drawing a given frame,
///    |        provides `RenderPass`es for issuing draw commands
///    |        to, and reports the frame health when complete.
///    V
/// [ RenderPass ] - Represents a render pass in a frame, consisting of
///   :              one or more `Step`s applied to the same target(s),
/// [ Step ] - - - - each describing the input buffers and textures and
///   :              the vertex/fragment functions and geometry to use.
///   :_ _ _ _ _ _ _ _ _ _/
///   v
/// [ Pipeline ] - Describes a vertex and fragment function to be used
///                for a `Step`; the `GraphicsAPI` is responsible for
///                these and they should be constructed and cached
///                ahead of time.
///
/// [ Buffer ] - An abstraction over a GPU buffer.
///
/// [ Texture ] - An abstraction over a GPU texture.
///
pub fn Renderer(comptime GraphicsAPI: type) type {
    return struct {
        const Self = @This();

        pub const API = GraphicsAPI;

        const Target = GraphicsAPI.Target;
        const Buffer = GraphicsAPI.Buffer;
        const Sampler = GraphicsAPI.Sampler;
        const Texture = GraphicsAPI.Texture;
        const RenderPass = GraphicsAPI.RenderPass;

        const shaderpkg = GraphicsAPI.shaders;
        const Shaders = shaderpkg.Shaders;
        const cellpkg = cellmod.CellModule(shaderpkg);
        const imagepkg = @import("image.zig").ImageModule(GraphicsAPI);

        pub const ImageState = imagepkg.State;
        pub const Image = imagepkg.Image;

        /// Allocator that can be used
        alloc: std.mem.Allocator,

        /// This mutex must be held whenever any state used in `drawFrame` is
        /// being modified, and also when it's being accessed in `drawFrame`.
        draw_mutex: std.Thread.Mutex = .{},

        /// The configuration we need derived from the main config.
        config: DerivedConfig,

        /// The mailbox for communicating with the window.
        surface_mailbox: apprt.surface.Mailbox,

        /// Current font metrics defining our grid.
        grid_metrics: font.Metrics,

        /// The size of everything.
        size: renderer.Size,

        /// True if the window is focused
        focused: bool,

        /// Runtime gate for publishing software frames to apprt.
        ///
        /// This is controlled by apprt runtime capability/fallback state and
        /// complements config-level toggles.
        software_frame_publishing: bool = true,

        /// Reusable shared-CPU frame pool for software renderer CPU route.
        cpu_frame_pool: ?cpu_renderer.FramePool = null,

        /// Reusable text-only layer for CPU software publish path.
        ///
        /// `composeSoftwareFrame` clears the destination each invocation, so
        /// keeping this buffer across frames is safe and avoids hot-path
        /// alloc/free churn.
        cpu_text_layer: ?cpu_renderer.FrameBuffer = null,

        /// Retired pools waiting for in-flight frame callbacks to release.
        retired_cpu_frame_pools: std.ArrayListUnmanaged(cpu_renderer.FramePool) = .{},

        /// Monotonic software frame generation, independent from pool lifetime.
        cpu_frame_generation: u64 = 0,

        /// One-shot warning guard when native transport disables CPU route.
        cpu_native_transport_warned: bool = false,

        /// One-shot warning guard when custom shaders disable CPU route
        /// because shader mode is explicitly off.
        cpu_custom_shader_mode_off_warned: bool = false,

        /// One-shot warning guard when custom shaders disable CPU route
        /// because shader execution capability has not been observed yet.
        cpu_custom_shader_capability_unobserved_warned: bool = false,

        /// One-shot warning guard when custom shaders disable CPU route
        /// because CPU-route shader execution is not yet available.
        cpu_custom_shader_unsupported_warned: bool = false,

        /// One-shot warning guard when safe mode timeout budget is invalid.
        cpu_custom_shader_safe_timeout_warned: bool = false,

        /// One-shot warning guard when runtime publishing disables CPU route.
        cpu_runtime_publishing_warned: bool = false,

        /// One-shot warning guard when config disables experimental CPU route.
        cpu_config_experimental_warned: bool = false,

        /// One-shot warning guard when legacy presenter disables CPU route.
        cpu_legacy_presenter_warned: bool = false,

        /// One-shot warning guard when all CPU frame slots are in flight.
        cpu_frame_pool_exhausted_warned: bool = false,

        /// One-shot warning guard when retired pool pressure blocks resizing.
        cpu_retired_pool_pressure_warned: bool = false,

        /// Consecutive CPU publish latency warning state.
        cpu_frame_publish_warning: CpuFramePublishWarningState = .{},

        /// Pending republish flag when CPU frame publication was backpressured.
        cpu_publish_pending: bool = false,

        /// Runtime diagnostics state for software renderer CPU route.
        cpu_route_diagnostics: CpuRouteDiagnosticsState = .{},

        /// Cached CPU custom-shader probe result to avoid repeated per-frame
        /// environment/path probing while shader set is unchanged.
        cpu_custom_shader_probe: ?cpu_renderer.CustomShaderExecutionProbe = null,
        cpu_custom_shader_reprobe_unavailable_frame_count: u32 = 0,

        /// CPU-route frame damage tracker.
        cpu_damage_tracker: cpu_renderer.DamageTracker =
            cpu_renderer.DamageTracker.init(software_renderer_cpu_damage_rect_cap),

        /// Pending CPU damage state captured during cell rebuild.
        cpu_rebuild_damage_full: bool = true,
        cpu_rebuild_damage_row_min: ?u32 = null,
        cpu_rebuild_damage_row_max_exclusive: u32 = 0,

        /// Flag to indicate that our focus state changed for custom
        /// shaders to update their state.
        custom_shader_focused_changed: bool = false,

        /// The most recent scrollbar state. We use this as a cache to
        /// determine if we need to notify the apprt that there was a
        /// scrollbar change.
        scrollbar: terminal.Scrollbar,
        scrollbar_dirty: bool,

        /// Tracks the last bottom-right pin of the screen to detect new output.
        /// When the final line changes (node or y differs), new content was added.
        /// Used for scroll-to-bottom on output feature.
        last_bottom_node: ?usize,
        last_bottom_y: terminal.size.CellCountInt,

        /// The most recent viewport matches so that we can render search
        /// matches in the visible frame. This is provided asynchronously
        /// from the search thread so we have the dirty flag to also note
        /// if we need to rebuild our cells to include search highlights.
        ///
        /// Note that the selections MAY BE INVALID (point to PageList nodes
        /// that do not exist anymore). These must be validated prior to use.
        search_matches: ?renderer.Message.SearchMatches,
        search_selected_match: ?renderer.Message.SearchMatch,
        search_matches_dirty: bool,

        /// The current set of cells to render. This is rebuilt on every frame
        /// but we keep this around so that we don't reallocate. Each set of
        /// cells goes into a separate shader.
        cells: cellpkg.Contents,

        /// Set to true after rebuildCells is called. This can be used
        /// to determine if any possible changes have been made to the
        /// cells for the draw call.
        cells_rebuilt: bool = false,

        /// The current GPU uniform values.
        uniforms: shaderpkg.Uniforms,

        /// Custom shader uniform values.
        custom_shader_uniforms: shadertoy.Uniforms,

        /// Timestamp we rendered out first frame.
        ///
        /// This is used when updating custom shader uniforms.
        first_frame_time: ?std.time.Instant = null,

        /// Timestamp when we rendered out more recent frame.
        ///
        /// This is used when updating custom shader uniforms.
        last_frame_time: ?std.time.Instant = null,

        /// The font structures.
        font_grid: *font.SharedGrid,
        font_shaper: font.Shaper,
        font_shaper_cache: font.ShaperCache,

        /// The images that we may render.
        images: ImageState = .empty,

        /// Background image, if we have one.
        bg_image: ?imagepkg.Image = null,
        /// Set whenever the background image changes, signalling
        /// that the new background image needs to be uploaded to
        /// the GPU.
        ///
        /// This is initialized as true so that we load the image
        /// on renderer initialization, not just on config change.
        bg_image_changed: bool = true,
        /// Background image vertex buffer.
        bg_image_buffer: shaderpkg.BgImage,
        /// This value is used to force-update the swap chain copy
        /// of the background image buffer whenever we change it.
        bg_image_buffer_modified: usize = 0,

        /// Graphics API state.
        api: GraphicsAPI,

        /// The CVDisplayLink used to drive the rendering loop in
        /// sync with the display. This is void on platforms that
        /// don't support a display link.
        display_link: ?DisplayLink = null,

        /// Health of the most recently completed frame.
        health: std.atomic.Value(Health) = .{ .raw = .healthy },

        /// Our swap chain (multiple buffering)
        swap_chain: SwapChain,

        /// This value is used to force-update swap chain targets in the
        /// event of a config change that requires it (such as blending mode).
        target_config_modified: usize = 0,

        /// If something happened that requires us to reinitialize our shaders,
        /// this is set to true so that we can do that whenever possible.
        reinitialize_shaders: bool = false,

        /// Whether or not we have custom shaders.
        has_custom_shaders: bool = false,

        /// Our shader pipelines.
        shaders: Shaders,

        /// The render state we update per loop.
        terminal_state: terminal.RenderState = .empty,

        /// The number of frames since the last terminal state reset.
        /// We reset the terminal state after ~100,000 frames (about 10 to
        /// 15 minutes at 120Hz) to prevent wasted memory buildup from
        /// a large screen.
        terminal_state_frame_count: usize = 0,

        /// Our overlay state, if any.
        overlay: ?Overlay = null,

        /// One-shot process-local diagnostic guard for software CPU route logs.
        var software_cpu_route_diagnostic_logged: bool = false;

        const HighlightTag = enum(u8) {
            search_match,
            search_match_selected,
        };
        /// Swap chain which maintains multiple copies of the state needed to
        /// render a frame, so that we can start building the next frame while
        /// the previous frame is still being processed on the GPU.
        const SwapChain = struct {
            // The count of buffers we use for double/triple buffering.
            // If this is one then we don't do any double+ buffering at all.
            // This is comptime because there isn't a good reason to change
            // this at runtime and there is a lot of complexity to support it.
            const buf_count = GraphicsAPI.swap_chain_count;

            /// `buf_count` structs that can hold the
            /// data needed by the GPU to draw a frame.
            frames: [buf_count]FrameState,
            /// Index of the most recently used frame state struct.
            frame_index: std.math.IntFittingRange(0, buf_count) = 0,
            /// Semaphore that we wait on to make sure we have an available
            /// frame state struct so we can start working on a new frame.
            frame_sema: std.Thread.Semaphore = .{ .permits = buf_count },

            /// Set to true when deinited, if you try to deinit a defunct
            /// swap chain it will just be ignored, to prevent double-free.
            ///
            /// This is required because of `displayUnrealized`, since it
            /// `deinits` the swapchain, which leads to a double-free if
            /// the renderer is deinited after that.
            defunct: bool = false,

            pub fn init(api: GraphicsAPI, custom_shaders: bool) !SwapChain {
                var result: SwapChain = .{ .frames = undefined };

                // Initialize all of our frame state.
                for (&result.frames) |*frame| {
                    frame.* = try FrameState.init(api, custom_shaders);
                }

                return result;
            }

            pub fn deinit(self: *SwapChain) void {
                if (self.defunct) return;
                self.defunct = true;

                // Wait for all of our inflight draws to complete
                // so that we can cleanly deinit our GPU state.
                for (0..buf_count) |_| self.frame_sema.wait();
                for (&self.frames) |*frame| frame.deinit();
            }

            /// Get the next frame state to draw to. This will wait on the
            /// semaphore to ensure that the frame is available. This must
            /// always be paired with a call to releaseFrame.
            pub fn nextFrame(self: *SwapChain) error{Defunct}!*FrameState {
                if (self.defunct) return error.Defunct;

                self.frame_sema.wait();
                errdefer self.frame_sema.post();
                self.frame_index = (self.frame_index + 1) % buf_count;
                return &self.frames[self.frame_index];
            }

            /// This should be called when the frame has completed drawing.
            pub fn releaseFrame(self: *SwapChain) void {
                self.frame_sema.post();
            }
        };

        /// State we need duplicated for every frame. Any state that could be
        /// in a data race between the GPU and CPU while a frame is being drawn
        /// should be in this struct.
        ///
        /// While a draw is in-process, we "lock" the state (via a semaphore)
        /// and prevent the CPU from updating the state until our graphics API
        /// reports that the frame is complete.
        ///
        /// This is used to implement double/triple buffering.
        const FrameState = struct {
            uniforms: UniformBuffer,
            cells: CellTextBuffer,
            cells_bg: CellBgBuffer,

            grayscale: Texture,
            grayscale_modified: usize = 0,
            color: Texture,
            color_modified: usize = 0,

            target: Target,
            /// See property of same name on Renderer for explanation.
            target_config_modified: usize = 0,

            /// Buffer with the vertex data for our background image.
            ///
            /// This is lazily allocated and only present when we need
            /// to render the background image.
            bg_image_buffer: ?BgImageBuffer = null,
            /// See property of same name on Renderer for explanation.
            bg_image_buffer_modified: usize = 0,

            /// Custom shader state, this is null if we have no custom shaders.
            custom_shader_state: ?CustomShaderState = null,

            const UniformBuffer = Buffer(shaderpkg.Uniforms);
            const CellBgBuffer = Buffer(shaderpkg.CellBg);
            const CellTextBuffer = Buffer(shaderpkg.CellText);
            const BgImageBuffer = Buffer(shaderpkg.BgImage);

            pub fn init(api: GraphicsAPI, custom_shaders: bool) !FrameState {
                // Uniform buffer contains exactly 1 uniform struct. The
                // uniform data will be undefined so this must be set before
                // a frame is drawn.
                var uniforms = try UniformBuffer.init(api.uniformBufferOptions(), 1);
                errdefer uniforms.deinit();

                // Create GPU buffers for our cells.
                //
                // We start them off with a size of 1, which will of course be
                // too small, but they will be resized as needed. This is a bit
                // wasteful but since it's a one-time thing it's not really a
                // huge concern.
                var cells = try CellTextBuffer.init(api.fgBufferOptions(), 1);
                errdefer cells.deinit();
                var cells_bg = try CellBgBuffer.init(api.bgBufferOptions(), 1);
                errdefer cells_bg.deinit();

                // Initialize our textures for our font atlas.
                //
                // As with the buffers above, we start these off as small
                // as possible since they'll inevitably be resized anyway.
                const grayscale = try api.initAtlasTexture(&.{
                    .data = undefined,
                    .size = 1,
                    .format = .grayscale,
                });
                errdefer grayscale.deinit();
                const color = try api.initAtlasTexture(&.{
                    .data = undefined,
                    .size = 1,
                    .format = .bgra,
                });
                errdefer color.deinit();

                var custom_shader_state =
                    if (custom_shaders)
                        try CustomShaderState.init(api)
                    else
                        null;
                errdefer if (custom_shader_state) |*state| state.deinit();

                // Initialize the target. Just as with the other resources,
                // start it off as small as we can since it'll be resized.
                const target = try api.initTarget(1, 1);

                return .{
                    .uniforms = uniforms,
                    .cells = cells,
                    .cells_bg = cells_bg,
                    .grayscale = grayscale,
                    .color = color,
                    .target = target,
                    .custom_shader_state = custom_shader_state,
                };
            }

            pub fn deinit(self: *FrameState) void {
                self.target.deinit();
                self.uniforms.deinit();
                self.cells.deinit();
                self.cells_bg.deinit();
                self.grayscale.deinit();
                self.color.deinit();
                if (self.bg_image_buffer) |*bg_image_buffer| bg_image_buffer.deinit();
                if (self.custom_shader_state) |*state| state.deinit();
            }

            pub fn resize(
                self: *FrameState,
                api: GraphicsAPI,
                width: usize,
                height: usize,
            ) !void {
                if (self.custom_shader_state) |*state| {
                    try state.resize(api, width, height);
                }
                const target = try api.initTarget(width, height);
                self.target.deinit();
                self.target = target;
            }
        };

        /// State relevant to our custom shaders if we have any.
        const CustomShaderState = struct {
            /// When we have a custom shader state, we maintain a front
            /// and back texture which we use as a swap chain to render
            /// between when multiple custom shaders are defined.
            front_texture: Texture,
            back_texture: Texture,

            /// Shadertoy uses a sampler for accessing the various channel
            /// textures. In Metal, we need to explicitly create these since
            /// the glslang-to-msl compiler doesn't do it for us (as we
            /// normally would in hand-written MSL). To keep it clean and
            /// consistent, we just force all rendering APIs to provide an
            /// explicit sampler.
            ///
            /// Samplers are immutable and describe sampling properties so
            /// we can share the sampler across front/back textures (although
            /// we only need it for the source texture at a time, we don't
            /// need to "swap" it).
            sampler: Sampler,

            uniforms: UniformBuffer,

            const UniformBuffer = Buffer(shadertoy.Uniforms);

            /// Swap the front and back textures.
            pub fn swap(self: *CustomShaderState) void {
                std.mem.swap(Texture, &self.front_texture, &self.back_texture);
            }

            pub fn init(api: GraphicsAPI) !CustomShaderState {
                // Create a GPU buffer to hold our uniforms.
                var uniforms = try UniformBuffer.init(api.uniformBufferOptions(), 1);
                errdefer uniforms.deinit();

                // Initialize the front and back textures at 1x1 px, this
                // is slightly wasteful but it's only done once so whatever.
                const front_texture = try Texture.init(
                    api.textureOptions(),
                    1,
                    1,
                    null,
                );
                errdefer front_texture.deinit();
                const back_texture = try Texture.init(
                    api.textureOptions(),
                    1,
                    1,
                    null,
                );
                errdefer back_texture.deinit();

                const sampler = try Sampler.init(api.samplerOptions());
                errdefer sampler.deinit();

                return .{
                    .front_texture = front_texture,
                    .back_texture = back_texture,
                    .sampler = sampler,
                    .uniforms = uniforms,
                };
            }

            pub fn deinit(self: *CustomShaderState) void {
                self.front_texture.deinit();
                self.back_texture.deinit();
                self.sampler.deinit();
                self.uniforms.deinit();
            }

            pub fn resize(
                self: *CustomShaderState,
                api: GraphicsAPI,
                width: usize,
                height: usize,
            ) !void {
                const front_texture = try Texture.init(
                    api.textureOptions(),
                    @intCast(width),
                    @intCast(height),
                    null,
                );
                errdefer front_texture.deinit();
                const back_texture = try Texture.init(
                    api.textureOptions(),
                    @intCast(width),
                    @intCast(height),
                    null,
                );
                errdefer back_texture.deinit();

                self.front_texture.deinit();
                self.back_texture.deinit();

                self.front_texture = front_texture;
                self.back_texture = back_texture;
            }
        };

        /// The configuration for this renderer that is derived from the main
        /// configuration. This must be exported so that we don't need to
        /// pass around Config pointers which makes memory management a pain.
        pub const DerivedConfig = struct {
            arena: ArenaAllocator,

            font_thicken: bool,
            font_thicken_strength: u8,
            font_features: std.ArrayListUnmanaged([:0]const u8),
            font_styles: font.CodepointResolver.StyleStatus,
            font_shaping_break: configpkg.FontShapingBreak,
            cursor_color: ?configpkg.Config.TerminalColor,
            cursor_opacity: f64,
            cursor_text: ?configpkg.Config.TerminalColor,
            background: terminal.color.RGB,
            background_opacity: f64,
            background_opacity_cells: bool,
            foreground: terminal.color.RGB,
            selection_background: ?configpkg.Config.TerminalColor,
            selection_foreground: ?configpkg.Config.TerminalColor,
            search_background: configpkg.Config.TerminalColor,
            search_foreground: configpkg.Config.TerminalColor,
            search_selected_background: configpkg.Config.TerminalColor,
            search_selected_foreground: configpkg.Config.TerminalColor,
            bold_color: ?configpkg.BoldColor,
            faint_opacity: u8,
            min_contrast: f32,
            padding_color: configpkg.WindowPaddingColor,
            custom_shaders: configpkg.RepeatablePath,
            bg_image: ?configpkg.Path,
            bg_image_opacity: f32,
            bg_image_position: configpkg.BackgroundImagePosition,
            bg_image_fit: configpkg.BackgroundImageFit,
            bg_image_repeat: bool,
            links: link.Set,
            vsync: bool,
            colorspace: configpkg.Config.WindowColorspace,
            blending: configpkg.Config.AlphaBlending,
            background_blur: configpkg.Config.BackgroundBlur,
            software_renderer_experimental: bool,
            software_renderer_presenter: configpkg.Config.SoftwareRendererPresenter,
            scroll_to_bottom_on_output: bool,

            pub fn init(
                alloc_gpa: Allocator,
                config: *const configpkg.Config,
            ) !DerivedConfig {
                var arena = ArenaAllocator.init(alloc_gpa);
                errdefer arena.deinit();
                const alloc = arena.allocator();

                // Copy our shaders
                const custom_shaders = try config.@"custom-shader".clone(alloc);

                // Copy our background image
                const bg_image =
                    if (config.@"background-image") |bg|
                        try bg.clone(alloc)
                    else
                        null;

                // Copy our font features
                const font_features = try config.@"font-feature".clone(alloc);

                // Get our font styles
                var font_styles = font.CodepointResolver.StyleStatus.initFill(true);
                font_styles.set(.bold, config.@"font-style-bold" != .false);
                font_styles.set(.italic, config.@"font-style-italic" != .false);
                font_styles.set(.bold_italic, config.@"font-style-bold-italic" != .false);

                // Our link configs
                const links = try link.Set.fromConfig(
                    alloc,
                    config.link.links.items,
                );

                return .{
                    .background_opacity = @max(0, @min(1, config.@"background-opacity")),
                    .background_opacity_cells = config.@"background-opacity-cells",
                    .font_thicken = config.@"font-thicken",
                    .font_thicken_strength = config.@"font-thicken-strength",
                    .font_features = font_features.list,
                    .font_styles = font_styles,
                    .font_shaping_break = config.@"font-shaping-break",

                    .cursor_color = config.@"cursor-color",
                    .cursor_text = config.@"cursor-text",
                    .cursor_opacity = @max(0, @min(1, config.@"cursor-opacity")),

                    .background = config.background.toTerminalRGB(),
                    .foreground = config.foreground.toTerminalRGB(),
                    .bold_color = config.@"bold-color",
                    .faint_opacity = @intFromFloat(@ceil(config.@"faint-opacity" * 255)),

                    .min_contrast = @floatCast(config.@"minimum-contrast"),
                    .padding_color = config.@"window-padding-color",

                    .selection_background = config.@"selection-background",
                    .selection_foreground = config.@"selection-foreground",
                    .search_background = config.@"search-background",
                    .search_foreground = config.@"search-foreground",
                    .search_selected_background = config.@"search-selected-background",
                    .search_selected_foreground = config.@"search-selected-foreground",

                    .custom_shaders = custom_shaders,
                    .bg_image = bg_image,
                    .bg_image_opacity = config.@"background-image-opacity",
                    .bg_image_position = config.@"background-image-position",
                    .bg_image_fit = config.@"background-image-fit",
                    .bg_image_repeat = config.@"background-image-repeat",
                    .links = links,
                    .vsync = config.@"window-vsync",
                    .colorspace = config.@"window-colorspace",
                    .blending = config.@"alpha-blending",
                    .background_blur = config.@"background-blur",
                    .software_renderer_experimental = config.@"software-renderer-experimental",
                    .software_renderer_presenter = config.@"software-renderer-presenter",
                    .scroll_to_bottom_on_output = config.@"scroll-to-bottom".output,
                    .arena = arena,
                };
            }

            pub fn deinit(self: *DerivedConfig) void {
                const alloc = self.arena.allocator();
                self.links.deinit(alloc);
                self.arena.deinit();
            }
        };

        pub fn init(alloc: Allocator, options: renderer.Options) !Self {
            maybeLogSoftwareCpuRouteDiagnostic();

            // Initialize our graphics API wrapper, this will prepare the
            // surface provided by the apprt and set up any API-specific
            // GPU resources.
            var api = try GraphicsAPI.init(alloc, options);
            errdefer api.deinit();

            const has_custom_shaders = options.config.custom_shaders.value.items.len > 0;

            // Prepare our swap chain
            var swap_chain = try SwapChain.init(
                api,
                has_custom_shaders,
            );
            errdefer swap_chain.deinit();

            // Create the font shaper.
            var font_shaper = try font.Shaper.init(alloc, .{
                .features = options.config.font_features.items,
            });
            errdefer font_shaper.deinit();

            // Initialize all the data that requires a critical font section.
            const font_critical: struct {
                metrics: font.Metrics,
            } = font_critical: {
                const grid: *font.SharedGrid = options.font_grid;
                grid.lock.lockShared();
                defer grid.lock.unlockShared();
                break :font_critical .{
                    .metrics = grid.metrics,
                };
            };

            const display_link: ?DisplayLink = switch (builtin.os.tag) {
                .macos => if (options.config.vsync)
                    try macos.video.DisplayLink.createWithActiveCGDisplays()
                else
                    null,
                else => null,
            };
            errdefer if (display_link) |v| v.release();

            var result: Self = .{
                .alloc = alloc,
                .config = options.config,
                .surface_mailbox = options.surface_mailbox,
                .grid_metrics = font_critical.metrics,
                .size = options.size,
                .focused = true,
                .scrollbar = .zero,
                .scrollbar_dirty = false,
                .last_bottom_node = null,
                .last_bottom_y = 0,
                .search_matches = null,
                .search_selected_match = null,
                .search_matches_dirty = false,

                // Render state
                .cells = .{},
                .uniforms = .{
                    .projection_matrix = undefined,
                    .cell_size = undefined,
                    .grid_size = undefined,
                    .grid_padding = undefined,
                    .screen_size = undefined,
                    .padding_extend = .{},
                    .min_contrast = options.config.min_contrast,
                    .cursor_pos = .{ std.math.maxInt(u16), std.math.maxInt(u16) },
                    .cursor_color = undefined,
                    .bg_color = .{
                        options.config.background.r,
                        options.config.background.g,
                        options.config.background.b,
                        // Note that if we're on macOS with glass effects
                        // we'll disable background opacity but we handle
                        // that in updateFrame.
                        @intFromFloat(@round(options.config.background_opacity * 255.0)),
                    },
                    .bools = .{
                        .cursor_wide = false,
                        .use_display_p3 = options.config.colorspace == .@"display-p3",
                        .use_linear_blending = options.config.blending.isLinear(),
                        .use_linear_correction = options.config.blending == .@"linear-corrected",
                    },
                },
                .custom_shader_uniforms = .{
                    .resolution = .{ 0, 0, 1 },
                    .time = 0,
                    .time_delta = 0,
                    .frame_rate = 60, // not currently updated
                    .frame = 0,
                    .channel_time = @splat(@splat(0)), // not currently updated
                    .channel_resolution = @splat(@splat(0)),
                    .mouse = @splat(0), // not currently updated
                    .date = @splat(0), // not currently updated
                    .sample_rate = 0, // N/A, we don't have any audio
                    .current_cursor = @splat(0),
                    .previous_cursor = @splat(0),
                    .current_cursor_color = @splat(0),
                    .previous_cursor_color = @splat(0),
                    .current_cursor_style = 0,
                    .previous_cursor_style = 0,
                    .cursor_visible = 0,
                    .cursor_change_time = 0,
                    .time_focus = 0,
                    .focus = 1, // assume focused initially
                    .palette = @splat(@splat(0)),
                    .background_color = @splat(0),
                    .foreground_color = @splat(0),
                    .cursor_color = @splat(0),
                    .cursor_text = @splat(0),
                    .selection_background_color = @splat(0),
                    .selection_foreground_color = @splat(0),
                },
                .bg_image_buffer = undefined,

                // Fonts
                .font_grid = options.font_grid,
                .font_shaper = font_shaper,
                .font_shaper_cache = font.ShaperCache.init(),

                // Shaders (initialized below)
                .shaders = undefined,

                // Graphics API stuff
                .api = api,
                .swap_chain = swap_chain,
                .display_link = display_link,
            };

            try result.initShaders();

            // Ensure our undefined values above are correctly initialized.
            result.updateFontGridUniforms();
            result.updateScreenSizeUniforms();
            result.updateBgImageBuffer();
            try result.prepBackgroundImage();

            return result;
        }

        fn maybeLogSoftwareCpuRouteDiagnostic() void {
            if (software_cpu_route_diagnostic_logged) return;
            software_cpu_route_diagnostic_logged = true;

            if (comptime build_config.renderer != .software) return;
            if (!comptime build_config.software_renderer_cpu_mvp) return;

            const cpu_min_macos_major = comptime if (@hasDecl(build_config, "software_renderer_cpu_min_macos_major"))
                build_config.software_renderer_cpu_min_macos_major
            else
                11;
            const cpu_min_macos_minor = comptime if (@hasDecl(build_config, "software_renderer_cpu_min_macos_minor"))
                build_config.software_renderer_cpu_min_macos_minor
            else
                0;
            const cpu_min_linux_major = comptime if (@hasDecl(build_config, "software_renderer_cpu_min_linux_major"))
                build_config.software_renderer_cpu_min_linux_major
            else
                5;
            const cpu_min_linux_minor = comptime if (@hasDecl(build_config, "software_renderer_cpu_min_linux_minor"))
                build_config.software_renderer_cpu_min_linux_minor
            else
                0;

            const cpu_effective = comptime if (@hasDecl(build_config, "software_renderer_cpu_effective"))
                build_config.software_renderer_cpu_effective
            else
                build_config.software_renderer_cpu_mvp;
            const cpu_target_os_supported = comptime buildCpuRouteTargetOsSupported(
                builtin.target.os.tag,
            );
            const cpu_build_source = comptime buildCpuRouteAvailabilitySource(
                cpu_effective,
                build_config.software_renderer_cpu_mvp,
                cpu_target_os_supported,
            );

            if (comptime cpu_effective) {
                if (comptime software_renderer_cpu_frame_damage_mode == .rects and
                    software_renderer_cpu_damage_rect_cap_configured == 0)
                {
                    log.warn(
                        "software renderer cpu damage rect cap 0 is invalid in rects mode; clamped to 1",
                        .{},
                    );
                }

                log.info(
                    "software renderer cpu-mvp route active target_os={s} route_backend={s} cpu_shader_backend={s} allow_legacy_os={} build_source={s} target_os_supported={} build_effective={}",
                    .{
                        @tagName(builtin.target.os.tag),
                        @tagName(build_config.software_renderer_route_backend),
                        @tagName(build_config.software_renderer_cpu_shader_backend),
                        build_config.software_renderer_cpu_allow_legacy_os,
                        @tagName(cpu_build_source),
                        cpu_target_os_supported,
                        cpu_effective,
                    },
                );

                if (comptime build_config.software_renderer_cpu_shader_mode != .off) {
                    const probe = cpu_renderer.customShaderExecutionProbe();
                    const hint_source = if (probe.vulkan_driver_hint_source) |source|
                        @tagName(source)
                    else
                        "none";
                    const hint_path = probe.vulkan_driver_hint_path orelse "none";
                    const capability_status: []const u8 = switch (probe.status) {
                        .available => "available",
                        .unavailable => "unavailable",
                    };
                    const capability_reason: []const u8 = switch (probe.status) {
                        .available => "n/a",
                        .unavailable => |reason| @tagName(reason),
                    };
                    switch (probe.status) {
                        .available => log.info(
                            "software renderer cpu shader capability status=available mode={s} backend={s} timeout_ms={} hint_source={s} hint_path={s} hint_readable={}",
                            .{
                                @tagName(build_config.software_renderer_cpu_shader_mode),
                                @tagName(probe.backend),
                                probe.timeout_ms,
                                hint_source,
                                hint_path,
                                probe.vulkan_driver_hint_readable,
                            },
                        ),
                        .unavailable => |reason| log.info(
                            "software renderer cpu shader capability status=unavailable mode={s} backend={s} timeout_ms={} reason={s} hint_source={s} hint_path={s} hint_readable={}",
                            .{
                                @tagName(build_config.software_renderer_cpu_shader_mode),
                                @tagName(probe.backend),
                                probe.timeout_ms,
                                @tagName(reason),
                                hint_source,
                                hint_path,
                                probe.vulkan_driver_hint_readable,
                            },
                        ),
                    }
                    log.info(
                        "software renderer cpu shader capability kv status={s} reason={s} mode={s} backend={s} timeout_ms={} hint_source={s} hint_path={s} hint_readable={} minimal_runtime_enabled={} observed=true",
                        .{
                            capability_status,
                            capability_reason,
                            @tagName(build_config.software_renderer_cpu_shader_mode),
                            @tagName(probe.backend),
                            probe.timeout_ms,
                            hint_source,
                            hint_path,
                            probe.vulkan_driver_hint_readable,
                            probe.enable_minimal_runtime,
                        },
                    );
                }

                return;
            }

            log.warn(
                "software renderer cpu-mvp requested but unavailable target_os={s} route_backend={s} cpu_shader_backend={s} allow_legacy_os={} build_source={s} target_os_supported={} build_effective={}; requires macOS >= {}.{} or Linux >= {}.{}, falling back to platform route",
                .{
                    @tagName(builtin.target.os.tag),
                    @tagName(build_config.software_renderer_route_backend),
                    @tagName(build_config.software_renderer_cpu_shader_backend),
                    build_config.software_renderer_cpu_allow_legacy_os,
                    @tagName(cpu_build_source),
                    cpu_target_os_supported,
                    cpu_effective,
                    cpu_min_macos_major,
                    cpu_min_macos_minor,
                    cpu_min_linux_major,
                    cpu_min_linux_minor,
                },
            );
        }

        fn waitForCpuFramePoolIdle(pool: *cpu_renderer.FramePool, timeout_ms: u64) bool {
            if (pool.isIdle()) return true;

            const start = std.time.Instant.now() catch return pool.isIdle();
            const timeout_ns = std.math.mul(
                u64,
                timeout_ms,
                std.time.ns_per_ms,
            ) catch std.math.maxInt(u64);
            while (true) {
                if (pool.isIdle()) return true;
                const now = std.time.Instant.now() catch break;
                if (now.since(start) >= timeout_ns) break;
                std.Thread.sleep(std.time.ns_per_ms);
            }

            return pool.isIdle();
        }

        pub fn deinit(self: *Self) void {
            if (self.overlay) |*overlay| overlay.deinit(self.alloc);
            self.terminal_state.deinit(self.alloc);
            if (self.search_selected_match) |*m| m.arena.deinit();
            if (self.search_matches) |*m| m.arena.deinit();
            self.swap_chain.deinit();

            if (DisplayLink != void) {
                if (self.display_link) |display_link| {
                    display_link.stop() catch {};
                    display_link.release();
                }
            }

            self.cells.deinit(self.alloc);

            self.font_shaper.deinit();
            self.font_shaper_cache.deinit(self.alloc);

            self.config.deinit();
            self.cpu_damage_tracker.deinit(self.alloc);

            self.images.deinit(self.alloc);

            if (self.bg_image) |img| img.deinit(self.alloc);

            self.deinitShaders();

            if (self.cpu_frame_pool) |*pool| {
                if (!pool.isIdle()) {
                    _ = waitForCpuFramePoolIdle(pool, cpu_frame_pool_deinit_wait_ms);
                }

                if (pool.isIdle()) {
                    pool.deinitIdle();
                } else {
                    log.warn(
                        "renderer deinit with in-flight cpu frame pool; leaking for safety",
                        .{},
                    );
                }
            }

            if (self.cpu_text_layer) |*layer| {
                layer.deinit(self.alloc);
            }

            self.collectRetiredCpuFramePools();
            for (self.retired_cpu_frame_pools.items) |*pool| {
                if (pool.isIdle()) {
                    pool.deinitIdle();
                    continue;
                }

                _ = waitForCpuFramePoolIdle(pool, cpu_frame_pool_deinit_wait_ms);
                if (pool.isIdle()) {
                    pool.deinitIdle();
                    continue;
                }

                log.warn(
                    "renderer deinit with in-flight retired cpu frame pool; leaking for safety",
                    .{},
                );
            }
            self.retired_cpu_frame_pools.deinit(self.alloc);

            self.api.deinit();

            self.* = undefined;
        }

        fn deinitShaders(self: *Self) void {
            self.shaders.deinit(self.alloc);
        }

        fn initShaders(self: *Self) !void {
            var arena = ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const arena_alloc = arena.allocator();

            // Load our custom shaders
            const custom_shaders: []const [:0]const u8 = shadertoy.loadFromFiles(
                arena_alloc,
                self.config.custom_shaders,
                GraphicsAPI.custom_shader_target,
            ) catch |err| err: {
                log.warn("error loading custom shaders err={}", .{err});
                break :err &.{};
            };

            const has_custom_shaders = custom_shaders.len > 0;

            var shaders = try self.api.initShaders(
                self.alloc,
                custom_shaders,
            );
            errdefer shaders.deinit(self.alloc);

            self.shaders = shaders;
            self.has_custom_shaders = has_custom_shaders;
            self.cpu_custom_shader_probe = null;
            self.cpu_custom_shader_reprobe_unavailable_frame_count = 0;
        }

        /// This is called early right after surface creation.
        pub fn surfaceInit(surface: *apprt.Surface) !void {
            // If our API has to do things here, let it.
            if (@hasDecl(GraphicsAPI, "surfaceInit")) {
                try GraphicsAPI.surfaceInit(surface);
            }
        }

        /// This is called just prior to spinning up the renderer thread for
        /// final main thread setup requirements.
        pub fn finalizeSurfaceInit(self: *Self, surface: *apprt.Surface) !void {
            // If our API has to do things to finalize surface init, let it.
            if (@hasDecl(GraphicsAPI, "finalizeSurfaceInit")) {
                try self.api.finalizeSurfaceInit(surface);
            }
        }

        /// Callback called by renderer.Thread when it begins.
        pub fn threadEnter(self: *const Self, surface: *apprt.Surface) !void {
            // If our API has to do things on thread enter, let it.
            if (@hasDecl(GraphicsAPI, "threadEnter")) {
                try self.api.threadEnter(surface);
            }
        }

        /// Callback called by renderer.Thread when it exits.
        pub fn threadExit(self: *const Self) void {
            // If our API has to do things on thread exit, let it.
            if (@hasDecl(GraphicsAPI, "threadExit")) {
                self.api.threadExit();
            }
        }

        /// Called by renderer.Thread when it starts the main loop.
        pub fn loopEnter(self: *Self, thr: *renderer.Thread) !void {
            // If our API has to do things on loop enter, let it.
            if (@hasDecl(GraphicsAPI, "loopEnter")) {
                self.api.loopEnter();
            }

            // If we don't support a display link we have no work to do.
            if (comptime DisplayLink == void) return;

            // This is when we know our "self" pointer is stable so we can
            // setup the display link. To setup the display link we set our
            // callback and we can start it immediately.
            const display_link = self.display_link orelse return;
            try display_link.setOutputCallback(
                xev.Async,
                &displayLinkCallback,
                &thr.draw_now,
            );
            display_link.start() catch {};
        }

        /// Called by renderer.Thread when it exits the main loop.
        pub fn loopExit(self: *Self) void {
            // If our API has to do things on loop exit, let it.
            if (@hasDecl(GraphicsAPI, "loopExit")) {
                self.api.loopExit();
            }

            // If we don't support a display link we have no work to do.
            if (comptime DisplayLink == void) return;

            // Stop our display link. If this fails its okay it just means
            // that we either never started it or the view its attached to
            // is gone which is fine.
            const display_link = self.display_link orelse return;
            display_link.stop() catch {};
        }

        /// This is called by the GTK apprt after the surface is
        /// reinitialized due to any of the events mentioned in
        /// the doc comment for `displayUnrealized`.
        pub fn displayRealized(self: *Self) !void {
            // If our API has to do things on realize, let it.
            if (@hasDecl(GraphicsAPI, "displayRealized")) {
                self.api.displayRealized();
            }

            // Lock the draw mutex so that we can
            // safely reinitialize our GPU resources.
            self.draw_mutex.lock();
            defer self.draw_mutex.unlock();

            // We assume that the swap chain was deinited in
            // `displayUnrealized`, in which case it should be
            // marked defunct. If not, we have a problem.
            assert(self.swap_chain.defunct);

            // We reinitialize our shaders and our swap chain.
            try self.initShaders();
            self.swap_chain = try SwapChain.init(
                self.api,
                self.has_custom_shaders,
            );
            self.reinitialize_shaders = false;
            self.target_config_modified = 1;
        }

        /// This is called by the GTK apprt when the surface is being destroyed.
        /// This can happen because the surface is being closed but also when
        /// moving the window between displays or splitting.
        pub fn displayUnrealized(self: *Self) void {
            // If our API has to do things on unrealize, let it.
            if (@hasDecl(GraphicsAPI, "displayUnrealized")) {
                self.api.displayUnrealized();
            }

            // Lock the draw mutex so that we can
            // safely deinitialize our GPU resources.
            self.draw_mutex.lock();
            defer self.draw_mutex.unlock();

            // We deinit our swap chain and shaders.
            //
            // This will mark them as defunct so that they
            // can't be double-freed or used in draw calls.
            self.swap_chain.deinit();
            self.shaders.deinit(self.alloc);
        }

        fn displayLinkCallback(
            _: *macos.video.DisplayLink,
            ud: ?*xev.Async,
        ) void {
            const draw_now = ud orelse return;
            draw_now.notify() catch |err| {
                log.err("error notifying draw_now err={}", .{err});
            };
        }

        /// Mark the full screen as dirty so that we redraw everything.
        pub inline fn markDirty(self: *Self) void {
            self.terminal_state.dirty = .full;
        }

        /// Called when we get an updated display ID for our display link.
        pub fn setMacOSDisplayID(self: *Self, id: u32) !void {
            if (comptime DisplayLink == void) return;
            const display_link = self.display_link orelse return;
            log.info("updating display link display id={}", .{id});
            display_link.setCurrentCGDisplay(id) catch |err| {
                log.warn("error setting display link display id err={}", .{err});
            };
        }

        /// True if our renderer has animations so that a higher frequency
        /// timer is used.
        pub fn hasAnimations(self: *const Self) bool {
            return self.has_custom_shaders;
        }

        /// True if our renderer is using vsync. If true, the renderer or apprt
        /// is responsible for triggering draw_now calls to the render thread.
        /// That is the only way to trigger a drawFrame.
        pub fn hasVsync(self: *const Self) bool {
            if (comptime DisplayLink == void) return false;
            const display_link = self.display_link orelse return false;
            return display_link.isRunning();
        }

        /// Callback when the focus changes for the terminal this is rendering.
        ///
        /// Must be called on the render thread.
        pub fn setFocus(self: *Self, focus: bool) !void {
            assert(self.focused != focus);

            self.focused = focus;

            // Flag that we need to update our custom shaders
            self.custom_shader_focused_changed = true;

            // If we're not focused, then we want to stop the display link
            // because it is a waste of resources and we can move to pure
            // change-driven updates.
            if (comptime DisplayLink != void) link: {
                const display_link = self.display_link orelse break :link;
                if (focus) {
                    display_link.start() catch {};
                } else {
                    display_link.stop() catch {};
                }
            }
        }

        /// Callback when the window is visible or occluded.
        ///
        /// Must be called on the render thread.
        pub fn setVisible(self: *Self, visible: bool) void {
            // If we're not visible, then we want to stop the display link
            // because it is a waste of resources and we can move to pure
            // change-driven updates.
            if (comptime DisplayLink != void) link: {
                const display_link = self.display_link orelse break :link;
                if (visible and self.focused) {
                    display_link.start() catch {};
                } else {
                    display_link.stop() catch {};
                }
            }
        }

        /// Enable or disable publishing software frames to apprt.
        ///
        /// Must be called on the render thread.
        pub fn setSoftwareFramePublishing(self: *Self, enabled: bool) void {
            self.draw_mutex.lock();
            defer self.draw_mutex.unlock();
            self.software_frame_publishing = enabled;
        }

        /// Return a snapshot of software renderer CPU route diagnostics.
        pub fn cpuRouteDiagnosticsSnapshot(self: *Self) CpuRouteDiagnosticsSnapshot {
            self.draw_mutex.lock();
            defer self.draw_mutex.unlock();
            return self.cpu_route_diagnostics.snapshot();
        }

        fn softwareCpuRouteWarnFlag(
            self: *Self,
            reason: SoftwareCpuRouteDisableReason,
        ) ?*bool {
            return switch (reason) {
                .runtime_publishing_disabled => &self.cpu_runtime_publishing_warned,
                .config_experimental_disabled => &self.cpu_config_experimental_warned,
                .config_presenter_legacy_gl => &self.cpu_legacy_presenter_warned,
                .custom_shaders_mode_off => &self.cpu_custom_shader_mode_off_warned,
                .custom_shaders_capability_unobserved => &self.cpu_custom_shader_capability_unobserved_warned,
                .custom_shaders_unsupported => &self.cpu_custom_shader_unsupported_warned,
                .custom_shaders_safe_timeout_invalid => &self.cpu_custom_shader_safe_timeout_warned,
                .transport_native => &self.cpu_native_transport_warned,
                .build_cpu_route_unavailable,
                .build_renderer_not_software,
                => null,
            };
        }

        fn resetSoftwareCpuRouteWarnFlags(self: *Self) void {
            if (self.software_frame_publishing) self.cpu_runtime_publishing_warned = false;
            if (self.config.software_renderer_experimental) self.cpu_config_experimental_warned = false;
            if (self.config.software_renderer_presenter != .@"legacy-gl") self.cpu_legacy_presenter_warned = false;
            if (!self.has_custom_shaders) {
                self.cpu_custom_shader_mode_off_warned = false;
                self.cpu_custom_shader_capability_unobserved_warned = false;
                self.cpu_custom_shader_unsupported_warned = false;
                self.cpu_custom_shader_safe_timeout_warned = false;
            }
            if (comptime build_config.software_frame_transport_mode != .native) {
                self.cpu_native_transport_warned = false;
            }
        }

        fn maybeReprobeCpuCustomShaderCapability(
            self: *Self,
            probe: cpu_renderer.CustomShaderExecutionProbe,
        ) cpu_renderer.CustomShaderExecutionProbe {
            if (cpu_custom_shader_capability_reprobe_interval_frames == 0) {
                self.cpu_custom_shader_reprobe_unavailable_frame_count = 0;
                return probe;
            }

            const reason = switch (probe.status) {
                .available => {
                    self.cpu_custom_shader_reprobe_unavailable_frame_count = 0;
                    return probe;
                },
                .unavailable => |reason| reason,
            };
            if (!cpuCustomShaderCapabilityReasonCanReprobe(reason)) {
                self.cpu_custom_shader_reprobe_unavailable_frame_count = 0;
                return probe;
            }

            const frame_count = std.math.add(
                u32,
                self.cpu_custom_shader_reprobe_unavailable_frame_count,
                1,
            ) catch std.math.maxInt(u32);
            self.cpu_custom_shader_reprobe_unavailable_frame_count = frame_count;
            if (frame_count < cpu_custom_shader_capability_reprobe_interval_frames) {
                return probe;
            }

            self.cpu_custom_shader_reprobe_unavailable_frame_count = 0;
            invalidateCpuCustomShaderProbeCache();
            const reprobed = cpu_renderer.customShaderExecutionProbe();
            self.cpu_custom_shader_probe = reprobed;
            self.cpu_route_diagnostics.recordCpuShaderCapabilityReprobe();
            return reprobed;
        }

        fn softwareCpuRouteDecisionInput(self: *Self) SoftwareCpuRouteDecisionInput {
            const cpu_route_target_os_supported = buildCpuRouteTargetOsSupported(builtin.target.os.tag);
            const cpu_route_build_source = buildCpuRouteAvailabilitySource(
                software_renderer_cpu_effective,
                build_config.software_renderer_cpu_mvp,
                cpu_route_target_os_supported,
            );
            var custom_shader_capability_observed = false;
            var custom_shader_available = false;
            var custom_shader_unavailable_reason: ?cpu_renderer.RuntimeCapabilityUnavailableReason = null;
            var custom_shader_hint_source: ?cpu_renderer.VulkanDriverHintSource = null;
            var custom_shader_hint_path: ?[]const u8 = null;
            var custom_shader_hint_readable = false;
            var custom_shader_minimal_runtime_enabled = cpuShaderMinimalRuntimeEnabledDefault();
            if (self.has_custom_shaders and
                build_config.software_renderer_cpu_shader_mode != .off)
            {
                if (self.cpu_custom_shader_probe == null) {
                    self.cpu_custom_shader_probe = cpu_renderer.customShaderExecutionProbe();
                }
                const custom_shader_probe = self.maybeReprobeCpuCustomShaderCapability(
                    self.cpu_custom_shader_probe.?,
                );
                custom_shader_capability_observed = true;
                custom_shader_available = true;
                custom_shader_hint_source = custom_shader_probe.vulkan_driver_hint_source;
                custom_shader_hint_path = custom_shader_probe.vulkan_driver_hint_path;
                custom_shader_hint_readable = custom_shader_probe.vulkan_driver_hint_readable;
                custom_shader_minimal_runtime_enabled = customShaderProbeMinimalRuntimeEnabled(custom_shader_probe);
                switch (custom_shader_probe.status) {
                    .available => {},
                    .unavailable => |reason| {
                        custom_shader_available = false;
                        custom_shader_unavailable_reason = reason;
                    },
                }
            } else {
                self.cpu_custom_shader_probe = null;
                self.cpu_custom_shader_reprobe_unavailable_frame_count = 0;
            }

            return .{
                .cpu_route_build_effective = software_renderer_cpu_effective,
                .cpu_route_mvp_requested = build_config.software_renderer_cpu_mvp,
                .cpu_route_build_source = cpu_route_build_source,
                .cpu_route_target_os_supported = cpu_route_target_os_supported,
                .cpu_route_allow_legacy_os = build_config.software_renderer_cpu_allow_legacy_os,
                .renderer_is_software = build_config.renderer == .software,
                .software_frame_publishing = self.software_frame_publishing,
                .software_renderer_experimental = self.config.software_renderer_experimental,
                .software_renderer_presenter = self.config.software_renderer_presenter,
                .custom_shaders_active = self.has_custom_shaders,
                .custom_shader_execution_capability_observed = custom_shader_capability_observed,
                .custom_shader_execution_available = custom_shader_available,
                .custom_shader_execution_unavailable_reason = custom_shader_unavailable_reason,
                .custom_shader_execution_hint_source = custom_shader_hint_source,
                .custom_shader_execution_hint_path = custom_shader_hint_path,
                .custom_shader_execution_hint_readable = custom_shader_hint_readable,
                .custom_shader_probe_minimal_runtime_enabled = custom_shader_minimal_runtime_enabled,
                .cpu_shader_mode = build_config.software_renderer_cpu_shader_mode,
                .cpu_shader_timeout_ms = build_config.software_renderer_cpu_shader_timeout_ms,
                .transport_mode_native = build_config.software_frame_transport_mode == .native,
            };
        }

        fn maybeLogSoftwareCpuRouteDisabled(
            self: *Self,
            decision: SoftwareCpuRouteDecision,
            input: SoftwareCpuRouteDecisionInput,
        ) void {
            const reason = decision.reason orelse return;
            const warned = self.softwareCpuRouteWarnFlag(reason) orelse return;
            if (warned.*) return;
            warned.* = true;

            log.warn(
                "software renderer cpu route is disabled reason={s} scope={s} publishing={} experimental={} presenter={s} custom_shaders={} shader_mode={s} shader_backend={s} shader_timeout_ms={} transport={s} build_cpu_route_source={s} build_cpu_route_effective={} build_cpu_route_mvp_requested={} build_cpu_route_target_os_supported={} build_cpu_route_allow_legacy_os={} shader_capability_reason={s} shader_capability_hint_source={s} shader_capability_hint_path={s} shader_capability_hint_readable={} shader_capability_observed={} shader_capability_available={} shader_minimal_runtime_enabled={}; using platform route",
                .{
                    @tagName(reason),
                    softwareCpuRouteDisableScope(reason),
                    self.software_frame_publishing,
                    self.config.software_renderer_experimental,
                    @tagName(self.config.software_renderer_presenter),
                    self.has_custom_shaders,
                    @tagName(build_config.software_renderer_cpu_shader_mode),
                    @tagName(build_config.software_renderer_cpu_shader_backend),
                    build_config.software_renderer_cpu_shader_timeout_ms,
                    @tagName(build_config.software_frame_transport_mode),
                    @tagName(input.cpu_route_build_source),
                    input.cpu_route_build_effective,
                    input.cpu_route_mvp_requested,
                    input.cpu_route_target_os_supported,
                    input.cpu_route_allow_legacy_os,
                    shaderCapabilityReasonForDisableReason(
                        reason,
                        decision.custom_shader_unavailable_reason,
                    ),
                    shaderCapabilityHintSourceForDisableReason(
                        reason,
                        decision.custom_shader_unavailable_hint_source,
                    ),
                    shaderCapabilityHintPathForDisableReason(
                        reason,
                        decision.custom_shader_unavailable_hint_path,
                    ),
                    shaderCapabilityHintReadableForDisableReason(
                        reason,
                        decision.custom_shader_unavailable_hint_readable,
                    ),
                    input.custom_shader_execution_capability_observed,
                    input.custom_shader_execution_available,
                    input.custom_shader_probe_minimal_runtime_enabled,
                },
            );
        }

        fn shouldUseSoftwareCpuFramePath(self: *Self) bool {
            self.resetSoftwareCpuRouteWarnFlags();

            const input = self.softwareCpuRouteDecisionInput();
            self.cpu_route_diagnostics.recordCapabilityObservation(input);
            const decision = decideSoftwareCpuRoute(input);
            self.cpu_route_diagnostics.recordRouteDecision(input, decision);
            if (!decision.enabled) {
                self.maybeLogSoftwareCpuRouteDisabled(decision, input);
            }

            return decision.enabled;
        }

        fn wouldUseSoftwareCpuFramePath(self: *Self) bool {
            const input = self.softwareCpuRouteDecisionInput();
            const decision = decideSoftwareCpuRoute(input);
            return decision.enabled;
        }

        fn collectRetiredCpuFramePools(self: *Self) void {
            collectRetiredCpuFramePoolsForDiagnostics(
                &self.retired_cpu_frame_pools,
                &self.cpu_retired_pool_pressure_warned,
            );
        }

        fn retireCpuFramePool(self: *Self, pool: cpu_renderer.FramePool) !void {
            try retireCpuFramePoolWithDiagnostics(
                self.alloc,
                &self.retired_cpu_frame_pools,
                &self.cpu_retired_pool_pressure_warned,
                &self.cpu_route_diagnostics,
                pool,
            );
        }

        fn ensureCpuFramePool(
            self: *Self,
            width_px: u32,
            height_px: u32,
        ) !*cpu_renderer.FramePool {
            self.collectRetiredCpuFramePools();

            if (self.cpu_frame_pool) |*pool| {
                if (pool.dimensionsMatch(width_px, height_px, .bgra8_premul)) {
                    return pool;
                }

                if (pool.isIdle()) {
                    pool.deinitIdle();
                } else {
                    const retired = pool.*;
                    try self.retireCpuFramePool(retired);
                }
                self.cpu_frame_pool = null;
            }

            self.cpu_frame_pool = try cpu_renderer.FramePool.init(
                self.alloc,
                3,
                width_px,
                height_px,
                .bgra8_premul,
                software_renderer_cpu_damage_rect_pool_capacity,
            );
            return &self.cpu_frame_pool.?;
        }

        fn acquireCpuFramePoolSlot(
            self: *Self,
            pool: *cpu_renderer.FramePool,
        ) ?cpu_renderer.FramePool.Acquired {
            return acquireCpuFramePoolSlotWithDiagnostics(
                pool,
                &self.cpu_frame_pool_exhausted_warned,
                &self.cpu_route_diagnostics,
            );
        }

        fn ensureCpuTextLayer(
            self: *Self,
            width_px: u32,
            height_px: u32,
        ) !*cpu_renderer.FrameBuffer {
            if (self.cpu_text_layer) |*layer| {
                if (layer.width_px == width_px and
                    layer.height_px == height_px and
                    layer.pixel_format == .bgra8_premul)
                {
                    return layer;
                }

                layer.deinit(self.alloc);
                self.cpu_text_layer = null;
            }

            self.cpu_text_layer = try cpu_renderer.FrameBuffer.init(
                self.alloc,
                width_px,
                height_px,
                .bgra8_premul,
            );
            return &self.cpu_text_layer.?;
        }

        fn pendingRgbaPixels(pending: imagepkg.Image.Pending) ?CpuImagePixels {
            if (pending.pixel_format != .rgba) return null;

            const stride_bytes = std.math.mul(u32, pending.width, 4) catch return null;
            const required = std.math.mul(
                usize,
                @as(usize, @intCast(stride_bytes)),
                @as(usize, @intCast(pending.height)),
            ) catch return null;
            const data = pending.dataSlice();
            if (data.len < required) return null;

            return .{
                .width = pending.width,
                .height = pending.height,
                .stride_bytes = stride_bytes,
                .data = data[0..required],
            };
        }

        fn imageCpuPixels(image: imagepkg.Image) ?CpuImagePixels {
            return switch (image) {
                .pending, .unload_pending => |pending| pendingRgbaPixels(pending),
                .replace, .unload_replace => |replace| pendingRgbaPixels(replace.pending),
                .ready, .unload_ready => null,
            };
        }

        fn kittyPlacementsSlice(
            images: *const ImageState,
            placement_type: ImageState.DrawPlacements,
        ) []const imagepkg.Placement {
            return switch (placement_type) {
                .kitty_below_bg => images.kitty_placements.items[0..images.kitty_bg_end],
                .kitty_below_text => images.kitty_placements.items[images.kitty_bg_end..images.kitty_text_end],
                .kitty_above_text => images.kitty_placements.items[images.kitty_text_end..],
                .overlay => images.overlay_placements.items,
            };
        }

        fn composeCpuBackground(self: *Self, framebuffer: *cpu_renderer.FrameBuffer) void {
            const bg_color = premulStorageColor(
                framebuffer.pixel_format,
                self.uniforms.bg_color,
            );
            const bg_image = self.bg_image orelse {
                framebuffer.clear(bg_color);
                return;
            };
            if (bg_image.isUnloading() and self.config.bg_image == null) {
                framebuffer.clear(bg_color);
                return;
            }
            const pixels = imageCpuPixels(bg_image) orelse {
                framebuffer.clear(bg_color);
                return;
            };
            if (pixels.width == 0 or pixels.height == 0) {
                framebuffer.clear(bg_color);
                return;
            }
            composeCpuBackgroundImageLegacy(
                self.alloc,
                framebuffer,
                self.uniforms.bg_color,
                .{
                    .opacity = self.bg_image_buffer.opacity,
                    .fit = switch (self.bg_image_buffer.info.fit) {
                        .contain => .contain,
                        .cover => .cover,
                        .stretch => .stretch,
                        .none => .none,
                    },
                    .position = switch (self.bg_image_buffer.info.position) {
                        .tl => .tl,
                        .tc => .tc,
                        .tr => .tr,
                        .ml => .ml,
                        .mc => .mc,
                        .mr => .mr,
                        .bl => .bl,
                        .bc => .bc,
                        .br => .br,
                    },
                    .repeat = self.bg_image_buffer.info.repeat,
                },
                pixels,
            ) catch {
                framebuffer.clear(bg_color);
            };
        }

        fn composeCpuCellBackgrounds(self: *Self, framebuffer: *cpu_renderer.FrameBuffer) void {
            const cols = @as(usize, @intCast(self.cells.size.columns));
            const rows = @as(usize, @intCast(self.cells.size.rows));
            if (cols == 0 or rows == 0) return;
            const cell_count = cpuCellGridCount(cols, rows) orelse return;
            if (self.cells.bg_cells.len < cell_count) return;
            if (self.size.cell.width == 0 or self.size.cell.height == 0) return;

            for (0..rows) |y| {
                const dst_y = cpuCellPixelOrigin(
                    self.size.padding.top,
                    self.size.cell.height,
                    y,
                ) orelse break;
                for (0..cols) |x| {
                    const idx = y * cols + x;
                    const bg = self.cells.bg_cells[idx];
                    if (bg[3] == 0) continue;

                    const dst_x = cpuCellPixelOrigin(
                        self.size.padding.left,
                        self.size.cell.width,
                        x,
                    ) orelse break;

                    framebuffer.fillRect(
                        .{
                            .x = dst_x,
                            .y = dst_y,
                            .width = self.size.cell.width,
                            .height = self.size.cell.height,
                        },
                        premulStorageColor(framebuffer.pixel_format, bg),
                    );
                }
            }
        }

        fn composeCpuKittyPlacement(
            self: *Self,
            framebuffer: *cpu_renderer.FrameBuffer,
            placement: imagepkg.Placement,
            pixels: CpuImagePixels,
        ) void {
            if (placement.width == 0 or placement.height == 0) return;
            if (placement.source_x >= pixels.width or placement.source_y >= pixels.height) return;

            const max_source_width = pixels.width - placement.source_x;
            const max_source_height = pixels.height - placement.source_y;
            const requested_source_width = if (placement.source_width == 0)
                max_source_width
            else
                placement.source_width;
            const requested_source_height = if (placement.source_height == 0)
                max_source_height
            else
                placement.source_height;
            const source_width = @min(max_source_width, requested_source_width);
            const source_height = @min(max_source_height, requested_source_height);
            if (source_width == 0 or source_height == 0) return;

            const dst_x = @as(i64, @intCast(self.size.padding.left)) +
                @as(i64, placement.x) * @as(i64, @intCast(self.size.cell.width)) +
                @as(i64, @intCast(placement.cell_offset_x));
            const dst_y = @as(i64, @intCast(self.size.padding.top)) +
                @as(i64, placement.y) * @as(i64, @intCast(self.size.cell.height)) +
                @as(i64, @intCast(placement.cell_offset_y));
            const dst_width = @as(i64, @intCast(placement.width));
            const dst_height = @as(i64, @intCast(placement.height));
            const fb_width = @as(i64, @intCast(framebuffer.width_px));
            const fb_height = @as(i64, @intCast(framebuffer.height_px));

            const visible_x0 = @max(@as(i64, 0), dst_x);
            const visible_y0 = @max(@as(i64, 0), dst_y);
            const visible_x1 = @min(fb_width, dst_x + dst_width);
            const visible_y1 = @min(fb_height, dst_y + dst_height);
            if (visible_x0 >= visible_x1 or visible_y0 >= visible_y1) return;

            const visible_width = std.math.cast(u32, visible_x1 - visible_x0) orelse return;
            const visible_height = std.math.cast(u32, visible_y1 - visible_y0) orelse return;
            const row_stride = std.math.mul(u32, visible_width, 4) catch return;
            var row_rgba = self.alloc.alloc(u8, @intCast(row_stride)) catch return;
            defer self.alloc.free(row_rgba);

            for (0..visible_height) |yi| {
                const dst_row_y = visible_y0 + @as(i64, @intCast(yi));
                const local_y = std.math.cast(u32, dst_row_y - dst_y) orelse continue;
                const src_y_scaled = (@as(u64, local_y) * @as(u64, source_height)) /
                    @as(u64, placement.height);
                const src_y = placement.source_y + @as(u32, @intCast(@min(
                    src_y_scaled,
                    @as(u64, source_height - 1),
                )));

                for (0..visible_width) |xi| {
                    const dst_col_x = visible_x0 + @as(i64, @intCast(xi));
                    const local_x = std.math.cast(u32, dst_col_x - dst_x) orelse continue;
                    const src_x_scaled = (@as(u64, local_x) * @as(u64, source_width)) /
                        @as(u64, placement.width);
                    const src_x = placement.source_x + @as(u32, @intCast(@min(
                        src_x_scaled,
                        @as(u64, source_width - 1),
                    )));

                    const src_off =
                        @as(usize, @intCast(src_y)) * @as(usize, @intCast(pixels.stride_bytes)) +
                        @as(usize, @intCast(src_x)) * 4;
                    const src_r = pixels.data[src_off];
                    const src_g = pixels.data[src_off + 1];
                    const src_b = pixels.data[src_off + 2];
                    const src_a = pixels.data[src_off + 3];
                    const row_off = @as(usize, @intCast(xi)) * 4;
                    row_rgba[row_off] = scaleByAlpha(src_r, src_a);
                    row_rgba[row_off + 1] = scaleByAlpha(src_g, src_a);
                    row_rgba[row_off + 2] = scaleByAlpha(src_b, src_a);
                    row_rgba[row_off + 3] = src_a;
                }

                framebuffer.blendPremulRgbaImage(
                    @intCast(visible_x0),
                    @intCast(dst_row_y),
                    visible_width,
                    1,
                    row_stride,
                    row_rgba,
                );
            }
        }

        fn composeCpuKittyLayer(
            self: *Self,
            framebuffer: *cpu_renderer.FrameBuffer,
            placement_type: ImageState.DrawPlacements,
        ) void {
            const placements = kittyPlacementsSlice(&self.images, placement_type);
            for (placements) |placement| {
                const image_entry = self.images.images.getPtr(placement.image_id) orelse continue;
                const pixels = imageCpuPixels(image_entry.image) orelse continue;
                self.composeCpuKittyPlacement(framebuffer, placement, pixels);
            }
        }

        fn blendCpuBgraLayer(
            dst: *cpu_renderer.FrameBuffer,
            src: *const cpu_renderer.FrameBuffer,
        ) void {
            if (dst.pixel_format != .bgra8_premul) return;
            if (src.pixel_format != .bgra8_premul) return;
            if (dst.width_px != src.width_px or dst.height_px != src.height_px) return;

            const width = @as(usize, @intCast(dst.width_px));
            const height = @as(usize, @intCast(dst.height_px));
            const dst_stride = @as(usize, @intCast(dst.stride_bytes));
            const src_stride = @as(usize, @intCast(src.stride_bytes));
            for (0..height) |row| {
                const dst_row = row * dst_stride;
                const src_row = row * src_stride;
                for (0..width) |col| {
                    const px_off = col * 4;
                    const src_px = src.bytes[src_row + px_off ..][0..4];
                    const src_a = src_px[3];
                    if (src_a == 0) continue;

                    var dst_px = dst.bytes[dst_row + px_off ..][0..4];
                    if (src_a == 255) {
                        std.mem.copyForwards(u8, dst_px, src_px);
                        continue;
                    }

                    dst_px[0] = overPremul(src_px[0], dst_px[0], src_a);
                    dst_px[1] = overPremul(src_px[1], dst_px[1], src_a);
                    dst_px[2] = overPremul(src_px[2], dst_px[2], src_a);
                    dst_px[3] = overPremul(src_px[3], dst_px[3], src_a);
                }
            }
        }

        fn resetCpuRebuildDamage(self: *Self, full: bool) void {
            self.cpu_rebuild_damage_full = full;
            self.cpu_rebuild_damage_row_min = null;
            self.cpu_rebuild_damage_row_max_exclusive = 0;
        }

        fn noteCpuRebuildDirtyRow(self: *Self, row: u32) void {
            if (self.cpu_rebuild_damage_full) return;
            const next = row + 1;
            if (self.cpu_rebuild_damage_row_min) |min_row| {
                self.cpu_rebuild_damage_row_min = @min(min_row, row);
                self.cpu_rebuild_damage_row_max_exclusive = @max(
                    self.cpu_rebuild_damage_row_max_exclusive,
                    next,
                );
                return;
            }

            self.cpu_rebuild_damage_row_min = row;
            self.cpu_rebuild_damage_row_max_exclusive = next;
        }

        fn hasCpuNonTextCompositingDamage(self: *const Self) bool {
            if (self.overlay != null) return true;
            if (bgImageRequiresConservativeFullCpuDamage(
                self.bg_image,
                self.config.bg_image != null,
            )) return true;

            const kitty_placements = [_]ImageState.DrawPlacements{
                .kitty_below_bg,
                .kitty_below_text,
                .kitty_above_text,
            };
            for (kitty_placements) |placement_type| {
                if (kittyPlacementsSlice(&self.images, placement_type).len > 0) {
                    return true;
                }
            }

            return false;
        }

        fn publishCpuSoftwareFrame(
            self: *Self,
            surface_size: anytype,
            force_full_damage: bool,
        ) !CpuPublishResult {
            self.collectRetiredCpuFramePools();

            const width_px = std.math.cast(u32, surface_size.width) orelse return .{
                .retry = .invalid_surface,
            };
            const height_px = std.math.cast(u32, surface_size.height) orelse return .{
                .retry = .invalid_surface,
            };
            if (width_px == 0 or height_px == 0) return .{
                .retry = .invalid_surface,
            };

            self.cpu_damage_tracker.resetRetainingCapacity();
            switch (comptime software_renderer_cpu_frame_damage_mode) {
                .off => {},
                .rects => {
                    if (force_full_damage or
                        self.cpu_rebuild_damage_full or
                        self.hasCpuNonTextCompositingDamage())
                    {
                        try self.cpu_damage_tracker.markFull(
                            self.alloc,
                            width_px,
                            height_px,
                        );
                    } else if (self.cpu_rebuild_damage_row_min) |row_min| {
                        const row_max = self.cpu_rebuild_damage_row_max_exclusive;
                        const span_rect = cpuDamageRectForRowSpan(
                            width_px,
                            height_px,
                            self.size.padding.top,
                            self.size.cell.height,
                            row_min,
                            row_max,
                            @intCast(self.cells.size.rows),
                        );
                        if (span_rect) |rect| {
                            try self.cpu_damage_tracker.markRect(
                                self.alloc,
                                width_px,
                                height_px,
                                rect,
                            );
                        } else {
                            try self.cpu_damage_tracker.markFull(
                                self.alloc,
                                width_px,
                                height_px,
                            );
                        }
                    } else {
                        try self.cpu_damage_tracker.markFull(
                            self.alloc,
                            width_px,
                            height_px,
                        );
                    }
                },
            }
            self.cpu_route_diagnostics.recordDamageStats(
                self.cpu_damage_tracker.rectCount(),
                self.cpu_damage_tracker.overflowCount(),
            );
            logCpuDamageOverflowKv(self.cpu_route_diagnostics.snapshot());

            var pool = self.ensureCpuFramePool(width_px, height_px) catch |err| switch (err) {
                error.CpuFramePoolRetiredPressure => return .{
                    .retry = .pool_retired_pressure,
                },
                else => return err,
            };
            var acquired = self.acquireCpuFramePoolSlot(pool) orelse return .{
                .retry = .frame_pool_exhausted,
            };

            self.font_grid.lock.lockShared();
            defer self.font_grid.lock.unlockShared();

            var framebuffer = acquired.framebuffer;
            const has_non_text_compositing = self.hasCpuNonTextCompositingDamage();
            const text_layer = if (has_non_text_compositing)
                self.ensureCpuTextLayer(width_px, height_px) catch null
            else
                null;

            if (text_layer) |layer| {
                self.composeCpuBackground(&framebuffer);
                self.composeCpuKittyLayer(&framebuffer, .kitty_below_bg);
                self.composeCpuCellBackgrounds(&framebuffer);
                self.composeCpuKittyLayer(&framebuffer, .kitty_below_text);

                cpu_renderer.composeSoftwareFrame(
                    shaderpkg.CellText,
                    layer,
                    .{
                        .padding_left_px = self.size.padding.left,
                        .padding_top_px = self.size.padding.top,
                        .cell_width_px = self.size.cell.width,
                        .cell_height_px = self.size.cell.height,
                        .grid_columns = self.cells.size.columns,
                        .grid_rows = self.cells.size.rows,
                    },
                    .{ 0, 0, 0, 0 },
                    self.cells.bg_cells[0..0],
                    self.cells.fg_rows.lists,
                    .{
                        .data = self.font_grid.atlas_grayscale.data,
                        .size = self.font_grid.atlas_grayscale.size,
                    },
                    .{
                        .data = self.font_grid.atlas_color.data,
                        .size = self.font_grid.atlas_color.size,
                    },
                );
                blendCpuBgraLayer(&framebuffer, layer);
                self.composeCpuKittyLayer(&framebuffer, .kitty_above_text);
            } else {
                cpu_renderer.composeSoftwareFrame(
                    shaderpkg.CellText,
                    &framebuffer,
                    .{
                        .padding_left_px = self.size.padding.left,
                        .padding_top_px = self.size.padding.top,
                        .cell_width_px = self.size.cell.width,
                        .cell_height_px = self.size.cell.height,
                        .grid_columns = self.cells.size.columns,
                        .grid_rows = self.cells.size.rows,
                    },
                    self.uniforms.bg_color,
                    self.cells.bg_cells,
                    self.cells.fg_rows.lists,
                    .{
                        .data = self.font_grid.atlas_grayscale.data,
                        .size = self.font_grid.atlas_grayscale.size,
                    },
                    .{
                        .data = self.font_grid.atlas_color.data,
                        .size = self.font_grid.atlas_color.size,
                    },
                );
            }

            if (self.overlay) |*overlay| {
                const pending = overlay.pendingImage();
                if (pending.pixel_format == .rgba) {
                    const stride_bytes = std.math.mul(
                        u32,
                        pending.width,
                        4,
                    ) catch 0;
                    if (stride_bytes > 0) {
                        framebuffer.blendStraightRgbaImage(
                            pending.width,
                            pending.height,
                            stride_bytes,
                            pending.dataSlice(),
                            .{
                                .src_rect = .{
                                    .x = 0,
                                    .y = 0,
                                    .width = @floatFromInt(pending.width),
                                    .height = @floatFromInt(pending.height),
                                },
                                .dst_rect = .{
                                    .x = @floatFromInt(self.size.padding.left),
                                    .y = @floatFromInt(self.size.padding.top),
                                    .width = @floatFromInt(pending.width),
                                    .height = @floatFromInt(pending.height),
                                },
                            },
                        );
                    }
                }
            }

            self.cpu_frame_generation +%= 1;
            const frame = pool.publish(
                &acquired,
                self.cpu_frame_generation,
                self.cpu_damage_tracker.slice(),
            );
            if (self.surface_mailbox.push(.{
                .software_frame_ready = frame,
            }, .instant) == 0) {
                frame.release();
                return .{ .retry = .mailbox_backpressure };
            }

            return .{ .published = {} };
        }

        /// Set the new font grid.
        ///
        /// Must be called on the render thread.
        pub fn setFontGrid(self: *Self, grid: *font.SharedGrid) void {
            self.draw_mutex.lock();
            defer self.draw_mutex.unlock();

            // Update our grid
            self.font_grid = grid;

            // Update all our textures so that they sync on the next frame.
            // We can modify this without a lock because the GPU does not
            // touch this data.
            for (&self.swap_chain.frames) |*frame| {
                frame.grayscale_modified = 0;
                frame.color_modified = 0;
            }

            // Get our metrics from the grid. This doesn't require a lock because
            // the metrics are never recalculated.
            const metrics = grid.metrics;
            self.grid_metrics = metrics;

            // Reset our shaper cache. If our font changed (not just the size) then
            // the data in the shaper cache may be invalid and cannot be used, so we
            // always clear the cache just in case.
            const font_shaper_cache = font.ShaperCache.init();
            self.font_shaper_cache.deinit(self.alloc);
            self.font_shaper_cache = font_shaper_cache;

            // Update cell size.
            self.size.cell = .{
                .width = metrics.cell_width,
                .height = metrics.cell_height,
            };

            // Update relevant uniforms
            self.updateFontGridUniforms();

            // Force a full rebuild, because cached rows may still reference
            // an outdated atlas from the old grid and this can cause garbage
            // to be rendered.
            self.markDirty();
        }

        /// Update uniforms that are based on the font grid.
        ///
        /// Caller must hold the draw mutex.
        fn updateFontGridUniforms(self: *Self) void {
            self.uniforms.cell_size = .{
                @floatFromInt(self.grid_metrics.cell_width),
                @floatFromInt(self.grid_metrics.cell_height),
            };
        }

        /// Update the frame data.
        pub fn updateFrame(
            self: *Self,
            state: *renderer.State,
            cursor_blink_visible: bool,
        ) Allocator.Error!void {
            // const start = std.time.Instant.now() catch unreachable;
            // const start_micro = std.time.microTimestamp();
            // defer {
            //     const end = std.time.Instant.now() catch unreachable;
            //     log.warn(
            //         "[updateFrame time] start_micro={} duration={}ns",
            //         .{ start_micro, end.since(start) / std.time.ns_per_us },
            //     );
            // }

            // We fully deinit and reset the terminal state every so often
            // so that a particularly large terminal state doesn't cause
            // the renderer to hold on to retained memory.
            //
            // Frame count is ~12 minutes at 120Hz.
            const max_terminal_state_frame_count = 100_000;
            if (self.terminal_state_frame_count >= max_terminal_state_frame_count) {
                self.terminal_state.deinit(self.alloc);
                self.terminal_state = .empty;
            }
            self.terminal_state_frame_count += 1;

            // Create an arena for all our temporary allocations while rebuilding
            var arena = ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const arena_alloc = arena.allocator();

            // Data we extract out of the critical area.
            const Critical = struct {
                links: terminal.RenderState.CellSet,
                mouse: renderer.State.Mouse,
                preedit: ?renderer.State.Preedit,
                scrollbar: terminal.Scrollbar,
                overlay_features: []const Overlay.Feature,
            };

            // Update all our data as tightly as possible within the mutex.
            var critical: Critical = critical: {
                // const start = try std.time.Instant.now();
                // const start_micro = std.time.microTimestamp();
                // defer {
                //     const end = std.time.Instant.now() catch unreachable;
                //     std.log.err("[updateFrame critical time] start={}\tduration={} us", .{ start_micro, end.since(start) / std.time.ns_per_us });
                // }

                state.mutex.lock();
                defer state.mutex.unlock();

                // If we're in a synchronized output state, we pause all rendering.
                if (state.terminal.modes.get(.synchronized_output)) {
                    log.debug("synchronized output started, skipping render", .{});
                    return;
                }

                // If scroll-to-bottom on output is enabled, check if the final line
                // changed by comparing the bottom-right pin. If the node pointer or
                // y offset changed, new content was added to the screen.
                // Update this BEFORE we update our render state so we can
                // draw the new scrolled data immediately.
                if (self.config.scroll_to_bottom_on_output) scroll: {
                    const br = state.terminal.screens.active.pages.getBottomRight(.screen) orelse break :scroll;

                    // If the pin hasn't changed, then don't scroll.
                    if (self.last_bottom_node == @intFromPtr(br.node) and
                        self.last_bottom_y == br.y) break :scroll;

                    // Update tracked pin state for next frame
                    self.last_bottom_node = @intFromPtr(br.node);
                    self.last_bottom_y = br.y;

                    // Scroll
                    state.terminal.scrollViewport(.bottom);
                }

                // Update our terminal state
                try self.terminal_state.update(self.alloc, state.terminal);

                // If our terminal state is dirty at all we need to redo
                // the viewport search.
                if (self.terminal_state.dirty != .false) {
                    state.terminal.flags.search_viewport_dirty = true;
                }

                // Get our scrollbar out of the terminal. We synchronize
                // the scrollbar read with frame data updates because this
                // naturally limits the number of calls to this method (it
                // can be expensive) and also makes it so we don't need another
                // cross-thread mailbox message within the IO path.
                const scrollbar = state.terminal.screens.active.pages.scrollbar();

                // Get our preedit state
                const preedit: ?renderer.State.Preedit = preedit: {
                    const p = state.preedit orelse break :preedit null;
                    break :preedit try p.clone(arena_alloc);
                };

                // If we have Kitty graphics data, we enter a SLOW SLOW SLOW path.
                // We only do this if the Kitty image state is dirty meaning only if
                // it changes.
                //
                // If we have any virtual references, we must also rebuild our
                // kitty state on every frame because any cell change can move
                // an image.
                const cpu_kitty_pixels_missing =
                    self.wouldUseSoftwareCpuFramePath() and
                    self.images.kittyNeedsCpuPixels();
                if (self.images.kittyRequiresUpdate(state.terminal) or cpu_kitty_pixels_missing) {
                    // We need to grab the draw mutex since this updates
                    // our image state that drawFrame uses.
                    self.draw_mutex.lock();
                    defer self.draw_mutex.unlock();
                    self.images.kittyUpdate(
                        self.alloc,
                        state.terminal,
                        .{
                            .width = self.grid_metrics.cell_width,
                            .height = self.grid_metrics.cell_height,
                        },
                        .{
                            .repopulate_pending_if_missing = cpu_kitty_pixels_missing,
                        },
                    );
                }

                // Get our OSC8 links we're hovering if we have a mouse.
                // This requires terminal state because of URLs.
                const links: terminal.RenderState.CellSet = osc8: {
                    // If our mouse isn't hovering, we have no links.
                    const vp = state.mouse.point orelse break :osc8 .empty;

                    // If the right mods aren't pressed, then we can't match.
                    if (!state.mouse.mods.equal(inputpkg.ctrlOrSuper(.{})))
                        break :osc8 .empty;

                    break :osc8 self.terminal_state.linkCells(
                        arena_alloc,
                        vp,
                    ) catch |err| {
                        log.warn("error searching for OSC8 links err={}", .{err});
                        break :osc8 .empty;
                    };
                };

                const overlay_features: []const Overlay.Feature = overlay: {
                    const insp = state.inspector orelse break :overlay &.{};
                    const renderer_info = insp.rendererInfo();
                    break :overlay renderer_info.overlayFeatures(
                        arena_alloc,
                    ) catch &.{};
                };

                break :critical .{
                    .links = links,
                    .mouse = state.mouse,
                    .preedit = preedit,
                    .scrollbar = scrollbar,
                    .overlay_features = overlay_features,
                };
            };

            // Outside the critical area we can update our links to contain
            // our regex results.
            self.config.links.renderCellMap(
                arena_alloc,
                &critical.links,
                &self.terminal_state,
                state.mouse.point,
                state.mouse.mods,
            ) catch |err| {
                log.warn("error searching for regex links err={}", .{err});
            };

            // Clear our highlight state and update.
            if (self.search_matches_dirty or self.terminal_state.dirty != .false) {
                self.search_matches_dirty = false;

                // Clear the prior highlights
                const row_data = self.terminal_state.row_data.slice();
                var any_dirty: bool = false;
                for (
                    row_data.items(.highlights),
                    row_data.items(.dirty),
                ) |*highlights, *dirty| {
                    if (highlights.items.len > 0) {
                        highlights.clearRetainingCapacity();
                        dirty.* = true;
                        any_dirty = true;
                    }
                }
                if (any_dirty and self.terminal_state.dirty == .false) {
                    self.terminal_state.dirty = .partial;
                }

                // NOTE: The order below matters. Highlights added earlier
                // will take priority.

                if (self.search_selected_match) |m| {
                    self.terminal_state.updateHighlightsFlattened(
                        self.alloc,
                        @intFromEnum(HighlightTag.search_match_selected),
                        &.{m.match},
                    ) catch |err| {
                        // Not a critical error, we just won't show highlights.
                        log.warn("error updating search selected highlight err={}", .{err});
                    };
                }

                if (self.search_matches) |m| {
                    self.terminal_state.updateHighlightsFlattened(
                        self.alloc,
                        @intFromEnum(HighlightTag.search_match),
                        m.matches,
                    ) catch |err| {
                        // Not a critical error, we just won't show highlights.
                        log.warn("error updating search highlights err={}", .{err});
                    };
                }
            }

            // From this point forward no more errors.
            errdefer comptime unreachable;

            // Reset our dirty state after updating.
            defer self.terminal_state.dirty = .false;

            // Rebuild the overlay image if we have one. We can do this
            // outside of any critical areas.
            self.rebuildOverlay(
                critical.overlay_features,
            ) catch |err| {
                log.warn(
                    "error rebuilding overlay surface err={}",
                    .{err},
                );
            };

            // Acquire the draw mutex for all remaining state updates.
            {
                self.draw_mutex.lock();
                defer self.draw_mutex.unlock();

                // Build our GPU cells
                self.rebuildCells(
                    critical.preedit,
                    renderer.cursorStyle(&self.terminal_state, .{
                        .preedit = critical.preedit != null,
                        .focused = self.focused,
                        .blink_visible = cursor_blink_visible,
                    }),
                    &critical.links,
                ) catch |err| {
                    // This means we weren't able to allocate our buffer
                    // to update the cells. In this case, we continue with
                    // our old buffer (frozen contents) and log it.
                    comptime assert(@TypeOf(err) == error{OutOfMemory});
                    log.warn("error rebuilding GPU cells err={}", .{err});
                };

                // The scrollbar is only emitted during draws so we also
                // check the scrollbar cache here and update if needed.
                // This is pretty fast.
                if (!self.scrollbar.eql(critical.scrollbar)) {
                    self.scrollbar = critical.scrollbar;
                    self.scrollbar_dirty = true;
                }

                // Update our background color
                self.uniforms.bg_color = .{
                    self.terminal_state.colors.background.r,
                    self.terminal_state.colors.background.g,
                    self.terminal_state.colors.background.b,
                    @intFromFloat(@round(self.config.background_opacity * 255.0)),
                };

                // If we're on macOS and have glass styles, we remove
                // the background opacity because the glass effect handles
                // it.
                if (comptime builtin.os.tag == .macos) switch (self.config.background_blur) {
                    .@"macos-glass-regular",
                    .@"macos-glass-clear",
                    => self.uniforms.bg_color[3] = 0,

                    else => {},
                };

                // Prepare our overlay image for upload (or unload). This
                // has to use our general allocator since it modifies
                // state that survives frames.
                self.images.overlayUpdate(
                    self.alloc,
                    self.overlay,
                ) catch |err| {
                    log.warn("error updating overlay images err={}", .{err});
                };

                // Update custom shader uniforms that depend on terminal state.
                self.updateCustomShaderUniformsFromState();
            }

            // Notify our shaper we're done for the frame. For some shapers,
            // such as CoreText, this triggers off-thread cleanup logic.
            self.font_shaper.endFrame();
        }

        /// Draw the frame to the screen.
        ///
        /// If `sync` is true, this will synchronously block until
        /// the frame is finished drawing and has been presented.
        pub fn drawFrame(
            self: *Self,
            sync: bool,
        ) !void {
            // const start = std.time.Instant.now() catch unreachable;
            // const start_micro = std.time.microTimestamp();
            // defer {
            //     const end = std.time.Instant.now() catch unreachable;
            //     log.warn(
            //         "[drawFrame time] start_micro={} duration={}ns",
            //         .{ start_micro, end.since(start) / std.time.ns_per_us },
            //     );
            // }

            // We hold a the draw mutex to prevent changes to any
            // data we access while we're in the middle of drawing.
            self.draw_mutex.lock();
            defer self.draw_mutex.unlock();

            // After the graphics API is complete (so we defer) we want to
            // update our scrollbar state.
            defer if (self.scrollbar_dirty) {
                // Fail instantly if the surface mailbox if full, we'll just
                // get it on the next frame.
                if (self.surface_mailbox.push(.{
                    .scrollbar = self.scrollbar,
                }, .instant) > 0) self.scrollbar_dirty = false;
            };

            // Let our graphics API do any bookkeeping, etc.
            // that it needs to do before / after `drawFrame`.
            self.api.drawFrameStart();
            defer self.api.drawFrameEnd();

            // Retrieve the most up-to-date surface size from the Graphics API
            const surface_size = try self.api.surfaceSize();

            // If either of our surface dimensions is zero
            // then drawing is absurd, so we just return.
            if (surface_size.width == 0 or surface_size.height == 0) return;

            const size_changed =
                self.size.screen.width != surface_size.width or
                self.size.screen.height != surface_size.height;

            // Conditions under which we need to draw the frame, otherwise we
            // don't need to since the previous frame should be identical.
            const use_software_cpu_path = self.shouldUseSoftwareCpuFramePath();
            if (!use_software_cpu_path) {
                clearCpuRouteTransientStateForPlatformRoute(
                    &self.cpu_publish_pending,
                    &self.cpu_frame_publish_warning,
                );
            }
            const has_animations = self.hasAnimations();

            const needs_redraw =
                size_changed or
                self.cells_rebuilt or
                has_animations or
                sync or
                (use_software_cpu_path and self.cpu_publish_pending);

            const force_full_cpu_damage =
                size_changed or
                has_animations or
                sync or
                self.cpu_publish_pending;

            // Keep renderer geometry in sync before any CPU/GPU publish path.
            if (size_changed) {
                self.size.screen = .{
                    .width = surface_size.width,
                    .height = surface_size.height,
                };
                self.updateScreenSizeUniforms();
            }

            if (!needs_redraw) {
                if (use_software_cpu_path) {
                    if (comptime software_renderer_cpu_frame_damage_mode == .rects) {
                        self.cpu_route_diagnostics.recordPublishSkippedNoDamage();
                    }
                    return;
                }

                // We still need to present the last target again, because the
                // apprt may be swapping buffers and display an outdated frame
                // if we don't draw something new.
                try self.api.presentLastTarget();
                return;
            }
            self.cells_rebuilt = false;

            if (use_software_cpu_path) {
                if (self.bg_image) |bg_image| {
                    if (!bg_image.isUnloading() and
                        imageCpuPixels(bg_image) == null and
                        self.config.bg_image != null)
                    {
                        self.prepBackgroundImage() catch |err| {
                            log.warn(
                                "error preparing background image for cpu route err={}",
                                .{err},
                            );
                        };
                    }
                }

                const publish_start = std.time.Instant.now() catch null;
                const publish_result = try self.publishCpuSoftwareFrame(
                    surface_size,
                    force_full_cpu_damage,
                );
                switch (publish_result) {
                    .retry => |reason| {
                        _ = applyCpuPublishResultState(
                            self.alloc,
                            &self.bg_image,
                            self.config.bg_image != null,
                            &self.cpu_publish_pending,
                            &self.cells_rebuilt,
                            .{ .retry = reason },
                        );
                        self.cpu_route_diagnostics.recordPublishRetryReason(reason);
                        logCpuPublishRetryKv(
                            self.cpu_route_diagnostics.snapshot(),
                            self.cpu_publish_pending,
                        );
                    },
                    .published => {
                        _ = applyCpuPublishResultState(
                            self.alloc,
                            &self.bg_image,
                            self.config.bg_image != null,
                            &self.cpu_publish_pending,
                            &self.cells_rebuilt,
                            .published,
                        );
                        if (publish_start) |start| {
                            const publish_end = std.time.Instant.now() catch null;
                            if (publish_end) |end| {
                                self.cpu_route_diagnostics.recordCpuFramePublished(end.since(start));
                                const snapshot = self.cpu_route_diagnostics.snapshot();
                                if (updateCpuFramePublishWarningState(
                                    &self.cpu_frame_publish_warning,
                                    snapshot,
                                )) {
                                    self.cpu_route_diagnostics.recordCpuPublishLatencyWarning(
                                        snapshot.last_cpu_frame_ms.?,
                                        self.cpu_frame_publish_warning.consecutive_over_threshold,
                                    );
                                    const warning_snapshot = self.cpu_route_diagnostics.snapshot();
                                    log.warn(
                                        "software renderer cpu publish latency warning last_cpu_frame_ms={} threshold_ms={} consecutive={} warning_count={} shader_capability_observed={} shader_capability_available={} shader_minimal_runtime_enabled={}",
                                        .{
                                            warning_snapshot.last_cpu_publish_latency_warning_frame_ms.?,
                                            cpu_frame_publish_warning_threshold_ms,
                                            warning_snapshot.last_cpu_publish_latency_warning_consecutive_count,
                                            warning_snapshot.cpu_publish_latency_warning_count,
                                            snapshot.shader_capability_observed,
                                            snapshot.shader_capability_available,
                                            snapshot.shader_minimal_runtime_enabled,
                                        },
                                    );
                                    logCpuPublishWarningKv(warning_snapshot);
                                }
                                logCpuPublishSuccessKv(
                                    self.cpu_route_diagnostics.snapshot(),
                                    self.cpu_publish_pending,
                                );
                            }
                        }
                    },
                }
                return;
            }

            // Wait for a frame to be available.
            const frame = try self.swap_chain.nextFrame();
            errdefer self.swap_chain.releaseFrame();
            // log.debug("drawing frame index={}", .{self.swap_chain.frame_index});

            // If we need to reinitialize our shaders, do so.
            if (self.reinitialize_shaders) {
                self.reinitialize_shaders = false;
                self.shaders.deinit(self.alloc);
                try self.initShaders();
            }

            // Our shaders should not be defunct at this point.
            assert(!self.shaders.defunct);

            // If we have custom shaders, make sure we have the
            // custom shader state in our frame state, otherwise
            // if we have a state but don't need it we remove it.
            if (self.has_custom_shaders) {
                if (frame.custom_shader_state == null) {
                    frame.custom_shader_state = try .init(self.api);
                    try frame.custom_shader_state.?.resize(
                        self.api,
                        surface_size.width,
                        surface_size.height,
                    );
                }
            } else if (frame.custom_shader_state) |*state| {
                state.deinit();
                frame.custom_shader_state = null;
            }

            // If this frame's target isn't the correct size, or the target
            // config has changed (such as when the blending mode changes),
            // remove it and replace it with a new one with the right values.
            if (frame.target.width != self.size.screen.width or
                frame.target.height != self.size.screen.height or
                frame.target_config_modified != self.target_config_modified)
            {
                try frame.resize(
                    self.api,
                    self.size.screen.width,
                    self.size.screen.height,
                );
                frame.target_config_modified = self.target_config_modified;
            }

            // Upload images to the GPU as necessary.
            _ = self.images.upload(self.alloc, &self.api);

            // Upload the background image to the GPU as necessary.
            try self.uploadBackgroundImage();

            // Update per-frame custom shader uniforms.
            try self.updateCustomShaderUniformsForFrame();

            // Setup our frame data
            try frame.uniforms.sync(&.{self.uniforms});
            try frame.cells_bg.sync(self.cells.bg_cells);
            const fg_count = try frame.cells.syncFromArrayLists(self.cells.fg_rows.lists);

            const frame_needs_bg_image_buffer = needsFrameBgImageBuffer(self.bg_image);
            if (frame_needs_bg_image_buffer) {
                var bg_image_buffer_created = false;
                if (frame.bg_image_buffer == null) {
                    frame.bg_image_buffer = try FrameState.BgImageBuffer.init(
                        self.api.bgImageBufferOptions(),
                        1,
                    );
                    bg_image_buffer_created = true;
                }

                // If our background image buffer has changed, sync it.
                if (bg_image_buffer_created or
                    frame.bg_image_buffer_modified != self.bg_image_buffer_modified)
                {
                    try frame.bg_image_buffer.?.sync(&.{self.bg_image_buffer});
                    frame.bg_image_buffer_modified = self.bg_image_buffer_modified;
                }
            } else if (frame.bg_image_buffer) |*bg_image_buffer| {
                bg_image_buffer.deinit();
                frame.bg_image_buffer = null;
            }

            // If our font atlas changed, sync the texture data
            texture: {
                const modified = self.font_grid.atlas_grayscale.modified.load(.monotonic);
                if (modified <= frame.grayscale_modified) break :texture;
                self.font_grid.lock.lockShared();
                defer self.font_grid.lock.unlockShared();
                frame.grayscale_modified = self.font_grid.atlas_grayscale.modified.load(.monotonic);
                try self.syncAtlasTexture(&self.font_grid.atlas_grayscale, &frame.grayscale);
            }
            texture: {
                const modified = self.font_grid.atlas_color.modified.load(.monotonic);
                if (modified <= frame.color_modified) break :texture;
                self.font_grid.lock.lockShared();
                defer self.font_grid.lock.unlockShared();
                frame.color_modified = self.font_grid.atlas_color.modified.load(.monotonic);
                try self.syncAtlasTexture(&self.font_grid.atlas_color, &frame.color);
            }

            // Get a frame context from the graphics API.
            const publish_software_frame =
                self.software_frame_publishing and
                self.config.software_renderer_experimental and
                self.config.software_renderer_presenter != .@"legacy-gl";
            const publish_software_frame_on_completion =
                comptime @hasDecl(GraphicsAPI, "softwareFramePublicationOnCompletion") and
                GraphicsAPI.softwareFramePublicationOnCompletion;

            var frame_ctx = try self.api.beginFrame(
                self,
                &frame.target,
                publish_software_frame and publish_software_frame_on_completion,
                self.size.screen.width,
                self.size.screen.height,
            );
            defer frame_ctx.complete(sync);

            {
                var pass = frame_ctx.renderPass(&.{.{
                    .target = if (frame.custom_shader_state) |state|
                        .{ .texture = state.back_texture }
                    else
                        .{ .target = frame.target },
                    .clear_color = .{ 0.0, 0.0, 0.0, 0.0 },
                }});
                defer pass.complete();

                // First we draw our background image, if we have one.
                // The bg image shader also draws the main bg color.
                //
                // Otherwise, if we don't have a background image, we
                // draw the background color by itself in its own step.
                //
                // NOTE: We don't use the clear_color for this because that
                //       would require us to do color space conversion on the
                //       CPU-side. In the future when we have utilities for
                //       that we should remove this step and use clear_color.
                if (self.bg_image) |img| switch (img) {
                    .ready => |texture| {
                        assert(frame.bg_image_buffer != null);
                        const bg_image_buffer = frame.bg_image_buffer.?;
                        pass.step(.{
                            .pipeline = self.shaders.pipelines.bg_image,
                            .uniforms = frame.uniforms.buffer,
                            .buffers = &.{bg_image_buffer.buffer},
                            .textures = &.{texture},
                            .draw = .{ .type = .triangle, .vertex_count = 3 },
                        });
                    },
                    else => {},
                } else {
                    pass.step(.{
                        .pipeline = self.shaders.pipelines.bg_color,
                        .uniforms = frame.uniforms.buffer,
                        .buffers = &.{ null, frame.cells_bg.buffer },
                        .draw = .{ .type = .triangle, .vertex_count = 3 },
                    });
                }

                // Then we draw any kitty images that need
                // to be behind text AND cell backgrounds.
                self.images.draw(
                    &self.api,
                    self.shaders.pipelines.image,
                    &pass,
                    .kitty_below_bg,
                );

                // Then we draw any opaque cell backgrounds.
                pass.step(.{
                    .pipeline = self.shaders.pipelines.cell_bg,
                    .uniforms = frame.uniforms.buffer,
                    .buffers = &.{ null, frame.cells_bg.buffer },
                    .draw = .{ .type = .triangle, .vertex_count = 3 },
                });

                // Kitty images between cell backgrounds and text.
                self.images.draw(
                    &self.api,
                    self.shaders.pipelines.image,
                    &pass,
                    .kitty_below_text,
                );

                // Text.
                pass.step(.{
                    .pipeline = self.shaders.pipelines.cell_text,
                    .uniforms = frame.uniforms.buffer,
                    .buffers = &.{
                        frame.cells.buffer,
                        frame.cells_bg.buffer,
                    },
                    .textures = &.{
                        frame.grayscale,
                        frame.color,
                    },
                    .draw = .{
                        .type = .triangle_strip,
                        .vertex_count = 4,
                        .instance_count = fg_count,
                    },
                });

                // Kitty images in front of text.
                self.images.draw(
                    &self.api,
                    self.shaders.pipelines.image,
                    &pass,
                    .kitty_above_text,
                );

                // Debug overlay. We do this before any custom shader state
                // because our debug overlay is aligned with the grid.
                if (self.overlay != null) self.images.draw(
                    &self.api,
                    self.shaders.pipelines.image,
                    &pass,
                    .overlay,
                );
            }

            // If we have custom shaders, then we render them.
            if (frame.custom_shader_state) |*state| {
                // Sync our uniforms.
                try state.uniforms.sync(&.{self.custom_shader_uniforms});

                for (self.shaders.post_pipelines, 0..) |pipeline, i| {
                    defer state.swap();

                    var pass = frame_ctx.renderPass(&.{.{
                        .target = if (i < self.shaders.post_pipelines.len - 1)
                            .{ .texture = state.front_texture }
                        else
                            .{ .target = frame.target },
                        .clear_color = .{ 0.0, 0.0, 0.0, 0.0 },
                    }});
                    defer pass.complete();

                    pass.step(.{
                        .pipeline = pipeline,
                        .uniforms = state.uniforms.buffer,
                        .textures = &.{state.back_texture},
                        .samplers = &.{state.sampler},
                        .draw = .{
                            .type = .triangle,
                            .vertex_count = 3,
                        },
                    });
                }
            }

            if (publish_software_frame and
                @hasDecl(GraphicsAPI, "publishSoftwareFrame") and
                !publish_software_frame_on_completion)
            {
                if (try self.api.publishSoftwareFrame(
                    &frame.target,
                    self.size.screen,
                )) |software_frame| {
                    if (self.surface_mailbox.push(.{
                        .software_frame_ready = software_frame,
                    }, .instant) == 0) {
                        software_frame.release();
                    }
                }
            }
        }

        // Callback from the graphics API when a frame is completed.
        pub fn frameCompleted(
            self: *Self,
            health: Health,
            completed_target: ?*const Target,
            publish_software_frame: bool,
            publish_width_px: u32,
            publish_height_px: u32,
        ) void {
            const publish_software_frame_on_completion =
                comptime @hasDecl(GraphicsAPI, "softwareFramePublicationOnCompletion") and
                GraphicsAPI.softwareFramePublicationOnCompletion;

            // If our health value hasn't changed, then we do nothing. We don't
            // do a cmpxchg here because strict atomicity isn't important.
            if (self.health.load(.seq_cst) != health) {
                self.health.store(health, .seq_cst);

                // Our health value changed, so we notify the surface so that it
                // can do something about it.
                _ = self.surface_mailbox.push(.{
                    .renderer_health = health,
                }, .{ .forever = {} });
            }

            if (health == .healthy and
                @hasDecl(GraphicsAPI, "publishSoftwareFrame") and
                publish_software_frame_on_completion and
                publish_software_frame and
                completed_target != null)
            {
                const software_frame = self.api.publishSoftwareFrame(
                    completed_target.?,
                    .{
                        .width = publish_width_px,
                        .height = publish_height_px,
                    },
                ) catch |err| blk: {
                    log.warn("error publishing software frame on completion err={}", .{err});
                    break :blk null;
                };
                if (software_frame) |ready| {
                    if (self.surface_mailbox.push(.{
                        .software_frame_ready = ready,
                    }, .instant) == 0) {
                        ready.release();
                    }
                }
            }

            // Always release our semaphore
            self.swap_chain.releaseFrame();
        }

        /// Call this any time the background image path changes.
        ///
        /// Caller must hold the draw mutex.
        fn prepBackgroundImage(self: *Self) !void {
            // Then we try to load the background image if we have a path.
            if (self.config.bg_image) |p| load_background: {
                var prepared = false;
                defer if (!prepared) {
                    _ = discardStaleUnloadingBackgroundImageAfterPrepareFailure(
                        self.alloc,
                        &self.bg_image,
                    );
                };

                const path = switch (p) {
                    .required, .optional => |slice| slice,
                };

                // Open the file
                var file = std.fs.openFileAbsolute(path, .{}) catch |err| {
                    log.warn(
                        "error opening background image file \"{s}\": {}",
                        .{ path, err },
                    );
                    break :load_background;
                };
                defer file.close();

                // Read it
                const contents = file.readToEndAlloc(
                    self.alloc,
                    std.math.maxInt(u32), // Max size of 4 GiB, for now.
                ) catch |err| {
                    log.warn(
                        "error reading background image file \"{s}\": {}",
                        .{ path, err },
                    );
                    break :load_background;
                };
                defer self.alloc.free(contents);

                // Figure out what type it probably is.
                const file_type = switch (FileType.detect(contents)) {
                    .unknown => FileType.guessFromExtension(
                        std.fs.path.extension(path),
                    ),
                    else => |t| t,
                };

                // Decode it if we know how.
                const image_data = switch (file_type) {
                    .png => try wuffs.png.decode(self.alloc, contents),
                    .jpeg => try wuffs.jpeg.decode(self.alloc, contents),
                    .unknown => {
                        log.warn(
                            "Cannot determine file type for background image file \"{s}\"!",
                            .{path},
                        );
                        break :load_background;
                    },
                    else => |f| {
                        log.warn(
                            "Unsupported file type {} for background image file \"{s}\"!",
                            .{ f, path },
                        );
                        break :load_background;
                    },
                };

                const image: imagepkg.Image = .{
                    .pending = .{
                        .width = image_data.width,
                        .height = image_data.height,
                        .pixel_format = .rgba,
                        .data = image_data.data.ptr,
                    },
                };

                // If we have an existing background image, replace it.
                // Otherwise, set this as our background image directly.
                applyPreparedBackgroundImage(self.alloc, &self.bg_image, image);
                prepared = true;
            } else {
                // If we don't have a background image path, mark our
                // background image for unload if we currently have one.
                clearConfiguredBackgroundImage(&self.bg_image);
            }
        }

        fn uploadBackgroundImage(self: *Self) !void {
            // Make sure our bg image is uploaded if it needs to be.
            if (finalizeUnloadingBgImage(self.alloc, &self.bg_image)) return;
            if (self.bg_image) |*bg| {
                if (bg.isPending()) try bg.upload(self.alloc, &self.api);
            }
        }

        /// Update the configuration.
        pub fn changeConfig(self: *Self, config: *DerivedConfig) !void {
            self.draw_mutex.lock();
            defer self.draw_mutex.unlock();

            // We always redo the font shaper in case font features changed. We
            // could check to see if there was an actual config change but this is
            // easier and rare enough to not cause performance issues.
            {
                var font_shaper = try font.Shaper.init(self.alloc, .{
                    .features = config.font_features.items,
                });
                errdefer font_shaper.deinit();
                self.font_shaper.deinit();
                self.font_shaper = font_shaper;
            }

            // We also need to reset the shaper cache so shaper info
            // from the previous font isn't reused for the new font.
            const font_shaper_cache = font.ShaperCache.init();
            self.font_shaper_cache.deinit(self.alloc);
            self.font_shaper_cache = font_shaper_cache;

            // Set our new minimum contrast
            self.uniforms.min_contrast = config.min_contrast;

            // Set our new color space and blending
            self.uniforms.bools.use_display_p3 = config.colorspace == .@"display-p3";
            self.uniforms.bools.use_linear_blending = config.blending.isLinear();
            self.uniforms.bools.use_linear_correction = config.blending == .@"linear-corrected";

            const bg_image_config_changed =
                self.config.bg_image_fit != config.bg_image_fit or
                self.config.bg_image_position != config.bg_image_position or
                self.config.bg_image_repeat != config.bg_image_repeat or
                self.config.bg_image_opacity != config.bg_image_opacity;

            const bg_image_changed =
                if (self.config.bg_image) |old|
                    if (config.bg_image) |new|
                        !old.equal(new)
                    else
                        true
                else
                    config.bg_image != null;

            const old_blending = self.config.blending;
            const custom_shaders_changed = !self.config.custom_shaders.equal(config.custom_shaders);

            self.config.deinit();
            self.config = config.*;

            // If our background image path changed, prepare the new bg image.
            if (bg_image_changed) try self.prepBackgroundImage();

            // If our background image config changed, update the vertex buffer.
            if (bg_image_config_changed) self.updateBgImageBuffer();

            // Reset our viewport to force a rebuild, in case of a font change.
            self.markDirty();

            const blending_changed = old_blending != config.blending;

            if (blending_changed) {
                // We update our API's blending mode.
                self.api.blending = config.blending;
                // And indicate that we need to reinitialize our shaders.
                self.reinitialize_shaders = true;
                // And indicate that our swap chain targets need to
                // be re-created to account for the new blending mode.
                self.target_config_modified +%= 1;
            }

            if (custom_shaders_changed) {
                self.reinitialize_shaders = true;
                self.cpu_custom_shader_probe = null;
                self.cpu_custom_shader_reprobe_unavailable_frame_count = 0;
            }
        }

        /// Resize the screen.
        pub fn setScreenSize(
            self: *Self,
            size: renderer.Size,
        ) void {
            self.draw_mutex.lock();
            defer self.draw_mutex.unlock();

            // We only actually need the padding from this,
            // everything else is derived elsewhere.
            self.size.padding = size.padding;

            self.updateScreenSizeUniforms();

            log.debug("screen size size={}", .{size});
        }

        /// Update uniforms that are based on the screen size.
        ///
        /// Caller must hold the draw mutex.
        fn updateScreenSizeUniforms(self: *Self) void {
            const terminal_size = self.size.terminal();

            // Blank space around the grid.
            const blank: renderer.Padding = self.size.screen.blankPadding(
                self.size.padding,
                .{
                    .columns = self.cells.size.columns,
                    .rows = self.cells.size.rows,
                },
                .{
                    .width = self.grid_metrics.cell_width,
                    .height = self.grid_metrics.cell_height,
                },
            ).add(self.size.padding);

            // Setup our uniforms
            self.uniforms.projection_matrix = math.ortho2d(
                -1 * @as(f32, @floatFromInt(self.size.padding.left)),
                @floatFromInt(terminal_size.width + self.size.padding.right),
                @floatFromInt(terminal_size.height + self.size.padding.bottom),
                -1 * @as(f32, @floatFromInt(self.size.padding.top)),
            );
            self.uniforms.grid_padding = .{
                @floatFromInt(blank.top),
                @floatFromInt(blank.right),
                @floatFromInt(blank.bottom),
                @floatFromInt(blank.left),
            };
            self.uniforms.screen_size = .{
                @floatFromInt(self.size.screen.width),
                @floatFromInt(self.size.screen.height),
            };
        }

        /// Update the background image vertex buffer (CPU-side).
        ///
        /// This should be called if and when configs change that
        /// could affect the background image.
        ///
        /// Caller must hold the draw mutex.
        fn updateBgImageBuffer(self: *Self) void {
            self.bg_image_buffer = .{
                .opacity = self.config.bg_image_opacity,
                .info = .{
                    .position = switch (self.config.bg_image_position) {
                        .@"top-left" => .tl,
                        .@"top-center" => .tc,
                        .@"top-right" => .tr,
                        .@"center-left" => .ml,
                        .@"center-center", .center => .mc,
                        .@"center-right" => .mr,
                        .@"bottom-left" => .bl,
                        .@"bottom-center" => .bc,
                        .@"bottom-right" => .br,
                    },
                    .fit = switch (self.config.bg_image_fit) {
                        .contain => .contain,
                        .cover => .cover,
                        .stretch => .stretch,
                        .none => .none,
                    },
                    .repeat = self.config.bg_image_repeat,
                },
            };
            // Signal that the buffer was modified.
            self.bg_image_buffer_modified +%= 1;
        }

        /// Update custom shader uniforms that depend on terminal state.
        ///
        /// This should be called in `updateFrame` when terminal state changes.
        fn updateCustomShaderUniformsFromState(self: *Self) void {
            // We only need to do this if we have custom shaders.
            if (!self.has_custom_shaders) return;

            // Only update when terminal state is dirty.
            if (self.terminal_state.dirty == .false) return;

            const uniforms: *shadertoy.Uniforms = &self.custom_shader_uniforms;
            const colors: *const terminal.RenderState.Colors = &self.terminal_state.colors;

            // 256-color palette
            for (colors.palette, 0..) |color, i| {
                uniforms.palette[i] = .{
                    @as(f32, @floatFromInt(color.r)) / 255.0,
                    @as(f32, @floatFromInt(color.g)) / 255.0,
                    @as(f32, @floatFromInt(color.b)) / 255.0,
                    1.0,
                };
            }

            // Background color
            uniforms.background_color = .{
                @as(f32, @floatFromInt(colors.background.r)) / 255.0,
                @as(f32, @floatFromInt(colors.background.g)) / 255.0,
                @as(f32, @floatFromInt(colors.background.b)) / 255.0,
                1.0,
            };

            // Foreground color
            uniforms.foreground_color = .{
                @as(f32, @floatFromInt(colors.foreground.r)) / 255.0,
                @as(f32, @floatFromInt(colors.foreground.g)) / 255.0,
                @as(f32, @floatFromInt(colors.foreground.b)) / 255.0,
                1.0,
            };

            // Cursor color
            if (colors.cursor) |cursor_color| {
                uniforms.cursor_color = .{
                    @as(f32, @floatFromInt(cursor_color.r)) / 255.0,
                    @as(f32, @floatFromInt(cursor_color.g)) / 255.0,
                    @as(f32, @floatFromInt(cursor_color.b)) / 255.0,
                    1.0,
                };
            }

            // NOTE: the following could be optimized to follow a change in
            // config for a slight optimization however this is only 12 bytes
            // each being updated and likely isn't a cause for concern

            // Cursor text color
            if (self.config.cursor_text) |cursor_text| {
                uniforms.cursor_text = .{
                    @as(f32, @floatFromInt(cursor_text.color.r)) / 255.0,
                    @as(f32, @floatFromInt(cursor_text.color.g)) / 255.0,
                    @as(f32, @floatFromInt(cursor_text.color.b)) / 255.0,
                    1.0,
                };
            }

            // Selection background color
            if (self.config.selection_background) |selection_bg| {
                uniforms.selection_background_color = .{
                    @as(f32, @floatFromInt(selection_bg.color.r)) / 255.0,
                    @as(f32, @floatFromInt(selection_bg.color.g)) / 255.0,
                    @as(f32, @floatFromInt(selection_bg.color.b)) / 255.0,
                    1.0,
                };
            }

            // Selection foreground color
            if (self.config.selection_foreground) |selection_fg| {
                uniforms.selection_foreground_color = .{
                    @as(f32, @floatFromInt(selection_fg.color.r)) / 255.0,
                    @as(f32, @floatFromInt(selection_fg.color.g)) / 255.0,
                    @as(f32, @floatFromInt(selection_fg.color.b)) / 255.0,
                    1.0,
                };
            }

            // Cursor visibility
            uniforms.cursor_visible = @intFromBool(self.terminal_state.cursor.visible);

            // Cursor style
            const cursor_style: renderer.CursorStyle = .fromTerminal(self.terminal_state.cursor.visual_style);
            uniforms.previous_cursor_style = uniforms.current_cursor_style;
            uniforms.current_cursor_style = @as(i32, @intFromEnum(cursor_style));
        }

        /// Update per-frame custom shader uniforms.
        ///
        /// This should be called exactly once per frame, inside `drawFrame`.
        fn updateCustomShaderUniformsForFrame(self: *Self) !void {
            // We only need to do this if we have custom shaders.
            if (!self.has_custom_shaders) return;

            const uniforms: *shadertoy.Uniforms = &self.custom_shader_uniforms;

            const now = try std.time.Instant.now();
            defer self.last_frame_time = now;
            const first_frame_time = self.first_frame_time orelse t: {
                self.first_frame_time = now;
                break :t now;
            };
            const last_frame_time = self.last_frame_time orelse now;

            const since_ns: f32 = @floatFromInt(now.since(first_frame_time));
            uniforms.time = since_ns / std.time.ns_per_s;

            const delta_ns: f32 = @floatFromInt(now.since(last_frame_time));
            uniforms.time_delta = delta_ns / std.time.ns_per_s;

            uniforms.frame += 1;

            const screen = self.size.screen;
            const padding = self.size.padding;
            const cell = self.size.cell;

            uniforms.resolution = .{
                @floatFromInt(screen.width),
                @floatFromInt(screen.height),
                1,
            };
            uniforms.channel_resolution[0] = .{
                @floatFromInt(screen.width),
                @floatFromInt(screen.height),
                1,
                0,
            };

            if (self.cells.getCursorGlyph()) |cursor| {
                const cursor_width: f32 = @floatFromInt(cursor.glyph_size[0]);
                const cursor_height: f32 = @floatFromInt(cursor.glyph_size[1]);

                // Left edge of the cell the cursor is in.
                var pixel_x: f32 = @floatFromInt(
                    cursor.grid_pos[0] * cell.width + padding.left,
                );
                // Top edge, relative to the top of the
                // screen, of the cell the cursor is in.
                var pixel_y: f32 = @floatFromInt(
                    cursor.grid_pos[1] * cell.height + padding.top,
                );

                // If +Y is up in our shaders, we need to flip the coordinate
                // so that it's instead the top edge of the cell relative to
                // the *bottom* of the screen.
                if (!GraphicsAPI.custom_shader_y_is_down) {
                    pixel_y = @as(f32, @floatFromInt(screen.height)) - pixel_y;
                }

                // Add the X bearing to get the -X (left) edge of the cursor.
                pixel_x += @floatFromInt(cursor.bearings[0]);

                // How we deal with the Y bearing depends on which direction
                // is "up", since we want our final `pixel_y` value to be the
                // +Y edge of the cursor.
                if (GraphicsAPI.custom_shader_y_is_down) {
                    // As a reminder, the Y bearing is the distance from the
                    // bottom of the cell to the top of the glyph, so to get
                    // the +Y edge we need to add the cell height, subtract
                    // the Y bearing, and add the glyph height to get the +Y
                    // (bottom) edge of the cursor.
                    pixel_y += @floatFromInt(cell.height);
                    pixel_y -= @floatFromInt(cursor.bearings[1]);
                    pixel_y += @floatFromInt(cursor.glyph_size[1]);
                } else {
                    // If the Y direction is reversed though, we instead want
                    // the *top* edge of the cursor, which means we just need
                    // to subtract the cell height and add the Y bearing.
                    pixel_y -= @floatFromInt(cell.height);
                    pixel_y += @floatFromInt(cursor.bearings[1]);
                }

                const new_cursor: [4]f32 = .{
                    pixel_x,
                    pixel_y,
                    cursor_width,
                    cursor_height,
                };
                const cursor_color: [4]f32 = .{
                    @as(f32, @floatFromInt(cursor.color[0])) / 255.0,
                    @as(f32, @floatFromInt(cursor.color[1])) / 255.0,
                    @as(f32, @floatFromInt(cursor.color[2])) / 255.0,
                    @as(f32, @floatFromInt(cursor.color[3])) / 255.0,
                };

                const cursor_changed: bool =
                    !std.meta.eql(new_cursor, uniforms.current_cursor) or
                    !std.meta.eql(cursor_color, uniforms.current_cursor_color);

                if (cursor_changed) {
                    uniforms.previous_cursor = uniforms.current_cursor;
                    uniforms.previous_cursor_color = uniforms.current_cursor_color;
                    uniforms.current_cursor = new_cursor;
                    uniforms.current_cursor_color = cursor_color;
                    uniforms.cursor_change_time = uniforms.time;
                }
            }

            // Update focus uniforms
            uniforms.focus = @intFromBool(self.focused);

            // If we need to update the time our focus state changed
            // then update it to our current frame time. This may not be
            // exactly correct since it is frame time, not exact focus
            // time, but focus time on its own isn't exactly correct anyways
            // since it comes async from a message.
            if (self.custom_shader_focused_changed and self.focused) {
                uniforms.time_focus = uniforms.time;
                self.custom_shader_focused_changed = false;
            }
        }

        /// Build the overlay as configured. Returns null if there is no
        /// overlay currently configured.
        fn rebuildOverlay(
            self: *Self,
            features: []const Overlay.Feature,
        ) Overlay.InitError!void {
            // const start = std.time.Instant.now() catch unreachable;
            // const start_micro = std.time.microTimestamp();
            // defer {
            //     const end = std.time.Instant.now() catch unreachable;
            //     log.warn(
            //         "[rebuildOverlay time] start_micro={} duration={}ns",
            //         .{ start_micro, end.since(start) / std.time.ns_per_us },
            //     );
            // }

            const alloc = self.alloc;

            // If we have no features enabled, don't build an overlay.
            // If we had a previous overlay, deallocate it.
            if (features.len == 0) {
                if (self.overlay) |*old| {
                    old.deinit(alloc);
                    self.overlay = null;
                }

                return;
            }

            // If we had a previous overlay, clear it. Otherwise, init.
            const overlay: *Overlay = overlay: {
                if (self.overlay) |*v| existing: {
                    // Verify that our overlay size matches our screen
                    // size as we know it now. If not, deinit and reinit.
                    // Note: these intCasts are always safe because z2d
                    // stores as i32 but we always init with a u32.
                    const width: u32 = @intCast(v.surface.getWidth());
                    const height: u32 = @intCast(v.surface.getHeight());
                    const term_size = self.size.terminal();
                    if (width != term_size.width or
                        height != term_size.height) break :existing;

                    // We also depend on cell size.
                    if (v.cell_size.width != self.size.cell.width or
                        v.cell_size.height != self.size.cell.height) break :existing;

                    // Everything matches, so we can just reset the surface
                    // and redraw.
                    v.reset();
                    break :overlay v;
                }

                // If we reached this point we want to reset our overlay.
                if (self.overlay) |*v| {
                    v.deinit(alloc);
                    self.overlay = null;
                }

                assert(self.overlay == null);
                const new: Overlay = try .init(alloc, self.size);
                self.overlay = new;
                break :overlay &self.overlay.?;
            };
            overlay.applyFeatures(
                alloc,
                &self.terminal_state,
                features,
            );
        }

        const PreeditRange = struct {
            y: terminal.size.CellCountInt,
            x: [2]terminal.size.CellCountInt,
            cp_offset: usize,
        };

        /// Convert the terminal state to GPU cells stored in CPU memory. These
        /// are then synced to the GPU in the next frame. This only updates CPU
        /// memory and doesn't touch the GPU.
        ///
        /// This requires the draw mutex.
        ///
        /// Dirty state on terminal state won't be reset by this.
        fn rebuildCells(
            self: *Self,
            preedit: ?renderer.State.Preedit,
            cursor_style_: ?renderer.CursorStyle,
            links: *const terminal.RenderState.CellSet,
        ) Allocator.Error!void {
            const state: *terminal.RenderState = &self.terminal_state;

            // const start = try std.time.Instant.now();
            // const start_micro = std.time.microTimestamp();
            // defer {
            //     const end = std.time.Instant.now() catch unreachable;
            //     // "[rebuildCells time] <START us>\t<TIME_TAKEN us>"
            //     std.log.warn("[rebuildCells time] {}\t{}", .{start_micro, end.since(start) / std.time.ns_per_us});
            // }

            const grid_size_diff =
                self.cells.size.rows != state.rows or
                self.cells.size.columns != state.cols;

            if (grid_size_diff) {
                var new_size = self.cells.size;
                new_size.rows = state.rows;
                new_size.columns = state.cols;
                try self.cells.resize(self.alloc, new_size);

                // Update our uniforms accordingly, otherwise
                // our background cells will be out of place.
                self.uniforms.grid_size = .{ new_size.columns, new_size.rows };
            }

            const rebuild = state.dirty == .full or grid_size_diff;
            self.resetCpuRebuildDamage(rebuild);
            if (rebuild) {
                // If we are doing a full rebuild, then we clear the entire cell buffer.
                self.cells.reset();

                // We also reset our padding extension depending on the screen type
                switch (self.config.padding_color) {
                    .background => {},

                    // For extension, assume we are extending in all directions.
                    // For "extend" this may be disabled due to heuristics below.
                    .extend, .@"extend-always" => {
                        self.uniforms.padding_extend = .{
                            .up = true,
                            .down = true,
                            .left = true,
                            .right = true,
                        };
                    },
                }
            }

            // From this point on we never fail. We produce some kind of
            // working terminal state, even if incorrect.
            errdefer comptime unreachable;

            // Get our row data from our state
            const row_data = state.row_data.slice();
            const row_raws = row_data.items(.raw);
            const row_cells = row_data.items(.cells);
            const row_dirty = row_data.items(.dirty);
            const row_selection = row_data.items(.selection);
            const row_highlights = row_data.items(.highlights);

            // If our cell contents buffer is shorter than the screen viewport,
            // we render the rows that fit, starting from the bottom. If instead
            // the viewport is shorter than the cell contents buffer, we align
            // the top of the viewport with the top of the contents buffer.
            const row_len: usize = @min(
                state.rows,
                self.cells.size.rows,
            );

            // Determine our x/y range for preedit. We don't want to render anything
            // here because we will render the preedit separately.
            const preedit_range: ?PreeditRange = if (preedit) |preedit_v| preedit: {
                // We base the preedit on the position of the cursor in the
                // viewport. If the cursor isn't visible in the viewport we
                // don't show it.
                const cursor_vp = state.cursor.viewport orelse
                    break :preedit null;

                // If our preedit row isn't dirty then we don't need the
                // preedit range. This also avoids an issue later where we
                // unconditionally add preedit cells when this is set.
                if (!rebuild and !row_dirty[cursor_vp.y]) break :preedit null;

                const range = preedit_v.range(
                    cursor_vp.x,
                    state.cols - 1,
                );
                break :preedit .{
                    .y = @intCast(cursor_vp.y),
                    .x = .{ range.start, range.end },
                    .cp_offset = range.cp_offset,
                };
            } else null;

            for (
                0..,
                row_raws[0..row_len],
                row_cells[0..row_len],
                row_dirty[0..row_len],
                row_selection[0..row_len],
                row_highlights[0..row_len],
            ) |y_usize, row, *cells, *dirty, selection, *highlights| {
                const y: terminal.size.CellCountInt = @intCast(y_usize);

                if (!rebuild) {
                    // Only rebuild if we are doing a full rebuild or this row is dirty.
                    if (!dirty.*) continue;

                    // Clear the cells if the row is dirty
                    self.cells.clear(y);
                }

                self.noteCpuRebuildDirtyRow(@intCast(y_usize));

                // Unmark the dirty state in our render state.
                dirty.* = false;

                self.rebuildRow(
                    y,
                    row,
                    cells,
                    preedit_range,
                    selection,
                    highlights,
                    links,
                ) catch |err| {
                    // This should never happen except under exceptional
                    // scenarios. In this case, we don't want to corrupt
                    // our render state so just clear this row and keep
                    // trying to finish it out.
                    log.warn("error building row y={} err={}", .{ y, err });
                    self.cells.clear(y);
                };
            }

            // Setup our cursor rendering information.
            cursor: {
                // Clear our cursor by default.
                self.cells.setCursor(null, null);
                self.uniforms.cursor_pos = .{
                    std.math.maxInt(u16),
                    std.math.maxInt(u16),
                };

                // If the cursor isn't visible on the viewport, don't show
                // a cursor. Otherwise, get our cursor cell, because we may
                // need it for styling.
                const cursor_vp = state.cursor.viewport orelse break :cursor;
                const cursor_style: terminal.Style = cursor_style: {
                    const cells = state.row_data.items(.cells);
                    const cell = cells[cursor_vp.y].get(cursor_vp.x);
                    break :cursor_style if (cell.raw.hasStyling())
                        cell.style
                    else
                        .{};
                };

                // If we have preedit text, we don't setup a cursor
                if (preedit != null) break :cursor;

                // If there isn't a cursor visual style requested then
                // we don't render a cursor.
                const style = cursor_style_ orelse break :cursor;

                // Determine the cursor color.
                const cursor_color = cursor_color: {
                    // If an explicit cursor color was set by OSC 12, use that.
                    if (state.colors.cursor) |v| break :cursor_color v;

                    // Use our configured color if specified
                    if (self.config.cursor_color) |v| switch (v) {
                        .color => |color| break :cursor_color color.toTerminalRGB(),

                        inline .@"cell-foreground",
                        .@"cell-background",
                        => |_, tag| {
                            const fg_style = cursor_style.fg(.{
                                .default = state.colors.foreground,
                                .palette = &state.colors.palette,
                                .bold = self.config.bold_color,
                            });
                            const bg_style = cursor_style.bg(
                                &state.cursor.cell,
                                &state.colors.palette,
                            ) orelse state.colors.background;

                            break :cursor_color switch (tag) {
                                .color => unreachable,
                                .@"cell-foreground" => if (cursor_style.flags.inverse)
                                    bg_style
                                else
                                    fg_style,
                                .@"cell-background" => if (cursor_style.flags.inverse)
                                    fg_style
                                else
                                    bg_style,
                            };
                        },
                    };

                    break :cursor_color state.colors.foreground;
                };

                self.addCursor(
                    &state.cursor,
                    style,
                    cursor_color,
                );

                // If the cursor is visible then we set our uniforms.
                if (style == .block) {
                    const wide = state.cursor.cell.wide;

                    self.uniforms.cursor_pos = .{
                        // If we are a spacer tail of a wide cell, our cursor needs
                        // to move back one cell. The saturate is to ensure we don't
                        // overflow but this shouldn't happen with well-formed input.
                        switch (wide) {
                            .narrow, .spacer_head, .wide => cursor_vp.x,
                            .spacer_tail => cursor_vp.x -| 1,
                        },
                        @intCast(cursor_vp.y),
                    };

                    self.uniforms.bools.cursor_wide = switch (wide) {
                        .narrow, .spacer_head => false,
                        .wide, .spacer_tail => true,
                    };

                    const uniform_color = if (self.config.cursor_text) |txt| blk: {
                        // If cursor-text is set, then compute the correct color.
                        // Otherwise, use the background color.
                        if (txt == .color) {
                            // Use the color set by cursor-text, if any.
                            break :blk txt.color.toTerminalRGB();
                        }

                        const fg_style = cursor_style.fg(.{
                            .default = state.colors.foreground,
                            .palette = &state.colors.palette,
                            .bold = self.config.bold_color,
                        });
                        const bg_style = cursor_style.bg(
                            &state.cursor.cell,
                            &state.colors.palette,
                        ) orelse state.colors.background;

                        break :blk switch (txt) {
                            // If the cell is reversed, use the opposite cell color instead.
                            .@"cell-foreground" => if (cursor_style.flags.inverse)
                                bg_style
                            else
                                fg_style,
                            .@"cell-background" => if (cursor_style.flags.inverse)
                                fg_style
                            else
                                bg_style,
                            else => unreachable,
                        };
                    } else state.colors.background;

                    self.uniforms.cursor_color = .{
                        uniform_color.r,
                        uniform_color.g,
                        uniform_color.b,
                        255,
                    };
                }
            }

            // Setup our preedit text.
            if (preedit) |preedit_v| preedit: {
                const range = preedit_range orelse break :preedit;
                var x = range.x[0];
                for (preedit_v.codepoints[range.cp_offset..]) |cp| {
                    self.addPreeditCell(
                        cp,
                        .{ .x = x, .y = range.y },
                        state.colors.foreground,
                    ) catch |err| {
                        log.warn("error building preedit cell, will be invalid x={} y={}, err={}", .{
                            x,
                            range.y,
                            err,
                        });
                    };

                    x += if (cp.wide) 2 else 1;
                }
            }

            // Update that our cells rebuilt
            self.cells_rebuilt = true;

            // Log some things
            // log.debug("rebuildCells complete cached_runs={}", .{
            //     self.font_shaper_cache.count(),
            // });
        }

        fn rebuildRow(
            self: *Self,
            y: terminal.size.CellCountInt,
            row: terminal.page.Row,
            cells: *std.MultiArrayList(terminal.RenderState.Cell),
            preedit_range: ?PreeditRange,
            selection: ?[2]terminal.size.CellCountInt,
            highlights: *const std.ArrayList(terminal.RenderState.Highlight),
            links: *const terminal.RenderState.CellSet,
        ) !void {
            const state = &self.terminal_state;

            // If our viewport is wider than our cell contents buffer,
            // we still only process cells up to the width of the buffer.
            const cells_slice = cells.slice();
            const cells_len = @min(cells_slice.len, self.cells.size.columns);
            const cells_raw = cells_slice.items(.raw);
            const cells_style = cells_slice.items(.style);

            // On primary screen, we still apply vertical padding
            // extension under certain conditions we feel are safe.
            //
            // This helps make some scenarios look better while
            // avoiding scenarios we know do NOT look good.
            switch (self.config.padding_color) {
                // These already have the correct values set above.
                .background, .@"extend-always" => {},

                // Apply heuristics for padding extension.
                .extend => if (y == 0) {
                    self.uniforms.padding_extend.up = !rowNeverExtendBg(
                        row,
                        cells_raw,
                        cells_style,
                        &state.colors.palette,
                        state.colors.background,
                    );
                } else if (y == self.cells.size.rows - 1) {
                    self.uniforms.padding_extend.down = !rowNeverExtendBg(
                        row,
                        cells_raw,
                        cells_style,
                        &state.colors.palette,
                        state.colors.background,
                    );
                },
            }

            // Iterator of runs for shaping.
            var run_iter_opts: font.shape.RunOptions = .{
                .grid = self.font_grid,
                .cells = cells_slice,
                .selection = if (selection) |s| s else null,

                // We want to do font shaping as long as the cursor is
                // visible on this viewport.
                .cursor_x = cursor_x: {
                    const vp = state.cursor.viewport orelse break :cursor_x null;
                    if (vp.y != y) break :cursor_x null;
                    break :cursor_x vp.x;
                },
            };
            run_iter_opts.applyBreakConfig(self.config.font_shaping_break);
            var run_iter = self.font_shaper.runIterator(run_iter_opts);
            var shaper_run: ?font.shape.TextRun = try run_iter.next(self.alloc);
            var shaper_cells: ?[]const font.shape.Cell = null;
            var shaper_cells_i: usize = 0;

            for (
                0..,
                cells_raw[0..cells_len],
                cells_style[0..cells_len],
            ) |x, *cell, *managed_style| {
                // If this cell falls within our preedit range then we
                // skip this because preedits are setup separately.
                if (preedit_range) |range| preedit: {
                    // We're not on the preedit line, no actions necessary.
                    if (range.y != y) break :preedit;
                    // We're before the preedit range, no actions necessary.
                    if (x < range.x[0]) break :preedit;
                    // We're in the preedit range, skip this cell.
                    if (x <= range.x[1]) continue;
                    // After exiting the preedit range we need to catch
                    // the run position up because of the missed cells.
                    // In all other cases, no action is necessary.
                    if (x != range.x[1] + 1) break :preedit;

                    // Step the run iterator until we find a run that ends
                    // after the current cell, which will be the soonest run
                    // that might contain glyphs for our cell.
                    while (shaper_run) |run| {
                        if (run.offset + run.cells > x) break;
                        shaper_run = try run_iter.next(self.alloc);
                        shaper_cells = null;
                        shaper_cells_i = 0;
                    }

                    const run = shaper_run orelse break :preedit;

                    // If we haven't shaped this run, do so now.
                    shaper_cells = shaper_cells orelse
                        // Try to read the cells from the shaping cache if we can.
                        self.font_shaper_cache.get(run) orelse
                        cache: {
                            // Otherwise we have to shape them.
                            const new_cells = try self.font_shaper.shape(run);

                            // Try to cache them. If caching fails for any reason we
                            // continue because it is just a performance optimization,
                            // not a correctness issue.
                            self.font_shaper_cache.put(
                                self.alloc,
                                run,
                                new_cells,
                            ) catch |err| {
                                log.warn(
                                    "error caching font shaping results err={}",
                                    .{err},
                                );
                            };

                            // The cells we get from direct shaping are always owned
                            // by the shaper and valid until the next shaping call so
                            // we can safely use them.
                            break :cache new_cells;
                        };

                    // Advance our index until we reach or pass
                    // our current x position in the shaper cells.
                    const shaper_cells_unwrapped = shaper_cells.?;
                    while (run.offset + shaper_cells_unwrapped[shaper_cells_i].x < x) {
                        shaper_cells_i += 1;
                    }
                }

                const wide = cell.wide;
                const style: terminal.Style = if (cell.hasStyling())
                    managed_style.*
                else
                    .{};

                // True if this cell is selected
                const selected: enum {
                    false,
                    selection,
                    search,
                    search_selected,
                } = selected: {
                    // Order below matters for precedence.

                    // Selection should take the highest precedence.
                    const x_compare = if (wide == .spacer_tail)
                        x -| 1
                    else
                        x;
                    if (selection) |sel| {
                        if (x_compare >= sel[0] and
                            x_compare <= sel[1]) break :selected .selection;
                    }

                    // If we're highlighted, then we're selected. In the
                    // future we want to use a different style for this
                    // but this to get started.
                    for (highlights.items) |hl| {
                        if (x_compare >= hl.range[0] and
                            x_compare <= hl.range[1])
                        {
                            const tag: HighlightTag = @enumFromInt(hl.tag);
                            break :selected switch (tag) {
                                .search_match => .search,
                                .search_match_selected => .search_selected,
                            };
                        }
                    }

                    break :selected .false;
                };

                // The `_style` suffixed values are the colors based on
                // the cell style (SGR), before applying any additional
                // configuration, inversions, selections, etc.
                const bg_style = style.bg(
                    cell,
                    &state.colors.palette,
                );
                const fg_style = style.fg(.{
                    .default = state.colors.foreground,
                    .palette = &state.colors.palette,
                    .bold = self.config.bold_color,
                });

                // The final background color for the cell.
                const bg = switch (selected) {
                    // If we have an explicit selection background color
                    // specified in the config, use that.
                    //
                    // If no configuration, then our selection background
                    // is our foreground color.
                    .selection => if (self.config.selection_background) |v| switch (v) {
                        .color => |color| color.toTerminalRGB(),
                        .@"cell-foreground" => if (style.flags.inverse) bg_style else fg_style,
                        .@"cell-background" => if (style.flags.inverse) fg_style else bg_style,
                    } else state.colors.foreground,

                    .search => switch (self.config.search_background) {
                        .color => |color| color.toTerminalRGB(),
                        .@"cell-foreground" => if (style.flags.inverse) bg_style else fg_style,
                        .@"cell-background" => if (style.flags.inverse) fg_style else bg_style,
                    },

                    .search_selected => switch (self.config.search_selected_background) {
                        .color => |color| color.toTerminalRGB(),
                        .@"cell-foreground" => if (style.flags.inverse) bg_style else fg_style,
                        .@"cell-background" => if (style.flags.inverse) fg_style else bg_style,
                    },

                    // Not selected
                    .false => if (style.flags.inverse != isCovering(cell.codepoint()))
                        // Two cases cause us to invert (use the fg color as the bg)
                        // - The "inverse" style flag.
                        // - A "covering" glyph; we use fg for bg in that
                        //   case to help make sure that padding extension
                        //   works correctly.
                        //
                        // If one of these is true (but not the other)
                        // then we use the fg style color for the bg.
                        fg_style
                    else
                        // Otherwise they cancel out.
                        bg_style,
                };

                const fg = fg: {
                    // Our happy-path non-selection background color
                    // is our style or our configured defaults.
                    const final_bg = bg_style orelse state.colors.background;

                    // Whether we need to use the bg color as our fg color:
                    // - Cell is selected, inverted, and set to cell-foreground
                    // - Cell is selected, not inverted, and set to cell-background
                    // - Cell is inverted and not selected
                    break :fg switch (selected) {
                        .selection => if (self.config.selection_foreground) |v| switch (v) {
                            .color => |color| color.toTerminalRGB(),
                            .@"cell-foreground" => if (style.flags.inverse) final_bg else fg_style,
                            .@"cell-background" => if (style.flags.inverse) fg_style else final_bg,
                        } else state.colors.background,

                        .search => switch (self.config.search_foreground) {
                            .color => |color| color.toTerminalRGB(),
                            .@"cell-foreground" => if (style.flags.inverse) final_bg else fg_style,
                            .@"cell-background" => if (style.flags.inverse) fg_style else final_bg,
                        },

                        .search_selected => switch (self.config.search_selected_foreground) {
                            .color => |color| color.toTerminalRGB(),
                            .@"cell-foreground" => if (style.flags.inverse) final_bg else fg_style,
                            .@"cell-background" => if (style.flags.inverse) fg_style else final_bg,
                        },

                        .false => if (style.flags.inverse)
                            final_bg
                        else
                            fg_style,
                    };
                };

                // Foreground alpha for this cell.
                const alpha: u8 = if (style.flags.faint) self.config.faint_opacity else 255;

                // Set the cell's background color.
                {
                    const rgb = bg orelse state.colors.background;

                    // Determine our background alpha. If we have transparency configured
                    // then this is dynamic depending on some situations. This is all
                    // in an attempt to make transparency look the best for various
                    // situations. See inline comments.
                    const bg_alpha: u8 = bg_alpha: {
                        const default: u8 = 255;

                        // Cells that are selected should be fully opaque.
                        if (selected != .false) break :bg_alpha default;

                        // Cells that are reversed should be fully opaque.
                        if (style.flags.inverse) break :bg_alpha default;

                        // If the user requested to have opacity on all cells, apply it.
                        if (self.config.background_opacity_cells and bg_style != null) {
                            var opacity: f64 = @floatFromInt(default);
                            opacity *= self.config.background_opacity;
                            break :bg_alpha @intFromFloat(opacity);
                        }

                        // Cells that have an explicit bg color should be fully opaque.
                        if (bg_style != null) break :bg_alpha default;

                        // Otherwise, we won't draw the bg for this cell,
                        // we'll let the already-drawn background color
                        // show through.
                        break :bg_alpha 0;
                    };

                    self.cells.bgCell(y, x).* = .{
                        rgb.r, rgb.g, rgb.b, bg_alpha,
                    };
                }

                // If the invisible flag is set on this cell then we
                // don't need to render any foreground elements, so
                // we just skip all glyphs with this x coordinate.
                //
                // NOTE: This behavior matches xterm. Some other terminal
                // emulators, e.g. Alacritty, still render text decorations
                // and only make the text itself invisible. The decision
                // has been made here to match xterm's behavior for this.
                if (style.flags.invisible) {
                    continue;
                }

                // Give links a single underline, unless they already have
                // an underline, in which case use a double underline to
                // distinguish them.
                const underline: terminal.Attribute.Underline = underline: {
                    if (links.contains(.{
                        .x = @intCast(x),
                        .y = @intCast(y),
                    })) {
                        break :underline if (style.flags.underline == .single)
                            .double
                        else
                            .single;
                    }
                    break :underline style.flags.underline;
                };

                // We draw underlines first so that they layer underneath text.
                // This improves readability when a colored underline is used
                // which intersects parts of the text (descenders).
                if (underline != .none) self.addUnderline(
                    @intCast(x),
                    @intCast(y),
                    underline,
                    style.underlineColor(&state.colors.palette) orelse fg,
                    alpha,
                ) catch |err| {
                    log.warn(
                        "error adding underline to cell, will be invalid x={} y={}, err={}",
                        .{ x, y, err },
                    );
                };

                if (style.flags.overline) self.addOverline(@intCast(x), @intCast(y), fg, alpha) catch |err| {
                    log.warn(
                        "error adding overline to cell, will be invalid x={} y={}, err={}",
                        .{ x, y, err },
                    );
                };

                // If we're at or past the end of our shaper run then
                // we need to get the next run from the run iterator.
                if (shaper_cells != null and shaper_cells_i >= shaper_cells.?.len) {
                    shaper_run = try run_iter.next(self.alloc);
                    shaper_cells = null;
                    shaper_cells_i = 0;
                }

                if (shaper_run) |run| glyphs: {
                    // If we haven't shaped this run yet, do so.
                    shaper_cells = shaper_cells orelse
                        // Try to read the cells from the shaping cache if we can.
                        self.font_shaper_cache.get(run) orelse
                        cache: {
                            // Otherwise we have to shape them.
                            const new_cells = try self.font_shaper.shape(run);

                            // Try to cache them. If caching fails for any reason we
                            // continue because it is just a performance optimization,
                            // not a correctness issue.
                            self.font_shaper_cache.put(
                                self.alloc,
                                run,
                                new_cells,
                            ) catch |err| {
                                log.warn(
                                    "error caching font shaping results err={}",
                                    .{err},
                                );
                            };

                            // The cells we get from direct shaping are always owned
                            // by the shaper and valid until the next shaping call so
                            // we can safely use them.
                            break :cache new_cells;
                        };

                    const shaped_cells = shaper_cells orelse break :glyphs;

                    // If there are no shaper cells for this run, ignore it.
                    // This can occur for runs of empty cells, and is fine.
                    if (shaped_cells.len == 0) break :glyphs;

                    // If we encounter a shaper cell to the left of the current
                    // cell then we have some problems. This logic relies on x
                    // position monotonically increasing.
                    assert(run.offset + shaped_cells[shaper_cells_i].x >= x);

                    // NOTE: An assumption is made here that a single cell will never
                    // be present in more than one shaper run. If that assumption is
                    // violated, this logic breaks.

                    while (shaper_cells_i < shaped_cells.len and
                        run.offset + shaped_cells[shaper_cells_i].x == x) : ({
                        shaper_cells_i += 1;
                    }) {
                        self.addGlyph(
                            @intCast(x),
                            @intCast(y),
                            state.cols,
                            cells_raw,
                            shaped_cells[shaper_cells_i],
                            shaper_run.?,
                            fg,
                            alpha,
                        ) catch |err| {
                            log.warn(
                                "error adding glyph to cell, will be invalid x={} y={}, err={}",
                                .{ x, y, err },
                            );
                        };
                    }
                }

                // Finally, draw a strikethrough if necessary.
                if (style.flags.strikethrough) self.addStrikethrough(
                    @intCast(x),
                    @intCast(y),
                    fg,
                    alpha,
                ) catch |err| {
                    log.warn(
                        "error adding strikethrough to cell, will be invalid x={} y={}, err={}",
                        .{ x, y, err },
                    );
                };
            }
        }

        /// Add an underline decoration to the specified cell
        fn addUnderline(
            self: *Self,
            x: terminal.size.CellCountInt,
            y: terminal.size.CellCountInt,
            style: terminal.Attribute.Underline,
            color: terminal.color.RGB,
            alpha: u8,
        ) !void {
            const sprite: font.Sprite = switch (style) {
                .none => unreachable,
                .single => .underline,
                .double => .underline_double,
                .dotted => .underline_dotted,
                .dashed => .underline_dashed,
                .curly => .underline_curly,
            };

            const render = try self.font_grid.renderGlyph(
                self.alloc,
                font.sprite_index,
                @intFromEnum(sprite),
                .{
                    .cell_width = 1,
                    .grid_metrics = self.grid_metrics,
                },
            );

            try self.cells.add(self.alloc, .underline, .{
                .atlas = .grayscale,
                .grid_pos = .{ @intCast(x), @intCast(y) },
                .color = .{ color.r, color.g, color.b, alpha },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
            });
        }

        /// Add a overline decoration to the specified cell
        fn addOverline(
            self: *Self,
            x: terminal.size.CellCountInt,
            y: terminal.size.CellCountInt,
            color: terminal.color.RGB,
            alpha: u8,
        ) !void {
            const render = try self.font_grid.renderGlyph(
                self.alloc,
                font.sprite_index,
                @intFromEnum(font.Sprite.overline),
                .{
                    .cell_width = 1,
                    .grid_metrics = self.grid_metrics,
                },
            );

            try self.cells.add(self.alloc, .overline, .{
                .atlas = .grayscale,
                .grid_pos = .{ @intCast(x), @intCast(y) },
                .color = .{ color.r, color.g, color.b, alpha },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
            });
        }

        /// Add a strikethrough decoration to the specified cell
        fn addStrikethrough(
            self: *Self,
            x: terminal.size.CellCountInt,
            y: terminal.size.CellCountInt,
            color: terminal.color.RGB,
            alpha: u8,
        ) !void {
            const render = try self.font_grid.renderGlyph(
                self.alloc,
                font.sprite_index,
                @intFromEnum(font.Sprite.strikethrough),
                .{
                    .cell_width = 1,
                    .grid_metrics = self.grid_metrics,
                },
            );

            try self.cells.add(self.alloc, .strikethrough, .{
                .atlas = .grayscale,
                .grid_pos = .{ @intCast(x), @intCast(y) },
                .color = .{ color.r, color.g, color.b, alpha },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
            });
        }

        // Add a glyph to the specified cell.
        fn addGlyph(
            self: *Self,
            x: terminal.size.CellCountInt,
            y: terminal.size.CellCountInt,
            cols: usize,
            cell_raws: []const terminal.page.Cell,
            shaper_cell: font.shape.Cell,
            shaper_run: font.shape.TextRun,
            color: terminal.color.RGB,
            alpha: u8,
        ) !void {
            const cell = cell_raws[x];
            const cp = cell.codepoint();

            // Render
            const render = try self.font_grid.renderGlyph(
                self.alloc,
                shaper_run.font_index,
                shaper_cell.glyph_index,
                .{
                    .grid_metrics = self.grid_metrics,
                    .thicken = self.config.font_thicken,
                    .thicken_strength = self.config.font_thicken_strength,
                    .cell_width = cell.gridWidth(),
                    // If there's no Nerd Font constraint for this codepoint
                    // then, if it's a symbol, we constrain it to fit inside
                    // its cell(s), we don't modify the alignment at all.
                    .constraint = getConstraint(cp) orelse
                        if (cellpkg.isSymbol(cp)) .{
                            .size = .fit,
                        } else .none,
                    .constraint_width = constraintWidth(
                        cell_raws,
                        x,
                        cols,
                    ),
                },
            );

            // If the glyph is 0 width or height, it will be invisible
            // when drawn, so don't bother adding it to the buffer.
            if (render.glyph.width == 0 or render.glyph.height == 0) {
                return;
            }

            try self.cells.add(self.alloc, .text, .{
                .atlas = switch (render.presentation) {
                    .emoji => .color,
                    .text => .grayscale,
                },
                .bools = .{ .no_min_contrast = noMinContrast(cp) },
                .grid_pos = .{ @intCast(x), @intCast(y) },
                .color = .{ color.r, color.g, color.b, alpha },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x + shaper_cell.x_offset),
                    @intCast(render.glyph.offset_y + shaper_cell.y_offset),
                },
            });
        }

        fn addCursor(
            self: *Self,
            cursor_state: *const terminal.RenderState.Cursor,
            cursor_style: renderer.CursorStyle,
            cursor_color: terminal.color.RGB,
        ) void {
            const cursor_vp = cursor_state.viewport orelse return;

            // Add the cursor. We render the cursor over the wide character if
            // we're on the wide character tail.
            const wide, const x = cell: {
                // The cursor goes over the screen cursor position.
                if (!cursor_vp.wide_tail) break :cell .{
                    cursor_state.cell.wide == .wide,
                    cursor_vp.x,
                };

                // If we're part of a wide character, we move the cursor back
                // to the actual character.
                break :cell .{ true, cursor_vp.x - 1 };
            };

            const alpha: u8 = if (!self.focused) 255 else alpha: {
                const alpha = 255 * self.config.cursor_opacity;
                break :alpha @intFromFloat(@ceil(alpha));
            };

            const render = switch (cursor_style) {
                .block,
                .block_hollow,
                .bar,
                .underline,
                => render: {
                    const sprite: font.Sprite = switch (cursor_style) {
                        .block => .cursor_rect,
                        .block_hollow => .cursor_hollow_rect,
                        .bar => .cursor_bar,
                        .underline => .cursor_underline,
                        .lock => unreachable,
                    };

                    break :render self.font_grid.renderGlyph(
                        self.alloc,
                        font.sprite_index,
                        @intFromEnum(sprite),
                        .{
                            .cell_width = if (wide) 2 else 1,
                            .grid_metrics = self.grid_metrics,
                        },
                    ) catch |err| {
                        log.warn("error rendering cursor glyph err={}", .{err});
                        return;
                    };
                },

                .lock => self.font_grid.renderCodepoint(
                    self.alloc,
                    0xF023, // lock symbol
                    .regular,
                    .text,
                    .{
                        .cell_width = if (wide) 2 else 1,
                        .grid_metrics = self.grid_metrics,
                    },
                ) catch |err| {
                    log.warn("error rendering cursor glyph err={}", .{err});
                    return;
                } orelse {
                    // This should never happen because we embed nerd
                    // fonts so we just log and return instead of fallback.
                    log.warn("failed to find lock symbol for cursor codepoint=0xF023", .{});
                    return;
                },
            };

            self.cells.setCursor(.{
                .atlas = .grayscale,
                .bools = .{ .is_cursor_glyph = true },
                .grid_pos = .{ x, cursor_vp.y },
                .color = .{ cursor_color.r, cursor_color.g, cursor_color.b, alpha },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
            }, cursor_style);
        }

        fn addPreeditCell(
            self: *Self,
            cp: renderer.State.Preedit.Codepoint,
            coord: terminal.Coordinate,
            screen_fg: terminal.color.RGB,
        ) !void {
            // Render the glyph for our preedit text
            const render_ = self.font_grid.renderCodepoint(
                self.alloc,
                @intCast(cp.codepoint),
                .regular,
                .text,
                .{ .grid_metrics = self.grid_metrics },
            ) catch |err| {
                log.warn("error rendering preedit glyph err={}", .{err});
                return;
            };
            const render = render_ orelse {
                log.warn("failed to find font for preedit codepoint={X}", .{cp.codepoint});
                return;
            };

            // Add our text
            try self.cells.add(self.alloc, .text, .{
                .atlas = .grayscale,
                .grid_pos = .{ @intCast(coord.x), @intCast(coord.y) },
                .color = .{ screen_fg.r, screen_fg.g, screen_fg.b, 255 },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
            });

            // Add underline
            try self.addUnderline(@intCast(coord.x), @intCast(coord.y), .single, screen_fg, 255);
            if (cp.wide and coord.x < self.cells.size.columns - 1) {
                try self.addUnderline(@intCast(coord.x + 1), @intCast(coord.y), .single, screen_fg, 255);
            }
        }

        /// Sync the atlas data to the given texture. This copies the bytes
        /// associated with the atlas to the given texture. If the atlas no
        /// longer fits into the texture, the texture will be resized.
        fn syncAtlasTexture(
            self: *const Self,
            atlas: *const font.Atlas,
            texture: *Texture,
        ) !void {
            if (atlas.size > texture.width) {
                // Free our old texture
                texture.*.deinit();

                // Reallocate
                texture.* = try self.api.initAtlasTexture(atlas);
            }

            try texture.replaceRegion(0, 0, atlas.size, atlas.size, atlas.data);
        }
    };
}

fn softwareCpuRouteDecisionInputDefaults() SoftwareCpuRouteDecisionInput {
    return .{
        .cpu_route_build_effective = true,
        .cpu_route_mvp_requested = true,
        .cpu_route_build_source = .effective,
        .cpu_route_target_os_supported = true,
        .cpu_route_allow_legacy_os = false,
        .renderer_is_software = true,
        .software_frame_publishing = true,
        .software_renderer_experimental = true,
        .software_renderer_presenter = .auto,
        .custom_shaders_active = false,
        .custom_shader_execution_capability_observed = false,
        .custom_shader_execution_available = false,
        .custom_shader_execution_unavailable_reason = .backend_unavailable,
        .custom_shader_execution_hint_source = null,
        .custom_shader_execution_hint_path = null,
        .custom_shader_execution_hint_readable = false,
        .custom_shader_probe_minimal_runtime_enabled = cpuShaderMinimalRuntimeEnabledDefault(),
        .cpu_shader_mode = .off,
        .cpu_shader_timeout_ms = 16,
        .transport_mode_native = false,
    };
}

fn cpuRouteDiagnosticsSnapshotDefaults() CpuRouteDiagnosticsSnapshot {
    const build_cpu_route_source = buildCpuRouteAvailabilitySourceForCurrentBuild();
    return .{
        .custom_shader_fallback_count = 0,
        .custom_shader_bypass_count = 0,
        .cpu_shader_capability_reprobe_count = 0,
        .cpu_shader_reprobe_interval_frames = cpu_custom_shader_capability_reprobe_interval_frames,
        .publish_retry_count = 0,
        .cpu_damage_rect_count = 0,
        .cpu_damage_rect_overflow_count = 0,
        .cpu_frame_damage_mode = @tagName(software_renderer_cpu_frame_damage_mode),
        .cpu_damage_rect_cap = software_renderer_cpu_damage_rect_cap,
        .cpu_publish_skipped_no_damage_count = 0,
        .cpu_publish_latency_warning_count = 0,
        .last_cpu_publish_latency_warning_frame_ms = null,
        .last_cpu_publish_latency_warning_consecutive_count = 0,
        .cpu_publish_warning_threshold_ms = cpu_frame_publish_warning_threshold_ms,
        .cpu_publish_warning_consecutive_limit = cpu_frame_publish_warning_consecutive_limit,
        .cpu_publish_retry_invalid_surface_count = 0,
        .cpu_publish_retry_pool_pressure_count = 0,
        .cpu_publish_retry_pool_exhausted_count = 0,
        .cpu_publish_retry_mailbox_backpressure_count = 0,
        .cpu_retired_pool_pressure_warning_count = 0,
        .cpu_frame_pool_exhausted_warning_count = 0,
        .last_cpu_publish_retry_reason = "n/a",
        .last_cpu_frame_pool_warning_reason = "n/a",
        .last_cpu_frame_ms = null,
        .last_fallback_reason = null,
        .last_fallback_scope = "none",
        .build_cpu_route_effective = software_renderer_cpu_effective,
        .build_cpu_route_mvp_requested = build_config.software_renderer_cpu_mvp,
        .build_cpu_route_source = @tagName(build_cpu_route_source),
        .build_cpu_route_target_os_supported = buildCpuRouteTargetOsSupported(builtin.target.os.tag),
        .build_cpu_route_allow_legacy_os = build_config.software_renderer_cpu_allow_legacy_os,
        .shader_capability_observed = false,
        .shader_capability_available = false,
        .shader_minimal_runtime_enabled = false,
        .cpu_shader_backend = build_config.software_renderer_cpu_shader_backend,
        .shader_capability_reason = "n/a",
        .shader_capability_hint_source = "n/a",
        .shader_capability_hint_path = "n/a",
        .shader_capability_hint_readable = false,
    };
}

test "effectiveCpuDamageRectCap keeps configured value when frame damage mode is off" {
    try std.testing.expectEqual(@as(u16, 0), effectiveCpuDamageRectCap(.off, 0));
    try std.testing.expectEqual(@as(u16, 8), effectiveCpuDamageRectCap(.off, 8));
}

test "effectiveCpuDamageRectCap clamps rects mode cap to at least one" {
    try std.testing.expectEqual(@as(u16, 1), effectiveCpuDamageRectCap(.rects, 0));
    try std.testing.expectEqual(@as(u16, 8), effectiveCpuDamageRectCap(.rects, 8));
}

test "cpu damage rect for row span clamps to surface bounds" {
    const rect = cpuDamageRectForRowSpan(
        800,
        120,
        10,
        20,
        0,
        8,
        8,
    ).?;
    try std.testing.expectEqualDeep(cpu_renderer.Rect{
        .x = 0,
        .y = 5,
        .width = 800,
        .height = 115,
    }, rect);
}

test "cpu damage rect for row span rejects empty and zero-cell-height spans" {
    try std.testing.expect(cpuDamageRectForRowSpan(
        800,
        120,
        10,
        20,
        3,
        3,
        10,
    ) == null);
    try std.testing.expect(cpuDamageRectForRowSpan(
        800,
        120,
        10,
        0,
        0,
        1,
        10,
    ) == null);
}

test "cpu damage rect for row span expands to neighbor rows" {
    const rect = cpuDamageRectForRowSpan(
        200,
        200,
        0,
        20,
        2,
        3,
        10,
    ).?;
    try std.testing.expectEqualDeep(cpu_renderer.Rect{
        .x = 0,
        .y = 15,
        .width = 200,
        .height = 70,
    }, rect);
}

test "cpu damage rect for row span includes top spill for first row" {
    const rect = cpuDamageRectForRowSpan(
        200,
        200,
        10,
        20,
        0,
        1,
        10,
    ).?;
    try std.testing.expectEqualDeep(cpu_renderer.Rect{
        .x = 0,
        .y = 5,
        .width = 200,
        .height = 50,
    }, rect);
}

test "cpu damage rect for row span includes bottom spill for last row" {
    const rect = cpuDamageRectForRowSpan(
        200,
        230,
        10,
        20,
        9,
        10,
        10,
    ).?;
    try std.testing.expectEqualDeep(cpu_renderer.Rect{
        .x = 0,
        .y = 165,
        .width = 200,
        .height = 50,
    }, rect);
}

test "cpuCellGridCount rejects overflow" {
    try std.testing.expect(cpuCellGridCount(std.math.maxInt(usize), 2) == null);
}

test "cpuCellPixelOrigin rejects offset and base overflow" {
    try std.testing.expectEqual(@as(?u32, 12), cpuCellPixelOrigin(2, 5, 2));
    try std.testing.expect(cpuCellPixelOrigin(0, std.math.maxInt(u32), 2) == null);
    try std.testing.expect(cpuCellPixelOrigin(std.math.maxInt(u32), 1, 1) == null);
}

test "needsFrameBgImageBuffer only enables for ready image" {
    const TestImage = Renderer(renderer.Renderer.API).Image;

    try std.testing.expect(!needsFrameBgImageBuffer(@as(?TestImage, null)));
    try std.testing.expect(!needsFrameBgImageBuffer(TestImage{ .pending = undefined }));
    try std.testing.expect(!needsFrameBgImageBuffer(TestImage{ .unload_ready = undefined }));
    try std.testing.expect(needsFrameBgImageBuffer(TestImage{ .ready = undefined }));
}

fn makeOwnedPendingRgbaImage(
    comptime ImageType: type,
    alloc: Allocator,
    width: u32,
    height: u32,
    rgba: []const u8,
) !ImageType {
    try std.testing.expectEqual(
        @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4,
        rgba.len,
    );

    const data = try alloc.dupe(u8, rgba);
    return .{ .pending = .{
        .height = height,
        .width = width,
        .pixel_format = .rgba,
        .data = data.ptr,
    } };
}

test "applyPreparedBackgroundImage stores first pending image" {
    const alloc = std.testing.allocator;
    const TestImage = Renderer(renderer.Renderer.API).Image;
    var bg_image: ?TestImage = null;
    defer if (bg_image) |*image| image.deinit(alloc);

    applyPreparedBackgroundImage(
        alloc,
        &bg_image,
        try makeOwnedPendingRgbaImage(TestImage, alloc, 1, 1, &.{ 1, 2, 3, 4 }),
    );

    try std.testing.expect(bg_image != null);
    try std.testing.expect(bg_image.?.isPending());
    switch (bg_image.?) {
        .pending => |pending| try std.testing.expectEqual(@as(u32, 1), pending.width),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(!needsFrameBgImageBuffer(bg_image));
}

test "applyPreparedBackgroundImage replaces pending image and clearConfiguredBackgroundImage marks unload" {
    const alloc = std.testing.allocator;
    const TestImage = Renderer(renderer.Renderer.API).Image;
    var bg_image: ?TestImage = try makeOwnedPendingRgbaImage(
        TestImage,
        alloc,
        1,
        1,
        &.{ 1, 2, 3, 4 },
    );
    defer if (bg_image) |*image| image.deinit(alloc);

    applyPreparedBackgroundImage(
        alloc,
        &bg_image,
        try makeOwnedPendingRgbaImage(
            TestImage,
            alloc,
            2,
            1,
            &.{ 5, 6, 7, 8, 9, 10, 11, 12 },
        ),
    );

    try std.testing.expect(bg_image != null);
    try std.testing.expect(bg_image.?.isPending());
    switch (bg_image.?) {
        .pending => |pending| {
            try std.testing.expectEqual(@as(u32, 2), pending.width);
            try std.testing.expectEqual(@as(u32, 1), pending.height);
        },
        else => return error.TestUnexpectedResult,
    }

    clearConfiguredBackgroundImage(&bg_image);
    try std.testing.expect(bg_image.?.isUnloading());
}

test "bg image unload boundary still forces full cpu damage" {
    const alloc = std.testing.allocator;
    const TestImage = Renderer(renderer.Renderer.API).Image;
    var bg_image: ?TestImage = try makeOwnedPendingRgbaImage(
        TestImage,
        alloc,
        1,
        1,
        &.{ 1, 2, 3, 4 },
    );
    defer if (bg_image) |*image| image.deinit(alloc);

    try std.testing.expect(bgImageRequiresConservativeFullCpuDamage(
        bg_image,
        true,
    ));

    clearConfiguredBackgroundImage(&bg_image);
    try std.testing.expect(bg_image.?.isUnloading());
    try std.testing.expect(bgImageRequiresConservativeFullCpuDamage(
        bg_image,
        false,
    ));
}

test "partial cpu row damage resumes after bg image slot is cleared" {
    const alloc = std.testing.allocator;
    const TestImage = Renderer(renderer.Renderer.API).Image;
    var bg_image: ?TestImage = try makeOwnedPendingRgbaImage(
        TestImage,
        alloc,
        1,
        1,
        &.{ 1, 2, 3, 4 },
    );

    clearConfiguredBackgroundImage(&bg_image);
    try std.testing.expect(finalizeUnloadingBgImage(alloc, &bg_image));
    try std.testing.expect(bg_image == null);
    try std.testing.expect(!bgImageRequiresConservativeFullCpuDamage(
        bg_image,
        false,
    ));
}

test "background image prepare failure clears stale unload slot" {
    const alloc = std.testing.allocator;
    const TestImage = Renderer(renderer.Renderer.API).Image;
    var bg_image: ?TestImage = try makeOwnedPendingRgbaImage(
        TestImage,
        alloc,
        1,
        1,
        &.{ 1, 2, 3, 4 },
    );

    clearConfiguredBackgroundImage(&bg_image);
    try std.testing.expect(bg_image.?.isUnloading());
    try std.testing.expect(discardStaleUnloadingBackgroundImageAfterPrepareFailure(
        alloc,
        &bg_image,
    ));
    try std.testing.expect(bg_image == null);
}

test "clear cpu route transient state resets stale pending publish and warnings" {
    var cpu_publish_pending = true;
    var cpu_frame_publish_warning: CpuFramePublishWarningState = .{
        .consecutive_over_threshold = cpu_frame_publish_warning_consecutive_limit,
        .warned = true,
    };

    clearCpuRouteTransientStateForPlatformRoute(
        &cpu_publish_pending,
        &cpu_frame_publish_warning,
    );

    try std.testing.expect(!cpu_publish_pending);
    try std.testing.expectEqual(@as(u8, 0), cpu_frame_publish_warning.consecutive_over_threshold);
    try std.testing.expect(!cpu_frame_publish_warning.warned);
}

test "cpu publish retry keeps redraw pending without clearing unloading background image" {
    const alloc = std.testing.allocator;
    const TestImage = Renderer(renderer.Renderer.API).Image;
    var bg_image: ?TestImage = try makeOwnedPendingRgbaImage(
        TestImage,
        alloc,
        1,
        1,
        &.{ 1, 2, 3, 4 },
    );
    defer if (bg_image) |*image| image.deinit(alloc);

    clearConfiguredBackgroundImage(&bg_image);
    var cpu_publish_pending = false;
    var cells_rebuilt = false;

    try std.testing.expect(!applyCpuPublishResultState(
        alloc,
        &bg_image,
        false,
        &cpu_publish_pending,
        &cells_rebuilt,
        .{ .retry = .mailbox_backpressure },
    ));
    try std.testing.expect(cpu_publish_pending);
    try std.testing.expect(cells_rebuilt);
    try std.testing.expect(bg_image != null);
    try std.testing.expect(bg_image.?.isUnloading());
}

test "published cpu frame finalizes unloading background only after config is cleared" {
    const alloc = std.testing.allocator;
    const TestImage = Renderer(renderer.Renderer.API).Image;

    var bg_image_gone: ?TestImage = try makeOwnedPendingRgbaImage(
        TestImage,
        alloc,
        1,
        1,
        &.{ 1, 2, 3, 4 },
    );
    clearConfiguredBackgroundImage(&bg_image_gone);
    var cpu_publish_pending = true;
    var cells_rebuilt = false;
    try std.testing.expect(applyCpuPublishResultState(
        alloc,
        &bg_image_gone,
        false,
        &cpu_publish_pending,
        &cells_rebuilt,
        .published,
    ));
    try std.testing.expect(!cpu_publish_pending);
    try std.testing.expect(!cells_rebuilt);
    try std.testing.expect(bg_image_gone == null);

    var bg_image_recovering: ?TestImage = try makeOwnedPendingRgbaImage(
        TestImage,
        alloc,
        1,
        1,
        &.{ 5, 6, 7, 8 },
    );
    defer if (bg_image_recovering) |*image| image.deinit(alloc);
    clearConfiguredBackgroundImage(&bg_image_recovering);
    cpu_publish_pending = true;
    cells_rebuilt = false;
    try std.testing.expect(!applyCpuPublishResultState(
        alloc,
        &bg_image_recovering,
        true,
        &cpu_publish_pending,
        &cells_rebuilt,
        .published,
    ));
    try std.testing.expect(!cpu_publish_pending);
    try std.testing.expect(bg_image_recovering != null);
    try std.testing.expect(bg_image_recovering.?.isUnloading());
}

test "applyPreparedBackgroundImage replaces unloading slot with new pending image" {
    const alloc = std.testing.allocator;
    const TestImage = Renderer(renderer.Renderer.API).Image;
    var bg_image: ?TestImage = try makeOwnedPendingRgbaImage(
        TestImage,
        alloc,
        1,
        1,
        &.{ 1, 2, 3, 4 },
    );
    defer if (bg_image) |*image| image.deinit(alloc);

    clearConfiguredBackgroundImage(&bg_image);
    try std.testing.expect(bg_image.?.isUnloading());

    applyPreparedBackgroundImage(
        alloc,
        &bg_image,
        try makeOwnedPendingRgbaImage(
            TestImage,
            alloc,
            2,
            1,
            &.{ 5, 6, 7, 8, 9, 10, 11, 12 },
        ),
    );

    try std.testing.expect(bg_image != null);
    try std.testing.expect(bg_image.?.isPending());
    try std.testing.expect(!bg_image.?.isUnloading());
    switch (bg_image.?) {
        .pending => |pending| {
            try std.testing.expectEqual(@as(u32, 2), pending.width);
            try std.testing.expectEqual(@as(u32, 1), pending.height);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "build cpu route availability source classifies build-side causes" {
    try std.testing.expectEqual(
        BuildCpuRouteAvailabilitySource.effective,
        buildCpuRouteAvailabilitySource(true, true, true),
    );
    try std.testing.expectEqual(
        BuildCpuRouteAvailabilitySource.mvp_not_requested,
        buildCpuRouteAvailabilitySource(false, false, true),
    );
    try std.testing.expectEqual(
        BuildCpuRouteAvailabilitySource.target_platform_unsupported,
        buildCpuRouteAvailabilitySource(false, true, false),
    );
    try std.testing.expectEqual(
        BuildCpuRouteAvailabilitySource.target_version_below_minimum,
        buildCpuRouteAvailabilitySource(false, true, true),
    );
}

test "software cpu route disable scope separates build and runtime gates" {
    try std.testing.expectEqualStrings(
        "build",
        softwareCpuRouteDisableScope(.build_cpu_route_unavailable),
    );
    try std.testing.expectEqualStrings(
        "runtime",
        softwareCpuRouteDisableScope(.runtime_publishing_disabled),
    );
    try std.testing.expectEqualStrings(
        "none",
        softwareCpuRouteFallbackScope(null),
    );
}

test "software cpu route decision enabled when all gates pass" {
    const decision = decideSoftwareCpuRoute(softwareCpuRouteDecisionInputDefaults());
    try std.testing.expect(decision.enabled);
    try std.testing.expectEqual(@as(?SoftwareCpuRouteDisableReason, null), decision.reason);
}

test "software cpu route decision disables when build cpu route is unavailable" {
    var input = softwareCpuRouteDecisionInputDefaults();
    input.cpu_route_build_effective = false;

    const decision = decideSoftwareCpuRoute(input);
    try std.testing.expect(!decision.enabled);
    try std.testing.expectEqual(
        SoftwareCpuRouteDisableReason.build_cpu_route_unavailable,
        decision.reason.?,
    );
}

test "software cpu route decision disables when renderer is not software" {
    var input = softwareCpuRouteDecisionInputDefaults();
    input.renderer_is_software = false;

    const decision = decideSoftwareCpuRoute(input);
    try std.testing.expect(!decision.enabled);
    try std.testing.expectEqual(
        SoftwareCpuRouteDisableReason.build_renderer_not_software,
        decision.reason.?,
    );
}

test "software cpu route decision disables when experimental is off" {
    var input = softwareCpuRouteDecisionInputDefaults();
    input.software_renderer_experimental = false;

    const decision = decideSoftwareCpuRoute(input);
    try std.testing.expect(!decision.enabled);
    try std.testing.expectEqual(
        SoftwareCpuRouteDisableReason.config_experimental_disabled,
        decision.reason.?,
    );
}

test "software cpu route decision disables when custom shaders are active and mode is off" {
    var input = softwareCpuRouteDecisionInputDefaults();
    input.custom_shaders_active = true;
    input.cpu_shader_mode = .off;

    const decision = decideSoftwareCpuRoute(input);
    try std.testing.expect(!decision.enabled);
    try std.testing.expectEqual(SoftwareCpuRouteDisableReason.custom_shaders_mode_off, decision.reason.?);
}

test "software cpu route decision disables when custom shaders are active and mode is safe" {
    var input = softwareCpuRouteDecisionInputDefaults();
    input.custom_shaders_active = true;
    input.cpu_shader_mode = .safe;
    input.custom_shader_execution_capability_observed = true;
    input.cpu_shader_timeout_ms = 8;
    input.custom_shader_execution_unavailable_reason = .pipeline_compile_failed;
    input.custom_shader_execution_hint_source = .vk_icd_filenames;
    input.custom_shader_execution_hint_path = "/opt/swiftshader/icd.json";
    input.custom_shader_execution_hint_readable = false;

    const decision = decideSoftwareCpuRoute(input);
    try std.testing.expect(!decision.enabled);
    try std.testing.expectEqual(SoftwareCpuRouteDisableReason.custom_shaders_unsupported, decision.reason.?);
    try std.testing.expectEqual(
        @as(?cpu_renderer.RuntimeCapabilityUnavailableReason, .pipeline_compile_failed),
        decision.custom_shader_unavailable_reason,
    );
    try std.testing.expectEqual(
        @as(?cpu_renderer.VulkanDriverHintSource, .vk_icd_filenames),
        decision.custom_shader_unavailable_hint_source,
    );
    try std.testing.expectEqualStrings(
        "/opt/swiftshader/icd.json",
        decision.custom_shader_unavailable_hint_path.?,
    );
    try std.testing.expect(!decision.custom_shader_unavailable_hint_readable);
}

test "software cpu route decision safe mode prefers capability-unobserved over unsupported and timeout invalid" {
    var input = softwareCpuRouteDecisionInputDefaults();
    input.custom_shaders_active = true;
    input.cpu_shader_mode = .safe;
    input.custom_shader_execution_capability_observed = false;
    input.custom_shader_execution_available = false;
    input.cpu_shader_timeout_ms = 0;

    const decision = decideSoftwareCpuRoute(input);
    try std.testing.expect(!decision.enabled);
    try std.testing.expectEqual(
        SoftwareCpuRouteDisableReason.custom_shaders_capability_unobserved,
        decision.reason.?,
    );
}

test "software cpu route decision disables safe mode when timeout budget is zero" {
    var input = softwareCpuRouteDecisionInputDefaults();
    input.custom_shaders_active = true;
    input.cpu_shader_mode = .safe;
    input.custom_shader_execution_capability_observed = true;
    input.custom_shader_execution_available = true;
    input.cpu_shader_timeout_ms = 0;

    const decision = decideSoftwareCpuRoute(input);
    try std.testing.expect(!decision.enabled);
    try std.testing.expectEqual(
        SoftwareCpuRouteDisableReason.custom_shaders_safe_timeout_invalid,
        decision.reason.?,
    );
}

test "software cpu route decision safe mode prefers unsupported over timeout invalid" {
    var input = softwareCpuRouteDecisionInputDefaults();
    input.custom_shaders_active = true;
    input.cpu_shader_mode = .safe;
    input.custom_shader_execution_capability_observed = true;
    input.custom_shader_execution_available = false;
    input.cpu_shader_timeout_ms = 0;

    const decision = decideSoftwareCpuRoute(input);
    try std.testing.expect(!decision.enabled);
    try std.testing.expectEqual(SoftwareCpuRouteDisableReason.custom_shaders_unsupported, decision.reason.?);
}

test "software cpu route decision enables safe mode when execution is available and timeout is positive" {
    var input = softwareCpuRouteDecisionInputDefaults();
    input.custom_shaders_active = true;
    input.cpu_shader_mode = .safe;
    input.custom_shader_execution_capability_observed = true;
    input.custom_shader_execution_available = true;
    input.cpu_shader_timeout_ms = 16;

    const decision = decideSoftwareCpuRoute(input);
    try std.testing.expect(decision.enabled);
    try std.testing.expectEqual(@as(?SoftwareCpuRouteDisableReason, null), decision.reason);
}

test "software cpu route decision disables full mode when custom shader execution is unavailable" {
    var input = softwareCpuRouteDecisionInputDefaults();
    input.custom_shaders_active = true;
    input.cpu_shader_mode = .full;
    input.custom_shader_execution_capability_observed = true;
    input.custom_shader_execution_unavailable_reason = .runtime_init_failed;
    input.custom_shader_execution_hint_source = .vk_driver_files;
    input.custom_shader_execution_hint_path = "/opt/swiftshader/driver.json";
    input.custom_shader_execution_hint_readable = false;

    const decision = decideSoftwareCpuRoute(input);
    try std.testing.expect(!decision.enabled);
    try std.testing.expectEqual(SoftwareCpuRouteDisableReason.custom_shaders_unsupported, decision.reason.?);
    try std.testing.expectEqual(
        @as(?cpu_renderer.RuntimeCapabilityUnavailableReason, .runtime_init_failed),
        decision.custom_shader_unavailable_reason,
    );
    try std.testing.expectEqual(
        @as(?cpu_renderer.VulkanDriverHintSource, .vk_driver_files),
        decision.custom_shader_unavailable_hint_source,
    );
    try std.testing.expectEqualStrings(
        "/opt/swiftshader/driver.json",
        decision.custom_shader_unavailable_hint_path.?,
    );
    try std.testing.expect(!decision.custom_shader_unavailable_hint_readable);
}

test "software cpu route decision full mode prefers capability-unobserved over unsupported and transport gate" {
    var input = softwareCpuRouteDecisionInputDefaults();
    input.custom_shaders_active = true;
    input.cpu_shader_mode = .full;
    input.custom_shader_execution_capability_observed = false;
    input.custom_shader_execution_available = false;
    input.transport_mode_native = true;

    const decision = decideSoftwareCpuRoute(input);
    try std.testing.expect(!decision.enabled);
    try std.testing.expectEqual(
        SoftwareCpuRouteDisableReason.custom_shaders_capability_unobserved,
        decision.reason.?,
    );
}

test "software cpu route decision full mode still respects transport gate" {
    var input = softwareCpuRouteDecisionInputDefaults();
    input.custom_shaders_active = true;
    input.cpu_shader_mode = .full;
    input.custom_shader_execution_capability_observed = true;
    input.custom_shader_execution_available = true;
    input.transport_mode_native = true;

    const decision = decideSoftwareCpuRoute(input);
    try std.testing.expect(!decision.enabled);
    try std.testing.expectEqual(SoftwareCpuRouteDisableReason.transport_native, decision.reason.?);
}

test "software cpu route decision full mode prefers unsupported over transport gate" {
    var input = softwareCpuRouteDecisionInputDefaults();
    input.custom_shaders_active = true;
    input.cpu_shader_mode = .full;
    input.custom_shader_execution_capability_observed = true;
    input.custom_shader_execution_available = false;
    input.transport_mode_native = true;

    const decision = decideSoftwareCpuRoute(input);
    try std.testing.expect(!decision.enabled);
    try std.testing.expectEqual(SoftwareCpuRouteDisableReason.custom_shaders_unsupported, decision.reason.?);
}

test "software cpu route decision enables full mode when custom shader execution is available" {
    var input = softwareCpuRouteDecisionInputDefaults();
    input.custom_shaders_active = true;
    input.cpu_shader_mode = .full;
    input.custom_shader_execution_capability_observed = true;
    input.custom_shader_execution_available = true;

    const decision = decideSoftwareCpuRoute(input);
    try std.testing.expect(decision.enabled);
    try std.testing.expectEqual(@as(?SoftwareCpuRouteDisableReason, null), decision.reason);
}

test "software cpu route decision disables when presenter is legacy-gl" {
    var input = softwareCpuRouteDecisionInputDefaults();
    input.software_renderer_presenter = .@"legacy-gl";

    const decision = decideSoftwareCpuRoute(input);
    try std.testing.expect(!decision.enabled);
    try std.testing.expectEqual(SoftwareCpuRouteDisableReason.config_presenter_legacy_gl, decision.reason.?);
}

test "software cpu route decision disables when transport mode is native" {
    var input = softwareCpuRouteDecisionInputDefaults();
    input.transport_mode_native = true;

    const decision = decideSoftwareCpuRoute(input);
    try std.testing.expect(!decision.enabled);
    try std.testing.expectEqual(SoftwareCpuRouteDisableReason.transport_native, decision.reason.?);
}

test "software cpu route decision reason priority keeps runtime gate first" {
    var input = softwareCpuRouteDecisionInputDefaults();
    input.software_frame_publishing = false;
    input.custom_shaders_active = true;
    input.transport_mode_native = true;

    const decision = decideSoftwareCpuRoute(input);
    try std.testing.expect(!decision.enabled);
    try std.testing.expectEqual(SoftwareCpuRouteDisableReason.runtime_publishing_disabled, decision.reason.?);
}

test "cpu route diagnostics tracks custom shader fallback count and reason" {
    var diagnostics: CpuRouteDiagnosticsState = .{};
    var capability_input = softwareCpuRouteDecisionInputDefaults();
    capability_input.custom_shader_execution_capability_observed = true;
    capability_input.custom_shader_execution_available = false;
    capability_input.custom_shader_execution_unavailable_reason = .pipeline_compile_failed;
    capability_input.custom_shader_execution_hint_source = .vk_driver_files;
    capability_input.custom_shader_execution_hint_path = "/opt/swiftshader/driver.json";
    capability_input.custom_shader_execution_hint_readable = true;
    capability_input.custom_shader_probe_minimal_runtime_enabled = true;
    diagnostics.recordCapabilityObservation(capability_input);
    var route_input_custom = softwareCpuRouteDecisionInputDefaults();
    route_input_custom.custom_shaders_active = true;
    diagnostics.recordRouteDecision(route_input_custom, .{
        .enabled = false,
        .reason = .custom_shaders_mode_off,
    });
    diagnostics.recordRouteDecision(softwareCpuRouteDecisionInputDefaults(), .{
        .enabled = true,
        .reason = null,
    });
    diagnostics.recordRouteDecision(route_input_custom, .{
        .enabled = false,
        .reason = .runtime_publishing_disabled,
    });
    diagnostics.recordRouteDecision(route_input_custom, .{
        .enabled = false,
        .reason = .custom_shaders_unsupported,
    });
    diagnostics.recordRouteDecision(route_input_custom, .{
        .enabled = false,
        .reason = .custom_shaders_safe_timeout_invalid,
    });
    diagnostics.recordRouteDecision(route_input_custom, .{
        .enabled = true,
        .reason = null,
    });

    const snapshot = diagnostics.snapshot();
    try std.testing.expectEqual(@as(u64, 3), snapshot.custom_shader_fallback_count);
    try std.testing.expectEqual(@as(u64, 1), snapshot.custom_shader_bypass_count);
    try std.testing.expectEqual(@as(u64, 0), snapshot.publish_retry_count);
    try std.testing.expectEqual(
        cpu_custom_shader_capability_reprobe_interval_frames,
        snapshot.cpu_shader_reprobe_interval_frames,
    );
    try std.testing.expectEqual(@as(u64, 0), snapshot.cpu_damage_rect_count);
    try std.testing.expectEqual(@as(u64, 0), snapshot.cpu_damage_rect_overflow_count);
    try std.testing.expectEqualStrings(
        @tagName(software_renderer_cpu_frame_damage_mode),
        snapshot.cpu_frame_damage_mode,
    );
    try std.testing.expectEqual(
        software_renderer_cpu_damage_rect_cap,
        snapshot.cpu_damage_rect_cap,
    );
    try std.testing.expectEqual(@as(u64, 0), snapshot.cpu_publish_skipped_no_damage_count);
    try std.testing.expectEqual(@as(u64, 0), snapshot.cpu_publish_latency_warning_count);
    try std.testing.expectEqual(@as(?u64, null), snapshot.last_cpu_publish_latency_warning_frame_ms);
    try std.testing.expectEqual(@as(u8, 0), snapshot.last_cpu_publish_latency_warning_consecutive_count);
    try std.testing.expectEqual(
        cpu_frame_publish_warning_threshold_ms,
        snapshot.cpu_publish_warning_threshold_ms,
    );
    try std.testing.expectEqual(
        cpu_frame_publish_warning_consecutive_limit,
        snapshot.cpu_publish_warning_consecutive_limit,
    );
    try std.testing.expectEqual(@as(u64, 0), snapshot.cpu_publish_retry_invalid_surface_count);
    try std.testing.expectEqual(@as(u64, 0), snapshot.cpu_publish_retry_pool_pressure_count);
    try std.testing.expectEqual(@as(u64, 0), snapshot.cpu_publish_retry_pool_exhausted_count);
    try std.testing.expectEqual(@as(u64, 0), snapshot.cpu_publish_retry_mailbox_backpressure_count);
    try std.testing.expectEqual(@as(u64, 0), snapshot.cpu_retired_pool_pressure_warning_count);
    try std.testing.expectEqual(@as(u64, 0), snapshot.cpu_frame_pool_exhausted_warning_count);
    try std.testing.expectEqualStrings("n/a", snapshot.last_cpu_publish_retry_reason);
    try std.testing.expectEqualStrings("n/a", snapshot.last_cpu_frame_pool_warning_reason);
    try std.testing.expectEqual(@as(?u64, null), snapshot.last_cpu_frame_ms);
    try std.testing.expectEqual(@as(?SoftwareCpuRouteDisableReason, null), snapshot.last_fallback_reason);
    try std.testing.expectEqualStrings("none", snapshot.last_fallback_scope);
    try std.testing.expectEqual(software_renderer_cpu_effective, snapshot.build_cpu_route_effective);
    try std.testing.expectEqual(
        build_config.software_renderer_cpu_mvp,
        snapshot.build_cpu_route_mvp_requested,
    );
    try std.testing.expectEqualStrings(
        @tagName(buildCpuRouteAvailabilitySourceForCurrentBuild()),
        snapshot.build_cpu_route_source,
    );
    try std.testing.expectEqual(
        buildCpuRouteTargetOsSupported(builtin.target.os.tag),
        snapshot.build_cpu_route_target_os_supported,
    );
    try std.testing.expectEqual(
        build_config.software_renderer_cpu_allow_legacy_os,
        snapshot.build_cpu_route_allow_legacy_os,
    );
    try std.testing.expect(snapshot.shader_capability_observed);
    try std.testing.expect(!snapshot.shader_capability_available);
    try std.testing.expect(snapshot.shader_minimal_runtime_enabled);
    try std.testing.expectEqual(
        build_config.software_renderer_cpu_shader_backend,
        snapshot.cpu_shader_backend,
    );
    try std.testing.expectEqualStrings("pipeline_compile_failed", snapshot.shader_capability_reason);
    try std.testing.expectEqualStrings("vk_driver_files", snapshot.shader_capability_hint_source);
    try std.testing.expectEqualStrings("/opt/swiftshader/driver.json", snapshot.shader_capability_hint_path);
    try std.testing.expect(snapshot.shader_capability_hint_readable);
}

test "cpu route diagnostics counts capability-unobserved as custom shader fallback" {
    var diagnostics: CpuRouteDiagnosticsState = .{};
    var route_input_custom = softwareCpuRouteDecisionInputDefaults();
    route_input_custom.custom_shaders_active = true;
    diagnostics.recordRouteDecision(route_input_custom, .{
        .enabled = false,
        .reason = .custom_shaders_capability_unobserved,
    });

    const snapshot = diagnostics.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snapshot.custom_shader_fallback_count);
    try std.testing.expectEqual(@as(u64, 0), snapshot.custom_shader_bypass_count);
    try std.testing.expectEqual(
        @as(?SoftwareCpuRouteDisableReason, .custom_shaders_capability_unobserved),
        snapshot.last_fallback_reason,
    );
    try std.testing.expectEqualStrings("runtime", snapshot.last_fallback_scope);
}

test "cpu route diagnostics increments custom shader bypass only for enabled custom route" {
    var diagnostics: CpuRouteDiagnosticsState = .{};

    const no_custom_input = softwareCpuRouteDecisionInputDefaults();
    const no_custom_decision = decideSoftwareCpuRoute(no_custom_input);
    try std.testing.expect(no_custom_decision.enabled);

    var custom_disabled_input = softwareCpuRouteDecisionInputDefaults();
    custom_disabled_input.custom_shaders_active = true;
    custom_disabled_input.cpu_shader_mode = .full;
    custom_disabled_input.custom_shader_execution_capability_observed = true;
    custom_disabled_input.custom_shader_execution_available = true;
    custom_disabled_input.transport_mode_native = true;
    const custom_disabled_decision = decideSoftwareCpuRoute(custom_disabled_input);
    try std.testing.expect(!custom_disabled_decision.enabled);

    var custom_enabled_input = custom_disabled_input;
    custom_enabled_input.transport_mode_native = false;
    const custom_enabled_decision = decideSoftwareCpuRoute(custom_enabled_input);
    try std.testing.expect(custom_enabled_decision.enabled);

    diagnostics.recordRouteDecision(no_custom_input, no_custom_decision);
    diagnostics.recordRouteDecision(custom_disabled_input, custom_disabled_decision);
    diagnostics.recordRouteDecision(custom_enabled_input, custom_enabled_decision);

    const snapshot = diagnostics.snapshot();
    try std.testing.expectEqual(@as(u64, 0), snapshot.custom_shader_fallback_count);
    try std.testing.expectEqual(@as(u64, 1), snapshot.custom_shader_bypass_count);
    try std.testing.expectEqual(@as(?SoftwareCpuRouteDisableReason, null), snapshot.last_fallback_reason);
    try std.testing.expectEqualStrings("none", snapshot.last_fallback_scope);
}

test "cpu route diagnostics snapshot defaults include capability reprobe count" {
    const snapshot = cpuRouteDiagnosticsSnapshotDefaults();
    try std.testing.expectEqual(@as(u64, 0), snapshot.cpu_shader_capability_reprobe_count);
    try std.testing.expectEqual(
        cpu_custom_shader_capability_reprobe_interval_frames,
        snapshot.cpu_shader_reprobe_interval_frames,
    );
    try std.testing.expectEqualStrings(
        @tagName(software_renderer_cpu_frame_damage_mode),
        snapshot.cpu_frame_damage_mode,
    );
    try std.testing.expectEqual(
        software_renderer_cpu_damage_rect_cap,
        snapshot.cpu_damage_rect_cap,
    );
    try std.testing.expectEqual(
        cpu_frame_publish_warning_threshold_ms,
        snapshot.cpu_publish_warning_threshold_ms,
    );
    try std.testing.expectEqual(
        cpu_frame_publish_warning_consecutive_limit,
        snapshot.cpu_publish_warning_consecutive_limit,
    );
    try std.testing.expectEqual(@as(u64, 0), snapshot.cpu_publish_retry_invalid_surface_count);
    try std.testing.expectEqual(@as(u64, 0), snapshot.cpu_publish_retry_pool_pressure_count);
    try std.testing.expectEqual(@as(u64, 0), snapshot.cpu_publish_retry_pool_exhausted_count);
    try std.testing.expectEqual(@as(u64, 0), snapshot.cpu_publish_retry_mailbox_backpressure_count);
    try std.testing.expectEqual(@as(u64, 0), snapshot.cpu_retired_pool_pressure_warning_count);
    try std.testing.expectEqual(@as(u64, 0), snapshot.cpu_frame_pool_exhausted_warning_count);
    try std.testing.expectEqualStrings("n/a", snapshot.last_cpu_publish_retry_reason);
    try std.testing.expectEqualStrings("n/a", snapshot.last_cpu_frame_pool_warning_reason);
    try std.testing.expectEqual(@as(?u64, null), snapshot.last_cpu_publish_latency_warning_frame_ms);
    try std.testing.expectEqual(@as(u8, 0), snapshot.last_cpu_publish_latency_warning_consecutive_count);
}

test "cpu route diagnostics tracks cpu shader capability reprobe count" {
    var diagnostics: CpuRouteDiagnosticsState = .{};
    diagnostics.recordCpuShaderCapabilityReprobe();
    diagnostics.recordCpuShaderCapabilityReprobe();

    const snapshot = diagnostics.snapshot();
    try std.testing.expectEqual(@as(u64, 2), snapshot.cpu_shader_capability_reprobe_count);
}

test "cpu route diagnostics tracks publish retry and cpu frame publish duration" {
    var diagnostics: CpuRouteDiagnosticsState = .{};
    var capability_input = softwareCpuRouteDecisionInputDefaults();
    capability_input.custom_shader_execution_capability_observed = true;
    capability_input.custom_shader_execution_available = true;
    capability_input.custom_shader_execution_unavailable_reason = null;
    capability_input.custom_shader_probe_minimal_runtime_enabled = false;
    diagnostics.recordCapabilityObservation(capability_input);
    diagnostics.recordPublishRetryReason(.pool_retired_pressure);
    diagnostics.recordPublishRetryReason(.mailbox_backpressure);
    diagnostics.recordDamageStats(3, 1);
    diagnostics.recordPublishSkippedNoDamage();
    diagnostics.recordPublishSkippedNoDamage();
    diagnostics.recordCpuPublishLatencyWarning(17, cpu_frame_publish_warning_consecutive_limit);
    diagnostics.recordCpuFramePublished((17 * std.time.ns_per_ms) + (500 * std.time.ns_per_us));

    const snapshot = diagnostics.snapshot();
    try std.testing.expectEqual(@as(u64, 0), snapshot.custom_shader_fallback_count);
    try std.testing.expectEqual(@as(u64, 0), snapshot.custom_shader_bypass_count);
    try std.testing.expectEqual(@as(u64, 2), snapshot.publish_retry_count);
    try std.testing.expectEqual(@as(u64, 3), snapshot.cpu_damage_rect_count);
    try std.testing.expectEqual(@as(u64, 1), snapshot.cpu_damage_rect_overflow_count);
    try std.testing.expectEqual(@as(u64, 2), snapshot.cpu_publish_skipped_no_damage_count);
    try std.testing.expectEqual(@as(u64, 1), snapshot.cpu_publish_latency_warning_count);
    try std.testing.expectEqual(@as(?u64, 17), snapshot.last_cpu_publish_latency_warning_frame_ms);
    try std.testing.expectEqual(
        cpu_frame_publish_warning_consecutive_limit,
        snapshot.last_cpu_publish_latency_warning_consecutive_count,
    );
    try std.testing.expectEqual(@as(u64, 0), snapshot.cpu_publish_retry_invalid_surface_count);
    try std.testing.expectEqual(@as(u64, 1), snapshot.cpu_publish_retry_pool_pressure_count);
    try std.testing.expectEqual(@as(u64, 0), snapshot.cpu_publish_retry_pool_exhausted_count);
    try std.testing.expectEqual(@as(u64, 1), snapshot.cpu_publish_retry_mailbox_backpressure_count);
    try std.testing.expectEqual(@as(u64, 0), snapshot.cpu_retired_pool_pressure_warning_count);
    try std.testing.expectEqual(@as(u64, 0), snapshot.cpu_frame_pool_exhausted_warning_count);
    try std.testing.expectEqualStrings("mailbox_backpressure", snapshot.last_cpu_publish_retry_reason);
    try std.testing.expectEqualStrings("n/a", snapshot.last_cpu_frame_pool_warning_reason);
    try std.testing.expectEqual(@as(?u64, 17), snapshot.last_cpu_frame_ms);
    try std.testing.expectEqual(@as(?SoftwareCpuRouteDisableReason, null), snapshot.last_fallback_reason);
    try std.testing.expectEqualStrings("none", snapshot.last_fallback_scope);
    try std.testing.expect(snapshot.shader_capability_observed);
    try std.testing.expect(snapshot.shader_capability_available);
    try std.testing.expect(!snapshot.shader_minimal_runtime_enabled);
    try std.testing.expectEqual(
        build_config.software_renderer_cpu_shader_backend,
        snapshot.cpu_shader_backend,
    );
    try std.testing.expectEqualStrings("n/a", snapshot.shader_capability_reason);
    try std.testing.expectEqualStrings("n/a", snapshot.shader_capability_hint_source);
    try std.testing.expectEqualStrings("n/a", snapshot.shader_capability_hint_path);
    try std.testing.expect(!snapshot.shader_capability_hint_readable);
}

test "cpu route diagnostics tracks publish retry reason buckets" {
    var diagnostics: CpuRouteDiagnosticsState = .{};
    diagnostics.recordPublishRetryReason(.invalid_surface);
    diagnostics.recordPublishRetryReason(.pool_retired_pressure);
    diagnostics.recordPublishRetryReason(.frame_pool_exhausted);
    diagnostics.recordPublishRetryReason(.mailbox_backpressure);

    const snapshot = diagnostics.snapshot();
    try std.testing.expectEqual(@as(u64, 4), snapshot.publish_retry_count);
    try std.testing.expectEqual(@as(u64, 1), snapshot.cpu_publish_retry_invalid_surface_count);
    try std.testing.expectEqual(@as(u64, 1), snapshot.cpu_publish_retry_pool_pressure_count);
    try std.testing.expectEqual(@as(u64, 1), snapshot.cpu_publish_retry_pool_exhausted_count);
    try std.testing.expectEqual(@as(u64, 1), snapshot.cpu_publish_retry_mailbox_backpressure_count);
    try std.testing.expectEqualStrings("mailbox_backpressure", snapshot.last_cpu_publish_retry_reason);
}

test "cpu route diagnostics tracks frame pool warning counts and last reason" {
    var diagnostics: CpuRouteDiagnosticsState = .{};
    diagnostics.recordFramePoolWarning(.retired_pool_pressure);
    diagnostics.recordFramePoolWarning(.frame_pool_exhausted);
    diagnostics.recordFramePoolWarning(.frame_pool_exhausted);

    const snapshot = diagnostics.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snapshot.cpu_retired_pool_pressure_warning_count);
    try std.testing.expectEqual(@as(u64, 2), snapshot.cpu_frame_pool_exhausted_warning_count);
    try std.testing.expectEqualStrings("frame_pool_exhausted", snapshot.last_cpu_frame_pool_warning_reason);
    try std.testing.expectEqual(@as(u64, 0), snapshot.publish_retry_count);
}

test "cpu route diagnostics capability snapshot clears when observation is unavailable" {
    var diagnostics: CpuRouteDiagnosticsState = .{};
    var observed_input = softwareCpuRouteDecisionInputDefaults();
    observed_input.custom_shader_execution_capability_observed = true;
    observed_input.custom_shader_execution_available = false;
    observed_input.custom_shader_execution_unavailable_reason = .runtime_init_failed;
    observed_input.custom_shader_execution_hint_source = .vk_icd_filenames;
    observed_input.custom_shader_execution_hint_path = "/opt/swiftshader/icd.json";
    observed_input.custom_shader_execution_hint_readable = true;
    observed_input.custom_shader_probe_minimal_runtime_enabled = true;
    diagnostics.recordCapabilityObservation(observed_input);

    var unobserved_input = softwareCpuRouteDecisionInputDefaults();
    unobserved_input.custom_shader_execution_capability_observed = false;
    // Unobserved capability should never report available=true in diagnostics.
    unobserved_input.custom_shader_execution_available = true;
    unobserved_input.custom_shader_probe_minimal_runtime_enabled = cpuShaderMinimalRuntimeEnabledDefault();
    diagnostics.recordCapabilityObservation(unobserved_input);

    const snapshot = diagnostics.snapshot();
    try std.testing.expect(!snapshot.shader_capability_observed);
    try std.testing.expect(!snapshot.shader_capability_available);
    try std.testing.expectEqual(
        cpuShaderMinimalRuntimeEnabledDefault(),
        snapshot.shader_minimal_runtime_enabled,
    );
    try std.testing.expectEqualStrings("n/a", snapshot.shader_capability_reason);
    try std.testing.expectEqualStrings("n/a", snapshot.shader_capability_hint_source);
    try std.testing.expectEqualStrings("n/a", snapshot.shader_capability_hint_path);
    try std.testing.expect(!snapshot.shader_capability_hint_readable);
}

test "cpu custom shader capability reprobe reason policy" {
    try std.testing.expect(!cpuCustomShaderCapabilityReasonCanReprobe(.backend_disabled));
    try std.testing.expect(!cpuCustomShaderCapabilityReasonCanReprobe(.backend_unavailable));
    try std.testing.expect(cpuCustomShaderCapabilityReasonCanReprobe(.runtime_init_failed));
    try std.testing.expect(cpuCustomShaderCapabilityReasonCanReprobe(.pipeline_compile_failed));
    try std.testing.expect(cpuCustomShaderCapabilityReasonCanReprobe(.execution_timeout));
    try std.testing.expect(!cpuCustomShaderCapabilityReasonCanReprobe(.minimal_runtime_disabled));
    try std.testing.expect(cpuCustomShaderCapabilityReasonCanReprobe(.device_lost));
}

test "shader capability reason derives from cpu runtime capability reason" {
    try std.testing.expectEqualStrings(
        "capability-unobserved",
        shaderCapabilityReasonForDisableReason(
            .custom_shaders_capability_unobserved,
            .runtime_init_failed,
        ),
    );
    try std.testing.expectEqualStrings(
        "runtime_init_failed",
        shaderCapabilityReasonForDisableReason(
            .custom_shaders_unsupported,
            .runtime_init_failed,
        ),
    );
    try std.testing.expectEqualStrings(
        "unknown",
        shaderCapabilityReasonForDisableReason(
            .custom_shaders_unsupported,
            null,
        ),
    );
    try std.testing.expectEqualStrings(
        "n/a",
        shaderCapabilityReasonForDisableReason(
            .transport_native,
            .backend_unavailable,
        ),
    );
    try std.testing.expectEqualStrings(
        "vk_driver_files",
        shaderCapabilityHintSourceForDisableReason(
            .custom_shaders_unsupported,
            .vk_driver_files,
        ),
    );
    try std.testing.expectEqualStrings(
        "none",
        shaderCapabilityHintSourceForDisableReason(
            .custom_shaders_unsupported,
            null,
        ),
    );
    try std.testing.expectEqualStrings(
        "/opt/swiftshader/icd.json",
        shaderCapabilityHintPathForDisableReason(
            .custom_shaders_unsupported,
            "/opt/swiftshader/icd.json",
        ),
    );
    try std.testing.expectEqualStrings(
        "none",
        shaderCapabilityHintPathForDisableReason(
            .custom_shaders_unsupported,
            null,
        ),
    );
    try std.testing.expect(shaderCapabilityHintReadableForDisableReason(
        .custom_shaders_unsupported,
        true,
    ));
    try std.testing.expect(!shaderCapabilityHintReadableForDisableReason(
        .transport_native,
        true,
    ));
    try std.testing.expectEqualStrings(
        "n/a",
        shaderCapabilityHintSourceForDisableReason(
            .custom_shaders_capability_unobserved,
            .vk_driver_files,
        ),
    );
    try std.testing.expectEqualStrings(
        "n/a",
        shaderCapabilityHintPathForDisableReason(
            .custom_shaders_capability_unobserved,
            "/opt/swiftshader/icd.json",
        ),
    );
    try std.testing.expect(!shaderCapabilityHintReadableForDisableReason(
        .custom_shaders_capability_unobserved,
        true,
    ));
}

test "custom shader probe minimal runtime follows cpu probe field" {
    const probe: cpu_renderer.CustomShaderExecutionProbe = .{
        .status = .available,
        .backend = build_config.software_renderer_cpu_shader_backend,
        .timeout_ms = 42,
        .enable_minimal_runtime = true,
    };

    try std.testing.expect(customShaderProbeMinimalRuntimeEnabled(probe));
}

test "cpu frame publish warning requires capability-ready consecutive slow frames" {
    var state: CpuFramePublishWarningState = .{};
    var snapshot = cpuRouteDiagnosticsSnapshotDefaults();
    snapshot.last_cpu_frame_ms = cpu_frame_publish_warning_threshold_ms + 1;
    snapshot.shader_capability_observed = true;
    snapshot.shader_capability_available = true;
    snapshot.shader_minimal_runtime_enabled = true;

    try std.testing.expect(!updateCpuFramePublishWarningState(&state, snapshot));
    try std.testing.expectEqual(@as(u8, 1), state.consecutive_over_threshold);
    try std.testing.expect(!state.warned);

    try std.testing.expect(!updateCpuFramePublishWarningState(&state, snapshot));
    try std.testing.expectEqual(@as(u8, 2), state.consecutive_over_threshold);
    try std.testing.expect(!state.warned);

    try std.testing.expect(updateCpuFramePublishWarningState(&state, snapshot));
    try std.testing.expect(state.warned);

    // Same condition should not emit repeatedly once warned.
    try std.testing.expect(!updateCpuFramePublishWarningState(&state, snapshot));
}

test "cpu frame publish warning resets on fast frame or capability-not-ready" {
    var state: CpuFramePublishWarningState = .{
        .consecutive_over_threshold = cpu_frame_publish_warning_consecutive_limit,
        .warned = true,
    };

    var fast_snapshot = cpuRouteDiagnosticsSnapshotDefaults();
    fast_snapshot.last_cpu_frame_ms = cpu_frame_publish_warning_threshold_ms;
    fast_snapshot.shader_capability_observed = true;
    fast_snapshot.shader_capability_available = true;
    fast_snapshot.shader_minimal_runtime_enabled = true;
    try std.testing.expect(!updateCpuFramePublishWarningState(&state, fast_snapshot));
    try std.testing.expectEqual(@as(u8, 0), state.consecutive_over_threshold);
    try std.testing.expect(!state.warned);

    var no_capability_snapshot = cpuRouteDiagnosticsSnapshotDefaults();
    no_capability_snapshot.last_cpu_frame_ms = cpu_frame_publish_warning_threshold_ms + 100;
    no_capability_snapshot.shader_capability_observed = true;
    no_capability_snapshot.shader_capability_available = false;
    no_capability_snapshot.shader_minimal_runtime_enabled = true;
    state.consecutive_over_threshold = 2;
    try std.testing.expect(!updateCpuFramePublishWarningState(&state, no_capability_snapshot));
    try std.testing.expectEqual(@as(u8, 0), state.consecutive_over_threshold);
    try std.testing.expect(!state.warned);
}

test "cpu publish latency warning count increments only when warning is emitted" {
    var diagnostics: CpuRouteDiagnosticsState = .{};
    var state: CpuFramePublishWarningState = .{};
    var snapshot = cpuRouteDiagnosticsSnapshotDefaults();
    snapshot.last_cpu_frame_ms = cpu_frame_publish_warning_threshold_ms + 1;
    snapshot.shader_capability_observed = true;
    snapshot.shader_capability_available = true;
    snapshot.shader_minimal_runtime_enabled = true;

    var i: u8 = 0;
    while (i < cpu_frame_publish_warning_consecutive_limit) : (i += 1) {
        if (updateCpuFramePublishWarningState(&state, snapshot)) {
            diagnostics.recordCpuPublishLatencyWarning(
                snapshot.last_cpu_frame_ms.?,
                state.consecutive_over_threshold,
            );
        }
    }
    if (updateCpuFramePublishWarningState(&state, snapshot)) {
        diagnostics.recordCpuPublishLatencyWarning(
            snapshot.last_cpu_frame_ms.?,
            state.consecutive_over_threshold,
        );
    }

    const diagnostics_snapshot = diagnostics.snapshot();
    try std.testing.expectEqual(@as(u64, 1), diagnostics_snapshot.cpu_publish_latency_warning_count);
    try std.testing.expectEqual(
        @as(?u64, cpu_frame_publish_warning_threshold_ms + 1),
        diagnostics_snapshot.last_cpu_publish_latency_warning_frame_ms,
    );
    try std.testing.expectEqual(
        cpu_frame_publish_warning_consecutive_limit,
        diagnostics_snapshot.last_cpu_publish_latency_warning_consecutive_count,
    );
}

test "cpu route diagnostics kv helpers emit structured logs" {
    var snapshot = cpuRouteDiagnosticsSnapshotDefaults();
    snapshot.cpu_damage_rect_count = 3;
    snapshot.cpu_damage_rect_overflow_count = 1;
    snapshot.publish_retry_count = 4;
    snapshot.cpu_publish_retry_invalid_surface_count = 1;
    snapshot.cpu_publish_retry_pool_pressure_count = 1;
    snapshot.cpu_publish_retry_pool_exhausted_count = 1;
    snapshot.cpu_publish_retry_mailbox_backpressure_count = 1;
    snapshot.last_cpu_publish_retry_reason = "mailbox_backpressure";
    snapshot.cpu_publish_latency_warning_count = 1;
    snapshot.last_cpu_publish_latency_warning_frame_ms = 17;
    snapshot.last_cpu_publish_latency_warning_consecutive_count =
        cpu_frame_publish_warning_consecutive_limit;
    snapshot.last_cpu_frame_ms = 17;
    snapshot.shader_capability_observed = true;
    snapshot.shader_capability_available = true;
    snapshot.shader_minimal_runtime_enabled = true;

    logCpuDamageOverflowKv(snapshot);
    logCpuPublishRetryKv(snapshot, true);
    logCpuPublishWarningKv(snapshot);
    logCpuPublishSuccessKv(snapshot, false);
}

const DrawFrameSmokePipeline = struct {};

const DrawFrameSmokeShaderPkg = struct {
    const OpenGLShaders = @import("opengl/shaders.zig");

    pub const Uniforms = OpenGLShaders.Uniforms;
    pub const CellText = OpenGLShaders.CellText;
    pub const CellBg = OpenGLShaders.CellBg;
    pub const Image = OpenGLShaders.Image;
    pub const BgImage = OpenGLShaders.BgImage;

    pub const Shaders = struct {
        pipelines: struct {
            bg_color: DrawFrameSmokePipeline = .{},
            cell_bg: DrawFrameSmokePipeline = .{},
            cell_text: DrawFrameSmokePipeline = .{},
            image: DrawFrameSmokePipeline = .{},
            bg_image: DrawFrameSmokePipeline = .{},
        } = .{},
        post_pipelines: []const DrawFrameSmokePipeline = &.{},
        defunct: bool = false,

        pub fn deinit(self: *@This(), alloc: Allocator) void {
            _ = self;
            _ = alloc;
        }
    };
};

const DrawFrameSmokeGraphicsAPI = struct {
    const Self = @This();

    pub const Pipeline = DrawFrameSmokePipeline;
    pub const swap_chain_count = 1;
    pub const custom_shader_target: shadertoy.Target = .glsl;
    pub const custom_shader_y_is_down = false;
    pub const softwareFramePublicationOnCompletion = false;
    pub const shaders = DrawFrameSmokeShaderPkg;

    pub const Target = struct {
        width: u32 = 0,
        height: u32 = 0,

        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    pub const Texture = struct {
        width: u32 = 0,
        height: u32 = 0,

        pub fn init(
            _: anytype,
            width: u32,
            height: u32,
            _: anytype,
        ) !@This() {
            return .{
                .width = width,
                .height = height,
            };
        }

        pub fn deinit(self: @This()) void {
            _ = self;
        }

        pub fn replaceRegion(
            self: @This(),
            x: usize,
            y: usize,
            width: usize,
            height: usize,
            data: []const u8,
        ) !void {
            _ = self;
            _ = x;
            _ = y;
            _ = width;
            _ = height;
            _ = data;
        }
    };

    pub const Sampler = struct {
        pub fn init(_: anytype) !@This() {
            return .{};
        }

        pub fn deinit(self: @This()) void {
            _ = self;
        }
    };

    pub fn Buffer(comptime T: type) type {
        return struct {
            buffer: ?usize = null,
            len: usize = 0,

            pub fn init(_: anytype, len: usize) !@This() {
                _ = T;
                return .{ .len = len };
            }

            pub fn initFill(_: anytype, items: anytype) !@This() {
                _ = T;
                return .{
                    .len = switch (@typeInfo(@TypeOf(items))) {
                        .pointer => items.len,
                        else => 0,
                    },
                };
            }

            pub fn sync(self: *@This(), items: anytype) !void {
                self.len = switch (@typeInfo(@TypeOf(items))) {
                    .pointer => items.len,
                    else => self.len,
                };
            }

            pub fn syncFromArrayLists(self: *@This(), lists: anytype) !u32 {
                _ = self;
                _ = lists;
                return 0;
            }

            pub fn deinit(self: *@This()) void {
                _ = self;
            }
        };
    }

    pub const RenderPass = struct {
        pub const Options = struct {
            pub const Attachment = struct {
                target: union(enum) {
                    texture: Texture,
                    target: Target,
                },
                clear_color: ?[4]f32 = null,
            };
        };

        pub fn step(self: *@This(), _: anytype) void {
            _ = self;
        }

        pub fn complete(self: *@This()) void {
            _ = self;
        }
    };

    pub const FrameContext = struct {
        pub fn renderPass(
            self: *@This(),
            _: []const RenderPass.Options.Attachment,
        ) RenderPass {
            _ = self;
            return .{};
        }

        pub fn complete(self: *@This(), _: bool) void {
            _ = self;
        }
    };

    surface_size: renderer.ScreenSize,
    draw_frame_start_count: u32 = 0,
    draw_frame_end_count: u32 = 0,
    present_last_target_count: u32 = 0,
    blending: configpkg.Config.AlphaBlending = .native,

    pub fn init(_: Allocator, options: renderer.Options) !Self {
        return .{
            .surface_size = options.size.screen,
            .blending = options.config.blending,
        };
    }

    pub fn deinit(self: *@This()) void {
        _ = self;
    }

    pub fn initShaders(
        self: *@This(),
        alloc: Allocator,
        post_shaders: []const [:0]const u8,
    ) !shaders.Shaders {
        _ = self;
        _ = alloc;
        _ = post_shaders;
        return .{};
    }

    pub fn initAtlasTexture(self: *const @This(), atlas: anytype) !Texture {
        _ = self;
        _ = atlas;
        return .{};
    }

    pub fn initTarget(self: *const @This(), width: usize, height: usize) !Target {
        _ = self;
        return .{
            .width = @intCast(width),
            .height = @intCast(height),
        };
    }

    pub fn uniformBufferOptions(_: *const Self) void {}
    pub fn fgBufferOptions(_: *const Self) void {}
    pub fn bgBufferOptions(_: *const Self) void {}
    pub fn imageBufferOptions(_: *const Self) void {}
    pub fn bgImageBufferOptions(_: *const Self) void {}
    pub fn textureOptions(_: *const Self) void {}
    pub fn samplerOptions(_: *const Self) void {}
    pub fn imageTextureOptions(_: *const Self, _: anytype, _: bool) void {}

    pub fn surfaceInit(_: anytype) !void {}
    pub fn finalizeSurfaceInit(_: *@This(), _: anytype) !void {}
    pub fn threadEnter(_: *@This(), _: anytype) !void {}
    pub fn threadExit(_: *@This()) void {}
    pub fn loopEnter(_: *@This()) void {}
    pub fn loopExit(_: *@This()) void {}
    pub fn displayRealized(_: *@This()) void {}
    pub fn displayUnrealized(_: *@This()) void {}

    pub fn drawFrameStart(self: *@This()) void {
        self.draw_frame_start_count += 1;
    }

    pub fn drawFrameEnd(self: *@This()) void {
        self.draw_frame_end_count += 1;
    }

    pub fn surfaceSize(self: *const Self) !renderer.ScreenSize {
        return self.surface_size;
    }

    pub fn presentLastTarget(self: *@This()) !void {
        self.present_last_target_count += 1;
    }

    pub fn beginFrame(
        self: *@This(),
        _: anytype,
        _: *Target,
        _: bool,
        _: u32,
        _: u32,
    ) !FrameContext {
        _ = self;
        return .{};
    }

    pub fn publishSoftwareFrame(
        self: *@This(),
        _: *const Target,
        _: renderer.ScreenSize,
    ) !?apprt.surface.Message.SoftwareFrameReady {
        _ = self;
        return null;
    }
};

const DrawFrameSmokeRenderer = Renderer(DrawFrameSmokeGraphicsAPI);

const DrawFrameSmokeFixture = struct {
    renderer: DrawFrameSmokeRenderer = undefined,
    font_grid_set: font.SharedGridSet = undefined,
    font_grid_key: ?font.SharedGridSet.Key = null,
    app_queue: App.Mailbox.Queue = .{},
    rt_app: apprt.App = .{},
    fake_surface: Surface = undefined,
    fake_rt_surface: apprt.Surface = undefined,
    fake_thread: renderer.Thread = undefined,

    fn init(
        self: *DrawFrameSmokeFixture,
        alloc: Allocator,
        surface_size: renderer.ScreenSize,
    ) !void {
        self.app_queue = .{};
        self.rt_app = .{};
        self.fake_surface = undefined;
        self.fake_rt_surface = undefined;
        self.fake_thread = undefined;
        self.font_grid_key = null;

        var raw_config = try configpkg.Config.default(alloc);
        defer raw_config.deinit();
        raw_config.@"software-renderer-experimental" = true;
        raw_config.@"software-renderer-presenter" = .auto;

        self.font_grid_set = try font.SharedGridSet.init(alloc);
        errdefer self.font_grid_set.deinit();

        var font_config = try font.SharedGridSet.DerivedConfig.init(alloc, &raw_config);
        defer font_config.deinit();

        const font_grid_key, const font_grid = try self.font_grid_set.ref(
            &font_config,
            .{ .points = 12 },
        );
        errdefer self.font_grid_set.deref(font_grid_key);
        self.font_grid_key = font_grid_key;

        const empty_bg_cells = try alloc.alloc(DrawFrameSmokeShaderPkg.CellBg, 0);
        errdefer alloc.free(empty_bg_cells);
        const empty_fg_rows = try alloc.alloc(
            std.ArrayListUnmanaged(DrawFrameSmokeShaderPkg.CellText),
            0,
        );
        errdefer alloc.free(empty_fg_rows);

        self.renderer = try DrawFrameSmokeRenderer.init(alloc, .{
            .config = try DrawFrameSmokeRenderer.DerivedConfig.init(alloc, &raw_config),
            .font_grid = font_grid,
            .size = .{
                .screen = surface_size,
                .cell = font_grid.cellSize(),
                .padding = .{},
            },
            .surface_mailbox = .{
                .surface = &self.fake_surface,
                .app = .{
                    .rt_app = &self.rt_app,
                    .mailbox = &self.app_queue,
                },
            },
            .rt_surface = &self.fake_rt_surface,
            .thread = &self.fake_thread,
        });
        self.renderer.cells = .{
            .bg_cells = empty_bg_cells,
            .fg_rows = .{ .lists = empty_fg_rows },
        };
        self.renderer.cells_rebuilt = false;
    }

    fn deinit(self: *DrawFrameSmokeFixture) void {
        _ = self.drainSurfaceMailboxAndReleaseFrames();
        self.renderer.deinit();
        if (self.font_grid_key) |key| self.font_grid_set.deref(key);
        self.font_grid_set.deinit();
        self.* = undefined;
    }

    fn drainSurfaceMailboxAndReleaseFrames(self: *DrawFrameSmokeFixture) usize {
        var released: usize = 0;
        while (self.app_queue.pop()) |msg| switch (msg) {
            .surface_message => |surface_msg| {
                _ = surface_msg.surface;
                switch (surface_msg.message) {
                    .software_frame_ready => |frame| {
                        frame.release();
                        released += 1;
                    },
                    else => {},
                }
            },
            else => {},
        };

        return released;
    }

    fn fillAppQueue(self: *DrawFrameSmokeFixture) usize {
        var count: usize = 0;
        while (self.app_queue.push(.quit, .instant) > 0) {
            count += 1;
        }

        return count;
    }

    fn initSingleCellGrid(
        self: *DrawFrameSmokeFixture,
        rgba: DrawFrameSmokeShaderPkg.CellBg,
    ) !void {
        try self.renderer.cells.resize(self.renderer.alloc, .{
            .rows = 1,
            .columns = 1,
        });
        self.renderer.uniforms.grid_size = .{ 1, 1 };
        self.renderer.cells.bgCell(0, 0).* = rgba;
    }

    fn setConfiguredBgImagePath(
        self: *DrawFrameSmokeFixture,
        path: []const u8,
    ) !void {
        self.renderer.config.bg_image = .{
            .required = try self.renderer.config.arena.allocator().dupeZ(u8, path),
        };
    }
};

test "drawFrame software cpu smoke retries exhausted pool and clears platform transient state" {
    if (build_config.renderer != .software) return error.SkipZigTest;
    if (!software_renderer_cpu_effective) return error.SkipZigTest;
    if (build_config.software_frame_transport_mode == .native) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const surface_size: renderer.ScreenSize = .{
        .width = 4,
        .height = 4,
    };

    var smoke: DrawFrameSmokeFixture = undefined;
    try smoke.init(alloc, surface_size);
    defer smoke.deinit();

    smoke.renderer.cpu_frame_pool = try cpu_renderer.FramePool.init(
        alloc,
        3,
        surface_size.width,
        surface_size.height,
        .bgra8_premul,
        software_renderer_cpu_damage_rect_pool_capacity,
    );

    var acquired: [3]cpu_renderer.FramePool.Acquired = undefined;
    for (&acquired) |*slot| {
        slot.* = smoke.renderer.cpu_frame_pool.?.acquire() orelse return error.TestUnexpectedResult;
    }

    smoke.renderer.cpu_frame_publish_warning = .{
        .consecutive_over_threshold = cpu_frame_publish_warning_consecutive_limit,
        .warned = true,
    };

    try smoke.renderer.drawFrame(true);

    const retry_snapshot = smoke.renderer.cpu_route_diagnostics.snapshot();
    try std.testing.expect(smoke.renderer.cpu_publish_pending);
    try std.testing.expect(smoke.renderer.cells_rebuilt);
    try std.testing.expectEqual(@as(u64, 1), retry_snapshot.publish_retry_count);
    try std.testing.expectEqualStrings(
        "frame_pool_exhausted",
        retry_snapshot.last_cpu_publish_retry_reason,
    );
    try std.testing.expectEqual(@as(u64, 1), retry_snapshot.cpu_publish_retry_pool_exhausted_count);
    try std.testing.expectEqual(@as(u32, 1), smoke.renderer.api.draw_frame_start_count);
    try std.testing.expectEqual(@as(u32, 1), smoke.renderer.api.draw_frame_end_count);

    smoke.renderer.config.software_renderer_experimental = false;
    smoke.renderer.cells_rebuilt = false;

    try smoke.renderer.drawFrame(false);

    try std.testing.expect(!smoke.renderer.cpu_publish_pending);
    try std.testing.expectEqual(@as(u8, 0), smoke.renderer.cpu_frame_publish_warning.consecutive_over_threshold);
    try std.testing.expect(!smoke.renderer.cpu_frame_publish_warning.warned);
    try std.testing.expectEqual(@as(u32, 1), smoke.renderer.api.present_last_target_count);
    try std.testing.expectEqual(@as(u32, 2), smoke.renderer.api.draw_frame_start_count);
    try std.testing.expectEqual(@as(u32, 2), smoke.renderer.api.draw_frame_end_count);

    for (&acquired, 0..) |*slot, i| {
        const frame = smoke.renderer.cpu_frame_pool.?.publish(slot, @intCast(i), &.{});
        frame.release();
    }
}

test "drawFrame software cpu smoke mailbox backpressure keeps pending until platform route clears transient state" {
    if (build_config.renderer != .software) return error.SkipZigTest;
    if (!software_renderer_cpu_effective) return error.SkipZigTest;
    if (build_config.software_frame_transport_mode == .native) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const surface_size: renderer.ScreenSize = .{
        .width = 4,
        .height = 4,
    };

    var smoke: DrawFrameSmokeFixture = undefined;
    try smoke.init(alloc, surface_size);
    defer smoke.deinit();

    const filled_count = smoke.fillAppQueue();
    try std.testing.expectEqual(@as(usize, 64), filled_count);

    smoke.renderer.cpu_frame_publish_warning = .{
        .consecutive_over_threshold = cpu_frame_publish_warning_consecutive_limit,
        .warned = true,
    };
    smoke.renderer.cells_rebuilt = true;

    try smoke.renderer.drawFrame(true);

    var snapshot = smoke.renderer.cpu_route_diagnostics.snapshot();
    try std.testing.expect(smoke.renderer.cpu_publish_pending);
    try std.testing.expect(smoke.renderer.cells_rebuilt);
    try std.testing.expectEqual(@as(u64, 1), snapshot.publish_retry_count);
    try std.testing.expectEqualStrings(
        "mailbox_backpressure",
        snapshot.last_cpu_publish_retry_reason,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        snapshot.cpu_publish_retry_mailbox_backpressure_count,
    );
    try std.testing.expectEqual(@as(u32, 1), smoke.renderer.api.draw_frame_start_count);
    try std.testing.expectEqual(@as(u32, 1), smoke.renderer.api.draw_frame_end_count);
    try std.testing.expectEqual(@as(u32, 0), smoke.renderer.api.present_last_target_count);
    try std.testing.expectEqual(@as(usize, 0), smoke.drainSurfaceMailboxAndReleaseFrames());

    smoke.renderer.config.software_renderer_experimental = false;
    smoke.renderer.cells_rebuilt = false;

    try smoke.renderer.drawFrame(false);

    snapshot = smoke.renderer.cpu_route_diagnostics.snapshot();
    try std.testing.expect(!smoke.renderer.cpu_publish_pending);
    try std.testing.expectEqual(@as(u8, 0), smoke.renderer.cpu_frame_publish_warning.consecutive_over_threshold);
    try std.testing.expect(!smoke.renderer.cpu_frame_publish_warning.warned);
    try std.testing.expectEqual(@as(u64, 1), snapshot.publish_retry_count);
    try std.testing.expectEqual(@as(u32, 1), smoke.renderer.api.present_last_target_count);
    try std.testing.expectEqual(@as(u32, 2), smoke.renderer.api.draw_frame_start_count);
    try std.testing.expectEqual(@as(u32, 2), smoke.renderer.api.draw_frame_end_count);
}

test "drawFrame software cpu smoke zero surface returns before invalid surface retry" {
    if (build_config.renderer != .software) return error.SkipZigTest;
    if (!software_renderer_cpu_effective) return error.SkipZigTest;
    if (build_config.software_frame_transport_mode == .native) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const surface_size: renderer.ScreenSize = .{
        .width = 4,
        .height = 4,
    };

    var smoke: DrawFrameSmokeFixture = undefined;
    try smoke.init(alloc, surface_size);
    defer smoke.deinit();

    smoke.renderer.api.surface_size = .{
        .width = 0,
        .height = surface_size.height,
    };
    smoke.renderer.cells_rebuilt = true;

    try smoke.renderer.drawFrame(true);

    const snapshot = smoke.renderer.cpu_route_diagnostics.snapshot();
    try std.testing.expect(!smoke.renderer.cpu_publish_pending);
    try std.testing.expect(smoke.renderer.cells_rebuilt);
    try std.testing.expectEqual(@as(u64, 0), snapshot.publish_retry_count);
    try std.testing.expectEqual(@as(u64, 0), snapshot.cpu_publish_retry_invalid_surface_count);
    try std.testing.expect(smoke.renderer.cpu_frame_pool == null);
    try std.testing.expectEqual(@as(u32, 1), smoke.renderer.api.draw_frame_start_count);
    try std.testing.expectEqual(@as(u32, 1), smoke.renderer.api.draw_frame_end_count);
    try std.testing.expectEqual(@as(u32, 0), smoke.renderer.api.present_last_target_count);
}

test "drawFrame software cpu smoke published frame clears pending state and finalizes unloading background" {
    if (build_config.renderer != .software) return error.SkipZigTest;
    if (!software_renderer_cpu_effective) return error.SkipZigTest;
    if (build_config.software_frame_transport_mode == .native) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const surface_size: renderer.ScreenSize = .{
        .width = 4,
        .height = 4,
    };

    var smoke: DrawFrameSmokeFixture = undefined;
    try smoke.init(alloc, surface_size);
    defer smoke.deinit();

    smoke.renderer.bg_image = try makeOwnedPendingRgbaImage(
        DrawFrameSmokeRenderer.Image,
        alloc,
        1,
        1,
        &.{ 1, 2, 3, 255 },
    );
    clearConfiguredBackgroundImage(&smoke.renderer.bg_image);
    try std.testing.expect(smoke.renderer.bg_image != null);
    try std.testing.expect(smoke.renderer.bg_image.?.isUnloading());

    smoke.renderer.config.bg_image = null;
    smoke.renderer.cpu_publish_pending = true;
    smoke.renderer.cells_rebuilt = true;

    try smoke.renderer.drawFrame(true);

    const snapshot = smoke.renderer.cpu_route_diagnostics.snapshot();
    try std.testing.expect(!smoke.renderer.cpu_publish_pending);
    try std.testing.expect(!smoke.renderer.cells_rebuilt);
    try std.testing.expect(smoke.renderer.bg_image == null);
    try std.testing.expectEqual(@as(u64, 0), snapshot.publish_retry_count);
    try std.testing.expectEqual(@as(u32, 1), smoke.renderer.api.draw_frame_start_count);
    try std.testing.expectEqual(@as(u32, 1), smoke.renderer.api.draw_frame_end_count);
    try std.testing.expectEqual(@as(u32, 0), smoke.renderer.api.present_last_target_count);
    try std.testing.expectEqual(@as(usize, 1), smoke.drainSurfaceMailboxAndReleaseFrames());
}

test "drawFrame software cpu smoke published frame keeps unloading background slot and uses non-empty grid" {
    if (build_config.renderer != .software) return error.SkipZigTest;
    if (!software_renderer_cpu_effective) return error.SkipZigTest;
    if (build_config.software_frame_transport_mode == .native) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const surface_size: renderer.ScreenSize = .{
        .width = 4,
        .height = 4,
    };

    var smoke: DrawFrameSmokeFixture = undefined;
    try smoke.init(alloc, surface_size);
    defer smoke.deinit();

    try smoke.initSingleCellGrid(.{ 10, 20, 30, 255 });
    try smoke.setConfiguredBgImagePath("/tmp/ghostty-smoke-bg.png");

    smoke.renderer.bg_image = try makeOwnedPendingRgbaImage(
        DrawFrameSmokeRenderer.Image,
        alloc,
        1,
        1,
        &.{ 1, 2, 3, 255 },
    );
    clearConfiguredBackgroundImage(&smoke.renderer.bg_image);
    smoke.renderer.cells_rebuilt = true;

    try smoke.renderer.drawFrame(true);

    const snapshot = smoke.renderer.cpu_route_diagnostics.snapshot();
    try std.testing.expect(!smoke.renderer.cpu_publish_pending);
    try std.testing.expect(!smoke.renderer.cells_rebuilt);
    try std.testing.expect(smoke.renderer.bg_image != null);
    try std.testing.expect(smoke.renderer.bg_image.?.isUnloading());
    try std.testing.expect(smoke.renderer.cpu_text_layer != null);
    try std.testing.expectEqual(@as(u32, 1), smoke.renderer.cells.size.rows);
    try std.testing.expectEqual(@as(u32, 1), smoke.renderer.cells.size.columns);
    try std.testing.expectEqual(@as(u64, 0), snapshot.publish_retry_count);
    try std.testing.expectEqual(@as(u32, 1), smoke.renderer.api.draw_frame_start_count);
    try std.testing.expectEqual(@as(u32, 1), smoke.renderer.api.draw_frame_end_count);
    try std.testing.expectEqual(@as(usize, 1), smoke.drainSurfaceMailboxAndReleaseFrames());
}

test "drawFrame software cpu smoke published frame route switch clears platform transient state" {
    if (build_config.renderer != .software) return error.SkipZigTest;
    if (!software_renderer_cpu_effective) return error.SkipZigTest;
    if (build_config.software_frame_transport_mode == .native) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const surface_size: renderer.ScreenSize = .{
        .width = 4,
        .height = 4,
    };

    var smoke: DrawFrameSmokeFixture = undefined;
    try smoke.init(alloc, surface_size);
    defer smoke.deinit();

    smoke.renderer.bg_image = try makeOwnedPendingRgbaImage(
        DrawFrameSmokeRenderer.Image,
        alloc,
        1,
        1,
        &.{ 1, 2, 3, 255 },
    );
    clearConfiguredBackgroundImage(&smoke.renderer.bg_image);
    smoke.renderer.config.bg_image = null;
    smoke.renderer.cpu_publish_pending = true;
    smoke.renderer.cells_rebuilt = true;

    try smoke.renderer.drawFrame(true);

    var snapshot = smoke.renderer.cpu_route_diagnostics.snapshot();
    try std.testing.expect(!smoke.renderer.cpu_publish_pending);
    try std.testing.expect(smoke.renderer.bg_image == null);
    try std.testing.expectEqual(@as(u64, 0), snapshot.publish_retry_count);

    smoke.renderer.cpu_publish_pending = true;
    smoke.renderer.cpu_frame_publish_warning = .{
        .consecutive_over_threshold = cpu_frame_publish_warning_consecutive_limit,
        .warned = true,
    };
    smoke.renderer.config.software_renderer_experimental = false;
    smoke.renderer.cells_rebuilt = false;

    try smoke.renderer.drawFrame(false);

    snapshot = smoke.renderer.cpu_route_diagnostics.snapshot();
    try std.testing.expect(!smoke.renderer.cpu_publish_pending);
    try std.testing.expectEqual(@as(u8, 0), smoke.renderer.cpu_frame_publish_warning.consecutive_over_threshold);
    try std.testing.expect(!smoke.renderer.cpu_frame_publish_warning.warned);
    try std.testing.expectEqual(@as(u64, 0), snapshot.publish_retry_count);
    try std.testing.expectEqual(@as(u32, 1), smoke.renderer.api.present_last_target_count);
    try std.testing.expectEqual(@as(u32, 2), smoke.renderer.api.draw_frame_start_count);
    try std.testing.expectEqual(@as(u32, 2), smoke.renderer.api.draw_frame_end_count);
    try std.testing.expectEqual(@as(usize, 1), smoke.drainSurfaceMailboxAndReleaseFrames());
}

test "drawFrame software cpu smoke no damage records skipped publish" {
    if (build_config.renderer != .software) return error.SkipZigTest;
    if (!software_renderer_cpu_effective) return error.SkipZigTest;
    if (build_config.software_frame_transport_mode == .native) return error.SkipZigTest;
    if (software_renderer_cpu_frame_damage_mode != .rects) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const surface_size: renderer.ScreenSize = .{
        .width = 4,
        .height = 4,
    };

    var smoke: DrawFrameSmokeFixture = undefined;
    try smoke.init(alloc, surface_size);
    defer smoke.deinit();

    try smoke.renderer.drawFrame(false);

    const snapshot = smoke.renderer.cpu_route_diagnostics.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snapshot.cpu_publish_skipped_no_damage_count);
    try std.testing.expectEqual(@as(u64, 0), snapshot.publish_retry_count);
    try std.testing.expect(!smoke.renderer.cpu_publish_pending);
    try std.testing.expectEqual(@as(u32, 0), smoke.renderer.api.present_last_target_count);
    try std.testing.expectEqual(@as(u32, 1), smoke.renderer.api.draw_frame_start_count);
    try std.testing.expectEqual(@as(u32, 1), smoke.renderer.api.draw_frame_end_count);
}

test "drawFrame software cpu smoke pool retired pressure keeps redraw pending" {
    if (build_config.renderer != .software) return error.SkipZigTest;
    if (!software_renderer_cpu_effective) return error.SkipZigTest;
    if (build_config.software_frame_transport_mode == .native) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const surface_size: renderer.ScreenSize = .{
        .width = 4,
        .height = 4,
    };

    var smoke: DrawFrameSmokeFixture = undefined;
    try smoke.init(alloc, surface_size);
    defer smoke.deinit();

    var current_pool = try GenericRendererTestPool.init(alloc, 1, 1);
    smoke.renderer.cpu_frame_pool = current_pool.pool;
    const current_frame = current_pool.frame;
    current_pool = undefined;

    var retired_frames: [max_retired_cpu_frame_pools]apprt.surface.Message.SoftwareFrameReady =
        undefined;
    var retired_count: usize = 0;
    defer {
        current_frame.release();
        for (retired_frames[0..retired_count]) |frame| frame.release();
    }

    for (0..max_retired_cpu_frame_pools) |i| {
        var retired_pool = try GenericRendererTestPool.init(alloc, 1, 1);
        try smoke.renderer.retired_cpu_frame_pools.append(
            alloc,
            retired_pool.pool,
        );
        retired_frames[i] = retired_pool.frame;
        retired_pool = undefined;
        retired_count += 1;
    }

    smoke.renderer.cells_rebuilt = true;

    try smoke.renderer.drawFrame(true);

    const snapshot = smoke.renderer.cpu_route_diagnostics.snapshot();
    try std.testing.expect(smoke.renderer.cpu_publish_pending);
    try std.testing.expect(smoke.renderer.cells_rebuilt);
    try std.testing.expectEqual(@as(u64, 1), snapshot.publish_retry_count);
    try std.testing.expectEqualStrings(
        "pool_retired_pressure",
        snapshot.last_cpu_publish_retry_reason,
    );
    try std.testing.expectEqual(@as(u64, 1), snapshot.cpu_publish_retry_pool_pressure_count);
    try std.testing.expectEqual(@as(u64, 1), snapshot.cpu_retired_pool_pressure_warning_count);
    try std.testing.expectEqualStrings(
        "retired_pool_pressure",
        snapshot.last_cpu_frame_pool_warning_reason,
    );
    try std.testing.expectEqual(@as(u32, 1), smoke.renderer.api.draw_frame_start_count);
    try std.testing.expectEqual(@as(u32, 1), smoke.renderer.api.draw_frame_end_count);
    try std.testing.expectEqual(@as(u32, 0), smoke.renderer.api.present_last_target_count);
}

const GenericRendererTestPool = struct {
    pool: cpu_renderer.FramePool,
    frame: apprt.surface.Message.SoftwareFrameReady,

    fn init(alloc: Allocator, width_px: u32, height_px: u32) !GenericRendererTestPool {
        var pool = try cpu_renderer.FramePool.init(
            alloc,
            1,
            width_px,
            height_px,
            .bgra8_premul,
            software_renderer_cpu_damage_rect_pool_capacity,
        );
        var acquired = pool.acquire() orelse return error.TestUnexpectedResult;
        return .{
            .pool = pool,
            .frame = pool.publish(&acquired, 1, &.{}),
        };
    }

    fn releaseAndDeinit(self: *GenericRendererTestPool) void {
        self.frame.release();
        self.pool.deinitIdle();
        self.* = undefined;
    }
};

fn expectFramebufferPixel(
    framebuffer: *const cpu_renderer.FrameBuffer,
    x: usize,
    y: usize,
    expected: [4]u8,
) !void {
    const stride = @as(usize, @intCast(framebuffer.stride_bytes));
    const off = y * stride + x * 4;
    try std.testing.expectEqualSlices(
        u8,
        expected[0..],
        framebuffer.bytes[off..][0..4],
    );
}

test "composeCpuBackground preserves translucent background alpha for opaque texels" {
    const alloc = std.testing.allocator;
    var framebuffer = try cpu_renderer.FrameBuffer.init(alloc, 1, 1, .bgra8_premul);
    defer framebuffer.deinit(alloc);

    const pixels = CpuImagePixels{
        .width = 1,
        .height = 1,
        .stride_bytes = 4,
        .data = &.{ 255, 0, 0, 255 },
    };

    try composeCpuBackgroundImageLegacy(
        alloc,
        &framebuffer,
        .{ 0, 0, 0, 128 },
        .{
            .opacity = 1.0,
            .fit = .none,
            .position = .mc,
            .repeat = false,
        },
        pixels,
    );

    try expectFramebufferPixel(&framebuffer, 0, 0, .{ 0, 0, 128, 128 });
}

test "composeCpuBackground stretch keeps scaled sampling stable across texel boundaries" {
    const alloc = std.testing.allocator;
    var framebuffer = try cpu_renderer.FrameBuffer.init(alloc, 4, 1, .bgra8_premul);
    defer framebuffer.deinit(alloc);

    const pixels = CpuImagePixels{
        .width = 2,
        .height = 1,
        .stride_bytes = 8,
        .data = &.{
            255, 0,   0, 255,
            0,   255, 0, 255,
        },
    };

    try composeCpuBackgroundImageLegacy(
        alloc,
        &framebuffer,
        .{ 0, 0, 0, 255 },
        .{
            .opacity = 1.0,
            .fit = .stretch,
            .position = .mc,
            .repeat = false,
        },
        pixels,
    );

    try std.testing.expectEqualSlices(
        u8,
        &.{
            0, 0,   255, 255,
            0, 0,   255, 255,
            0, 255, 0,   255,
            0, 255, 0,   255,
        },
        framebuffer.bytes,
    );
}

test "retired cpu frame pool pressure diagnostics reset after idle pool collection" {
    const alloc = std.testing.allocator;

    var diagnostics: CpuRouteDiagnosticsState = .{};
    var retired_cpu_frame_pools: std.ArrayListUnmanaged(cpu_renderer.FramePool) = .{};
    defer retired_cpu_frame_pools.deinit(alloc);
    var retired_pool_pressure_warned = false;

    var retired_frames: [max_retired_cpu_frame_pools]apprt.surface.Message.SoftwareFrameReady =
        undefined;
    for (0..max_retired_cpu_frame_pools) |i| {
        const in_flight = try GenericRendererTestPool.init(alloc, 1, 1);
        try retireCpuFramePoolWithDiagnostics(
            alloc,
            &retired_cpu_frame_pools,
            &retired_pool_pressure_warned,
            &diagnostics,
            in_flight.pool,
        );
        retired_frames[i] = in_flight.frame;
    }

    var overflow_one = try GenericRendererTestPool.init(alloc, 1, 1);
    defer overflow_one.releaseAndDeinit();
    try std.testing.expectError(
        error.CpuFramePoolRetiredPressure,
        retireCpuFramePoolWithDiagnostics(
            alloc,
            &retired_cpu_frame_pools,
            &retired_pool_pressure_warned,
            &diagnostics,
            overflow_one.pool,
        ),
    );

    var snapshot = diagnostics.snapshot();
    try std.testing.expect(retired_pool_pressure_warned);
    try std.testing.expectEqual(@as(u64, 1), snapshot.cpu_retired_pool_pressure_warning_count);
    try std.testing.expectEqualStrings(
        "retired_pool_pressure",
        snapshot.last_cpu_frame_pool_warning_reason,
    );

    var overflow_two = try GenericRendererTestPool.init(alloc, 1, 1);
    defer overflow_two.releaseAndDeinit();
    try std.testing.expectError(
        error.CpuFramePoolRetiredPressure,
        retireCpuFramePoolWithDiagnostics(
            alloc,
            &retired_cpu_frame_pools,
            &retired_pool_pressure_warned,
            &diagnostics,
            overflow_two.pool,
        ),
    );

    snapshot = diagnostics.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snapshot.cpu_retired_pool_pressure_warning_count);

    retired_frames[0].release();
    collectRetiredCpuFramePoolsForDiagnostics(
        &retired_cpu_frame_pools,
        &retired_pool_pressure_warned,
    );
    try std.testing.expect(!retired_pool_pressure_warned);

    const replacement = try GenericRendererTestPool.init(alloc, 1, 1);
    try retireCpuFramePoolWithDiagnostics(
        alloc,
        &retired_cpu_frame_pools,
        &retired_pool_pressure_warned,
        &diagnostics,
        replacement.pool,
    );
    retired_frames[0] = replacement.frame;

    var overflow_three = try GenericRendererTestPool.init(alloc, 1, 1);
    defer overflow_three.releaseAndDeinit();
    try std.testing.expectError(
        error.CpuFramePoolRetiredPressure,
        retireCpuFramePoolWithDiagnostics(
            alloc,
            &retired_cpu_frame_pools,
            &retired_pool_pressure_warned,
            &diagnostics,
            overflow_three.pool,
        ),
    );

    snapshot = diagnostics.snapshot();
    try std.testing.expect(retired_pool_pressure_warned);
    try std.testing.expectEqual(@as(u64, 2), snapshot.cpu_retired_pool_pressure_warning_count);
    try std.testing.expectEqualStrings(
        "retired_pool_pressure",
        snapshot.last_cpu_frame_pool_warning_reason,
    );

    for (retired_frames) |frame| frame.release();
    collectRetiredCpuFramePoolsForDiagnostics(
        &retired_cpu_frame_pools,
        &retired_pool_pressure_warned,
    );
    try std.testing.expectEqual(@as(usize, 0), retired_cpu_frame_pools.items.len);
}

test "cpu frame pool exhaustion diagnostics reset after successful acquire" {
    const alloc = std.testing.allocator;

    var diagnostics: CpuRouteDiagnosticsState = .{};
    var frame_pool_exhausted_warned = false;
    var cpu_frame_pool = try cpu_renderer.FramePool.init(
        alloc,
        1,
        1,
        1,
        .bgra8_premul,
        software_renderer_cpu_damage_rect_pool_capacity,
    );
    defer if (cpu_frame_pool.isIdle()) {
        cpu_frame_pool.deinitIdle();
    };

    var in_flight = cpu_frame_pool.acquire() orelse return error.TestUnexpectedResult;

    try std.testing.expect(acquireCpuFramePoolSlotWithDiagnostics(
        &cpu_frame_pool,
        &frame_pool_exhausted_warned,
        &diagnostics,
    ) == null);

    var snapshot = diagnostics.snapshot();
    try std.testing.expect(frame_pool_exhausted_warned);
    try std.testing.expectEqual(@as(u64, 1), snapshot.cpu_frame_pool_exhausted_warning_count);
    try std.testing.expectEqualStrings(
        "frame_pool_exhausted",
        snapshot.last_cpu_frame_pool_warning_reason,
    );

    try std.testing.expect(acquireCpuFramePoolSlotWithDiagnostics(
        &cpu_frame_pool,
        &frame_pool_exhausted_warned,
        &diagnostics,
    ) == null);

    snapshot = diagnostics.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snapshot.cpu_frame_pool_exhausted_warning_count);

    const cleanup = cpu_frame_pool.publish(&in_flight, 0, &.{});
    cleanup.release();

    var reacquired = acquireCpuFramePoolSlotWithDiagnostics(
        &cpu_frame_pool,
        &frame_pool_exhausted_warned,
        &diagnostics,
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!frame_pool_exhausted_warned);

    const release_reacquired = cpu_frame_pool.publish(&reacquired, 1, &.{});
    release_reacquired.release();

    in_flight = cpu_frame_pool.acquire() orelse return error.TestUnexpectedResult;
    try std.testing.expect(acquireCpuFramePoolSlotWithDiagnostics(
        &cpu_frame_pool,
        &frame_pool_exhausted_warned,
        &diagnostics,
    ) == null);

    snapshot = diagnostics.snapshot();
    try std.testing.expect(frame_pool_exhausted_warned);
    try std.testing.expectEqual(@as(u64, 2), snapshot.cpu_frame_pool_exhausted_warning_count);

    const final_cleanup = cpu_frame_pool.publish(&in_flight, 2, &.{});
    final_cleanup.release();
}
