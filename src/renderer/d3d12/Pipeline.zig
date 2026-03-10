const Self = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;
const internal_os = @import("../../os/main.zig");
const winos = internal_os.windows;

fn shouldTraceWin32D3D12Pipeline() bool {
    if (comptime builtin.target.os.tag != .windows) return false;
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

fn traceWin32D3D12Pipeline(step: []const u8) void {
    if (!shouldTraceWin32D3D12Pipeline()) return;
    std.debug.print("info(renderer_d3d12): ci.win32.d3d12.pipeline.step={s}\n", .{step});
}

pub const Options = struct {
    alloc: Allocator,
    device: ?*winos.graphics.ID3D12Device = null,
    vertex_source: [:0]const u8,
    fragment_source: [:0]const u8,
    vertex_entry: [:0]const u8,
    fragment_entry: [:0]const u8,
    input_elements: []const winos.c.D3D12_INPUT_ELEMENT_DESC = &.{},
    step_fn: StepFunction = .per_vertex,
    blending_enabled: bool = true,
    primitive_topology: winos.c.D3D12_PRIMITIVE_TOPOLOGY = winos.c.D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST,
    render_target_format: u32 = if (builtin.target.os.tag == .windows)
        @intCast(winos.c.DXGI_FORMAT_B8G8R8A8_UNORM)
    else
        0,
};

pub const StepFunction = enum {
    constant,
    per_vertex,
    per_instance,
};

vertex_source: [:0]const u8,
fragment_source: [:0]const u8,
vertex_entry: [:0]const u8,
fragment_entry: [:0]const u8,
vertex_blob: ShaderBlob = .{},
fragment_blob: ShaderBlob = .{},
root_signature: ?*winos.graphics.ID3D12RootSignature = null,
pipeline_state: ?*winos.graphics.ID3D12PipelineState = null,
vertex_stride: usize,
input_elements: []const winos.c.D3D12_INPUT_ELEMENT_DESC,
step_fn: StepFunction,
blending_enabled: bool,
primitive_topology: winos.c.D3D12_PRIMITIVE_TOPOLOGY,
render_target_format: u32,

pub fn init(comptime VertexAttributes: ?type, opts: Options) !Self {
    var result: Self = .{
        .vertex_source = try opts.alloc.dupeZ(u8, opts.vertex_source),
        .fragment_source = try opts.alloc.dupeZ(u8, opts.fragment_source),
        .vertex_entry = try opts.alloc.dupeZ(u8, opts.vertex_entry),
        .fragment_entry = try opts.alloc.dupeZ(u8, opts.fragment_entry),
        .vertex_stride = if (VertexAttributes) |VA| @sizeOf(VA) else 0,
        .input_elements = opts.input_elements,
        .step_fn = opts.step_fn,
        .blending_enabled = opts.blending_enabled,
        .primitive_topology = opts.primitive_topology,
        .render_target_format = opts.render_target_format,
    };
    errdefer result.deinit(opts.alloc);

    if (builtin.target.os.tag == .windows) {
        if (shouldTraceWin32D3D12Pipeline()) {
            std.debug.print(
                "info(renderer_d3d12): ci.win32.d3d12.pipeline.init entries vs={s} ps={s}\n",
                .{ result.vertex_entry, result.fragment_entry },
            );
        }
        traceWin32D3D12Pipeline("compile.vertex.begin");
        result.vertex_blob = try compileShader(
            result.vertex_source,
            result.vertex_entry,
            "vs_5_0",
        );
        traceWin32D3D12Pipeline("compile.vertex.ready");
        errdefer result.vertex_blob.deinit();
        traceWin32D3D12Pipeline("compile.fragment.begin");
        result.fragment_blob = try compileShader(
            result.fragment_source,
            result.fragment_entry,
            "ps_5_0",
        );
        traceWin32D3D12Pipeline("compile.fragment.ready");
        errdefer result.fragment_blob.deinit();

        if (opts.device) |device| {
            traceWin32D3D12Pipeline("graphics_objects.begin");
            try result.initGraphicsObjects(device);
            traceWin32D3D12Pipeline("graphics_objects.ready");
        }
    }

    return result;
}

pub fn deinit(self: *const Self, alloc: Allocator) void {
    if (self.pipeline_state) |state| winos.graphics.release(@ptrCast(state));
    if (self.root_signature) |signature| winos.graphics.release(@ptrCast(signature));
    self.vertex_blob.deinit();
    self.fragment_blob.deinit();
    alloc.free(self.vertex_source);
    alloc.free(self.fragment_source);
    alloc.free(self.vertex_entry);
    alloc.free(self.fragment_entry);
}

pub fn isReady(self: *const Self) bool {
    return self.root_signature != null and self.pipeline_state != null;
}

pub const ShaderBlob = struct {
    ptr: ?*winos.c.ID3DBlob = null,

    pub fn deinit(self: *const ShaderBlob) void {
        if (self.ptr) |blob| winos.graphics.release(@ptrCast(blob));
    }
};

fn compileShader(
    source: [:0]const u8,
    entry: [:0]const u8,
    profile: [:0]const u8,
) !ShaderBlob {
    const D3DCompileFn = *const fn (
        src_data: ?*const anyopaque,
        src_data_len: usize,
        source_name: ?[*:0]const u8,
        defines: ?*const anyopaque,
        include: ?*const anyopaque,
        entrypoint: [*:0]const u8,
        target: [*:0]const u8,
        flags1: u32,
        flags2: u32,
        code: *?*winos.c.ID3DBlob,
        error_msgs: *?*winos.c.ID3DBlob,
    ) callconv(.winapi) windows.HRESULT;

    const lib_name = std.unicode.utf8ToUtf16LeStringLiteral("d3dcompiler_47.dll");
    const module = windows.LoadLibraryW(lib_name) catch return error.D3D12ShaderCompilerUnavailable;
    defer windows.FreeLibrary(module);

    const proc = winos.kernel32.GetProcAddress(module, "D3DCompile") orelse
        return error.D3D12ShaderCompilerUnavailable;
    const d3d_compile: D3DCompileFn = @ptrFromInt(@intFromPtr(proc));

    var raw_code: ?*winos.c.ID3DBlob = null;
    var raw_errors: ?*winos.c.ID3DBlob = null;
    defer if (raw_errors) |blob| winos.graphics.release(@ptrCast(blob));

    const flags: u32 = if (@hasDecl(winos.c, "D3DCOMPILE_ENABLE_STRICTNESS"))
        winos.c.D3DCOMPILE_ENABLE_STRICTNESS
    else
        0;

    if (shouldTraceWin32D3D12Pipeline()) {
        std.debug.print(
            "info(renderer_d3d12): ci.win32.d3d12.pipeline.compile.call entry={s} profile={s} len={d}\n",
            .{ entry, profile, source.len },
        );
    }
    const hr = d3d_compile(
        source.ptr,
        source.len,
        null,
        null,
        null,
        entry.ptr,
        profile.ptr,
        flags,
        0,
        &raw_code,
        &raw_errors,
    );
    if (shouldTraceWin32D3D12Pipeline()) {
        std.debug.print(
            "info(renderer_d3d12): ci.win32.d3d12.pipeline.compile.return entry={s} profile={s} hr=0x{x} code_null={}\n",
            .{ entry, profile, @as(u32, @bitCast(hr)), raw_code == null },
        );
    }
    if (hr != winos.S_OK or raw_code == null) {
        if (raw_errors) |blob| {
            const ptr = blob.lpVtbl[0].GetBufferPointer.?(@ptrCast(blob));
            const len = blob.lpVtbl[0].GetBufferSize.?(@ptrCast(blob));
            if (ptr != null and len > 0) {
                const bytes: [*]const u8 = @ptrCast(ptr.?);
                std.log.scoped(.d3d12).warn(
                    "d3d12 shader compile failed entry={s} profile={s} message={s}",
                    .{
                        entry,
                        profile,
                        bytes[0..len],
                    },
                );
            }
        }
        return error.D3D12ShaderCompileFailed;
    }

    return .{ .ptr = raw_code };
}

fn initGraphicsObjects(self: *Self, raw_device: *winos.graphics.ID3D12Device) !void {
    const device: *winos.c.ID3D12Device = @ptrFromInt(@intFromPtr(raw_device));

    const texture0_range = winos.c.D3D12_DESCRIPTOR_RANGE{
        .RangeType = winos.c.D3D12_DESCRIPTOR_RANGE_TYPE_SRV,
        .NumDescriptors = 1,
        .BaseShaderRegister = 0,
        .RegisterSpace = 0,
        .OffsetInDescriptorsFromTableStart = winos.c.D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND,
    };
    const texture1_range = winos.c.D3D12_DESCRIPTOR_RANGE{
        .RangeType = winos.c.D3D12_DESCRIPTOR_RANGE_TYPE_SRV,
        .NumDescriptors = 1,
        .BaseShaderRegister = 1,
        .RegisterSpace = 0,
        .OffsetInDescriptorsFromTableStart = winos.c.D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND,
    };

    const root_parameters = [_]winos.c.D3D12_ROOT_PARAMETER{
        .{
            .ParameterType = winos.c.D3D12_ROOT_PARAMETER_TYPE_CBV,
            .unnamed_0 = .{
                .Descriptor = .{
                    .ShaderRegister = 1,
                    .RegisterSpace = 0,
                },
            },
            .ShaderVisibility = winos.c.D3D12_SHADER_VISIBILITY_ALL,
        },
        .{
            .ParameterType = winos.c.D3D12_ROOT_PARAMETER_TYPE_SRV,
            .unnamed_0 = .{
                .Descriptor = .{
                    .ShaderRegister = 2,
                    .RegisterSpace = 0,
                },
            },
            .ShaderVisibility = winos.c.D3D12_SHADER_VISIBILITY_ALL,
        },
        .{
            .ParameterType = winos.c.D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE,
            .unnamed_0 = .{
                .DescriptorTable = .{
                    .NumDescriptorRanges = 1,
                    .pDescriptorRanges = @ptrCast(&texture0_range),
                },
            },
            .ShaderVisibility = winos.c.D3D12_SHADER_VISIBILITY_ALL,
        },
        .{
            .ParameterType = winos.c.D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE,
            .unnamed_0 = .{
                .DescriptorTable = .{
                    .NumDescriptorRanges = 1,
                    .pDescriptorRanges = @ptrCast(&texture1_range),
                },
            },
            .ShaderVisibility = winos.c.D3D12_SHADER_VISIBILITY_ALL,
        },
    };

    const static_sampler = winos.c.D3D12_STATIC_SAMPLER_DESC{
        .Filter = winos.c.D3D12_FILTER_MIN_MAG_MIP_LINEAR,
        .AddressU = winos.c.D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
        .AddressV = winos.c.D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
        .AddressW = winos.c.D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
        .MipLODBias = 0,
        .MaxAnisotropy = 1,
        .ComparisonFunc = winos.c.D3D12_COMPARISON_FUNC_ALWAYS,
        .BorderColor = winos.c.D3D12_STATIC_BORDER_COLOR_TRANSPARENT_BLACK,
        .MinLOD = 0,
        .MaxLOD = winos.c.D3D12_FLOAT32_MAX,
        .ShaderRegister = 0,
        .RegisterSpace = 0,
        .ShaderVisibility = winos.c.D3D12_SHADER_VISIBILITY_ALL,
    };

    var root_signature_desc: winos.c.D3D12_ROOT_SIGNATURE_DESC =
        std.mem.zeroes(winos.c.D3D12_ROOT_SIGNATURE_DESC);
    root_signature_desc.NumParameters = root_parameters.len;
    root_signature_desc.pParameters = @ptrCast(&root_parameters);
    root_signature_desc.NumStaticSamplers = 1;
    root_signature_desc.pStaticSamplers = @ptrCast(&static_sampler);
    root_signature_desc.Flags = @intCast(winos.c.D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT);

    var root_signature_blob: ?*winos.c.ID3DBlob = null;
    var root_signature_errors: ?*winos.c.ID3DBlob = null;
    defer if (root_signature_blob) |blob| winos.graphics.release(@ptrCast(blob));
    defer if (root_signature_errors) |blob| winos.graphics.release(@ptrCast(blob));

    if (winos.c.D3D12SerializeRootSignature(
        &root_signature_desc,
        winos.c.D3D_ROOT_SIGNATURE_VERSION_1,
        &root_signature_blob,
        &root_signature_errors,
    ) != winos.S_OK or root_signature_blob == null) {
        logBlobMessage("d3d12 root signature serialize failed", root_signature_errors);
        return error.D3D12RootSignatureSerializeFailed;
    }

    const blob = root_signature_blob.?;
    const signature_ptr = blob.lpVtbl[0].GetBufferPointer.?(@ptrCast(blob));
    const signature_len = blob.lpVtbl[0].GetBufferSize.?(@ptrCast(blob));

    var raw_root_signature: ?*anyopaque = null;
    if (device.lpVtbl[0].CreateRootSignature.?(
        device,
        0,
        signature_ptr,
        signature_len,
        &winos.c.IID_ID3D12RootSignature,
        &raw_root_signature,
    ) != winos.S_OK or raw_root_signature == null) {
        return error.D3D12RootSignatureCreateFailed;
    }
    self.root_signature = @ptrCast(raw_root_signature.?);
    errdefer {
        winos.graphics.release(@ptrCast(self.root_signature));
        self.root_signature = null;
    }

    const default_blend = defaultBlendDesc(self.blending_enabled);
    const default_rasterizer = defaultRasterizerDesc();
    const default_depth = defaultDepthStencilDesc();
    var pso_desc: winos.c.D3D12_GRAPHICS_PIPELINE_STATE_DESC =
        std.mem.zeroes(winos.c.D3D12_GRAPHICS_PIPELINE_STATE_DESC);
    pso_desc.pRootSignature = @ptrFromInt(@intFromPtr(self.root_signature.?));
    pso_desc.VS = shaderBytecode(self.vertex_blob.ptr.?);
    pso_desc.PS = shaderBytecode(self.fragment_blob.ptr.?);
    pso_desc.BlendState = default_blend;
    pso_desc.SampleMask = std.math.maxInt(u32);
    pso_desc.RasterizerState = default_rasterizer;
    pso_desc.DepthStencilState = default_depth;
    pso_desc.InputLayout = .{
        .pInputElementDescs = if (self.input_elements.len > 0)
            @ptrCast(self.input_elements.ptr)
        else
            null,
        .NumElements = @intCast(self.input_elements.len),
    };
    pso_desc.IBStripCutValue = winos.c.D3D12_INDEX_BUFFER_STRIP_CUT_VALUE_DISABLED;
    pso_desc.PrimitiveTopologyType = winos.c.D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pso_desc.NumRenderTargets = 1;
    pso_desc.RTVFormats[0] = self.render_target_format;
    pso_desc.SampleDesc = .{ .Count = 1, .Quality = 0 };

    var raw_pipeline_state: ?*anyopaque = null;
    if (device.lpVtbl[0].CreateGraphicsPipelineState.?(
        device,
        &pso_desc,
        &winos.c.IID_ID3D12PipelineState,
        &raw_pipeline_state,
    ) != winos.S_OK or raw_pipeline_state == null) {
        return error.D3D12PipelineStateCreateFailed;
    }
    self.pipeline_state = @ptrCast(raw_pipeline_state.?);
}

fn shaderBytecode(blob: *winos.c.ID3DBlob) winos.c.D3D12_SHADER_BYTECODE {
    return .{
        .pShaderBytecode = blob.lpVtbl[0].GetBufferPointer.?(@ptrCast(blob)),
        .BytecodeLength = blob.lpVtbl[0].GetBufferSize.?(@ptrCast(blob)),
    };
}

fn defaultBlendDesc(enabled: bool) winos.c.D3D12_BLEND_DESC {
    var desc: winos.c.D3D12_BLEND_DESC = std.mem.zeroes(winos.c.D3D12_BLEND_DESC);
    desc.AlphaToCoverageEnable = winos.FALSE;
    desc.IndependentBlendEnable = winos.FALSE;
    desc.RenderTarget[0] = .{
        .BlendEnable = if (enabled) winos.TRUE else winos.FALSE,
        .LogicOpEnable = winos.FALSE,
        .SrcBlend = winos.c.D3D12_BLEND_ONE,
        .DestBlend = if (enabled) winos.c.D3D12_BLEND_INV_SRC_ALPHA else winos.c.D3D12_BLEND_ZERO,
        .BlendOp = winos.c.D3D12_BLEND_OP_ADD,
        .SrcBlendAlpha = winos.c.D3D12_BLEND_ONE,
        .DestBlendAlpha = if (enabled) winos.c.D3D12_BLEND_INV_SRC_ALPHA else winos.c.D3D12_BLEND_ZERO,
        .BlendOpAlpha = winos.c.D3D12_BLEND_OP_ADD,
        .LogicOp = winos.c.D3D12_LOGIC_OP_NOOP,
        .RenderTargetWriteMask = winos.c.D3D12_COLOR_WRITE_ENABLE_ALL,
    };
    return desc;
}

fn defaultRasterizerDesc() winos.c.D3D12_RASTERIZER_DESC {
    var desc: winos.c.D3D12_RASTERIZER_DESC = std.mem.zeroes(winos.c.D3D12_RASTERIZER_DESC);
    desc.FillMode = winos.c.D3D12_FILL_MODE_SOLID;
    desc.CullMode = winos.c.D3D12_CULL_MODE_NONE;
    desc.FrontCounterClockwise = winos.FALSE;
    desc.DepthBias = winos.c.D3D12_DEFAULT_DEPTH_BIAS;
    desc.DepthBiasClamp = winos.c.D3D12_DEFAULT_DEPTH_BIAS_CLAMP;
    desc.SlopeScaledDepthBias = winos.c.D3D12_DEFAULT_SLOPE_SCALED_DEPTH_BIAS;
    desc.DepthClipEnable = winos.TRUE;
    desc.MultisampleEnable = winos.FALSE;
    desc.AntialiasedLineEnable = winos.FALSE;
    desc.ForcedSampleCount = 0;
    desc.ConservativeRaster = winos.c.D3D12_CONSERVATIVE_RASTERIZATION_MODE_OFF;
    return desc;
}

fn defaultDepthStencilDesc() winos.c.D3D12_DEPTH_STENCIL_DESC {
    var desc: winos.c.D3D12_DEPTH_STENCIL_DESC =
        std.mem.zeroes(winos.c.D3D12_DEPTH_STENCIL_DESC);
    desc.DepthEnable = winos.FALSE;
    desc.DepthWriteMask = winos.c.D3D12_DEPTH_WRITE_MASK_ZERO;
    desc.DepthFunc = winos.c.D3D12_COMPARISON_FUNC_ALWAYS;
    desc.StencilEnable = winos.FALSE;
    desc.StencilReadMask = winos.c.D3D12_DEFAULT_STENCIL_READ_MASK;
    desc.StencilWriteMask = winos.c.D3D12_DEFAULT_STENCIL_WRITE_MASK;
    desc.FrontFace = .{
        .StencilFailOp = winos.c.D3D12_STENCIL_OP_KEEP,
        .StencilDepthFailOp = winos.c.D3D12_STENCIL_OP_KEEP,
        .StencilPassOp = winos.c.D3D12_STENCIL_OP_KEEP,
        .StencilFunc = winos.c.D3D12_COMPARISON_FUNC_ALWAYS,
    };
    desc.BackFace = desc.FrontFace;
    return desc;
}

fn logBlobMessage(prefix: []const u8, blob: ?*winos.c.ID3DBlob) void {
    const raw_blob = blob orelse {
        std.log.scoped(.d3d12).warn("{s}", .{prefix});
        return;
    };
    const ptr = raw_blob.lpVtbl[0].GetBufferPointer.?(@ptrCast(raw_blob));
    const len = raw_blob.lpVtbl[0].GetBufferSize.?(@ptrCast(raw_blob));
    if (ptr == null or len == 0) {
        std.log.scoped(.d3d12).warn("{s}", .{prefix});
        return;
    }

    const bytes: [*]const u8 = @ptrCast(ptr.?);
    std.log.scoped(.d3d12).warn("{s}: {s}", .{ prefix, bytes[0..len] });
}
