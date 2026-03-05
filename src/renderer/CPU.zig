//! CPU software renderer MVP scaffolding.
//!
//! This module intentionally keeps rendering behavior identical to the
//! transitional software route today while introducing reusable CPU-side frame
//! primitives for incremental migration.

const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
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

/// CPU-route runtime capabilities.
///
/// Extend this enum as new CPU execution paths become available.
pub const RuntimeCapability = enum {
    custom_shader_execution,
};

/// Runtime capability unavailability reasons for CPU-route feature gating.
pub const RuntimeCapabilityUnavailableReason = enum {
    /// CPU custom-shader execution backend is explicitly disabled.
    backend_disabled,

    /// CPU custom-shader execution backend is selected but unavailable.
    backend_unavailable,

    /// CPU custom-shader runtime initialization failed.
    runtime_init_failed,

    /// CPU custom-shader pipeline compilation failed.
    pipeline_compile_failed,

    /// CPU custom-shader execution timed out.
    execution_timeout,

    /// CPU custom-shader execution backend lost the device/context.
    device_lost,
};

/// Runtime capability status for CPU-route feature gating.
pub const RuntimeCapabilityStatus = union(enum) {
    available: void,
    unavailable: RuntimeCapabilityUnavailableReason,
};

/// Runtime capability status query for CPU-route feature gating.
///
/// Custom shader execution backend selection is controlled by build options.
/// Backend runtime initialization is staged and may report unavailable.
pub fn runtimeCapabilityStatus(capability: RuntimeCapability) RuntimeCapabilityStatus {
    return switch (capability) {
        .custom_shader_execution => customShaderExecutionCapabilityStatus(),
    };
}

pub fn customShaderExecutionProbe() CustomShaderExecutionProbe {
    const timeout_ms = runtimeCustomShaderTimeoutMs();
    if (!@hasDecl(build_config, "software_renderer_cpu_shader_backend")) {
        return .{
            .status = .{ .unavailable = .backend_unavailable },
            .backend = .off,
            .timeout_ms = timeout_ms,
        };
    }

    const backend = build_config.software_renderer_cpu_shader_backend;
    const probe: VulkanSwiftshaderProbe = switch (backend) {
        .off => .{},
        .vulkan_swiftshader => vulkanSwiftshaderProbe(),
    };
    return .{
        .status = customShaderExecutionCapabilityStatusForBackendProbe(
            backend,
            timeout_ms,
            probe,
        ),
        .backend = backend,
        .timeout_ms = timeout_ms,
        .vulkan_driver_hint_source = probe.hint_source,
        .vulkan_driver_hint_path = probe.candidate_path,
        .vulkan_driver_hint_readable = probe.candidate_readable,
    };
}

fn customShaderExecutionCapabilityStatus() RuntimeCapabilityStatus {
    return customShaderExecutionProbe().status;
}

const VulkanDriverEnvHints = struct {
    vk_driver_files: ?[]const u8 = null,
    vk_icd_filenames: ?[]const u8 = null,
    vk_add_driver_files: ?[]const u8 = null,
};

pub const VulkanDriverHintSource = enum {
    vk_driver_files,
    vk_icd_filenames,
    vk_add_driver_files,
};

pub const CustomShaderExecutionProbe = struct {
    status: RuntimeCapabilityStatus,
    backend: build_config.SoftwareRendererCpuShaderBackend,
    timeout_ms: u32,
    vulkan_driver_hint_source: ?VulkanDriverHintSource = null,
    vulkan_driver_hint_path: ?[]const u8 = null,
    vulkan_driver_hint_readable: bool = false,
};

const VulkanSwiftshaderProbe = struct {
    hint_source: ?VulkanDriverHintSource = null,
    candidate_path: ?[]const u8 = null,
    candidate_readable: bool = false,
};

const VulkanSwiftshaderDriverHint = struct {
    source: VulkanDriverHintSource,
    path: []const u8,
};

const CustomShaderExecutorInitError = error{
    BackendUnavailable,
    RuntimeInitFailed,
    DeviceLost,
};

const CustomShaderExecutorCompileError = error{
    PipelineCompileFailed,
};

const CustomShaderExecutorExecuteError = error{
    PipelineCompileFailed,
    ExecutionTimeout,
    DeviceLost,
};

const CustomShaderCompileState = struct {
    source_len: usize,
    source_hash: u64,
};

const VulkanSwiftshaderExecutor = struct {
    candidate_path: []const u8,
    compiled_shader: ?CustomShaderCompileState = null,
};

const CustomShaderExecutor = union(enum) {
    vulkan_swiftshader: VulkanSwiftshaderExecutor,

    const capability_probe_source =
        \\@stage cpu-custom-shader-capability-probe
        \\void main() {}
    ;

    fn init(
        backend: build_config.SoftwareRendererCpuShaderBackend,
        probe: VulkanSwiftshaderProbe,
    ) CustomShaderExecutorInitError!CustomShaderExecutor {
        return switch (backend) {
            .off => error.BackendUnavailable,
            .vulkan_swiftshader => init: {
                const candidate = probe.candidate_path orelse break :init error.BackendUnavailable;
                if (!probe.candidate_readable) break :init error.RuntimeInitFailed;
                break :init .{
                    .vulkan_swiftshader = .{
                        .candidate_path = candidate,
                        .compiled_shader = null,
                    },
                };
            },
        };
    }

    fn deinit(self: *CustomShaderExecutor) void {
        _ = self;
    }

    fn compileCustomShader(
        self: *CustomShaderExecutor,
        source: []const u8,
    ) CustomShaderExecutorCompileError!void {
        if (!customShaderSourceHasCode(source)) return error.PipelineCompileFailed;

        const compiled = CustomShaderCompileState{
            .source_len = source.len,
            .source_hash = customShaderSourceHash(source),
        };
        switch (self.*) {
            .vulkan_swiftshader => |*executor| {
                executor.compiled_shader = compiled;
            },
        }
    }

    fn executeCustomShader(
        self: *CustomShaderExecutor,
        timeout_ms: u32,
    ) CustomShaderExecutorExecuteError!void {
        const compiled = switch (self.*) {
            .vulkan_swiftshader => |*executor| executor.compiled_shader orelse return error.PipelineCompileFailed,
        };

        if (timeout_ms < customShaderExecutionTimeoutFloorMs(compiled)) {
            return error.ExecutionTimeout;
        }

        // Stage guard: compilation state is now tracked and consulted, but the
        // backend execution path remains intentionally unavailable until full
        // wiring lands.
        return error.DeviceLost;
    }
};

fn customShaderSourceHasCode(source: []const u8) bool {
    for (source) |byte| {
        if (!std.ascii.isWhitespace(byte)) return true;
    }
    return false;
}

fn customShaderSourceHash(source: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (source) |byte| {
        hash ^= @as(u64, byte);
        hash *%= 1099511628211;
    }
    return hash;
}

fn customShaderExecutionTimeoutFloorMs(compiled: CustomShaderCompileState) u32 {
    const len_component: u32 = @intCast(compiled.source_len % 8);
    const hash_component: u32 = @intCast(compiled.source_hash % 8);
    return 1 + len_component + hash_component;
}

fn runtimeCustomShaderTimeoutMs() u32 {
    return if (@hasDecl(build_config, "software_renderer_cpu_shader_timeout_ms"))
        build_config.software_renderer_cpu_shader_timeout_ms
    else
        16;
}

fn customShaderExecutionCapabilityStatusForBackendProbe(
    backend: build_config.SoftwareRendererCpuShaderBackend,
    timeout_ms: u32,
    probe: VulkanSwiftshaderProbe,
) RuntimeCapabilityStatus {
    if (backend == .off) {
        return .{ .unavailable = .backend_disabled };
    }

    var executor = CustomShaderExecutor.init(backend, probe) catch |err| {
        return .{ .unavailable = mapCustomShaderExecutorInitError(err) };
    };
    defer executor.deinit();

    executor.compileCustomShader(CustomShaderExecutor.capability_probe_source) catch |err| {
        return .{ .unavailable = mapCustomShaderExecutorCompileError(err) };
    };

    executor.executeCustomShader(timeout_ms) catch |err| {
        return .{ .unavailable = mapCustomShaderExecutorExecuteError(err) };
    };

    return .{ .available = {} };
}

fn mapCustomShaderExecutorInitError(err: CustomShaderExecutorInitError) RuntimeCapabilityUnavailableReason {
    return switch (err) {
        error.BackendUnavailable => .backend_unavailable,
        error.RuntimeInitFailed => .runtime_init_failed,
        error.DeviceLost => .device_lost,
    };
}

fn mapCustomShaderExecutorCompileError(err: CustomShaderExecutorCompileError) RuntimeCapabilityUnavailableReason {
    return switch (err) {
        error.PipelineCompileFailed => .pipeline_compile_failed,
    };
}

fn mapCustomShaderExecutorExecuteError(err: CustomShaderExecutorExecuteError) RuntimeCapabilityUnavailableReason {
    return switch (err) {
        error.PipelineCompileFailed => .pipeline_compile_failed,
        error.ExecutionTimeout => .execution_timeout,
        error.DeviceLost => .device_lost,
    };
}

fn vulkanSwiftshaderProbe() VulkanSwiftshaderProbe {
    return switch (builtin.os.tag) {
        .windows => .{},
        else => vulkanSwiftshaderProbeFromEnvHints(
            .{
                .vk_driver_files = std.posix.getenv("VK_DRIVER_FILES"),
                .vk_icd_filenames = std.posix.getenv("VK_ICD_FILENAMES"),
                .vk_add_driver_files = std.posix.getenv("VK_ADD_DRIVER_FILES"),
            },
            pathLooksReadable,
        ),
    };
}

fn vulkanSwiftshaderProbeFromEnvHints(
    hints: VulkanDriverEnvHints,
    comptime path_readable_fn: fn ([]const u8) bool,
) VulkanSwiftshaderProbe {
    const hint = vulkanSwiftshaderDriverHintFromEnvHints(hints);
    const candidate = if (hint) |driver_hint| driver_hint.path else null;
    return .{
        .hint_source = if (hint) |driver_hint| driver_hint.source else null,
        .candidate_path = candidate,
        .candidate_readable = if (candidate) |path| path_readable_fn(path) else false,
    };
}

fn vulkanSwiftshaderDriverPathFromEnvHints(hints: VulkanDriverEnvHints) ?[]const u8 {
    if (vulkanSwiftshaderDriverHintFromEnvHints(hints)) |hint| {
        return hint.path;
    }
    return null;
}

fn vulkanSwiftshaderDriverHintFromEnvHints(
    hints: VulkanDriverEnvHints,
) ?VulkanSwiftshaderDriverHint {
    // Match Vulkan loader override precedence: VK_DRIVER_FILES >
    // VK_ICD_FILENAMES > VK_ADD_DRIVER_FILES.
    if (hints.vk_driver_files) |value| {
        if (extractSwiftshaderPath(value)) |path| return .{
            .source = .vk_driver_files,
            .path = path,
        };
    }
    if (hints.vk_icd_filenames) |value| {
        if (extractSwiftshaderPath(value)) |path| return .{
            .source = .vk_icd_filenames,
            .path = path,
        };
    }
    if (hints.vk_add_driver_files) |value| {
        if (extractSwiftshaderPath(value)) |path| return .{
            .source = .vk_add_driver_files,
            .path = path,
        };
    }
    return null;
}

fn extractSwiftshaderPath(value: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(
        u8,
        value,
        if (builtin.os.tag == .windows) ';' else ':',
    );
    while (it.next()) |entry| {
        const trimmed = trimEnvPathEntry(entry);
        if (trimmed.len == 0) continue;
        if (containsAsciiIgnoreCase(trimmed, "swiftshader")) return trimmed;
    }

    return null;
}

fn trimEnvPathEntry(value: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len < 2) return trimmed;

    if ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or
        (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\''))
    {
        trimmed = trimmed[1 .. trimmed.len - 1];
    }

    return trimmed;
}

fn pathLooksReadable(path: []const u8) bool {
    if (path.len == 0) return false;
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }

    return false;
}

/// Runtime capability query for CPU-route feature gating.
pub fn supportsRuntimeCapability(capability: RuntimeCapability) bool {
    return switch (runtimeCapabilityStatus(capability)) {
        .available => true,
        .unavailable => false,
    };
}

/// Runtime capability reason query for diagnostics.
pub fn runtimeCapabilityUnavailableReason(
    capability: RuntimeCapability,
) ?RuntimeCapabilityUnavailableReason {
    return switch (runtimeCapabilityStatus(capability)) {
        .available => null,
        .unavailable => |reason| reason,
    };
}

/// Runtime feature-compatibility helper for CPU-route presentation.
///
/// Custom shaders still force fallback to the platform route. Background
/// images and kitty image placements do not force CPU-route disablement.
pub fn isRuntimeCompatibleWithCpuRoute(
    custom_shaders_active: bool,
    background_image_active: bool,
    kitty_images_active: bool,
) bool {
    _ = background_image_active;
    _ = kitty_images_active;
    if (custom_shaders_active and !supportsRuntimeCapability(.custom_shader_execution)) {
        return false;
    }
    return true;
}

/// Runtime API shim used by renderer.GenericRenderer while CPU internals
/// are developed in parallel.
pub const CPU = switch (routed_backend) {
    .opengl => OpenGL,
    .metal => Metal,
    else => unreachable,
};

pub const PixelFormat = apprt.surface.Message.SoftwareFramePixelFormat;
pub const SoftwareFrameDamageRect = apprt.surface.Message.SoftwareFrameDamageRect;
pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// CPU-route frame damage publication mode.
pub const FrameDamageMode = enum {
    off,
    rects,
};

/// Damage rectangle tracker with overflow-safe fallback semantics.
pub const DamageTracker = struct {
    rects: ArrayList(Rect) = .{},
    max_rects: usize,
    overflow_count: u64 = 0,

    pub fn init(max_rects: u16) DamageTracker {
        return .{
            .max_rects = max_rects,
        };
    }

    pub fn deinit(self: *DamageTracker, alloc: std.mem.Allocator) void {
        self.rects.deinit(alloc);
        self.* = undefined;
    }

    pub fn resetRetainingCapacity(self: *DamageTracker) void {
        self.rects.clearRetainingCapacity();
    }

    pub fn hasDamage(self: *const DamageTracker) bool {
        return self.rects.items.len > 0;
    }

    pub fn rectCount(self: *const DamageTracker) usize {
        return self.rects.items.len;
    }

    pub fn overflowCount(self: *const DamageTracker) u64 {
        return self.overflow_count;
    }

    pub fn slice(self: *const DamageTracker) []const Rect {
        return self.rects.items;
    }

    pub fn markFull(
        self: *DamageTracker,
        alloc: std.mem.Allocator,
        bounds_width: u32,
        bounds_height: u32,
    ) !void {
        if (bounds_width == 0 or bounds_height == 0) return;
        try self.markRect(alloc, bounds_width, bounds_height, .{
            .x = 0,
            .y = 0,
            .width = bounds_width,
            .height = bounds_height,
        });
    }

    pub fn markRect(
        self: *DamageTracker,
        alloc: std.mem.Allocator,
        bounds_width: u32,
        bounds_height: u32,
        rect: Rect,
    ) !void {
        const clipped = clipRectToBounds(bounds_width, bounds_height, rect) orelse return;

        if (self.max_rects == 0) {
            self.overflow_count +%= 1;
            return;
        }

        var merged = clipped;
        var i: usize = 0;
        while (i < self.rects.items.len) {
            const existing = self.rects.items[i];
            if (!rectsTouchOrOverlap(existing, merged)) {
                i += 1;
                continue;
            }

            merged = rectUnion(existing, merged);
            _ = self.rects.swapRemove(i);
        }

        try self.appendOrOverflow(alloc, bounds_width, bounds_height, merged);
    }

    fn appendOrOverflow(
        self: *DamageTracker,
        alloc: std.mem.Allocator,
        bounds_width: u32,
        bounds_height: u32,
        rect: Rect,
    ) !void {
        if (self.rects.items.len < self.max_rects) {
            try self.rects.append(alloc, rect);
            return;
        }

        self.overflow_count +%= 1;
        self.rects.clearRetainingCapacity();

        const full = clipRectToBounds(bounds_width, bounds_height, .{
            .x = 0,
            .y = 0,
            .width = bounds_width,
            .height = bounds_height,
        }) orelse return;
        try self.rects.append(alloc, full);
    }
};

fn clipRectToBounds(bounds_width: u32, bounds_height: u32, rect: Rect) ?Rect {
    if (bounds_width == 0 or bounds_height == 0) return null;
    if (rect.width == 0 or rect.height == 0) return null;

    const x0 = @as(u64, rect.x);
    const y0 = @as(u64, rect.y);
    const x1 = @as(u64, rect.x) + @as(u64, rect.width);
    const y1 = @as(u64, rect.y) + @as(u64, rect.height);
    const bx1 = @as(u64, bounds_width);
    const by1 = @as(u64, bounds_height);

    if (x0 >= bx1 or y0 >= by1) return null;

    const clipped_x1 = @min(x1, bx1);
    const clipped_y1 = @min(y1, by1);
    if (clipped_x1 <= x0 or clipped_y1 <= y0) return null;

    return .{
        .x = @intCast(x0),
        .y = @intCast(y0),
        .width = @intCast(clipped_x1 - x0),
        .height = @intCast(clipped_y1 - y0),
    };
}

fn rectsTouchOrOverlap(a: Rect, b: Rect) bool {
    if (a.width == 0 or a.height == 0) return false;
    if (b.width == 0 or b.height == 0) return false;

    const ax0 = @as(u64, a.x);
    const ay0 = @as(u64, a.y);
    const ax1 = ax0 + @as(u64, a.width);
    const ay1 = ay0 + @as(u64, a.height);

    const bx0 = @as(u64, b.x);
    const by0 = @as(u64, b.y);
    const bx1 = bx0 + @as(u64, b.width);
    const by1 = by0 + @as(u64, b.height);

    return ax0 <= bx1 and bx0 <= ax1 and ay0 <= by1 and by0 <= ay1;
}

fn rectUnion(a: Rect, b: Rect) Rect {
    const x0 = @min(@as(u64, a.x), @as(u64, b.x));
    const y0 = @min(@as(u64, a.y), @as(u64, b.y));
    const x1 = @max(@as(u64, a.x) + @as(u64, a.width), @as(u64, b.x) + @as(u64, b.width));
    const y1 = @max(@as(u64, a.y) + @as(u64, a.height), @as(u64, b.y) + @as(u64, b.height));
    return .{
        .x = @intCast(x0),
        .y = @intCast(y0),
        .width = @intCast(x1 - x0),
        .height = @intCast(y1 - y0),
    };
}

pub const FloatRect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const ImageBoundaryMode = enum {
    clamp_to_edge,
    clamp_to_zero,
};

pub const StraightRgbaCompose = struct {
    src_rect: FloatRect,
    dst_rect: FloatRect,
    boundary: ImageBoundaryMode = .clamp_to_edge,
    opacity: f32 = 1.0,
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

    /// Blend a premultiplied RGBA image into the framebuffer.
    ///
    /// Source pixels are interpreted as RGBA premultiplied-alpha and converted
    /// into framebuffer storage order prior to blending.
    pub fn blendPremulRgbaImage(
        self: *FrameBuffer,
        dst_x: u32,
        dst_y: u32,
        image_width: u32,
        image_height: u32,
        image_stride_bytes: u32,
        image_rgba: []const u8,
    ) void {
        if (image_width == 0 or image_height == 0) return;

        const min_stride_u64 = std.math.mul(u64, image_width, 4) catch return;
        if (image_stride_bytes < min_stride_u64) return;

        const required_len_u64 = std.math.mul(
            u64,
            image_stride_bytes,
            image_height,
        ) catch return;
        const required_len = std.math.cast(usize, required_len_u64) orelse return;
        if (image_rgba.len < required_len) return;

        const clipped = self.clippedRect(.{
            .x = dst_x,
            .y = dst_y,
            .width = image_width,
            .height = image_height,
        }) orelse return;

        const dst_stride = @as(usize, @intCast(self.stride_bytes));
        const src_stride = @as(usize, @intCast(image_stride_bytes));
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
                const src_off = src_row_start + (src_col * 4);
                const rgba: [4]u8 = .{
                    image_rgba[src_off + 0],
                    image_rgba[src_off + 1],
                    image_rgba[src_off + 2],
                    image_rgba[src_off + 3],
                };
                if (rgba[3] == 0) continue;

                const src: [4]u8 = switch (self.pixel_format) {
                    .bgra8_premul => .{ rgba[2], rgba[1], rgba[0], rgba[3] },
                    .rgba8_premul => rgba,
                };

                const off = dst_row_start + (dst_col * 4);
                blendPremulBgra(self.bytes[off .. off + 4], src);
            }
        }
    }

    /// Blend a straight-alpha RGBA image using source rect sampling and
    /// destination scaling.
    ///
    /// Sampling uses bilinear filtering. `boundary` controls behavior for
    /// source taps outside the image bounds.
    pub fn blendStraightRgbaImage(
        self: *FrameBuffer,
        image_width: u32,
        image_height: u32,
        image_stride_bytes: u32,
        image_rgba: []const u8,
        compose: StraightRgbaCompose,
    ) void {
        if (!(compose.src_rect.width > 0) or !(compose.src_rect.height > 0)) return;
        if (!(compose.dst_rect.width > 0) or !(compose.dst_rect.height > 0)) return;

        if (image_width == 0 or image_height == 0) return;
        const min_stride_u64 = std.math.mul(u64, image_width, 4) catch return;
        if (image_stride_bytes < min_stride_u64) return;

        const required_len_u64 = std.math.mul(
            u64,
            image_stride_bytes,
            image_height,
        ) catch return;
        const required_len = std.math.cast(usize, required_len_u64) orelse return;
        if (image_rgba.len < required_len) return;

        const opacity = clampUnit(compose.opacity);
        if (opacity <= 0) return;

        const fb_width_i64 = @as(i64, @intCast(self.width_px));
        const fb_height_i64 = @as(i64, @intCast(self.height_px));
        if (fb_width_i64 <= 0 or fb_height_i64 <= 0) return;

        const dst_x0 = compose.dst_rect.x;
        const dst_y0 = compose.dst_rect.y;
        const dst_x1 = dst_x0 + compose.dst_rect.width;
        const dst_y1 = dst_y0 + compose.dst_rect.height;
        if (!(dst_x1 > dst_x0) or !(dst_y1 > dst_y0)) return;

        var start_x = @as(i64, @intFromFloat(@floor(dst_x0)));
        var start_y = @as(i64, @intFromFloat(@floor(dst_y0)));
        var end_x = @as(i64, @intFromFloat(@ceil(dst_x1)));
        var end_y = @as(i64, @intFromFloat(@ceil(dst_y1)));

        start_x = std.math.clamp(start_x, 0, fb_width_i64);
        start_y = std.math.clamp(start_y, 0, fb_height_i64);
        end_x = std.math.clamp(end_x, 0, fb_width_i64);
        end_y = std.math.clamp(end_y, 0, fb_height_i64);
        if (start_x >= end_x or start_y >= end_y) return;

        const src_rect = compose.src_rect;
        const dst_rect = compose.dst_rect;
        const dst_stride = @as(usize, @intCast(self.stride_bytes));
        const src_width = @as(usize, @intCast(image_width));
        const src_height = @as(usize, @intCast(image_height));
        const src_stride = @as(usize, @intCast(image_stride_bytes));

        var y = start_y;
        while (y < end_y) : (y += 1) {
            const dst_row = @as(usize, @intCast(y)) * dst_stride;
            const dst_center_y = @as(f32, @floatFromInt(y)) + 0.5;
            const ty = (dst_center_y - dst_rect.y) / dst_rect.height;
            const src_y = src_rect.y + ty * src_rect.height - 0.5;

            var x = start_x;
            while (x < end_x) : (x += 1) {
                const dst_center_x = @as(f32, @floatFromInt(x)) + 0.5;
                const tx = (dst_center_x - dst_rect.x) / dst_rect.width;
                const src_x = src_rect.x + tx * src_rect.width - 0.5;

                const sample = sampleStraightRgbaBilinear(
                    src_width,
                    src_height,
                    src_stride,
                    image_rgba,
                    src_x,
                    src_y,
                    compose.boundary,
                );
                const src_px = straightSampleToPremulStorage(
                    sample,
                    opacity,
                    self.pixel_format,
                );
                if (src_px[3] == 0) continue;

                const off = dst_row + @as(usize, @intCast(x)) * 4;
                blendPremulBgra(self.bytes[off .. off + 4], src_px);
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

fn clampUnit(value: f32) f32 {
    if (!(value > 0)) return 0;
    if (value >= 1) return 1;
    return value;
}

fn f32ToU8(value: f32) u8 {
    if (!(value > 0)) return 0;
    if (value >= 255) return 255;
    return @as(u8, @intFromFloat(value + 0.5));
}

fn straightSampleToPremulStorage(
    sample: [4]f32,
    opacity: f32,
    pixel_format: PixelFormat,
) [4]u8 {
    const alpha = f32ToU8(sample[3] * clampUnit(opacity));
    if (alpha == 0) return .{ 0, 0, 0, 0 };

    const alpha_scale = @as(f32, @floatFromInt(alpha)) / 255.0;
    const r = f32ToU8(sample[0] * alpha_scale);
    const g = f32ToU8(sample[1] * alpha_scale);
    const b = f32ToU8(sample[2] * alpha_scale);

    return switch (pixel_format) {
        .bgra8_premul => .{ b, g, r, alpha },
        .rgba8_premul => .{ r, g, b, alpha },
    };
}

fn sampleStraightRgbaBilinear(
    image_width: usize,
    image_height: usize,
    image_stride_bytes: usize,
    image_rgba: []const u8,
    src_x: f32,
    src_y: f32,
    boundary: ImageBoundaryMode,
) [4]f32 {
    const x0f = @floor(src_x);
    const y0f = @floor(src_y);
    const x0 = @as(i32, @intFromFloat(x0f));
    const y0 = @as(i32, @intFromFloat(y0f));
    const x1 = x0 + 1;
    const y1 = y0 + 1;
    const fx = src_x - x0f;
    const fy = src_y - y0f;
    const one_minus_fx = 1.0 - fx;
    const one_minus_fy = 1.0 - fy;

    const c00 = sampleStraightRgbaTap(
        image_width,
        image_height,
        image_stride_bytes,
        image_rgba,
        x0,
        y0,
        boundary,
    );
    const c10 = sampleStraightRgbaTap(
        image_width,
        image_height,
        image_stride_bytes,
        image_rgba,
        x1,
        y0,
        boundary,
    );
    const c01 = sampleStraightRgbaTap(
        image_width,
        image_height,
        image_stride_bytes,
        image_rgba,
        x0,
        y1,
        boundary,
    );
    const c11 = sampleStraightRgbaTap(
        image_width,
        image_height,
        image_stride_bytes,
        image_rgba,
        x1,
        y1,
        boundary,
    );

    var out: [4]f32 = .{ 0, 0, 0, 0 };
    for (0..4) |channel| {
        out[channel] = c00[channel] * one_minus_fx * one_minus_fy +
            c10[channel] * fx * one_minus_fy +
            c01[channel] * one_minus_fx * fy +
            c11[channel] * fx * fy;
    }
    return out;
}

fn sampleStraightRgbaTap(
    image_width: usize,
    image_height: usize,
    image_stride_bytes: usize,
    image_rgba: []const u8,
    src_x: i32,
    src_y: i32,
    boundary: ImageBoundaryMode,
) [4]f32 {
    var x = src_x;
    var y = src_y;
    const width_i32 = @as(i32, @intCast(image_width));
    const height_i32 = @as(i32, @intCast(image_height));

    switch (boundary) {
        .clamp_to_zero => {
            if (x < 0 or y < 0 or x >= width_i32 or y >= height_i32) {
                return .{ 0, 0, 0, 0 };
            }
        },
        .clamp_to_edge => {
            if (x < 0) x = 0;
            if (y < 0) y = 0;
            if (x >= width_i32) x = width_i32 - 1;
            if (y >= height_i32) y = height_i32 - 1;
        },
    }

    const off = @as(usize, @intCast(y)) * image_stride_bytes +
        @as(usize, @intCast(x)) * 4;
    return .{
        @as(f32, @floatFromInt(image_rgba[off + 0])),
        @as(f32, @floatFromInt(image_rgba[off + 1])),
        @as(f32, @floatFromInt(image_rgba[off + 2])),
        @as(f32, @floatFromInt(image_rgba[off + 3])),
    };
}

fn computeBackgroundImageSize(
    fit: BackgroundImageFit,
    frame_w: f32,
    frame_h: f32,
    src_w: f32,
    src_h: f32,
) ?struct { width: f32, height: f32 } {
    switch (fit) {
        .fill => return .{ .width = frame_w, .height = frame_h },
        .none => return .{ .width = src_w, .height = src_h },
        .contain => {
            const scale = @min(frame_w / src_w, frame_h / src_h);
            return .{ .width = src_w * scale, .height = src_h * scale };
        },
        .cover => {
            const scale = @max(frame_w / src_w, frame_h / src_h);
            return .{ .width = src_w * scale, .height = src_h * scale };
        },
    }
}

fn isRepeatX(mode: BackgroundImageRepeat) bool {
    return mode == .repeat_x or mode == .repeat;
}

fn isRepeatY(mode: BackgroundImageRepeat) bool {
    return mode == .repeat_y or mode == .repeat;
}

fn repeatStart(origin: f32, step: f32) f32 {
    if (!(step > 0)) return origin;

    const tiles_to_zero = @floor((-origin) / step);
    var start = origin + tiles_to_zero * step;
    if (start > 0) start -= step;
    while (start + step <= 0) start += step;
    return start;
}

/// A fixed-size reusable pool of shared CPU frame buffers.
///
/// Each acquired slot is released through `SoftwareFrameReady.release_fn`,
/// avoiding per-frame heap allocations in the hot path.
///
/// Concurrency contract: `acquire`/`deinitIdle` are called from the renderer
/// thread. `release_fn` may be called from presenter/runtime callbacks.
pub const FramePool = struct {
    const Slot = struct {
        bytes: []u8,
        damage_rects: []SoftwareFrameDamageRect,
        damage_rects_len: usize = 0,
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
        damage_rect_capacity: usize,
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
            for (slots[0..i]) |slot| {
                alloc.free(slot.damage_rects);
                alloc.free(slot.bytes);
            }
            alloc.free(slots);
        }
        while (i < slot_count) : (i += 1) {
            const slot_bytes = try alloc.alloc(u8, len);
            errdefer alloc.free(slot_bytes);
            const slot_damage_rects = try alloc.alloc(
                SoftwareFrameDamageRect,
                damage_rect_capacity,
            );
            errdefer alloc.free(slot_damage_rects);

            slots[i] = .{
                .bytes = slot_bytes,
                .damage_rects = slot_damage_rects,
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
        for (self.slots) |slot| {
            self.alloc.free(slot.damage_rects);
            self.alloc.free(slot.bytes);
        }
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
        acquired: *Acquired,
        generation: u64,
        damage_rects: []const Rect,
    ) apprt.surface.Message.SoftwareFrameReady {
        const slot = acquired.slot;
        const copy_len = @min(slot.damage_rects.len, damage_rects.len);
        for (damage_rects[0..copy_len], 0..) |rect, i| {
            slot.damage_rects[i] = .{
                .x_px = rect.x,
                .y_px = rect.y,
                .width_px = rect.width,
                .height_px = rect.height,
            };
        }
        slot.damage_rects_len = copy_len;

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
            .damage_rects = if (slot.damage_rects_len > 0)
                slot.damage_rects.ptr
            else
                null,
            .damage_rects_len = slot.damage_rects_len,
            .release_ctx = @ptrCast(slot),
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

pub const BackgroundImageFit = enum {
    fill,
    contain,
    cover,
    none,
};

pub const BackgroundImagePosition = struct {
    x: f32 = 0.5,
    y: f32 = 0.5,
};

pub const BackgroundImageRepeat = enum {
    no_repeat,
    repeat_x,
    repeat_y,
    repeat,
};

pub const BackgroundImagePass = struct {
    fit: BackgroundImageFit = .cover,
    position: BackgroundImagePosition = .{},
    repeat: BackgroundImageRepeat = .no_repeat,
    opacity: f32 = 1.0,
    bg_color_rgba: [4]u8 = .{ 0, 0, 0, 0 },
};

/// Compose a background pass with optional image fit/position/repeat behavior.
///
/// The pass always clears the framebuffer with `bg_color_rgba` first, then
/// blends the background image over it using straight RGBA sampling.
pub fn composeBackgroundImagePass(
    framebuffer: *FrameBuffer,
    pass: BackgroundImagePass,
    image_width: u32,
    image_height: u32,
    image_stride_bytes: u32,
    image_rgba: []const u8,
) void {
    framebuffer.clear(rgbaToPremulStorage(pass.bg_color_rgba, framebuffer.pixel_format));

    const opacity = clampUnit(pass.opacity);
    if (opacity <= 0) return;
    if (image_width == 0 or image_height == 0) return;

    const frame_w = @as(f32, @floatFromInt(framebuffer.width_px));
    const frame_h = @as(f32, @floatFromInt(framebuffer.height_px));
    if (!(frame_w > 0) or !(frame_h > 0)) return;

    const src_w = @as(f32, @floatFromInt(image_width));
    const src_h = @as(f32, @floatFromInt(image_height));
    if (!(src_w > 0) or !(src_h > 0)) return;

    const scaled = computeBackgroundImageSize(pass.fit, frame_w, frame_h, src_w, src_h) orelse return;
    if (!(scaled.width > 0) or !(scaled.height > 0)) return;

    const base_x = (frame_w - scaled.width) * pass.position.x;
    const base_y = (frame_h - scaled.height) * pass.position.y;
    const repeat_x = isRepeatX(pass.repeat);
    const repeat_y = isRepeatY(pass.repeat);

    const start_y = if (repeat_y)
        repeatStart(base_y, scaled.height)
    else
        base_y;
    const end_y = if (repeat_y)
        frame_h
    else
        base_y + 0.001;

    var tile_y = start_y;
    while (tile_y < end_y) : (tile_y += scaled.height) {
        const start_x = if (repeat_x)
            repeatStart(base_x, scaled.width)
        else
            base_x;
        const end_x = if (repeat_x)
            frame_w
        else
            base_x + 0.001;

        var tile_x = start_x;
        while (tile_x < end_x) : (tile_x += scaled.width) {
            framebuffer.blendStraightRgbaImage(
                image_width,
                image_height,
                image_stride_bytes,
                image_rgba,
                .{
                    .src_rect = .{
                        .x = 0,
                        .y = 0,
                        .width = src_w,
                        .height = src_h,
                    },
                    .dst_rect = .{
                        .x = tile_x,
                        .y = tile_y,
                        .width = scaled.width,
                        .height = scaled.height,
                    },
                    .boundary = .clamp_to_edge,
                    .opacity = opacity,
                },
            );

            if (!repeat_x) break;
        }

        if (!repeat_y) break;
    }
}

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

fn rgbaToPremulStorage(rgba: [4]u8, pixel_format: PixelFormat) [4]u8 {
    const a = rgba[3];
    const r = scaleByAlpha(rgba[0], a);
    const g = scaleByAlpha(rgba[1], a);
    const b = scaleByAlpha(rgba[2], a);

    return switch (pixel_format) {
        .bgra8_premul => .{ b, g, r, a },
        .rgba8_premul => .{ r, g, b, a },
    };
}

fn rgbaToPremulBgra(rgba: [4]u8) [4]u8 {
    return rgbaToPremulStorage(rgba, .bgra8_premul);
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

test "FrameBuffer blendPremulRgbaImage converts to BGRA storage and blends" {
    const alloc = std.testing.allocator;
    var fb = try FrameBuffer.init(alloc, 2, 1, .bgra8_premul);
    defer fb.deinit(alloc);

    fb.clear(.{ 10, 20, 30, 40 });
    const src = [_]u8{
        100, 0, 0, 128,
        0,   0, 0, 0,
    };
    fb.blendPremulRgbaImage(
        1,
        0,
        2,
        1,
        8,
        src[0..],
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            10, 20, 30,  40,
            5,  10, 115, 148,
        },
        fb.bytes,
    );
}

test "FrameBuffer blendPremulRgbaImage copies opaque RGBA source" {
    const alloc = std.testing.allocator;
    var fb = try FrameBuffer.init(alloc, 1, 1, .bgra8_premul);
    defer fb.deinit(alloc);

    fb.clear(.{ 0, 0, 0, 0 });
    const src = [_]u8{ 50, 100, 150, 255 };
    fb.blendPremulRgbaImage(
        0,
        0,
        1,
        1,
        4,
        src[0..],
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 150, 100, 50, 255 },
        fb.bytes,
    );
}

test "FrameBuffer blendStraightRgbaImage converts straight RGBA to premultiplied storage" {
    const alloc = std.testing.allocator;
    var fb = try FrameBuffer.init(alloc, 1, 1, .bgra8_premul);
    defer fb.deinit(alloc);

    fb.clear(.{ 0, 0, 0, 0 });
    const src = [_]u8{ 255, 0, 0, 128 };
    fb.blendStraightRgbaImage(
        1,
        1,
        4,
        src[0..],
        .{
            .src_rect = .{
                .x = 0,
                .y = 0,
                .width = 1,
                .height = 1,
            },
            .dst_rect = .{
                .x = 0,
                .y = 0,
                .width = 1,
                .height = 1,
            },
        },
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0, 128, 128 },
        fb.bytes,
    );
}

test "isMvpEffective requires both effective route and MVP opt-in" {
    try std.testing.expect(isMvpEffective(true, true));
    try std.testing.expect(!isMvpEffective(true, false));
    try std.testing.expect(!isMvpEffective(false, true));
    try std.testing.expect(!isMvpEffective(false, false));
}

test "supportsRuntimeCapability reflects custom shader execution capability status" {
    try std.testing.expectEqual(
        runtimeCapabilityStatus(.custom_shader_execution) == .available,
        supportsRuntimeCapability(.custom_shader_execution),
    );
}

test "runtimeCapabilityStatus reports staged custom shader execution reasons" {
    const status = runtimeCapabilityStatus(.custom_shader_execution);
    const expected = if (@hasDecl(
        build_config,
        "software_renderer_cpu_shader_backend",
    ))
        customShaderExecutionCapabilityStatusForBackendProbe(
            build_config.software_renderer_cpu_shader_backend,
            runtimeCustomShaderTimeoutMs(),
            vulkanSwiftshaderProbe(),
        )
    else
        RuntimeCapabilityStatus{
            .unavailable = .backend_unavailable,
        };

    try std.testing.expectEqualDeep(expected, status);
    switch (status) {
        .available => try std.testing.expect(
            runtimeCapabilityUnavailableReason(.custom_shader_execution) == null,
        ),
        .unavailable => |reason| try std.testing.expectEqual(
            reason,
            runtimeCapabilityUnavailableReason(.custom_shader_execution).?,
        ),
    }
}

test "customShaderExecutionCapabilityStatusForBackendProbe maps staged reasons" {
    try std.testing.expectEqualDeep(
        RuntimeCapabilityStatus{ .unavailable = .backend_disabled },
        customShaderExecutionCapabilityStatusForBackendProbe(
            .off,
            runtimeCustomShaderTimeoutMs(),
            .{},
        ),
    );
    try std.testing.expectEqualDeep(
        RuntimeCapabilityStatus{ .unavailable = .backend_unavailable },
        customShaderExecutionCapabilityStatusForBackendProbe(
            .vulkan_swiftshader,
            runtimeCustomShaderTimeoutMs(),
            .{},
        ),
    );
    try std.testing.expectEqualDeep(
        RuntimeCapabilityStatus{ .unavailable = .runtime_init_failed },
        customShaderExecutionCapabilityStatusForBackendProbe(
            .vulkan_swiftshader,
            runtimeCustomShaderTimeoutMs(),
            .{
                .candidate_path = "/opt/swiftshader/icd.json",
                .candidate_readable = false,
            },
        ),
    );
    try std.testing.expectEqualDeep(
        RuntimeCapabilityStatus{ .unavailable = .execution_timeout },
        customShaderExecutionCapabilityStatusForBackendProbe(
            .vulkan_swiftshader,
            0,
            .{
                .candidate_path = "/opt/swiftshader/icd.json",
                .candidate_readable = true,
            },
        ),
    );
    try std.testing.expectEqualDeep(
        RuntimeCapabilityStatus{ .unavailable = .device_lost },
        customShaderExecutionCapabilityStatusForBackendProbe(
            .vulkan_swiftshader,
            255,
            .{
                .candidate_path = "/opt/swiftshader/icd.json",
                .candidate_readable = true,
            },
        ),
    );
}

test "containsAsciiIgnoreCase matches swiftshader tokens" {
    try std.testing.expect(containsAsciiIgnoreCase(
        "/opt/swiftshader/icd.json",
        "swiftshader",
    ));
    try std.testing.expect(containsAsciiIgnoreCase(
        "/opt/SwiftShader/icd.json",
        "swiftshader",
    ));
    try std.testing.expect(!containsAsciiIgnoreCase(
        "/usr/share/vulkan/icd.d/intel_icd.x86_64.json",
        "swiftshader",
    ));
}

test "vulkanSwiftshaderDriverPathFromEnvHints follows loader precedence" {
    try std.testing.expectEqualStrings(
        "/opt/swiftshader/driver.json",
        vulkanSwiftshaderDriverPathFromEnvHints(.{
            .vk_driver_files = "/opt/swiftshader/driver.json",
            .vk_icd_filenames = "/opt/other/icd.json",
            .vk_add_driver_files = "/opt/other/add.json",
        }).?,
    );

    try std.testing.expectEqualStrings(
        "/opt/swiftshader/icd.json",
        vulkanSwiftshaderDriverPathFromEnvHints(.{
            .vk_driver_files = "/opt/other/driver.json",
            .vk_icd_filenames = "/opt/swiftshader/icd.json",
            .vk_add_driver_files = "/opt/other/add.json",
        }).?,
    );

    try std.testing.expectEqualStrings(
        "/opt/swiftshader/add.json",
        vulkanSwiftshaderDriverPathFromEnvHints(.{
            .vk_driver_files = "/opt/other/driver.json",
            .vk_icd_filenames = "/opt/other/icd.json",
            .vk_add_driver_files = "/opt/swiftshader/add.json",
        }).?,
    );

    try std.testing.expectEqualStrings(
        "/opt/swiftshader/quoted.json",
        vulkanSwiftshaderDriverPathFromEnvHints(.{
            .vk_driver_files = " /opt/other/driver.json : '/opt/swiftshader/quoted.json' ",
        }).?,
    );

    try std.testing.expect(
        vulkanSwiftshaderDriverPathFromEnvHints(.{
            .vk_driver_files = "/opt/other/driver.json",
            .vk_icd_filenames = "/opt/other/icd.json",
            .vk_add_driver_files = "/opt/other/add.json",
        }) == null,
    );
}

test "vulkanSwiftshaderDriverHintFromEnvHints tracks source precedence" {
    try std.testing.expectEqualDeep(
        VulkanSwiftshaderDriverHint{
            .source = .vk_driver_files,
            .path = "/opt/swiftshader/driver.json",
        },
        vulkanSwiftshaderDriverHintFromEnvHints(.{
            .vk_driver_files = "/opt/swiftshader/driver.json",
            .vk_icd_filenames = "/opt/swiftshader/icd.json",
            .vk_add_driver_files = "/opt/swiftshader/add.json",
        }).?,
    );

    try std.testing.expectEqualDeep(
        VulkanSwiftshaderDriverHint{
            .source = .vk_icd_filenames,
            .path = "/opt/swiftshader/icd.json",
        },
        vulkanSwiftshaderDriverHintFromEnvHints(.{
            .vk_driver_files = "/opt/other/driver.json",
            .vk_icd_filenames = "/opt/swiftshader/icd.json",
        }).?,
    );

    try std.testing.expectEqualDeep(
        VulkanSwiftshaderDriverHint{
            .source = .vk_add_driver_files,
            .path = "/opt/swiftshader/add.json",
        },
        vulkanSwiftshaderDriverHintFromEnvHints(.{
            .vk_driver_files = "/opt/other/driver.json",
            .vk_icd_filenames = "/opt/other/icd.json",
            .vk_add_driver_files = "/opt/swiftshader/add.json",
        }).?,
    );
}

test "vulkanSwiftshaderProbeFromEnvHints uses readability callback" {
    const ReadableAlways = struct {
        fn fn_(path: []const u8) bool {
            _ = path;
            return true;
        }
    };
    const ReadableNever = struct {
        fn fn_(path: []const u8) bool {
            _ = path;
            return false;
        }
    };

    const readable = vulkanSwiftshaderProbeFromEnvHints(
        .{ .vk_icd_filenames = "/opt/swiftshader/icd.json" },
        ReadableAlways.fn_,
    );
    try std.testing.expectEqual(
        @as(?VulkanDriverHintSource, .vk_icd_filenames),
        readable.hint_source,
    );
    try std.testing.expectEqualStrings("/opt/swiftshader/icd.json", readable.candidate_path.?);
    try std.testing.expect(readable.candidate_readable);

    const unreadable = vulkanSwiftshaderProbeFromEnvHints(
        .{ .vk_icd_filenames = "/opt/swiftshader/icd.json" },
        ReadableNever.fn_,
    );
    try std.testing.expectEqual(
        @as(?VulkanDriverHintSource, .vk_icd_filenames),
        unreadable.hint_source,
    );
    try std.testing.expectEqualStrings("/opt/swiftshader/icd.json", unreadable.candidate_path.?);
    try std.testing.expect(!unreadable.candidate_readable);

    const missing = vulkanSwiftshaderProbeFromEnvHints(
        .{ .vk_icd_filenames = "/opt/vendor/intel_icd.json" },
        ReadableAlways.fn_,
    );
    try std.testing.expect(missing.hint_source == null);
    try std.testing.expect(missing.candidate_path == null);
    try std.testing.expect(!missing.candidate_readable);
}

test "customShaderExecutor tracks compiled state and maps staged errors" {
    try std.testing.expectError(
        error.BackendUnavailable,
        CustomShaderExecutor.init(.vulkan_swiftshader, .{}),
    );
    try std.testing.expectError(
        error.RuntimeInitFailed,
        CustomShaderExecutor.init(.vulkan_swiftshader, .{
            .candidate_path = "/opt/swiftshader/icd.json",
            .candidate_readable = false,
        }),
    );

    var executor = try CustomShaderExecutor.init(
        .vulkan_swiftshader,
        .{
            .candidate_path = "/opt/swiftshader/icd.json",
            .candidate_readable = true,
        },
    );
    defer executor.deinit();

    try std.testing.expectError(
        error.PipelineCompileFailed,
        executor.executeCustomShader(1),
    );
    try std.testing.expectError(
        error.PipelineCompileFailed,
        executor.compileCustomShader(" \n\t "),
    );

    const source =
        \\@stage cpu-custom-shader-test
        \\void main() {}
    ;
    try executor.compileCustomShader(source);

    const compiled = switch (executor) {
        .vulkan_swiftshader => |swiftshader| swiftshader.compiled_shader.?,
    };
    try std.testing.expectEqual(source.len, compiled.source_len);
    try std.testing.expectEqual(customShaderSourceHash(source), compiled.source_hash);

    const timeout_floor = customShaderExecutionTimeoutFloorMs(compiled);
    try std.testing.expectError(
        error.ExecutionTimeout,
        executor.executeCustomShader(timeout_floor - 1),
    );
    try std.testing.expectError(
        error.DeviceLost,
        executor.executeCustomShader(timeout_floor),
    );

    try std.testing.expectEqual(
        RuntimeCapabilityUnavailableReason.backend_unavailable,
        mapCustomShaderExecutorInitError(error.BackendUnavailable),
    );
    try std.testing.expectEqual(
        RuntimeCapabilityUnavailableReason.runtime_init_failed,
        mapCustomShaderExecutorInitError(error.RuntimeInitFailed),
    );
    try std.testing.expectEqual(
        RuntimeCapabilityUnavailableReason.pipeline_compile_failed,
        mapCustomShaderExecutorCompileError(error.PipelineCompileFailed),
    );
    try std.testing.expectEqual(
        RuntimeCapabilityUnavailableReason.execution_timeout,
        mapCustomShaderExecutorExecuteError(error.ExecutionTimeout),
    );
    try std.testing.expectEqual(
        RuntimeCapabilityUnavailableReason.pipeline_compile_failed,
        mapCustomShaderExecutorExecuteError(error.PipelineCompileFailed),
    );
    try std.testing.expectEqual(
        RuntimeCapabilityUnavailableReason.device_lost,
        mapCustomShaderExecutorExecuteError(error.DeviceLost),
    );
}

test "isRuntimeCompatibleWithCpuRoute gates custom shader execution by runtime capability" {
    try std.testing.expect(isRuntimeCompatibleWithCpuRoute(false, true, false));
    try std.testing.expect(isRuntimeCompatibleWithCpuRoute(false, false, true));
    try std.testing.expect(isRuntimeCompatibleWithCpuRoute(false, true, true));
    try std.testing.expectEqual(
        supportsRuntimeCapability(.custom_shader_execution),
        isRuntimeCompatibleWithCpuRoute(true, true, true),
    );
}

test "DamageTracker clips rects to bounds" {
    const alloc = std.testing.allocator;
    var tracker = DamageTracker.init(8);
    defer tracker.deinit(alloc);

    try tracker.markRect(alloc, 10, 10, .{
        .x = 8,
        .y = 7,
        .width = 6,
        .height = 5,
    });

    try std.testing.expectEqual(@as(usize, 1), tracker.rectCount());
    try std.testing.expectEqual(@as(u64, 0), tracker.overflowCount());
    try std.testing.expectEqualDeep(Rect{
        .x = 8,
        .y = 7,
        .width = 2,
        .height = 3,
    }, tracker.slice()[0]);
}

test "DamageTracker merges touching and overlapping rects" {
    const alloc = std.testing.allocator;
    var tracker = DamageTracker.init(8);
    defer tracker.deinit(alloc);

    try tracker.markRect(alloc, 20, 20, .{
        .x = 2,
        .y = 2,
        .width = 4,
        .height = 4,
    });
    try tracker.markRect(alloc, 20, 20, .{
        .x = 6,
        .y = 4,
        .width = 3,
        .height = 3,
    });

    try std.testing.expectEqual(@as(usize, 1), tracker.rectCount());
    try std.testing.expectEqualDeep(Rect{
        .x = 2,
        .y = 2,
        .width = 7,
        .height = 5,
    }, tracker.slice()[0]);
}

test "DamageTracker overflow degrades to full-frame rect" {
    const alloc = std.testing.allocator;
    var tracker = DamageTracker.init(2);
    defer tracker.deinit(alloc);

    try tracker.markRect(alloc, 10, 8, .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    try tracker.markRect(alloc, 10, 8, .{
        .x = 3,
        .y = 0,
        .width = 1,
        .height = 1,
    });
    try tracker.markRect(alloc, 10, 8, .{
        .x = 6,
        .y = 0,
        .width = 1,
        .height = 1,
    });

    try std.testing.expectEqual(@as(usize, 1), tracker.rectCount());
    try std.testing.expectEqual(@as(u64, 1), tracker.overflowCount());
    try std.testing.expectEqualDeep(Rect{
        .x = 0,
        .y = 0,
        .width = 10,
        .height = 8,
    }, tracker.slice()[0]);
}

test "DamageTracker resetRetainingCapacity clears damage while preserving overflow total" {
    const alloc = std.testing.allocator;
    var tracker = DamageTracker.init(0);
    defer tracker.deinit(alloc);

    try tracker.markRect(alloc, 10, 10, .{
        .x = 1,
        .y = 1,
        .width = 2,
        .height = 2,
    });
    try std.testing.expectEqual(@as(u64, 1), tracker.overflowCount());
    try std.testing.expectEqual(@as(usize, 0), tracker.rectCount());

    tracker.resetRetainingCapacity();
    try std.testing.expect(!tracker.hasDamage());
    try std.testing.expectEqual(@as(u64, 1), tracker.overflowCount());
}

test "FramePool publish uses caller generation and release returns slot to idle" {
    const alloc = std.testing.allocator;
    var pool = try FramePool.init(alloc, 1, 1, 1, .bgra8_premul, 2);
    defer if (pool.isIdle()) pool.deinitIdle();

    try std.testing.expect(pool.isIdle());

    var acquired = pool.acquire() orelse return error.TestUnexpectedResult;
    try std.testing.expect(!pool.isIdle());

    const frame = pool.publish(&acquired, 99, &.{
        .{ .x = 1, .y = 2, .width = 3, .height = 4 },
    });
    try std.testing.expectEqual(@as(u64, 99), frame.generation);
    try std.testing.expectEqual(@as(usize, 4), frame.data_len);
    try std.testing.expectEqual(@as(usize, 1), frame.damage_rects_len);
    try std.testing.expect(frame.damage_rects != null);
    try std.testing.expectEqualDeep(SoftwareFrameDamageRect{
        .x_px = 1,
        .y_px = 2,
        .width_px = 3,
        .height_px = 4,
    }, frame.damage_rects.?[0]);
    try std.testing.expect(frame.release_fn != null);

    frame.release();
    try std.testing.expect(pool.isIdle());
}

test "FramePool publish truncates damage rects to slot capacity" {
    const alloc = std.testing.allocator;
    var pool = try FramePool.init(alloc, 1, 1, 1, .bgra8_premul, 1);
    defer if (pool.isIdle()) pool.deinitIdle();

    var acquired = pool.acquire() orelse return error.TestUnexpectedResult;
    const frame = pool.publish(&acquired, 1, &.{
        .{ .x = 1, .y = 1, .width = 1, .height = 1 },
        .{ .x = 2, .y = 2, .width = 1, .height = 1 },
    });

    try std.testing.expectEqual(@as(usize, 1), frame.damage_rects_len);
    try std.testing.expect(frame.damage_rects != null);
    try std.testing.expectEqualDeep(SoftwareFrameDamageRect{
        .x_px = 1,
        .y_px = 1,
        .width_px = 1,
        .height_px = 1,
    }, frame.damage_rects.?[0]);

    frame.release();
}

test "FramePool publish clears damage metadata on empty publish after prior damage" {
    const alloc = std.testing.allocator;
    var pool = try FramePool.init(alloc, 1, 1, 1, .bgra8_premul, 2);
    defer if (pool.isIdle()) pool.deinitIdle();

    var acquired = pool.acquire() orelse return error.TestUnexpectedResult;
    var frame = pool.publish(&acquired, 1, &.{
        .{ .x = 1, .y = 1, .width = 1, .height = 1 },
    });
    try std.testing.expectEqual(@as(usize, 1), frame.damage_rects_len);
    frame.release();

    acquired = pool.acquire() orelse return error.TestUnexpectedResult;
    frame = pool.publish(&acquired, 2, &.{});
    try std.testing.expectEqual(@as(usize, 0), frame.damage_rects_len);
    try std.testing.expect(frame.damage_rects == null);
    frame.release();
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

test "composeSoftwareFrame clears previous pixels when framebuffer is reused" {
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
        .color = .{ 255, 0, 0, 255 },
        .atlas = .grayscale,
    });

    const bg_cells = [_][4]u8{
        .{ 0, 0, 0, 0 },
    };
    const atlas_gray = [_]u8{255};
    const empty_color: [0]u8 = .{};
    const layout: Layout = .{
        .padding_left_px = 0,
        .padding_top_px = 0,
        .cell_width_px = 1,
        .cell_height_px = 1,
        .grid_columns = 1,
        .grid_rows = 1,
    };

    composeSoftwareFrame(
        TestCellText,
        &fb,
        layout,
        .{ 0, 0, 0, 0 },
        bg_cells[0..],
        rows[0..],
        .{ .data = atlas_gray[0..], .size = 1 },
        .{ .data = empty_color[0..], .size = 0 },
    );
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0, 255, 255 },
        fb.bytes,
    );

    rows[0].clearRetainingCapacity();
    composeSoftwareFrame(
        TestCellText,
        &fb,
        layout,
        .{ 0, 0, 0, 0 },
        bg_cells[0..],
        rows[0..],
        .{ .data = atlas_gray[0..], .size = 1 },
        .{ .data = empty_color[0..], .size = 0 },
    );
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0, 0, 0 },
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

test "FrameBuffer blendStraightRgbaImage clamp-to-zero drops out-of-range samples" {
    const alloc = std.testing.allocator;
    var fb = try FrameBuffer.init(alloc, 1, 1, .bgra8_premul);
    defer fb.deinit(alloc);

    fb.clear(.{ 9, 8, 7, 6 });
    const src = [_]u8{ 255, 0, 0, 255 };

    fb.blendStraightRgbaImage(
        1,
        1,
        4,
        src[0..],
        .{
            .src_rect = .{
                .x = -1,
                .y = 0,
                .width = 1,
                .height = 1,
            },
            .dst_rect = .{
                .x = 0,
                .y = 0,
                .width = 1,
                .height = 1,
            },
            .boundary = .clamp_to_zero,
        },
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 9, 8, 7, 6 },
        fb.bytes,
    );
}

test "FrameBuffer blendStraightRgbaImage clamp-to-edge samples border texel" {
    const alloc = std.testing.allocator;
    var fb = try FrameBuffer.init(alloc, 1, 1, .bgra8_premul);
    defer fb.deinit(alloc);

    fb.clear(.{ 0, 0, 0, 0 });
    const src = [_]u8{ 255, 0, 0, 255 };

    fb.blendStraightRgbaImage(
        1,
        1,
        4,
        src[0..],
        .{
            .src_rect = .{
                .x = -1,
                .y = 0,
                .width = 1,
                .height = 1,
            },
            .dst_rect = .{
                .x = 0,
                .y = 0,
                .width = 1,
                .height = 1,
            },
            .boundary = .clamp_to_edge,
        },
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0, 255, 255 },
        fb.bytes,
    );
}

test "composeBackgroundImagePass repeat wraps background image across x axis" {
    const alloc = std.testing.allocator;
    var fb = try FrameBuffer.init(alloc, 3, 1, .bgra8_premul);
    defer fb.deinit(alloc);

    const image = [_]u8{
        255, 0,   0, 255,
        0,   255, 0, 255,
    };

    composeBackgroundImagePass(
        &fb,
        .{
            .fit = .none,
            .position = .{ .x = 0, .y = 0 },
            .repeat = .repeat_x,
            .opacity = 1.0,
            .bg_color_rgba = .{ 0, 0, 0, 0 },
        },
        2,
        1,
        8,
        image[0..],
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            0, 0,   255, 255,
            0, 255, 0,   255,
            0, 0,   255, 255,
        },
        fb.bytes,
    );
}

test "composeBackgroundImagePass contain and cover use different scaled sizes" {
    const alloc = std.testing.allocator;
    const image = [_]u8{ 255, 0, 0, 255 };

    var contain_fb = try FrameBuffer.init(alloc, 4, 2, .bgra8_premul);
    defer contain_fb.deinit(alloc);
    composeBackgroundImagePass(
        &contain_fb,
        .{
            .fit = .contain,
            .position = .{ .x = 0, .y = 0 },
            .repeat = .no_repeat,
            .opacity = 1.0,
            .bg_color_rgba = .{ 10, 20, 30, 255 },
        },
        1,
        1,
        4,
        image[0..],
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            0, 0, 255, 255, 0, 0, 255, 255, 30, 20, 10, 255, 30, 20, 10, 255,
            0, 0, 255, 255, 0, 0, 255, 255, 30, 20, 10, 255, 30, 20, 10, 255,
        },
        contain_fb.bytes,
    );

    var cover_fb = try FrameBuffer.init(alloc, 4, 2, .bgra8_premul);
    defer cover_fb.deinit(alloc);
    composeBackgroundImagePass(
        &cover_fb,
        .{
            .fit = .cover,
            .position = .{ .x = 0, .y = 0 },
            .repeat = .no_repeat,
            .opacity = 1.0,
            .bg_color_rgba = .{ 10, 20, 30, 255 },
        },
        1,
        1,
        4,
        image[0..],
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255,
            0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255,
        },
        cover_fb.bytes,
    );
}

test "composeBackgroundImagePass repeat tiles across both axes" {
    const alloc = std.testing.allocator;
    var fb = try FrameBuffer.init(alloc, 3, 3, .bgra8_premul);
    defer fb.deinit(alloc);

    const image = [_]u8{
        255, 0, 0,   255, 0,   255, 0, 255,
        0,   0, 255, 255, 255, 255, 0, 255,
    };

    composeBackgroundImagePass(
        &fb,
        .{
            .fit = .none,
            .position = .{ .x = 0, .y = 0 },
            .repeat = .repeat,
            .opacity = 1.0,
            .bg_color_rgba = .{ 0, 0, 0, 0 },
        },
        2,
        2,
        8,
        image[0..],
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            0,   0, 255, 255, 0, 255, 0,   255, 0,   0, 255, 255,
            255, 0, 0,   255, 0, 255, 255, 255, 255, 0, 0,   255,
            0,   0, 255, 255, 0, 255, 0,   255, 0,   0, 255, 255,
        },
        fb.bytes,
    );
}

test "composeBackgroundImagePass position boundaries anchor to 0 and 1" {
    const alloc = std.testing.allocator;
    const image = [_]u8{ 255, 0, 0, 255 };

    var start_fb = try FrameBuffer.init(alloc, 3, 2, .bgra8_premul);
    defer start_fb.deinit(alloc);
    composeBackgroundImagePass(
        &start_fb,
        .{
            .fit = .none,
            .position = .{ .x = 0, .y = 0 },
            .repeat = .no_repeat,
            .opacity = 1.0,
            .bg_color_rgba = .{ 0, 0, 0, 0 },
        },
        1,
        1,
        4,
        image[0..],
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            0, 0, 255, 255, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0,   0,   0, 0, 0, 0, 0, 0, 0, 0,
        },
        start_fb.bytes,
    );

    var end_fb = try FrameBuffer.init(alloc, 3, 2, .bgra8_premul);
    defer end_fb.deinit(alloc);
    composeBackgroundImagePass(
        &end_fb,
        .{
            .fit = .none,
            .position = .{ .x = 1, .y = 1 },
            .repeat = .no_repeat,
            .opacity = 1.0,
            .bg_color_rgba = .{ 0, 0, 0, 0 },
        },
        1,
        1,
        4,
        image[0..],
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,   0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255,
        },
        end_fb.bytes,
    );
}

test "composeBackgroundImagePass opacity blends image over background color" {
    const alloc = std.testing.allocator;
    var fb = try FrameBuffer.init(alloc, 1, 1, .bgra8_premul);
    defer fb.deinit(alloc);

    const image = [_]u8{ 255, 0, 0, 255 };
    composeBackgroundImagePass(
        &fb,
        .{
            .fit = .fill,
            .position = .{ .x = 0.5, .y = 0.5 },
            .repeat = .no_repeat,
            .opacity = 0.5,
            .bg_color_rgba = .{ 20, 40, 60, 255 },
        },
        1,
        1,
        4,
        image[0..],
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 30, 20, 138, 255 },
        fb.bytes,
    );
}

test "composeBackgroundImagePass opacity zero keeps only background color" {
    const alloc = std.testing.allocator;
    var fb = try FrameBuffer.init(alloc, 2, 1, .bgra8_premul);
    defer fb.deinit(alloc);

    const image = [_]u8{ 255, 0, 0, 255 };
    composeBackgroundImagePass(
        &fb,
        .{
            .fit = .fill,
            .position = .{ .x = 0.5, .y = 0.5 },
            .repeat = .no_repeat,
            .opacity = 0,
            .bg_color_rgba = .{ 20, 40, 60, 255 },
        },
        1,
        1,
        4,
        image[0..],
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            60, 40, 20, 255,
            60, 40, 20, 255,
        },
        fb.bytes,
    );
}
