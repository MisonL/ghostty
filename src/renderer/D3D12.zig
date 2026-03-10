//! Transitional D3D12 backend scaffold.
//!
//! The long-term Windows product renderer is `Win32 + DXGI + D3D12`.
//! Current stage:
//! - native Win32 swapchain present path
//! - real D3D12 resource/pipeline layer for GenericRenderer
//! - native draw path preferred on Win32 once initialization succeeds

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
const bufferpkg = @import("d3d12/buffer.zig");

const log = std.log.scoped(.d3d12);

fn shouldTraceWin32D3D12Init() bool {
    const alloc = std.heap.page_allocator;
    const smoke = std.process.getEnvVarOwned(alloc, "GHOSTTY_CI_WIN32_SMOKE") catch null;
    defer if (smoke) |value| alloc.free(value);
    if (smoke) |value| {
        if (value.len > 0 and !std.mem.eql(u8, value, "0")) return true;
    }

    const label = std.process.getEnvVarOwned(alloc, "GHOSTTY_CI_INTERACTION_LABEL") catch null;
    defer if (label) |value| alloc.free(value);
    return if (label) |value| value.len > 0 else false;
}

fn traceWin32D3D12Init(step: []const u8) void {
    if (!shouldTraceWin32D3D12Init()) return;
    std.debug.print("info(renderer_d3d12): ci.win32.d3d12.step={s}\n", .{step});
    log.info("ci.win32.d3d12.step={s}", .{step});
}

pub const GraphicsAPI = D3D12;
pub const force_software_cpu_route = false;

pub const custom_shader_target: shadertoy.Target = .hlsl;
pub const custom_shader_y_is_down = false;
pub const swap_chain_count = 1;
pub const softwareFramePublicationOnCompletion = false;

pub const MIN_VERSION_MAJOR = 12;
pub const MIN_VERSION_MINOR = 0;

const srv_heap_capacity = 4096;

pub const ImageTextureFormat = enum {
    grayscale,
    bgra,
    rgba,
};

pub const Pipeline = @import("d3d12/Pipeline.zig");
pub const Buffer = bufferpkg.Buffer;
pub const shaders = @import("d3d12/shaders.zig");

const DeferredBufferRelease = struct {
    buffer: *winos.graphics.ID3D12Resource,
    was_mapped: bool,
};

fn softwareFrameReleaseReadback(
    ctx: ?*anyopaque,
    data: ?[*]const u8,
    data_len: usize,
    handle: ?*anyopaque,
) callconv(.c) void {
    _ = data;
    _ = data_len;
    _ = handle;
    const raw = ctx orelse return;
    const resource = nativePtr(*winos.c.ID3D12Resource, raw);
    resource.lpVtbl[0].Unmap.?(
        resource,
        0,
        null,
    );
    winos.graphics.release(@ptrCast(raw));
}

pub const Texture = struct {
    pub const Error = error{
        D3D12DescriptorHeapCreateFailed,
        D3D12DeviceUnavailable,
        D3D12SrvHeapExhausted,
        D3D12TextureCreateFailed,
        D3D12UploadBufferCreateFailed,
        D3D12TextureMapFailed,
        OutOfMemory,
        Unexpected,
    };

    pub const Options = struct {
        owner: *D3D12,
        resource_format: u32,
        copy_format: u32,
        srv_format: ?u32 = null,
        rtv_format: ?u32 = null,
        bytes_per_pixel: u32,
        render_target: bool = false,
        sampled: bool = true,
        swizzle_bgra_to_rgba: bool = false,
        debug_name: ?[]const u8 = null,
    };

    pub const Data = struct {
        owner: *D3D12,
        resource: *winos.graphics.ID3D12Resource,
        resource_format: u32,
        copy_format: u32,
        srv_format: ?u32,
        rtv_format: ?u32,
        bytes_per_pixel: u32,
        render_target: bool,
        sampled: bool,
        swizzle_bgra_to_rgba: bool,
        debug_name: ?[]const u8,
        state: u32,
        srv_index: ?u32 = null,
        rtv_heap: ?*winos.graphics.ID3D12DescriptorHeap = null,
        rtv_handle: winos.c.D3D12_CPU_DESCRIPTOR_HANDLE = std.mem.zeroes(winos.c.D3D12_CPU_DESCRIPTOR_HANDLE),
    };

    data: *Data,
    width: usize,
    height: usize,

    pub fn init(
        opts: Options,
        width: usize,
        height: usize,
        bytes: ?[]const u8,
    ) Error!@This() {
        var data = try opts.owner.alloc.create(Data);
        errdefer opts.owner.alloc.destroy(data);

        data.* = .{
            .owner = opts.owner,
            .resource = try createTextureResource(opts, width, height),
            .resource_format = opts.resource_format,
            .copy_format = opts.copy_format,
            .srv_format = opts.srv_format,
            .rtv_format = opts.rtv_format,
            .bytes_per_pixel = opts.bytes_per_pixel,
            .render_target = opts.render_target,
            .sampled = opts.sampled,
            .swizzle_bgra_to_rgba = opts.swizzle_bgra_to_rgba,
            .debug_name = opts.debug_name,
            .state = if (opts.render_target)
                @intCast(winos.c.D3D12_RESOURCE_STATE_RENDER_TARGET)
            else
                @intCast(winos.c.D3D12_RESOURCE_STATE_COPY_DEST),
        };
        errdefer {
            winos.graphics.release(@ptrCast(data.resource));
            opts.owner.alloc.destroy(data);
        }

        if (opts.sampled) {
            data.srv_index = try opts.owner.allocateSrvIndex();
            errdefer if (data.srv_index) |index| opts.owner.releaseSrvIndex(index);
            try opts.owner.writeTextureSrv(data);
        }

        if (opts.render_target) {
            try opts.owner.initTextureRtv(data);
        }

        var texture: Texture = .{
            .data = data,
            .width = width,
            .height = height,
        };

        if (bytes) |initial| {
            texture.replaceRegion(0, 0, width, height, initial) catch |err| {
                log.err(
                    "failed to upload initial d3d12 texture data name={s} err={}",
                    .{ data.debug_name orelse "unnamed", err },
                );
                return err;
            };
            if (opts.render_target) {
                data.state = @intCast(winos.c.D3D12_RESOURCE_STATE_RENDER_TARGET);
            }
        }

        return texture;
    }

    pub fn deinit(self: @This()) void {
        if (self.data.owner.last_target) |last_target| {
            if (last_target.texture.data == self.data) {
                self.data.owner.last_target = null;
            }
        }

        if (self.data.rtv_heap) |heap| {
            winos.graphics.release(@ptrCast(heap));
        }
        if (self.data.srv_index) |index| {
            self.data.owner.releaseSrvIndex(index);
        }
        winos.graphics.release(@ptrCast(self.data.resource));
        self.data.owner.alloc.destroy(self.data);
    }

    pub fn replaceRegion(
        self: @This(),
        x: usize,
        y: usize,
        width: usize,
        height: usize,
        bytes: []const u8,
    ) Error!void {
        try self.data.owner.uploadTextureRegion(
            self.data,
            x,
            y,
            width,
            height,
            bytes,
        );
    }
};

pub const Target = struct {
    texture: Texture,
    width: u32,
    height: u32,

    pub fn init(owner: *D3D12, width: usize, height: usize) Texture.Error!Target {
        const texture = try Texture.init(
            owner.textureOptions(),
            width,
            height,
            null,
        );
        return .{
            .texture = texture,
            .width = @intCast(width),
            .height = @intCast(height),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.texture.deinit();
    }
};

pub const Sampler = struct {
    pub const Options = struct {
        owner: *D3D12,
    };

    owner: *D3D12,

    pub fn init(opts: Options) !@This() {
        return .{ .owner = opts.owner };
    }

    pub fn deinit(self: @This()) void {
        _ = self;
    }
};

pub const RenderPass = struct {
    pub const Options = struct {
        api: *D3D12,
        attachments: []const Attachment,

        pub const Attachment = struct {
            target: union(enum) {
                texture: Texture,
                target: Target,
            },
            clear_color: ?[4]f32 = null,
        };
    };

    api: ?*D3D12 = null,
    attachments: []const Options.Attachment = &.{},
    attachment_texture: ?*Texture.Data = null,
    attachment_after_state: u32 = 0,

    pub fn begin(opts: Options) @This() {
        var pass: RenderPass = .{
            .api = opts.api,
            .attachments = opts.attachments,
        };
        pass.beginImpl() catch |err| {
            log.warn("error beginning d3d12 render pass err={}", .{err});
            pass.api = null;
            pass.attachment_texture = null;
        };
        return pass;
    }

    pub fn step(self: *@This(), s: anytype) void {
        if (self.api == null) return;
        self.stepImpl(s) catch |err| {
            log.warn("error encoding d3d12 render step err={}", .{err});
            self.api = null;
        };
    }

    pub fn complete(self: *@This()) void {
        if (self.api == null) return;
        self.completeImpl() catch |err| {
            log.warn("error completing d3d12 render pass err={}", .{err});
        };
    }

    fn beginImpl(self: *@This()) !void {
        const api = self.api orelse return;
        const command_list = api.currentCommandList() orelse return error.Unexpected;
        if (self.attachments.len == 0) return;

        const texture = attachmentTexture(self.attachments[0]);
        self.attachment_texture = texture;
        self.attachment_after_state = switch (self.attachments[0].target) {
            .texture => @intCast(winos.c.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE),
            .target => @intCast(winos.c.D3D12_RESOURCE_STATE_RENDER_TARGET),
        };

        try api.transitionTextureState(
            command_list,
            texture,
            @intCast(winos.c.D3D12_RESOURCE_STATE_RENDER_TARGET),
        );

        var rtv_handle = texture.rtv_handle;
        command_list.lpVtbl[0].OMSetRenderTargets.?(
            command_list,
            1,
            &rtv_handle,
            winos.FALSE,
            null,
        );

        const viewport = winos.c.D3D12_VIEWPORT{
            .TopLeftX = 0,
            .TopLeftY = 0,
            .Width = @floatFromInt(switch (self.attachments[0].target) {
                .texture => |t| t.width,
                .target => |t| t.width,
            }),
            .Height = @floatFromInt(switch (self.attachments[0].target) {
                .texture => |t| t.height,
                .target => |t| t.height,
            }),
            .MinDepth = 0.0,
            .MaxDepth = 1.0,
        };
        command_list.lpVtbl[0].RSSetViewports.?(
            command_list,
            1,
            &viewport,
        );

        const rect = winos.c.D3D12_RECT{
            .left = 0,
            .top = 0,
            .right = @intCast(switch (self.attachments[0].target) {
                .texture => |t| t.width,
                .target => |t| t.width,
            }),
            .bottom = @intCast(switch (self.attachments[0].target) {
                .texture => |t| t.height,
                .target => |t| t.height,
            }),
        };
        command_list.lpVtbl[0].RSSetScissorRects.?(
            command_list,
            1,
            &rect,
        );

        if (self.attachments[0].clear_color) |clear_color| {
            command_list.lpVtbl[0].ClearRenderTargetView.?(
                command_list,
                rtv_handle,
                &clear_color,
                0,
                null,
            );
        }
    }

    fn stepImpl(self: *@This(), s: anytype) !void {
        const instance_count: usize = if (@hasField(@TypeOf(s.draw), "instance_count"))
            s.draw.instance_count
        else
            1;
        if (instance_count == 0) return;

        const api = self.api orelse return;
        const command_list = api.currentCommandList() orelse return error.Unexpected;
        const pipeline = s.pipeline;
        if (!pipeline.isReady()) return;

        command_list.lpVtbl[0].SetPipelineState.?(
            command_list,
            nativePtr(*winos.c.ID3D12PipelineState, pipeline.pipeline_state.?),
        );
        command_list.lpVtbl[0].SetGraphicsRootSignature.?(
            command_list,
            nativePtr(*winos.c.ID3D12RootSignature, pipeline.root_signature.?),
        );

        if (@hasField(@TypeOf(s), "uniforms")) {
            if (s.uniforms) |uniforms| {
                const resource = nativePtr(*winos.c.ID3D12Resource, uniforms);
                command_list.lpVtbl[0].SetGraphicsRootConstantBufferView.?(
                    command_list,
                    0,
                    resource.lpVtbl[0].GetGPUVirtualAddress.?(resource),
                );
            }
        }

        if (@hasField(@TypeOf(s), "buffers")) {
            if (s.buffers.len > 1) if (s.buffers[1]) |buffer| {
                const resource = nativePtr(*winos.c.ID3D12Resource, buffer);
                command_list.lpVtbl[0].SetGraphicsRootShaderResourceView.?(
                    command_list,
                    1,
                    resource.lpVtbl[0].GetGPUVirtualAddress.?(resource),
                );
            };
        }

        if (@hasField(@TypeOf(s), "textures") and s.textures.len > 0) {
            const heap = api.srvHeap() orelse return error.Unexpected;
            const native_heap = nativePtr(*winos.c.ID3D12DescriptorHeap, heap);
            const heaps = [_][*c]winos.c.ID3D12DescriptorHeap{
                @ptrCast(native_heap),
            };
            command_list.lpVtbl[0].SetDescriptorHeaps.?(
                command_list,
                1,
                @ptrCast(&heaps),
            );

            if (@typeInfo(@TypeOf(s.textures[0])) == .optional) {
                if (s.textures[0]) |tex| {
                    try api.transitionTextureState(
                        command_list,
                        tex.data,
                        @intCast(winos.c.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE),
                    );
                    command_list.lpVtbl[0].SetGraphicsRootDescriptorTable.?(
                        command_list,
                        2,
                        api.srvGpuHandleForIndex(tex.data.srv_index.?),
                    );
                }
            } else {
                const tex = s.textures[0];
                try api.transitionTextureState(
                    command_list,
                    tex.data,
                    @intCast(winos.c.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE),
                );
                command_list.lpVtbl[0].SetGraphicsRootDescriptorTable.?(
                    command_list,
                    2,
                    api.srvGpuHandleForIndex(tex.data.srv_index.?),
                );
            }
            if (s.textures.len > 1) {
                if (@typeInfo(@TypeOf(s.textures[1])) == .optional) {
                    if (s.textures[1]) |tex| {
                        try api.transitionTextureState(
                            command_list,
                            tex.data,
                            @intCast(winos.c.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE),
                        );
                        command_list.lpVtbl[0].SetGraphicsRootDescriptorTable.?(
                            command_list,
                            3,
                            api.srvGpuHandleForIndex(tex.data.srv_index.?),
                        );
                    }
                } else {
                    const tex = s.textures[1];
                    try api.transitionTextureState(
                        command_list,
                        tex.data,
                        @intCast(winos.c.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE),
                    );
                    command_list.lpVtbl[0].SetGraphicsRootDescriptorTable.?(
                        command_list,
                        3,
                        api.srvGpuHandleForIndex(tex.data.srv_index.?),
                    );
                }
            }
        }

        if (@hasField(@TypeOf(s), "buffers") and s.buffers.len > 0 and pipeline.vertex_stride > 0) {
            if (s.buffers[0]) |buffer| {
                var view = vertexBufferView(buffer, pipeline.vertex_stride);
                command_list.lpVtbl[0].IASetVertexBuffers.?(
                    command_list,
                    0,
                    1,
                    &view,
                );
            }
        }

        command_list.lpVtbl[0].IASetPrimitiveTopology.?(
            command_list,
            pipeline.primitive_topology,
        );
        command_list.lpVtbl[0].DrawInstanced.?(
            command_list,
            @intCast(s.draw.vertex_count),
            @intCast(instance_count),
            0,
            0,
        );
    }

    fn completeImpl(self: *@This()) !void {
        const api = self.api orelse return;
        const command_list = api.currentCommandList() orelse return error.Unexpected;
        if (self.attachment_texture) |texture| {
            try api.transitionTextureState(
                command_list,
                texture,
                self.attachment_after_state,
            );
        }
    }

    fn attachmentTexture(attachment: Options.Attachment) *Texture.Data {
        return switch (attachment.target) {
            .texture => |texture| texture.data,
            .target => |target| target.texture.data,
        };
    }
};

pub const Frame = struct {
    api: *D3D12,
    renderer: *rendererpkg.GenericRenderer(D3D12),
    target: *Target,
    publish_software_frame: bool,
    publish_width_px: u32,
    publish_height_px: u32,

    pub const Options = struct {};

    pub fn begin(
        opts: Options,
        api: *D3D12,
        renderer: *rendererpkg.GenericRenderer(D3D12),
        target: *Target,
        publish_software_frame: bool,
        publish_width_px: u32,
        publish_height_px: u32,
    ) !Frame {
        _ = opts;
        return .{
            .api = api,
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
        return RenderPass.begin(.{
            .api = self.api,
            .attachments = attachments,
        });
    }

    pub fn complete(self: *const Frame, sync: bool) void {
        _ = sync;

        const health: Health = .healthy;
        self.api.present(self.target.*) catch |err| {
            log.err("failed to present d3d12 render target err={}", .{err});
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

alloc: Allocator,
blending: configpkg.Config.AlphaBlending,
dxgi_factory: ?*winos.graphics.IDXGIFactory4 = null,
d3d12_device: ?*winos.graphics.ID3D12Device = null,
dwrite_factory: ?*winos.graphics.IDWriteFactory = null,
swap_chain: ?*winos.graphics.IDXGISwapChain3 = null,
command_queue: ?*winos.graphics.ID3D12CommandQueue = null,
rt_surface: ?*apprt.Surface = null,
last_target: ?Target = null,
last_present_generation: u64 = 0,
software_generation: u64 = 0,
has_native_present_path: bool = false,
has_native_draw_path: bool = false,
srv_descriptor_size: u32 = 0,
srv_heap_cpu_start_ptr: u64 = 0,
srv_heap_gpu_start_ptr: u64 = 0,
next_srv_index: u32 = 0,
free_srv_indices: std.ArrayListUnmanaged(u32) = .empty,
deferred_buffer_releases: std.ArrayListUnmanaged(DeferredBufferRelease) = .empty,
command_recording_active: bool = false,

pub fn init(alloc: Allocator, opts: rendererpkg.Options) !D3D12 {
    traceWin32D3D12Init("renderer.init.begin");
    var result: D3D12 = .{
        .alloc = alloc,
        .blending = opts.config.blending,
    };
    result.rt_surface = opts.rt_surface;
    if (@hasField(@TypeOf(opts.rt_surface.*), "graphics")) {
        if (opts.rt_surface.graphics.dxgi_factory) |raw| {
            result.dxgi_factory = @ptrCast(raw);
        }
        if (opts.rt_surface.graphics.d3d12_device) |raw| {
            result.d3d12_device = @ptrCast(raw);
        }
        if (opts.rt_surface.graphics.dwrite_factory) |raw| {
            result.dwrite_factory = raw;
        }
        if (opts.rt_surface.graphics.swap_chain) |raw| {
            result.swap_chain = @ptrCast(raw);
        }
        if (opts.rt_surface.graphics.command_queue) |raw| {
            result.command_queue = @ptrCast(raw);
        }
    }
    result.has_native_present_path = result.swap_chain != null;
    if (result.d3d12_device != null) {
        traceWin32D3D12Init("renderer.init.ensure_srv_heap.begin");
        try result.ensureSrvHeap();
        traceWin32D3D12Init("renderer.init.ensure_srv_heap.ready");
    }
    result.has_native_draw_path = result.has_native_present_path and result.d3d12_device != null;
    traceWin32D3D12Init("renderer.init.ready");
    return result;
}

pub fn deinit(self: *D3D12) void {
    self.flushDeferredBufferReleases();
    self.free_srv_indices.deinit(self.alloc);
    self.deferred_buffer_releases.deinit(self.alloc);
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
    return try shaders.Shaders.init(alloc, self.d3d12_device, custom_shaders);
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
    return try Target.init(@constCast(self), width, height);
}

pub fn present(self: *D3D12, target: Target) !void {
    if (!self.command_recording_active) {
        _ = try self.beginCommandRecording();
    }
    defer self.last_target = target;

    try self.appendPresentCopy(target);
    try self.executeRecordedCommands();

    const sc = self.currentSwapChain() orelse return error.Unexpected;
    if (sc.lpVtbl[0].Present.?(sc, 1, 0) != winos.S_OK) {
        return error.Unexpected;
    }

    try self.waitForGpuIdle();
    self.flushDeferredBufferReleases();
    self.updateCurrentFrameIndex(sc);
    self.last_present_generation +%= 1;
}

pub fn presentLastTarget(self: *D3D12) !void {
    if (self.last_target) |target| {
        try self.present(target);
        return;
    }

    const sc = self.currentSwapChain() orelse return error.Unexpected;
    if (sc.lpVtbl[0].Present.?(sc, 1, 0) != winos.S_OK) return error.Unexpected;
    try self.waitForGpuIdle();
    self.updateCurrentFrameIndex(sc);
}

pub fn publishSoftwareFrame(
    self: *D3D12,
    target: *const Target,
    screen: rendererpkg.ScreenSize,
) !?apprt.surface.Message.SoftwareFrameReady {
    _ = screen;

    if (target.width == 0 or target.height == 0) return null;
    const command_list = self.currentCommandList() orelse return null;

    const width_px = target.width;
    const height_px = target.height;
    const row_pitch = std.mem.alignForward(
        u32,
        width_px * 4,
        winos.c.D3D12_TEXTURE_DATA_PITCH_ALIGNMENT,
    );
    const data_len = std.math.mul(
        usize,
        @as(usize, row_pitch),
        @as(usize, height_px),
    ) catch return error.OutOfMemory;

    const readback = try self.createReadbackBuffer(data_len);
    errdefer winos.graphics.release(@ptrCast(readback));

    try self.transitionTextureState(
        command_list,
        target.texture.data,
        @intCast(winos.c.D3D12_RESOURCE_STATE_COPY_SOURCE),
    );

    const src_location: winos.c.D3D12_TEXTURE_COPY_LOCATION = .{
        .pResource = nativePtr(*winos.c.ID3D12Resource, target.texture.data.resource),
        .Type = winos.c.D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX,
        .unnamed_0 = .{ .SubresourceIndex = 0 },
    };
    const dst_location: winos.c.D3D12_TEXTURE_COPY_LOCATION = .{
        .pResource = nativePtr(*winos.c.ID3D12Resource, readback),
        .Type = winos.c.D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT,
        .unnamed_0 = .{
            .PlacedFootprint = .{
                .Offset = 0,
                .Footprint = .{
                    .Format = target.texture.data.copy_format,
                    .Width = width_px,
                    .Height = height_px,
                    .Depth = 1,
                    .RowPitch = row_pitch,
                },
            },
        },
    };
    command_list.lpVtbl[0].CopyTextureRegion.?(
        command_list,
        &dst_location,
        0,
        0,
        0,
        &src_location,
        null,
    );

    try self.executeRecordedCommands();
    try self.waitForGpuIdle();
    self.flushDeferredBufferReleases();

    var mapped: ?*anyopaque = null;
    const native = nativePtr(*winos.c.ID3D12Resource, readback);
    if (native.lpVtbl[0].Map.?(
        native,
        0,
        null,
        &mapped,
    ) != winos.S_OK or mapped == null) {
        winos.graphics.release(@ptrCast(readback));
        return error.Unexpected;
    }

    self.software_generation +%= 1;

    return .{
        .width_px = width_px,
        .height_px = height_px,
        .stride_bytes = row_pitch,
        .generation = self.software_generation,
        .pixel_format = .bgra8_premul,
        .storage = .shared_cpu_bytes,
        .data = @ptrCast(mapped),
        .data_len = data_len,
        .handle = null,
        .release_ctx = @ptrCast(readback),
        .release_fn = &softwareFrameReleaseReadback,
    };
}

pub fn bufferOptions(self: *const D3D12) bufferpkg.Options {
    return .{
        .device = self.d3d12_device,
        .defer_release_ctx = @ptrCast(@constCast(self)),
        .defer_release_fn = deferReleaseBuffer,
    };
}
pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

pub fn textureOptions(self: *const D3D12) Texture.Options {
    const format = self.renderTargetViewFormat();
    return .{
        .owner = @constCast(self),
        .resource_format = renderTargetResourceFormat(format),
        .copy_format = renderTargetCopyFormat(format),
        .srv_format = format,
        .rtv_format = format,
        .bytes_per_pixel = 4,
        .render_target = true,
        .sampled = true,
        .swizzle_bgra_to_rgba = false,
        .debug_name = "render-target",
    };
}

pub fn samplerOptions(self: *const D3D12) Sampler.Options {
    return .{ .owner = @constCast(self) };
}

pub fn imageTextureOptions(
    self: *const D3D12,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    // Hosted Windows runners consistently remove the D3D12 device when we
    // create sampled sRGB textures, so we store color textures as UNORM and
    // linearize them explicitly in the D3D12 shader path.
    const storage_format = imageDxgiFormat(format, false);
    return .{
        .owner = @constCast(self),
        .resource_format = storage_format,
        .copy_format = storage_format,
        .srv_format = storage_format,
        .bytes_per_pixel = switch (format) {
            .grayscale => 1,
            .bgra, .rgba => 4,
        },
        .render_target = false,
        .sampled = true,
        .swizzle_bgra_to_rgba = false,
        .debug_name = switch (format) {
            .grayscale => "image-grayscale",
            .bgra => if (srgb) "image-bgra-srgb" else "image-bgra",
            .rgba => if (srgb) "image-rgba-srgb" else "image-rgba",
        },
    };
}

pub fn initAtlasTexture(
    self: *const D3D12,
    atlas: *const @import("../font/main.zig").Atlas,
) Texture.Error!Texture {
    const format: ImageTextureFormat = switch (atlas.format) {
        .grayscale => .grayscale,
        .bgr => return error.Unexpected,
        .bgra => .rgba,
    };
    var opts = @constCast(self).imageTextureOptions(format, atlas.format == .bgra);
    if (atlas.format == .bgra) {
        opts.swizzle_bgra_to_rgba = true;
        opts.debug_name = "atlas-color-rgba-unorm";
    } else {
        opts.debug_name = "atlas-grayscale";
    }
    return try Texture.init(
        opts,
        atlas.size,
        atlas.size,
        atlas.data,
    );
}

pub fn beginFrame(
    self: *D3D12,
    renderer: *@import("../renderer.zig").GenericRenderer(D3D12),
    target: *Target,
    publish_software_frame: bool,
    publish_width_px: u32,
    publish_height_px: u32,
) !Frame {
    _ = try self.beginCommandRecording();
    return try Frame.begin(
        .{},
        self,
        renderer,
        target,
        publish_software_frame,
        publish_width_px,
        publish_height_px,
    );
}

fn ensureSrvHeap(self: *D3D12) !void {
    traceWin32D3D12Init("renderer.ensure_srv_heap.enter");
    const device = self.currentDevice() orelse return error.D3D12DeviceUnavailable;
    if (self.srvHeap()) |heap| {
        if (self.srv_descriptor_size != 0) return;

        traceWin32D3D12Init("renderer.ensure_srv_heap.reuse.begin");
        const native_heap = nativePtr(*winos.c.ID3D12DescriptorHeap, heap);
        var cpu_handle: winos.c.D3D12_CPU_DESCRIPTOR_HANDLE = std.mem.zeroes(winos.c.D3D12_CPU_DESCRIPTOR_HANDLE);
        var gpu_handle: winos.c.D3D12_GPU_DESCRIPTOR_HANDLE = std.mem.zeroes(winos.c.D3D12_GPU_DESCRIPTOR_HANDLE);
        _ = native_heap.lpVtbl[0].GetCPUDescriptorHandleForHeapStart.?(native_heap, &cpu_handle);
        _ = native_heap.lpVtbl[0].GetGPUDescriptorHandleForHeapStart.?(native_heap, &gpu_handle);

        self.srv_descriptor_size = device.lpVtbl[0].GetDescriptorHandleIncrementSize.?(
            device,
            winos.c.D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,
        );
        self.srv_heap_cpu_start_ptr = cpu_handle.ptr;
        self.srv_heap_gpu_start_ptr = gpu_handle.ptr;
        traceWin32D3D12Init("renderer.ensure_srv_heap.reuse.ready");
        return;
    }

    var desc: winos.c.D3D12_DESCRIPTOR_HEAP_DESC = std.mem.zeroes(winos.c.D3D12_DESCRIPTOR_HEAP_DESC);
    desc.Type = winos.c.D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
    desc.NumDescriptors = srv_heap_capacity;
    desc.Flags = winos.c.D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    desc.NodeMask = 0;

    var raw_heap: ?*winos.c.ID3D12DescriptorHeap = null;
    traceWin32D3D12Init("renderer.ensure_srv_heap.create.begin");
    if (device.lpVtbl[0].CreateDescriptorHeap.?(
        device,
        &desc,
        &winos.c.IID_ID3D12DescriptorHeap,
        @ptrCast(&raw_heap),
    ) != winos.S_OK or raw_heap == null) {
        return error.D3D12DescriptorHeapCreateFailed;
    }

    if (self.rt_surface) |surface| {
        if (@hasField(@TypeOf(surface.*), "graphics")) {
            surface.graphics.srv_heap = raw_heap.?;
        }
    }

    const heap = raw_heap.?;
    var cpu_handle: winos.c.D3D12_CPU_DESCRIPTOR_HANDLE = std.mem.zeroes(winos.c.D3D12_CPU_DESCRIPTOR_HANDLE);
    var gpu_handle: winos.c.D3D12_GPU_DESCRIPTOR_HANDLE = std.mem.zeroes(winos.c.D3D12_GPU_DESCRIPTOR_HANDLE);
    _ = heap.lpVtbl[0].GetCPUDescriptorHandleForHeapStart.?(heap, &cpu_handle);
    _ = heap.lpVtbl[0].GetGPUDescriptorHandleForHeapStart.?(heap, &gpu_handle);

    self.srv_descriptor_size = device.lpVtbl[0].GetDescriptorHandleIncrementSize.?(
        device,
        winos.c.D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,
    );
    self.srv_heap_cpu_start_ptr = cpu_handle.ptr;
    self.srv_heap_gpu_start_ptr = gpu_handle.ptr;
    traceWin32D3D12Init("renderer.ensure_srv_heap.create.ready");
}

fn allocateSrvIndex(self: *D3D12) !u32 {
    try self.ensureSrvHeap();
    if (self.free_srv_indices.pop()) |index| return index;
    if (self.next_srv_index >= srv_heap_capacity) return error.D3D12SrvHeapExhausted;
    defer self.next_srv_index += 1;
    return self.next_srv_index;
}

fn releaseSrvIndex(self: *D3D12, index: u32) void {
    self.free_srv_indices.append(self.alloc, index) catch {};
}

fn writeTextureSrv(self: *D3D12, texture: *Texture.Data) !void {
    const device = self.currentDevice() orelse return error.D3D12DeviceUnavailable;
    const resource = nativePtr(*winos.c.ID3D12Resource, texture.resource);
    const format = texture.srv_format orelse return error.Unexpected;
    var desc: winos.c.D3D12_SHADER_RESOURCE_VIEW_DESC =
        std.mem.zeroes(winos.c.D3D12_SHADER_RESOURCE_VIEW_DESC);
    desc.Format = format;
    desc.ViewDimension = winos.c.D3D12_SRV_DIMENSION_TEXTURE2D;
    desc.Shader4ComponentMapping = winos.c.D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
    desc.unnamed_0.Texture2D = .{
        .MostDetailedMip = 0,
        .MipLevels = 1,
        .PlaneSlice = 0,
        .ResourceMinLODClamp = 0,
    };
    device.lpVtbl[0].CreateShaderResourceView.?(
        device,
        resource,
        &desc,
        self.srvCpuHandleForIndex(texture.srv_index.?),
    );
}

fn initTextureRtv(self: *D3D12, texture: *Texture.Data) !void {
    const device = self.currentDevice() orelse return error.D3D12DeviceUnavailable;
    const format = texture.rtv_format orelse return error.Unexpected;

    var heap_desc: winos.c.D3D12_DESCRIPTOR_HEAP_DESC =
        std.mem.zeroes(winos.c.D3D12_DESCRIPTOR_HEAP_DESC);
    heap_desc.Type = winos.c.D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
    heap_desc.NumDescriptors = 1;
    heap_desc.Flags = winos.c.D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
    heap_desc.NodeMask = 0;

    var raw_heap: ?*anyopaque = null;
    if (device.lpVtbl[0].CreateDescriptorHeap.?(
        device,
        &heap_desc,
        &winos.c.IID_ID3D12DescriptorHeap,
        &raw_heap,
    ) != winos.S_OK or raw_heap == null) {
        return error.D3D12DescriptorHeapCreateFailed;
    }

    texture.rtv_heap = @ptrCast(raw_heap.?);
    const heap = nativePtr(*winos.c.ID3D12DescriptorHeap, texture.rtv_heap.?);
    _ = heap.lpVtbl[0].GetCPUDescriptorHandleForHeapStart.?(
        heap,
        &texture.rtv_handle,
    );
    var view_desc: winos.c.D3D12_RENDER_TARGET_VIEW_DESC =
        std.mem.zeroes(winos.c.D3D12_RENDER_TARGET_VIEW_DESC);
    view_desc.Format = format;
    view_desc.ViewDimension = winos.c.D3D12_RTV_DIMENSION_TEXTURE2D;
    view_desc.unnamed_0.Texture2D = .{
        .MipSlice = 0,
        .PlaneSlice = 0,
    };
    device.lpVtbl[0].CreateRenderTargetView.?(
        device,
        nativePtr(*winos.c.ID3D12Resource, texture.resource),
        &view_desc,
        texture.rtv_handle,
    );
}

fn uploadTextureRegion(
    self: *D3D12,
    texture: *Texture.Data,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    bytes: []const u8,
) Texture.Error!void {
    const device = self.currentDevice() orelse return error.D3D12DeviceUnavailable;
    const resource = nativePtr(*winos.c.ID3D12Resource, texture.resource);
    const command_list = try self.beginCommandRecording();
    errdefer {
        self.command_recording_active = false;
        self.flushDeferredBufferReleases();
    }

    var footprint_desc: winos.c.D3D12_RESOURCE_DESC =
        std.mem.zeroes(winos.c.D3D12_RESOURCE_DESC);
    footprint_desc.Dimension = winos.c.D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    footprint_desc.Alignment = 0;
    footprint_desc.Width = width;
    footprint_desc.Height = @intCast(height);
    footprint_desc.DepthOrArraySize = 1;
    footprint_desc.MipLevels = 1;
    footprint_desc.Format = texture.copy_format;
    footprint_desc.SampleDesc = .{ .Count = 1, .Quality = 0 };
    footprint_desc.Layout = winos.c.D3D12_TEXTURE_LAYOUT_UNKNOWN;
    footprint_desc.Flags = winos.c.D3D12_RESOURCE_FLAG_NONE;

    var placed_footprint: winos.c.D3D12_PLACED_SUBRESOURCE_FOOTPRINT =
        std.mem.zeroes(winos.c.D3D12_PLACED_SUBRESOURCE_FOOTPRINT);
    var num_rows: u32 = 0;
    var row_size_in_bytes: u64 = 0;
    var upload_size: u64 = 0;
    device.lpVtbl[0].GetCopyableFootprints.?(
        device,
        &footprint_desc,
        0,
        1,
        0,
        &placed_footprint,
        &num_rows,
        &row_size_in_bytes,
        &upload_size,
    );
    const row_pitch = placed_footprint.Footprint.RowPitch;

    var heap_props: winos.c.D3D12_HEAP_PROPERTIES =
        std.mem.zeroes(winos.c.D3D12_HEAP_PROPERTIES);
    heap_props.Type = winos.c.D3D12_HEAP_TYPE_UPLOAD;
    heap_props.CreationNodeMask = 1;
    heap_props.VisibleNodeMask = 1;

    var upload_desc: winos.c.D3D12_RESOURCE_DESC =
        std.mem.zeroes(winos.c.D3D12_RESOURCE_DESC);
    upload_desc.Dimension = winos.c.D3D12_RESOURCE_DIMENSION_BUFFER;
    upload_desc.Width = upload_size;
    upload_desc.Height = 1;
    upload_desc.DepthOrArraySize = 1;
    upload_desc.MipLevels = 1;
    upload_desc.SampleDesc = .{ .Count = 1, .Quality = 0 };
    upload_desc.Layout = winos.c.D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    upload_desc.Flags = winos.c.D3D12_RESOURCE_FLAG_NONE;

    var raw_upload: ?*anyopaque = null;
    if (device.lpVtbl[0].CreateCommittedResource.?(
        device,
        &heap_props,
        winos.c.D3D12_HEAP_FLAG_NONE,
        &upload_desc,
        winos.c.D3D12_RESOURCE_STATE_GENERIC_READ,
        null,
        &winos.c.IID_ID3D12Resource,
        &raw_upload,
    ) != winos.S_OK or raw_upload == null) {
        logDeviceRemovedReason(device, "create upload buffer");
        log.err(
            "failed to create d3d12 upload buffer name={s} width={} height={} upload_size={} row_pitch={} rows={}",
            .{ texture.debug_name orelse "unnamed", width, height, upload_size, row_pitch, num_rows },
        );
        return error.D3D12UploadBufferCreateFailed;
    }
    defer winos.graphics.release(raw_upload);

    const upload = nativePtr(*winos.c.ID3D12Resource, raw_upload.?);
    var mapped: ?*anyopaque = null;
    if (upload.lpVtbl[0].Map.?(
        upload,
        0,
        null,
        &mapped,
    ) != winos.S_OK or mapped == null) {
        logDeviceRemovedReason(device, "map upload buffer");
        log.err(
            "failed to map d3d12 upload buffer name={s} width={} height={} upload_size={}",
            .{ texture.debug_name orelse "unnamed", width, height, upload_size },
        );
        return error.D3D12TextureMapFailed;
    }
    defer upload.lpVtbl[0].Unmap.?(
        upload,
        0,
        null,
    );

    const dst: [*]u8 = @ptrCast(mapped.?);
    const src_stride = width * texture.bytes_per_pixel;
    if (row_size_in_bytes != src_stride) {
        log.warn(
            "d3d12 copy footprint row size differs from expected name={s} row_size={} expected_stride={} row_pitch={} rows={}",
            .{ texture.debug_name orelse "unnamed", row_size_in_bytes, src_stride, row_pitch, num_rows },
        );
    }
    var row: usize = 0;
    while (row < height) : (row += 1) {
        const src_off = row * src_stride;
        const dst_off = row * @as(usize, row_pitch);
        const src_row = bytes[src_off .. src_off + src_stride];
        const dst_row = dst[dst_off .. dst_off + src_stride];
        if (texture.swizzle_bgra_to_rgba) {
            var px: usize = 0;
            while (px < src_stride) : (px += 4) {
                dst_row[px + 0] = src_row[px + 2];
                dst_row[px + 1] = src_row[px + 1];
                dst_row[px + 2] = src_row[px + 0];
                dst_row[px + 3] = src_row[px + 3];
            }
        } else {
            @memcpy(dst_row, src_row);
        }
        if (@as(usize, row_pitch) > src_stride) {
            @memset(dst[dst_off + src_stride .. dst_off + @as(usize, row_pitch)], 0);
        }
    }

    try self.transitionTextureState(
        command_list,
        texture,
        @intCast(winos.c.D3D12_RESOURCE_STATE_COPY_DEST),
    );

    const dst_location: winos.c.D3D12_TEXTURE_COPY_LOCATION = .{
        .pResource = resource,
        .Type = winos.c.D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX,
        .unnamed_0 = .{ .SubresourceIndex = 0 },
    };
    const src_location: winos.c.D3D12_TEXTURE_COPY_LOCATION = .{
        .pResource = upload,
        .Type = winos.c.D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT,
        .unnamed_0 = .{ .PlacedFootprint = placed_footprint },
    };
    command_list.lpVtbl[0].CopyTextureRegion.?(
        command_list,
        &dst_location,
        @intCast(x),
        @intCast(y),
        0,
        &src_location,
        null,
    );

    const after_state: u32 = if (texture.render_target)
        @intCast(winos.c.D3D12_RESOURCE_STATE_RENDER_TARGET)
    else
        @intCast(winos.c.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
    try self.transitionTextureState(
        command_list,
        texture,
        after_state,
    );

    try self.executeRecordedCommands();
    try self.waitForGpuIdle();
    self.flushDeferredBufferReleases();
}

fn createReadbackBuffer(
    self: *D3D12,
    size_bytes: usize,
) !*winos.graphics.ID3D12Resource {
    const device = self.currentDevice() orelse return error.D3D12DeviceUnavailable;

    var heap_props: winos.c.D3D12_HEAP_PROPERTIES =
        std.mem.zeroes(winos.c.D3D12_HEAP_PROPERTIES);
    heap_props.Type = winos.c.D3D12_HEAP_TYPE_READBACK;
    heap_props.CreationNodeMask = 1;
    heap_props.VisibleNodeMask = 1;

    var desc: winos.c.D3D12_RESOURCE_DESC =
        std.mem.zeroes(winos.c.D3D12_RESOURCE_DESC);
    desc.Dimension = winos.c.D3D12_RESOURCE_DIMENSION_BUFFER;
    desc.Width = size_bytes;
    desc.Height = 1;
    desc.DepthOrArraySize = 1;
    desc.MipLevels = 1;
    desc.SampleDesc = .{ .Count = 1, .Quality = 0 };
    desc.Layout = winos.c.D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    desc.Flags = winos.c.D3D12_RESOURCE_FLAG_NONE;

    var raw_resource: ?*anyopaque = null;
    if (device.lpVtbl[0].CreateCommittedResource.?(
        device,
        &heap_props,
        winos.c.D3D12_HEAP_FLAG_NONE,
        &desc,
        @intCast(winos.c.D3D12_RESOURCE_STATE_COPY_DEST),
        null,
        &winos.c.IID_ID3D12Resource,
        &raw_resource,
    ) != winos.S_OK or raw_resource == null) {
        return error.Unexpected;
    }

    return @ptrCast(raw_resource.?);
}

fn appendPresentCopy(self: *D3D12, target: Target) !void {
    const command_list = self.currentCommandList() orelse return error.Unexpected;
    const backbuffer = self.currentBackbufferResource() orelse return error.Unexpected;
    const source = nativePtr(*winos.c.ID3D12Resource, target.texture.data.resource);

    try self.transitionTextureState(
        command_list,
        target.texture.data,
        @intCast(winos.c.D3D12_RESOURCE_STATE_COPY_SOURCE),
    );

    var barrier = transitionBarrier(
        backbuffer,
        winos.c.D3D12_RESOURCE_STATE_PRESENT,
        winos.c.D3D12_RESOURCE_STATE_COPY_DEST,
    );
    command_list.lpVtbl[0].ResourceBarrier.?(
        command_list,
        1,
        &barrier,
    );

    const dst_location: winos.c.D3D12_TEXTURE_COPY_LOCATION = .{
        .pResource = backbuffer,
        .Type = winos.c.D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX,
        .unnamed_0 = .{ .SubresourceIndex = 0 },
    };
    const src_location: winos.c.D3D12_TEXTURE_COPY_LOCATION = .{
        .pResource = source,
        .Type = winos.c.D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX,
        .unnamed_0 = .{ .SubresourceIndex = 0 },
    };
    command_list.lpVtbl[0].CopyTextureRegion.?(
        command_list,
        &dst_location,
        0,
        0,
        0,
        &src_location,
        null,
    );

    barrier = transitionBarrier(
        backbuffer,
        winos.c.D3D12_RESOURCE_STATE_COPY_DEST,
        winos.c.D3D12_RESOURCE_STATE_PRESENT,
    );
    command_list.lpVtbl[0].ResourceBarrier.?(
        command_list,
        1,
        &barrier,
    );
}

fn beginCommandRecording(self: *D3D12) !*winos.c.ID3D12GraphicsCommandList {
    if (self.command_recording_active) {
        return self.currentCommandList() orelse error.Unexpected;
    }

    try self.waitForGpuIdle();

    const allocator = self.currentCommandAllocator() orelse return error.Unexpected;
    const command_list = self.currentCommandList() orelse return error.Unexpected;
    if (allocator.lpVtbl[0].Reset.?(allocator) != winos.S_OK) return error.Unexpected;
    if (command_list.lpVtbl[0].Reset.?(
        command_list,
        allocator,
        null,
    ) != winos.S_OK) return error.Unexpected;

    self.command_recording_active = true;
    return command_list;
}

fn executeRecordedCommands(self: *D3D12) !void {
    if (!self.command_recording_active) return;

    const command_list = self.currentCommandList() orelse return error.Unexpected;
    const queue = self.currentQueue() orelse return error.Unexpected;
    if (command_list.lpVtbl[0].Close.?(command_list) != winos.S_OK) return error.Unexpected;

    const lists = [_][*c]winos.c.ID3D12CommandList{
        @ptrCast(command_list),
    };
    queue.lpVtbl[0].ExecuteCommandLists.?(
        queue,
        1,
        @ptrCast(&lists),
    );
    self.command_recording_active = false;
}

fn transitionTextureState(
    self: *D3D12,
    command_list: *winos.c.ID3D12GraphicsCommandList,
    texture: *Texture.Data,
    after_state: u32,
) !void {
    _ = self;
    if (texture.state == after_state) return;

    var barrier = transitionBarrier(
        nativePtr(*winos.c.ID3D12Resource, texture.resource),
        texture.state,
        after_state,
    );
    command_list.lpVtbl[0].ResourceBarrier.?(
        command_list,
        1,
        &barrier,
    );
    texture.state = after_state;
}

fn waitForGpuIdle(self: *D3D12) !void {
    const surface = self.rt_surface orelse return;
    if (!@hasField(@TypeOf(surface.*), "graphics")) return;
    if (surface.graphics.command_queue == null or
        surface.graphics.fence == null or
        surface.graphics.fence_event == null)
    {
        return;
    }

    const queue = surface.graphics.command_queue.?;
    const fence = surface.graphics.fence.?;
    const device = self.currentDevice();

    surface.graphics.fence_value += 1;
    const wait_value = surface.graphics.fence_value;
    if (queue.lpVtbl[0].Signal.?(
        queue,
        fence,
        wait_value,
    ) != winos.S_OK) {
        if (device) |d| logDeviceRemovedReason(d, "signal fence");
        return error.Unexpected;
    }

    if (fence.lpVtbl[0].GetCompletedValue.?(fence) < wait_value) {
        if (fence.lpVtbl[0].SetEventOnCompletion.?(
            fence,
            wait_value,
            surface.graphics.fence_event.?,
        ) != winos.S_OK) {
            if (device) |d| logDeviceRemovedReason(d, "set fence completion");
            return error.Unexpected;
        }
        if (winos.c.WaitForSingleObject(surface.graphics.fence_event.?, winos.INFINITE) == winos.WAIT_FAILED) {
            if (device) |d| logDeviceRemovedReason(d, "wait for gpu idle");
            return error.Unexpected;
        }
    }
}

fn hresultCode(hr: winos.graphics.HRESULT) u32 {
    return @bitCast(hr);
}

fn logDeviceRemovedReason(device: *winos.c.ID3D12Device, context: []const u8) void {
    const removed_hr = device.lpVtbl[0].GetDeviceRemovedReason.?(device);
    if (removed_hr == winos.S_OK) return;
    log.err(
        "d3d12 device removed reason context={s} hr=0x{x}",
        .{ context, hresultCode(removed_hr) },
    );
}

fn currentDevice(self: *const D3D12) ?*winos.c.ID3D12Device {
    return if (self.d3d12_device) |device|
        nativePtr(*winos.c.ID3D12Device, device)
    else
        null;
}

fn currentQueue(self: *const D3D12) ?*winos.c.ID3D12CommandQueue {
    return if (self.command_queue) |queue|
        nativePtr(*winos.c.ID3D12CommandQueue, queue)
    else
        null;
}

fn currentCommandAllocator(self: *const D3D12) ?*winos.c.ID3D12CommandAllocator {
    const surface = self.rt_surface orelse return null;
    if (!@hasField(@TypeOf(surface.*), "graphics")) return null;
    return surface.graphics.command_allocator;
}

fn currentCommandList(self: *const D3D12) ?*winos.c.ID3D12GraphicsCommandList {
    const surface = self.rt_surface orelse return null;
    if (!@hasField(@TypeOf(surface.*), "graphics")) return null;
    return surface.graphics.command_list;
}

fn currentSwapChain(self: *const D3D12) ?*winos.c.IDXGISwapChain3 {
    return if (self.swap_chain) |swap_chain|
        nativePtr(*winos.c.IDXGISwapChain3, swap_chain)
    else
        null;
}

fn srvHeap(self: *const D3D12) ?*winos.graphics.ID3D12DescriptorHeap {
    const surface = self.rt_surface orelse return null;
    if (!@hasField(@TypeOf(surface.*), "graphics")) return null;
    return if (surface.graphics.srv_heap) |raw| @ptrCast(raw) else null;
}

fn currentBackbufferResource(self: *const D3D12) ?*winos.c.ID3D12Resource {
    const surface = self.rt_surface orelse return null;
    if (!@hasField(@TypeOf(surface.*), "graphics")) return null;
    const index: usize = @intCast(surface.graphics.frame_index);
    if (index >= surface.graphics.backbuffers.len) return null;
    return surface.graphics.backbuffers[index];
}

fn updateCurrentFrameIndex(self: *D3D12, sc: *winos.c.IDXGISwapChain3) void {
    if (self.rt_surface) |surface| {
        if (@hasField(@TypeOf(surface.*), "graphics")) {
            surface.graphics.frame_index = sc.lpVtbl[0].GetCurrentBackBufferIndex.?(sc);
        }
    }
}

fn renderTargetViewFormat(self: *const D3D12) u32 {
    return if (self.blending.isLinear())
        @intCast(winos.c.DXGI_FORMAT_B8G8R8A8_UNORM_SRGB)
    else
        @intCast(winos.c.DXGI_FORMAT_B8G8R8A8_UNORM);
}

fn renderTargetResourceFormat(view_format: u32) u32 {
    return switch (view_format) {
        winos.c.DXGI_FORMAT_B8G8R8A8_UNORM,
        winos.c.DXGI_FORMAT_B8G8R8A8_UNORM_SRGB,
        => @intCast(winos.c.DXGI_FORMAT_B8G8R8A8_TYPELESS),
        else => view_format,
    };
}

fn renderTargetCopyFormat(view_format: u32) u32 {
    return switch (view_format) {
        winos.c.DXGI_FORMAT_B8G8R8A8_UNORM_SRGB => @intCast(winos.c.DXGI_FORMAT_B8G8R8A8_UNORM),
        else => view_format,
    };
}

fn srvCpuHandleForIndex(self: *const D3D12, index: u32) winos.c.D3D12_CPU_DESCRIPTOR_HANDLE {
    return .{
        .ptr = self.srv_heap_cpu_start_ptr +
            (@as(u64, index) * @as(u64, self.srv_descriptor_size)),
    };
}

fn srvGpuHandleForIndex(self: *const D3D12, index: u32) winos.c.D3D12_GPU_DESCRIPTOR_HANDLE {
    return .{
        .ptr = self.srv_heap_gpu_start_ptr +
            (@as(u64, index) * @as(u64, self.srv_descriptor_size)),
    };
}

fn flushDeferredBufferReleases(self: *D3D12) void {
    for (self.deferred_buffer_releases.items) |release| {
        const resource = nativePtr(*winos.c.ID3D12Resource, release.buffer);
        if (release.was_mapped) {
            resource.lpVtbl[0].Unmap.?(
                resource,
                0,
                null,
            );
        }
        winos.graphics.release(@ptrCast(release.buffer));
    }
    self.deferred_buffer_releases.clearRetainingCapacity();
}

fn deferReleaseBuffer(ctx: ?*anyopaque, buffer: *winos.graphics.ID3D12Resource, was_mapped: bool) void {
    const self: *D3D12 = @ptrCast(@alignCast(ctx orelse {
        if (was_mapped) {
            const resource = nativePtr(*winos.c.ID3D12Resource, buffer);
            resource.lpVtbl[0].Unmap.?(
                resource,
                0,
                null,
            );
        }
        winos.graphics.release(@ptrCast(buffer));
        return;
    }));

    if (!self.command_recording_active) {
        const resource = nativePtr(*winos.c.ID3D12Resource, buffer);
        if (was_mapped) {
            resource.lpVtbl[0].Unmap.?(
                resource,
                0,
                null,
            );
        }
        winos.graphics.release(@ptrCast(buffer));
        return;
    }

    self.deferred_buffer_releases.append(self.alloc, .{
        .buffer = buffer,
        .was_mapped = was_mapped,
    }) catch {
        const resource = nativePtr(*winos.c.ID3D12Resource, buffer);
        if (was_mapped) {
            resource.lpVtbl[0].Unmap.?(
                resource,
                0,
                null,
            );
        }
        winos.graphics.release(@ptrCast(buffer));
    };
}

fn createTextureResource(
    opts: Texture.Options,
    width: usize,
    height: usize,
) Texture.Error!*winos.graphics.ID3D12Resource {
    const device = opts.owner.currentDevice() orelse return error.D3D12DeviceUnavailable;

    var heap_props: winos.c.D3D12_HEAP_PROPERTIES =
        std.mem.zeroes(winos.c.D3D12_HEAP_PROPERTIES);
    heap_props.Type = winos.c.D3D12_HEAP_TYPE_DEFAULT;
    heap_props.CreationNodeMask = 1;
    heap_props.VisibleNodeMask = 1;

    var desc: winos.c.D3D12_RESOURCE_DESC =
        std.mem.zeroes(winos.c.D3D12_RESOURCE_DESC);
    desc.Dimension = winos.c.D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    desc.Alignment = 0;
    desc.Width = width;
    desc.Height = @intCast(height);
    desc.DepthOrArraySize = 1;
    desc.MipLevels = 1;
    desc.Format = opts.resource_format;
    desc.SampleDesc = .{ .Count = 1, .Quality = 0 };
    desc.Layout = winos.c.D3D12_TEXTURE_LAYOUT_UNKNOWN;
    desc.Flags = if (opts.render_target)
        winos.c.D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET
    else
        winos.c.D3D12_RESOURCE_FLAG_NONE;

    const initial_state: winos.c.D3D12_RESOURCE_STATES = if (opts.render_target)
        @intCast(winos.c.D3D12_RESOURCE_STATE_RENDER_TARGET)
    else
        @intCast(winos.c.D3D12_RESOURCE_STATE_COPY_DEST);

    var clear_value: winos.c.D3D12_CLEAR_VALUE = std.mem.zeroes(winos.c.D3D12_CLEAR_VALUE);
    const clear_value_ptr: ?*const winos.c.D3D12_CLEAR_VALUE = if (opts.render_target) blk: {
        clear_value.Format = opts.rtv_format orelse return error.Unexpected;
        clear_value.unnamed_0.Color = .{ 0.0, 0.0, 0.0, 0.0 };
        break :blk &clear_value;
    } else null;

    var raw_resource: ?*anyopaque = null;
    const hr = device.lpVtbl[0].CreateCommittedResource.?(
        device,
        &heap_props,
        winos.c.D3D12_HEAP_FLAG_NONE,
        &desc,
        initial_state,
        clear_value_ptr,
        &winos.c.IID_ID3D12Resource,
        &raw_resource,
    );
    if (hr != winos.S_OK or raw_resource == null) {
        logDeviceRemovedReason(device, "create texture resource");
        log.err(
            "failed to create d3d12 texture resource name={s} hr=0x{x} resource_format=0x{x} copy_format=0x{x} srv_format=0x{x} rtv_format=0x{x} render_target={} sampled={} initial_state=0x{x} width={} height={}",
            .{ opts.debug_name orelse "unnamed", hresultCode(hr), opts.resource_format, opts.copy_format, opts.srv_format orelse 0, opts.rtv_format orelse 0, opts.render_target, opts.sampled, initial_state, width, height },
        );
        return error.D3D12TextureCreateFailed;
    }

    return @ptrCast(raw_resource.?);
}

fn imageDxgiFormat(format: ImageTextureFormat, srgb: bool) u32 {
    return switch (format) {
        .grayscale => @intCast(winos.c.DXGI_FORMAT_R8_UNORM),
        .rgba => if (srgb)
            @intCast(winos.c.DXGI_FORMAT_R8G8B8A8_UNORM_SRGB)
        else
            @intCast(winos.c.DXGI_FORMAT_R8G8B8A8_UNORM),
        .bgra => if (srgb)
            @intCast(winos.c.DXGI_FORMAT_B8G8R8A8_UNORM_SRGB)
        else
            @intCast(winos.c.DXGI_FORMAT_B8G8R8A8_UNORM),
    };
}

fn vertexBufferView(
    raw_buffer: *winos.graphics.ID3D12Resource,
    stride: usize,
) winos.c.D3D12_VERTEX_BUFFER_VIEW {
    const buffer = nativePtr(*winos.c.ID3D12Resource, raw_buffer);
    var desc: winos.c.D3D12_RESOURCE_DESC = std.mem.zeroes(winos.c.D3D12_RESOURCE_DESC);
    _ = buffer.lpVtbl[0].GetDesc.?(buffer, &desc);
    return .{
        .BufferLocation = buffer.lpVtbl[0].GetGPUVirtualAddress.?(buffer),
        .SizeInBytes = @intCast(desc.Width),
        .StrideInBytes = @intCast(stride),
    };
}

fn transitionBarrier(
    resource: *winos.c.ID3D12Resource,
    before: winos.c.D3D12_RESOURCE_STATES,
    after: winos.c.D3D12_RESOURCE_STATES,
) winos.c.D3D12_RESOURCE_BARRIER {
    return .{
        .Type = winos.c.D3D12_RESOURCE_BARRIER_TYPE_TRANSITION,
        .Flags = winos.c.D3D12_RESOURCE_BARRIER_FLAG_NONE,
        .unnamed_0 = .{
            .Transition = .{
                .pResource = resource,
                .Subresource = winos.c.D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
                .StateBefore = before,
                .StateAfter = after,
            },
        },
    };
}

fn nativePtr(comptime T: type, raw: anytype) T {
    return @ptrFromInt(@intFromPtr(raw));
}
