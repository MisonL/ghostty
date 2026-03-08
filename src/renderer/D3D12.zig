//! Transitional D3D12 backend scaffold.
//!
//! The long-term Windows product renderer is `Win32 + DXGI + D3D12`.
//! Current stage:
//! - native Win32 swapchain present path
//! - dummy resource layer so GenericRenderer can run without a GL context
//! - forced CPU software-frame route until native D3D12 draw is implemented

pub const D3D12 = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Health = rendererpkg.Health;
const shadertoy = @import("shadertoy.zig");
const internal_os = @import("../os/main.zig");
const winos = internal_os.windows;

pub const GraphicsAPI = D3D12;
pub const force_software_cpu_route = true;

pub const custom_shader_target: shadertoy.Target = .hlsl;
pub const custom_shader_y_is_down = false;
pub const swap_chain_count = 1;
pub const softwareFramePublicationOnCompletion = false;

pub const MIN_VERSION_MAJOR = 12;
pub const MIN_VERSION_MINOR = 0;

pub const ImageTextureFormat = enum {
    grayscale,
    bgra,
    rgba,
};

pub const Pipeline = @import("d3d12/Pipeline.zig");

pub const Target = struct {
    width: u32 = 0,
    height: u32 = 0,

    pub fn deinit(self: *@This()) void {
        _ = self;
    }
};

pub const Texture = struct {
    pub const Error = error{};
    pub const Options = struct {};

    width: u32 = 0,
    height: u32 = 0,

    pub fn init(
        _: Options,
        width: u32,
        height: u32,
        _: ?[]const u8,
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
    pub const Options = struct {};

    pub fn init(_: Options) !@This() {
        return .{};
    }

    pub fn deinit(self: @This()) void {
        _ = self;
    }
};

pub fn Buffer(comptime T: type) type {
    return struct {
        buffer: ?*anyopaque = null,
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

    pub fn begin(_: anytype) @This() {
        return .{};
    }

    pub fn step(self: *@This(), _: anytype) void {
        _ = self;
    }

    pub fn complete(self: *@This()) void {
        _ = self;
    }
};

pub const shaders = @import("d3d12/shaders.zig");

pub const Frame = struct {
    renderer: *rendererpkg.GenericRenderer(D3D12),
    target: *Target,
    publish_software_frame: bool,
    publish_width_px: u32,
    publish_height_px: u32,

    pub const Options = struct {};

    pub fn begin(
        opts: Options,
        renderer: *rendererpkg.GenericRenderer(D3D12),
        target: *Target,
        publish_software_frame: bool,
        publish_width_px: u32,
        publish_height_px: u32,
    ) !Frame {
        _ = opts;
        return .{
            .renderer = renderer,
            .target = target,
            .publish_software_frame = publish_software_frame,
            .publish_width_px = publish_width_px,
            .publish_height_px = publish_height_px,
        };
    }

    pub fn renderPass(
        self: *const Frame,
        attachments: []const RenderPass.Options.Attachment,
    ) RenderPass {
        _ = self;
        return RenderPass.begin(.{ .attachments = attachments });
    }

    pub fn complete(self: *const Frame, sync: bool) void {
        _ = sync;

        const health: Health = .healthy;
        self.renderer.api.present(self.target.*) catch |err| {
            std.log.scoped(.d3d12).err("Failed to present render target: err={}", .{err});
            self.renderer.frameCompleted(
                .unhealthy,
                self.target,
                self.publish_software_frame,
                self.publish_width_px,
                self.publish_height_px,
            );
            return;
        };

        self.renderer.frameCompleted(
            health,
            self.target,
            self.publish_software_frame,
            self.publish_width_px,
            self.publish_height_px,
        );
    }
};

blending: configpkg.Config.AlphaBlending,
dxgi_factory: ?*winos.graphics.IDXGIFactory4 = null,
d3d12_device: ?*winos.graphics.ID3D12Device = null,
dwrite_factory: ?*winos.graphics.IDWriteFactory = null,
swap_chain: ?*winos.graphics.IDXGISwapChain3 = null,
command_queue: ?*winos.graphics.ID3D12CommandQueue = null,
rt_surface: ?*apprt.Surface = null,
last_present_generation: u64 = 0,
has_native_present_path: bool = false,
has_native_draw_path: bool = false,

pub fn init(_: Allocator, opts: rendererpkg.Options) !D3D12 {
    var result: D3D12 = .{
        .blending = opts.config.blending,
    };
    result.rt_surface = opts.rt_surface;
    if (@hasField(@TypeOf(opts.rt_surface.*), "graphics")) {
        result.dxgi_factory = opts.rt_surface.graphics.dxgi_factory;
        result.d3d12_device = opts.rt_surface.graphics.d3d12_device;
        result.dwrite_factory = opts.rt_surface.graphics.dwrite_factory;
        result.swap_chain = opts.rt_surface.graphics.swap_chain;
        result.command_queue = opts.rt_surface.graphics.command_queue;
    }
    result.has_native_present_path = result.swap_chain != null;
    result.has_native_draw_path = false;
    return result;
}

pub fn deinit(self: *D3D12) void {
    self.* = undefined;
}

pub fn surfaceInit(_: *apprt.Surface) !void {}
pub fn finalizeSurfaceInit(_: *const D3D12, _: *apprt.Surface) !void {}
pub fn threadEnter(_: *const D3D12, _: *apprt.Surface) !void {}
pub fn threadExit(_: *const D3D12) void {}
pub fn loopEnter(_: *D3D12) void {}
pub fn loopExit(_: *D3D12) void {}
pub fn displayRealized(_: *const D3D12) void {}
pub fn displayUnrealized(_: *const D3D12) void {}
pub fn drawFrameStart(_: *D3D12) void {}
pub fn drawFrameEnd(_: *D3D12) void {}

pub fn initShaders(
    self: *const D3D12,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    _ = self;
    return try shaders.Shaders.init(alloc, custom_shaders);
}

pub fn surfaceSize(self: *const D3D12) !struct { width: u32, height: u32 } {
    if (self.rt_surface) |surface| {
        const size = try surface.getSize();
        return .{
            .width = size.width,
            .height = size.height,
        };
    }

    return .{ .width = 0, .height = 0 };
}

pub fn initTarget(self: *const D3D12, width: usize, height: usize) !Target {
    _ = self;
    return .{
        .width = @intCast(width),
        .height = @intCast(height),
    };
}

pub fn present(self: *D3D12, target: Target) !void {
    _ = target;
    if (self.swap_chain) |swap_chain| {
        if (self.rt_surface) |surface| {
            if (@hasDecl(@TypeOf(surface.*), "prepareNativePresent")) {
                try surface.prepareNativePresent();
            }
        }
        const sc: *winos.c.IDXGISwapChain3 = @ptrFromInt(@intFromPtr(swap_chain));
        if (sc.lpVtbl[0].Present.?(sc, 1, 0) != winos.S_OK) return error.Unexpected;
        if (self.rt_surface) |surface| {
            if (@hasDecl(@TypeOf(surface.*), "finishNativePresent")) {
                try surface.finishNativePresent();
            }
        }
        self.last_present_generation +%= 1;
        return;
    }

    return error.Unexpected;
}

pub fn presentLastTarget(self: *D3D12) !void {
    try self.present(.{});
}

pub fn publishSoftwareFrame(
    self: *D3D12,
    target: *const Target,
    screen: rendererpkg.ScreenSize,
) !?apprt.surface.Message.SoftwareFrameReady {
    _ = self;
    _ = target;
    _ = screen;
    return null;
}

pub fn bufferOptions(_: D3D12) void {}
pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

pub fn textureOptions(_: D3D12) Texture.Options {
    return .{};
}

pub fn samplerOptions(_: D3D12) Sampler.Options {
    return .{};
}

pub fn imageTextureOptions(
    self: D3D12,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    _ = self;
    _ = format;
    _ = srgb;
    return .{};
}

pub fn initAtlasTexture(
    self: *const D3D12,
    atlas: *const @import("../font/main.zig").Atlas,
) Texture.Error!Texture {
    _ = self;
    return try Texture.init(.{}, atlas.size, atlas.size, atlas.data);
}

pub fn beginFrame(
    self: *const D3D12,
    renderer: *@import("../renderer.zig").GenericRenderer(D3D12),
    target: *Target,
    publish_software_frame: bool,
    publish_width_px: u32,
    publish_height_px: u32,
) !Frame {
    _ = self;
    return try Frame.begin(
        .{},
        renderer,
        target,
        publish_software_frame,
        publish_width_px,
        publish_height_px,
    );
}
