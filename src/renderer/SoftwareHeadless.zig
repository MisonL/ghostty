//! Headless software backend for shared CPU software-frame publication.
//!
//! This backend exists so `libghostty` software-host builds can exercise the
//! CPU software-frame route without requiring an OpenGL or Metal context.

pub const SoftwareHeadless = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Health = rendererpkg.Health;
const shadertoy = @import("shadertoy.zig");
const OpenGLShaders = @import("opengl/shaders.zig");

pub const GraphicsAPI = SoftwareHeadless;
pub const force_software_cpu_route = true;

pub const custom_shader_target: shadertoy.Target = .glsl;
pub const custom_shader_y_is_down = false;
pub const swap_chain_count = 1;
pub const softwareFramePublicationOnCompletion = false;

pub const ImageTextureFormat = enum {
    grayscale,
    bgra,
    rgba,
};

pub const Pipeline = struct {};

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

pub const shaders = struct {
    pub const Uniforms = OpenGLShaders.Uniforms;
    pub const CellText = OpenGLShaders.CellText;
    pub const CellBg = OpenGLShaders.CellBg;
    pub const Image = OpenGLShaders.Image;
    pub const BgImage = OpenGLShaders.BgImage;

    pub const Shaders = struct {
        pipelines: struct {
            bg_color: Pipeline = .{},
            cell_bg: Pipeline = .{},
            cell_text: Pipeline = .{},
            image: Pipeline = .{},
            bg_image: Pipeline = .{},
        } = .{},
        post_pipelines: []const Pipeline = &.{},
        defunct: bool = false,

        pub fn deinit(self: *@This(), alloc: Allocator) void {
            _ = self;
            _ = alloc;
        }
    };
};

pub const Frame = struct {
    renderer: *rendererpkg.GenericRenderer(SoftwareHeadless),
    target: *Target,
    publish_software_frame: bool,
    publish_width_px: u32,
    publish_height_px: u32,

    pub const Options = struct {};

    pub fn begin(
        opts: Options,
        renderer: *rendererpkg.GenericRenderer(SoftwareHeadless),
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
        self.renderer.frameCompleted(
            .healthy,
            self.target,
            self.publish_software_frame,
            self.publish_width_px,
            self.publish_height_px,
        );
    }
};

blending: configpkg.Config.AlphaBlending,
rt_surface: ?*apprt.Surface = null,

pub fn init(_: Allocator, opts: rendererpkg.Options) !SoftwareHeadless {
    return .{
        .blending = opts.config.blending,
        .rt_surface = opts.rt_surface,
    };
}

pub fn deinit(self: *SoftwareHeadless) void {
    self.* = undefined;
}

pub fn surfaceInit(_: *apprt.Surface) !void {}
pub fn finalizeSurfaceInit(_: *const SoftwareHeadless, _: *apprt.Surface) !void {}
pub fn threadEnter(_: *const SoftwareHeadless, _: *apprt.Surface) !void {}
pub fn threadExit(_: *const SoftwareHeadless) void {}
pub fn loopEnter(_: *SoftwareHeadless) void {}
pub fn loopExit(_: *SoftwareHeadless) void {}
pub fn displayRealized(_: *const SoftwareHeadless) void {}
pub fn displayUnrealized(_: *const SoftwareHeadless) void {}
pub fn drawFrameStart(_: *SoftwareHeadless) void {}
pub fn drawFrameEnd(_: *SoftwareHeadless) void {}

pub fn initShaders(
    self: *const SoftwareHeadless,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    _ = self;
    _ = alloc;
    _ = custom_shaders;
    return .{};
}

pub fn surfaceSize(self: *const SoftwareHeadless) !struct { width: u32, height: u32 } {
    if (self.rt_surface) |surface| {
        const size = try surface.getSize();
        return .{
            .width = size.width,
            .height = size.height,
        };
    }

    return .{ .width = 0, .height = 0 };
}

pub fn initTarget(self: *const SoftwareHeadless, width: usize, height: usize) !Target {
    _ = self;
    return .{
        .width = @intCast(width),
        .height = @intCast(height),
    };
}

pub fn present(self: *SoftwareHeadless, target: Target) !void {
    _ = self;
    _ = target;
}

pub fn presentLastTarget(self: *SoftwareHeadless) !void {
    _ = self;
}

pub fn publishSoftwareFrame(
    self: *SoftwareHeadless,
    target: *const Target,
    screen: rendererpkg.ScreenSize,
) !?apprt.surface.Message.SoftwareFrameReady {
    _ = self;
    _ = target;
    _ = screen;
    return null;
}

pub fn bufferOptions(_: SoftwareHeadless) void {}
pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

pub fn textureOptions(_: SoftwareHeadless) Texture.Options {
    return .{};
}

pub fn samplerOptions(_: SoftwareHeadless) Sampler.Options {
    return .{};
}

pub fn imageTextureOptions(
    self: SoftwareHeadless,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    _ = self;
    _ = format;
    _ = srgb;
    return .{};
}

pub fn initAtlasTexture(
    self: *const SoftwareHeadless,
    atlas: *const @import("../font/main.zig").Atlas,
) Texture.Error!Texture {
    _ = self;
    return try Texture.init(.{}, atlas.size, atlas.size, atlas.data);
}

pub fn beginFrame(
    self: *const SoftwareHeadless,
    renderer: *@import("../renderer.zig").GenericRenderer(SoftwareHeadless),
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
