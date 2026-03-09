const std = @import("std");
const Allocator = std.mem.Allocator;
const Pipeline = @import("Pipeline.zig");
const OpenGLShaders = @import("../opengl/shaders.zig");
const internal_os = @import("../../os/main.zig");
const winos = internal_os.windows;

const log = std.log.scoped(.d3d12);

const semantic_texcoord: [*:0]const u8 = "TEXCOORD";

const cell_text_input_elements = [_]winos.c.D3D12_INPUT_ELEMENT_DESC{
    .{
        .SemanticName = semantic_texcoord,
        .SemanticIndex = 0,
        .Format = winos.c.DXGI_FORMAT_R32G32_UINT,
        .InputSlot = 0,
        .AlignedByteOffset = 0,
        .InputSlotClass = winos.c.D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA,
        .InstanceDataStepRate = 1,
    },
    .{
        .SemanticName = semantic_texcoord,
        .SemanticIndex = 1,
        .Format = winos.c.DXGI_FORMAT_R32G32_UINT,
        .InputSlot = 0,
        .AlignedByteOffset = 8,
        .InputSlotClass = winos.c.D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA,
        .InstanceDataStepRate = 1,
    },
    .{
        .SemanticName = semantic_texcoord,
        .SemanticIndex = 2,
        .Format = winos.c.DXGI_FORMAT_R16G16_SINT,
        .InputSlot = 0,
        .AlignedByteOffset = 16,
        .InputSlotClass = winos.c.D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA,
        .InstanceDataStepRate = 1,
    },
    .{
        .SemanticName = semantic_texcoord,
        .SemanticIndex = 3,
        .Format = winos.c.DXGI_FORMAT_R16G16_UINT,
        .InputSlot = 0,
        .AlignedByteOffset = 20,
        .InputSlotClass = winos.c.D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA,
        .InstanceDataStepRate = 1,
    },
    .{
        .SemanticName = semantic_texcoord,
        .SemanticIndex = 4,
        .Format = winos.c.DXGI_FORMAT_R8G8B8A8_UINT,
        .InputSlot = 0,
        .AlignedByteOffset = 24,
        .InputSlotClass = winos.c.D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA,
        .InstanceDataStepRate = 1,
    },
    .{
        .SemanticName = semantic_texcoord,
        .SemanticIndex = 5,
        .Format = winos.c.DXGI_FORMAT_R8_UINT,
        .InputSlot = 0,
        .AlignedByteOffset = 28,
        .InputSlotClass = winos.c.D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA,
        .InstanceDataStepRate = 1,
    },
    .{
        .SemanticName = semantic_texcoord,
        .SemanticIndex = 6,
        .Format = winos.c.DXGI_FORMAT_R8_UINT,
        .InputSlot = 0,
        .AlignedByteOffset = 29,
        .InputSlotClass = winos.c.D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA,
        .InstanceDataStepRate = 1,
    },
};

const image_input_elements = [_]winos.c.D3D12_INPUT_ELEMENT_DESC{
    .{
        .SemanticName = semantic_texcoord,
        .SemanticIndex = 0,
        .Format = winos.c.DXGI_FORMAT_R32G32_FLOAT,
        .InputSlot = 0,
        .AlignedByteOffset = 0,
        .InputSlotClass = winos.c.D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA,
        .InstanceDataStepRate = 1,
    },
    .{
        .SemanticName = semantic_texcoord,
        .SemanticIndex = 1,
        .Format = winos.c.DXGI_FORMAT_R32G32_FLOAT,
        .InputSlot = 0,
        .AlignedByteOffset = 8,
        .InputSlotClass = winos.c.D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA,
        .InstanceDataStepRate = 1,
    },
    .{
        .SemanticName = semantic_texcoord,
        .SemanticIndex = 2,
        .Format = winos.c.DXGI_FORMAT_R32G32B32A32_FLOAT,
        .InputSlot = 0,
        .AlignedByteOffset = 16,
        .InputSlotClass = winos.c.D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA,
        .InstanceDataStepRate = 1,
    },
    .{
        .SemanticName = semantic_texcoord,
        .SemanticIndex = 3,
        .Format = winos.c.DXGI_FORMAT_R32G32_FLOAT,
        .InputSlot = 0,
        .AlignedByteOffset = 32,
        .InputSlotClass = winos.c.D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA,
        .InstanceDataStepRate = 1,
    },
};

const bg_image_input_elements = [_]winos.c.D3D12_INPUT_ELEMENT_DESC{
    .{
        .SemanticName = semantic_texcoord,
        .SemanticIndex = 0,
        .Format = winos.c.DXGI_FORMAT_R32_FLOAT,
        .InputSlot = 0,
        .AlignedByteOffset = 0,
        .InputSlotClass = winos.c.D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA,
        .InstanceDataStepRate = 1,
    },
    .{
        .SemanticName = semantic_texcoord,
        .SemanticIndex = 1,
        .Format = winos.c.DXGI_FORMAT_R8_UINT,
        .InputSlot = 0,
        .AlignedByteOffset = 4,
        .InputSlotClass = winos.c.D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA,
        .InstanceDataStepRate = 1,
    },
};

const pipeline_descs: []const struct { [:0]const u8, PipelineDescription } =
    &.{
        .{ "bg_color", .{
            .vertex_hlsl = full_screen_vertex_hlsl,
            .fragment_hlsl = bg_color_fragment_hlsl,
            .vertex_entry = "full_screen_vertex",
            .fragment_entry = "bg_color_fragment",
            .blending_enabled = false,
        } },
        .{ "cell_bg", .{
            .vertex_hlsl = full_screen_vertex_hlsl,
            .fragment_hlsl = cell_bg_fragment_hlsl,
            .vertex_entry = "full_screen_vertex",
            .fragment_entry = "cell_bg_fragment",
            .blending_enabled = true,
        } },
        .{ "cell_text", .{
            .vertex_attributes = CellText,
            .input_elements = &cell_text_input_elements,
            .vertex_hlsl = cell_text_vertex_hlsl,
            .fragment_hlsl = cell_text_fragment_hlsl,
            .vertex_entry = "cell_text_vertex",
            .fragment_entry = "cell_text_fragment",
            .step_fn = .per_instance,
            .primitive_topology = winos.c.D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP,
            .blending_enabled = true,
        } },
        .{ "image", .{
            .vertex_attributes = Image,
            .input_elements = &image_input_elements,
            .vertex_hlsl = image_vertex_hlsl,
            .fragment_hlsl = image_fragment_hlsl,
            .vertex_entry = "image_vertex",
            .fragment_entry = "image_fragment",
            .step_fn = .per_instance,
            .primitive_topology = winos.c.D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP,
            .blending_enabled = true,
        } },
        .{ "bg_image", .{
            .vertex_attributes = BgImage,
            .input_elements = &bg_image_input_elements,
            .vertex_hlsl = bg_image_vertex_hlsl,
            .fragment_hlsl = bg_image_fragment_hlsl,
            .vertex_entry = "bg_image_vertex",
            .fragment_entry = "bg_image_fragment",
            .step_fn = .per_instance,
            .primitive_topology = winos.c.D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST,
            .blending_enabled = true,
        } },
    };

const PipelineDescription = struct {
    vertex_attributes: ?type = null,
    input_elements: []const winos.c.D3D12_INPUT_ELEMENT_DESC = &.{},
    vertex_hlsl: [:0]const u8,
    fragment_hlsl: [:0]const u8,
    vertex_entry: [:0]const u8,
    fragment_entry: [:0]const u8,
    step_fn: Pipeline.StepFunction = .per_vertex,
    primitive_topology: winos.c.D3D12_PRIMITIVE_TOPOLOGY = winos.c.D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST,
    blending_enabled: bool = true,

    fn initPipeline(
        self: PipelineDescription,
        alloc: Allocator,
        device: ?*winos.graphics.ID3D12Device,
    ) !Pipeline {
        return try Pipeline.init(self.vertex_attributes, .{
            .alloc = alloc,
            .device = device,
            .vertex_source = self.vertex_hlsl,
            .fragment_source = self.fragment_hlsl,
            .vertex_entry = self.vertex_entry,
            .fragment_entry = self.fragment_entry,
            .input_elements = self.input_elements,
            .step_fn = self.step_fn,
            .primitive_topology = self.primitive_topology,
            .blending_enabled = self.blending_enabled,
        });
    }
};

const PipelineCollection = t: {
    var fields: [pipeline_descs.len]std.builtin.Type.StructField = undefined;
    for (pipeline_descs, 0..) |pipeline, i| {
        fields[i] = .{
            .name = pipeline[0],
            .type = Pipeline,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(Pipeline),
        };
    }
    break :t @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
};

pub const Shaders = struct {
    pipelines: PipelineCollection,
    post_pipelines: []const Pipeline,
    defunct: bool = false,

    pub fn init(
        alloc: Allocator,
        device: ?*winos.graphics.ID3D12Device,
        post_shaders: []const [:0]const u8,
    ) !Shaders {
        var pipelines: PipelineCollection = undefined;

        var initialized_pipelines: usize = 0;
        errdefer inline for (pipeline_descs, 0..) |pipeline, i| {
            if (i < initialized_pipelines) {
                @field(pipelines, pipeline[0]).deinit(alloc);
            }
        };

        inline for (pipeline_descs) |pipeline| {
            @field(pipelines, pipeline[0]) = try pipeline[1].initPipeline(alloc, device);
            initialized_pipelines += 1;
        }

        const post_pipelines: []const Pipeline = initPostPipelines(alloc, device, post_shaders) catch |err| err: {
            log.warn("error initializing d3d12 postprocess shaders err={}", .{err});
            break :err &.{};
        };
        errdefer if (post_pipelines.len > 0) {
            for (post_pipelines) |*pipeline| pipeline.deinit(alloc);
            alloc.free(post_pipelines);
        };

        return .{
            .pipelines = pipelines,
            .post_pipelines = post_pipelines,
        };
    }

    pub fn deinit(self: *Shaders, alloc: Allocator) void {
        if (self.defunct) return;
        self.defunct = true;

        inline for (pipeline_descs) |pipeline| {
            @field(self.pipelines, pipeline[0]).deinit(alloc);
        }

        if (self.post_pipelines.len > 0) {
            for (self.post_pipelines) |*pipeline| {
                pipeline.deinit(alloc);
            }
            alloc.free(self.post_pipelines);
        }
    }
};

pub const Uniforms = OpenGLShaders.Uniforms;
pub const CellText = OpenGLShaders.CellText;
pub const CellBg = OpenGLShaders.CellBg;
pub const Image = OpenGLShaders.Image;
pub const BgImage = OpenGLShaders.BgImage;

fn initPostPipelines(
    alloc: Allocator,
    device: ?*winos.graphics.ID3D12Device,
    shader_sources: []const [:0]const u8,
) ![]const Pipeline {
    if (shader_sources.len == 0) return &.{};

    var pipelines = try alloc.alloc(Pipeline, shader_sources.len);
    errdefer alloc.free(pipelines);

    var count: usize = 0;
    errdefer for (pipelines[0..count]) |*pipeline| pipeline.deinit(alloc);

    for (shader_sources) |source| {
        pipelines[count] = try initPostPipeline(alloc, device, source);
        count += 1;
    }

    return pipelines;
}

fn initPostPipeline(
    alloc: Allocator,
    device: ?*winos.graphics.ID3D12Device,
    data: [:0]const u8,
) !Pipeline {
    return try Pipeline.init(null, .{
        .alloc = alloc,
        .device = device,
        .vertex_source = full_screen_vertex_hlsl,
        .fragment_source = data,
        .vertex_entry = "full_screen_vertex",
        .fragment_entry = "main",
        .primitive_topology = winos.c.D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST,
    });
}

test "d3d12 built-in shaders compile to hlsl" {
    const testing = std.testing;
    var shader_set = try Shaders.init(testing.allocator, null, &.{});
    defer shader_set.deinit(testing.allocator);
    try testing.expect(shader_set.pipelines.bg_color.vertex_source.len > 0);
    try testing.expect(shader_set.pipelines.cell_text.fragment_source.len > 0);
}

const common_hlsl =
    \\cbuffer Globals : register(b1) {
    \\    row_major float4x4 projection_matrix : packoffset(c0);
    \\    float2 screen_size : packoffset(c4.x);
    \\    float2 cell_size : packoffset(c4.z);
    \\    uint grid_size_packed_2u16 : packoffset(c5.x);
    \\    float4 grid_padding : packoffset(c6);
    \\    uint padding_extend : packoffset(c7.x);
    \\    float min_contrast : packoffset(c7.y);
    \\    uint cursor_pos_packed_2u16 : packoffset(c7.z);
    \\    uint cursor_color_packed_4u8 : packoffset(c7.w);
    \\    uint bg_color_packed_4u8 : packoffset(c8.x);
    \\    uint bools : packoffset(c8.y);
    \\};
    \\
    \\StructuredBuffer<uint> bg_cells : register(t2);
    \\SamplerState linear_sampler : register(s0);
    \\
    \\static const uint CURSOR_WIDE = 1u;
    \\static const uint USE_DISPLAY_P3 = 2u;
    \\static const uint USE_LINEAR_BLENDING = 4u;
    \\static const uint USE_LINEAR_CORRECTION = 8u;
    \\static const uint EXTEND_LEFT = 1u;
    \\static const uint EXTEND_RIGHT = 2u;
    \\static const uint EXTEND_UP = 4u;
    \\static const uint EXTEND_DOWN = 8u;
    \\
    \\uint4 unpack4u8(uint packed_value) {
    \\    return uint4(
    \\        (packed_value >> 0) & 0xFFu,
    \\        (packed_value >> 8) & 0xFFu,
    \\        (packed_value >> 16) & 0xFFu,
    \\        (packed_value >> 24) & 0xFFu
    \\    );
    \\}
    \\
    \\uint2 unpack2u16(uint packed_value) {
    \\    return uint2(
    \\        (packed_value >> 0) & 0xFFFFu,
    \\        (packed_value >> 16) & 0xFFFFu
    \\    );
    \\}
    \\
    \\float luminance(float3 color) {
    \\    return dot(color, float3(0.2126f, 0.7152f, 0.0722f));
    \\}
    \\
    \\float contrast_ratio(float3 color1, float3 color2) {
    \\    float l1 = luminance(color1) + 0.05f;
    \\    float l2 = luminance(color2) + 0.05f;
    \\    return max(l1, l2) / min(l1, l2);
    \\}
    \\
    \\float4 contrasted_color(float min_ratio, float4 fg, float4 bg) {
    \\    float ratio = contrast_ratio(fg.rgb, bg.rgb);
    \\    if (ratio < min_ratio) {
    \\        float white_ratio = contrast_ratio(float3(1.0f, 1.0f, 1.0f), bg.rgb);
    \\        float black_ratio = contrast_ratio(float3(0.0f, 0.0f, 0.0f), bg.rgb);
    \\        return white_ratio > black_ratio ? float4(1.0f, 1.0f, 1.0f, 1.0f) : float4(0.0f, 0.0f, 0.0f, 1.0f);
    \\    }
    \\    return fg;
    \\}
    \\
    \\float4 linearize(float4 srgb) {
    \\    bool3 cutoff = srgb.rgb <= 0.04045;
    \\    float3 lower = srgb.rgb / 12.92;
    \\    float3 higher = pow((srgb.rgb + 0.055) / 1.055, 2.4);
    \\    return float4(lerp(higher, lower, cutoff), srgb.a);
    \\}
    \\
    \\float linearize_scalar(float v) {
    \\    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
    \\}
    \\
    \\float4 unlinearize(float4 linear_color) {
    \\    bool3 cutoff = linear_color.rgb <= 0.0031308;
    \\    float3 lower = linear_color.rgb * 12.92;
    \\    float3 higher = pow(linear_color.rgb, 1.0 / 2.4) * 1.055 - 0.055;
    \\    return float4(lerp(higher, lower, cutoff), linear_color.a);
    \\}
    \\
    \\float unlinearize_scalar(float v) {
    \\    return v <= 0.0031308 ? v * 12.92 : pow(v, 1.0 / 2.4) * 1.055 - 0.055;
    \\}
    \\
    \\float4 load_color_u4(uint4 in_color, bool want_linear) {
    \\    float4 color = float4(in_color) / 255.0f;
    \\    if (want_linear) color = linearize(color);
    \\    color.rgb *= color.a;
    \\    return color;
    \\}
    \\
    \\float4 load_color_packed(uint packed, bool want_linear) {
    \\    return load_color_u4(unpack4u8(packed), want_linear);
    \\}
    \\
    \\struct FullScreenVertexOut {
    \\    float4 position : SV_Position;
    \\};
;

const full_screen_vertex_hlsl = common_hlsl ++
    \\FullScreenVertexOut full_screen_vertex(uint vertex_id : SV_VertexID) {
    \\    FullScreenVertexOut outv;
    \\    float2 pos = (vertex_id == 0u) ? float2(-1.0f, -3.0f) :
    \\        ((vertex_id == 1u) ? float2(-1.0f, 1.0f) : float2(3.0f, 1.0f));
    \\    outv.position = float4(pos, 0.0f, 1.0f);
    \\    return outv;
    \\}
;

const bg_color_fragment_hlsl = common_hlsl ++
    \\float4 bg_color_fragment(FullScreenVertexOut input) : SV_Target0 {
    \\    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0u;
    \\    return load_color_packed(bg_color_packed_4u8, use_linear_blending);
    \\}
;

const cell_bg_fragment_hlsl = common_hlsl ++
    \\float4 cell_bg_fragment(FullScreenVertexOut input) : SV_Target0 {
    \\    uint2 grid_size = unpack2u16(grid_size_packed_2u16);
    \\    int2 grid_pos = int2(floor((input.position.xy - float2(grid_padding.w, grid_padding.x)) / cell_size));
    \\    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0u;
    \\    float4 bg = float4(0.0f, 0.0f, 0.0f, 0.0f);
    \\
    \\    if (grid_pos.x < 0) {
    \\        if ((padding_extend & EXTEND_LEFT) != 0u) grid_pos.x = 0;
    \\        else return bg;
    \\    } else if (grid_pos.x > int(grid_size.x) - 1) {
    \\        if ((padding_extend & EXTEND_RIGHT) != 0u) grid_pos.x = int(grid_size.x) - 1;
    \\        else return bg;
    \\    }
    \\
    \\    if (grid_pos.y < 0) {
    \\        if ((padding_extend & EXTEND_UP) != 0u) grid_pos.y = 0;
    \\        else return bg;
    \\    } else if (grid_pos.y > int(grid_size.y) - 1) {
    \\        if ((padding_extend & EXTEND_DOWN) != 0u) grid_pos.y = int(grid_size.y) - 1;
    \\        else return bg;
    \\    }
    \\
    \\    uint cell_color = bg_cells[grid_pos.y * int(grid_size.x) + grid_pos.x];
    \\    return load_color_packed(cell_color, use_linear_blending);
    \\}
;

const cell_text_vertex_hlsl = common_hlsl ++
    \\struct CellTextVertexIn {
    \\    uint2 glyph_pos : TEXCOORD0;
    \\    uint2 glyph_size : TEXCOORD1;
    \\    int2 bearings : TEXCOORD2;
    \\    uint2 grid_pos : TEXCOORD3;
    \\    uint4 color : TEXCOORD4;
    \\    uint atlas : TEXCOORD5;
    \\    uint glyph_bools : TEXCOORD6;
    \\};
    \\
    \\struct CellTextVertexOut {
    \\    float4 position : SV_Position;
    \\    nointerpolation uint atlas : TEXCOORD0;
    \\    nointerpolation float4 color : TEXCOORD1;
    \\    nointerpolation float4 bg_color : TEXCOORD2;
    \\    float2 tex_coord : TEXCOORD3;
    \\};
    \\
    \\static const uint ATLAS_GRAYSCALE = 0u;
    \\static const uint ATLAS_COLOR = 1u;
    \\static const uint NO_MIN_CONTRAST = 1u;
    \\static const uint IS_CURSOR_GLYPH = 2u;
    \\
    \\CellTextVertexOut cell_text_vertex(uint vertex_id : SV_VertexID, CellTextVertexIn input) {
    \\    CellTextVertexOut outv;
    \\    float2 cell_pos = cell_size * float2(input.grid_pos);
    \\    float2 corner = float2((vertex_id == 1u || vertex_id == 3u) ? 1.0f : 0.0f, (vertex_id == 2u || vertex_id == 3u) ? 1.0f : 0.0f);
    \\    float2 size = float2(input.glyph_size);
    \\    float2 offset = float2(input.bearings);
    \\    uint2 grid_size = unpack2u16(grid_size_packed_2u16);
    \\    uint2 cursor_pos = unpack2u16(cursor_pos_packed_2u16);
    \\    bool cursor_wide = (bools & CURSOR_WIDE) != 0u;
    \\    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0u;
    \\
    \\    offset.y = cell_size.y - offset.y;
    \\    cell_pos = cell_pos + size * corner + offset;
    \\    outv.position = mul(projection_matrix, float4(cell_pos.x, cell_pos.y, 0.0f, 1.0f));
    \\    outv.tex_coord = float2(input.glyph_pos) + float2(input.glyph_size) * corner;
    \\    outv.atlas = input.atlas;
    \\    outv.color = load_color_u4(input.color, true);
    \\    outv.bg_color = load_color_packed(bg_cells[input.grid_pos.y * grid_size.x + input.grid_pos.x], true);
    \\    {
    \\        float4 global_bg = load_color_packed(bg_color_packed_4u8, true);
    \\        outv.bg_color += global_bg * (1.0f - outv.bg_color.a);
    \\    }
    \\    if (min_contrast > 1.0f && (input.glyph_bools & NO_MIN_CONTRAST) == 0u) {
    \\        outv.color = contrasted_color(min_contrast, outv.color, outv.bg_color);
    \\    }
    \\    {
    \\        bool is_cursor_pos = ((input.grid_pos.x == cursor_pos.x) || (cursor_wide && input.grid_pos.x == cursor_pos.x + 1u)) && input.grid_pos.y == cursor_pos.y;
    \\        if ((input.glyph_bools & IS_CURSOR_GLYPH) == 0u && is_cursor_pos) {
    \\            outv.color = load_color_packed(cursor_color_packed_4u8, use_linear_blending);
    \\        }
    \\    }
    \\    return outv;
    \\}
;

const cell_text_fragment_hlsl = common_hlsl ++
    \\Texture2D<float> atlas_grayscale : register(t0);
    \\Texture2D<float4> atlas_color : register(t1);
    \\
    \\struct CellTextVertexOut {
    \\    float4 position : SV_Position;
    \\    nointerpolation uint atlas : TEXCOORD0;
    \\    nointerpolation float4 color : TEXCOORD1;
    \\    nointerpolation float4 bg_color : TEXCOORD2;
    \\    float2 tex_coord : TEXCOORD3;
    \\};
    \\
    \\static const uint ATLAS_GRAYSCALE = 0u;
    \\static const uint ATLAS_COLOR = 1u;
    \\
    \\float4 cell_text_fragment(CellTextVertexOut input) : SV_Target0 {
    \\    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0u;
    \\    bool use_linear_correction = (bools & USE_LINEAR_CORRECTION) != 0u;
    \\
    \\    if (input.atlas == ATLAS_COLOR) {
    \\        float4 color = atlas_color.Load(int3(int2(input.tex_coord), 0));
    \\        if (use_linear_blending) return color;
    \\        if (color.a > 0.0f) {
    \\            color.rgb /= color.a;
    \\            color = unlinearize(color);
    \\            color.rgb *= color.a;
    \\        }
    \\        return color;
    \\    }
    \\
    \\    float4 color = input.color;
    \\    if (!use_linear_blending && color.a > 0.0f) {
    \\        color.rgb /= color.a;
    \\        color = unlinearize(color);
    \\        color.rgb *= color.a;
    \\    }
    \\
    \\    float a = atlas_grayscale.Load(int3(int2(input.tex_coord), 0));
    \\    if (use_linear_correction) {
    \\        float fg_l = luminance(color.rgb);
    \\        float bg_l = luminance(input.bg_color.rgb);
    \\        if (abs(fg_l - bg_l) > 0.001f) {
    \\            float blend_l = linearize_scalar(unlinearize_scalar(fg_l) * a + unlinearize_scalar(bg_l) * (1.0f - a));
    \\            a = clamp((blend_l - bg_l) / (fg_l - bg_l), 0.0f, 1.0f);
    \\        }
    \\    }
    \\    color *= a;
    \\    return color;
    \\}
;

const image_vertex_hlsl = common_hlsl ++
    \\Texture2D<float4> image_texture : register(t0);
    \\
    \\struct ImageVertexIn {
    \\    float2 grid_pos : TEXCOORD0;
    \\    float2 cell_offset : TEXCOORD1;
    \\    float4 source_rect : TEXCOORD2;
    \\    float2 dest_size : TEXCOORD3;
    \\};
    \\
    \\struct ImageVertexOut {
    \\    float4 position : SV_Position;
    \\    float2 tex_coord : TEXCOORD0;
    \\};
    \\
    \\ImageVertexOut image_vertex(uint vertex_id : SV_VertexID, ImageVertexIn input) {
    \\    ImageVertexOut outv;
    \\    uint tex_w;
    \\    uint tex_h;
    \\    image_texture.GetDimensions(tex_w, tex_h);
    \\    float2 corner = float2((vertex_id == 1u || vertex_id == 3u) ? 1.0f : 0.0f, (vertex_id == 2u || vertex_id == 3u) ? 1.0f : 0.0f);
    \\    float2 tex_coord = input.source_rect.xy + input.source_rect.zw * corner;
    \\    float2 image_pos = (cell_size * input.grid_pos) + input.cell_offset;
    \\    image_pos += input.dest_size * corner;
    \\    outv.position = mul(projection_matrix, float4(image_pos.x, image_pos.y, 0.0f, 1.0f));
    \\    outv.tex_coord = tex_coord / float2(tex_w, tex_h);
    \\    return outv;
    \\}
;

const image_fragment_hlsl = common_hlsl ++
    \\Texture2D<float4> image_texture : register(t0);
    \\
    \\struct ImageVertexOut {
    \\    float4 position : SV_Position;
    \\    float2 tex_coord : TEXCOORD0;
    \\};
    \\
    \\float4 image_fragment(ImageVertexOut input) : SV_Target0 {
    \\    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0u;
    \\    float4 rgba = image_texture.SampleLevel(linear_sampler, input.tex_coord, 0.0f);
    \\    if (!use_linear_blending) {
    \\        rgba = unlinearize(rgba);
    \\    }
    \\    rgba.rgb *= rgba.a;
    \\    return rgba;
    \\}
;

const bg_image_vertex_hlsl = common_hlsl ++
    \\Texture2D<float4> image_texture : register(t0);
    \\
    \\static const uint BG_IMAGE_POSITION = 15u;
    \\static const uint BG_IMAGE_TL = 0u;
    \\static const uint BG_IMAGE_TC = 1u;
    \\static const uint BG_IMAGE_TR = 2u;
    \\static const uint BG_IMAGE_ML = 3u;
    \\static const uint BG_IMAGE_MC = 4u;
    \\static const uint BG_IMAGE_MR = 5u;
    \\static const uint BG_IMAGE_BL = 6u;
    \\static const uint BG_IMAGE_BC = 7u;
    \\static const uint BG_IMAGE_BR = 8u;
    \\static const uint BG_IMAGE_FIT = 3u << 4;
    \\static const uint BG_IMAGE_CONTAIN = 0u << 4;
    \\static const uint BG_IMAGE_COVER = 1u << 4;
    \\static const uint BG_IMAGE_STRETCH = 2u << 4;
    \\static const uint BG_IMAGE_NO_FIT = 3u << 4;
    \\static const uint BG_IMAGE_REPEAT = 1u << 6;
    \\
    \\struct BgImageVertexIn {
    \\    float opacity : TEXCOORD0;
    \\    uint info : TEXCOORD1;
    \\};
    \\
    \\struct BgImageVertexOut {
    \\    float4 position : SV_Position;
    \\    nointerpolation float4 bg_color : TEXCOORD0;
    \\    nointerpolation float2 offset : TEXCOORD1;
    \\    nointerpolation float2 scale : TEXCOORD2;
    \\    nointerpolation float opacity : TEXCOORD3;
    \\    nointerpolation uint repeat : TEXCOORD4;
    \\};
    \\
    \\BgImageVertexOut bg_image_vertex(uint vertex_id : SV_VertexID, BgImageVertexIn input) {
    \\    BgImageVertexOut outv;
    \\    uint tex_w;
    \\    uint tex_h;
    \\    image_texture.GetDimensions(tex_w, tex_h);
    \\    float2 tex_size = float2(tex_w, tex_h);
    \\    float4 position;
    \\    position.x = (vertex_id == 2u) ? 3.0f : -1.0f;
    \\    position.y = (vertex_id == 0u) ? -3.0f : 1.0f;
    \\    position.z = 0.0f;
    \\    position.w = 1.0f;
    \\    outv.position = position;
    \\    outv.opacity = input.opacity;
    \\    outv.repeat = input.info & BG_IMAGE_REPEAT;
    \\    float2 dest_size = tex_size;
    \\    switch (input.info & BG_IMAGE_FIT) {
    \\        case BG_IMAGE_CONTAIN: {
    \\            float scale_factor = min(screen_size.x / tex_size.x, screen_size.y / tex_size.y);
    \\            dest_size = tex_size * scale_factor;
    \\        } break;
    \\        case BG_IMAGE_COVER: {
    \\            float scale_factor = max(screen_size.x / tex_size.x, screen_size.y / tex_size.y);
    \\            dest_size = tex_size * scale_factor;
    \\        } break;
    \\        case BG_IMAGE_STRETCH: dest_size = screen_size; break;
    \\        default: break;
    \\    }
    \\    float2 start = float2(0.0f, 0.0f);
    \\    float2 mid = (screen_size - dest_size) / 2.0f;
    \\    float2 end = screen_size - dest_size;
    \\    float2 dest_offset = mid;
    \\    switch (input.info & BG_IMAGE_POSITION) {
    \\        case BG_IMAGE_TL: dest_offset = float2(start.x, start.y); break;
    \\        case BG_IMAGE_TC: dest_offset = float2(mid.x, start.y); break;
    \\        case BG_IMAGE_TR: dest_offset = float2(end.x, start.y); break;
    \\        case BG_IMAGE_ML: dest_offset = float2(start.x, mid.y); break;
    \\        case BG_IMAGE_MC: dest_offset = float2(mid.x, mid.y); break;
    \\        case BG_IMAGE_MR: dest_offset = float2(end.x, mid.y); break;
    \\        case BG_IMAGE_BL: dest_offset = float2(start.x, end.y); break;
    \\        case BG_IMAGE_BC: dest_offset = float2(mid.x, end.y); break;
    \\        case BG_IMAGE_BR: dest_offset = float2(end.x, end.y); break;
    \\        default: break;
    \\    }
    \\    outv.offset = dest_offset;
    \\    outv.scale = tex_size / dest_size;
    \\    {
    \\        uint4 bg = unpack4u8(bg_color_packed_4u8);
    \\        outv.bg_color = float4(load_color_u4(uint4(bg.rgb, 255u), (bools & USE_LINEAR_BLENDING) != 0u).rgb, float(bg.a) / 255.0f);
    \\    }
    \\    return outv;
    \\}
;

const bg_image_fragment_hlsl = common_hlsl ++
    \\Texture2D<float4> image_texture : register(t0);
    \\
    \\struct BgImageVertexOut {
    \\    float4 position : SV_Position;
    \\    nointerpolation float4 bg_color : TEXCOORD0;
    \\    nointerpolation float2 offset : TEXCOORD1;
    \\    nointerpolation float2 scale : TEXCOORD2;
    \\    nointerpolation float opacity : TEXCOORD3;
    \\    nointerpolation uint repeat : TEXCOORD4;
    \\};
    \\
    \\float4 bg_image_fragment(BgImageVertexOut input) : SV_Target0 {
    \\    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0u;
    \\    uint tex_w;
    \\    uint tex_h;
    \\    image_texture.GetDimensions(tex_w, tex_h);
    \\    float2 tex_size = float2(tex_w, tex_h);
    \\    float2 tex_coord = (input.position.xy - input.offset) * input.scale;
    \\    if (input.repeat != 0u) {
    \\        tex_coord = fmod(fmod(tex_coord, tex_size) + tex_size, tex_size);
    \\    }
    \\    float4 rgba;
    \\    if (any(tex_coord < float2(0.0f, 0.0f)) || any(tex_coord > tex_size)) {
    \\        rgba = float4(0.0f, 0.0f, 0.0f, 0.0f);
    \\    } else {
    \\        rgba = image_texture.SampleLevel(linear_sampler, tex_coord / tex_size, 0.0f);
    \\        if (!use_linear_blending) {
    \\            rgba = unlinearize(rgba);
    \\        }
    \\        rgba.rgb *= rgba.a;
    \\    }
    \\    rgba *= min(input.opacity, 1.0f / input.bg_color.a);
    \\    rgba += max(float4(0.0f, 0.0f, 0.0f, 0.0f), float4(input.bg_color.rgb, 1.0f) * (1.0f - rgba.a));
    \\    rgba *= input.bg_color.a;
    \\    return rgba;
    \\}
;
