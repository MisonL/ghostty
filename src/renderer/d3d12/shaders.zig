const std = @import("std");
const Allocator = std.mem.Allocator;
const Pipeline = @import("Pipeline.zig");
const OpenGLShaders = @import("../opengl/shaders.zig");

const log = std.log.scoped(.d3d12);

const pipeline_descs: []const struct { [:0]const u8, PipelineDescription } =
    &.{
        .{ "bg_color", .{
            .vertex_hlsl = full_screen_vertex_hlsl,
            .fragment_hlsl = bg_color_fragment_hlsl,
            .blending_enabled = false,
        } },
        .{ "cell_bg", .{
            .vertex_hlsl = full_screen_vertex_hlsl,
            .fragment_hlsl = cell_bg_fragment_hlsl,
            .blending_enabled = true,
        } },
        .{ "cell_text", .{
            .vertex_attributes = CellText,
            .vertex_hlsl = cell_text_vertex_hlsl,
            .fragment_hlsl = cell_text_fragment_hlsl,
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "image", .{
            .vertex_attributes = Image,
            .vertex_hlsl = image_vertex_hlsl,
            .fragment_hlsl = image_fragment_hlsl,
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "bg_image", .{
            .vertex_attributes = BgImage,
            .vertex_hlsl = bg_image_vertex_hlsl,
            .fragment_hlsl = bg_image_fragment_hlsl,
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
    };

const PipelineDescription = struct {
    vertex_attributes: ?type = null,
    vertex_hlsl: [:0]const u8,
    fragment_hlsl: [:0]const u8,
    step_fn: Pipeline.StepFunction = .per_vertex,
    blending_enabled: bool = true,

    fn initPipeline(self: PipelineDescription, alloc: Allocator) !Pipeline {
        return try Pipeline.init(self.vertex_attributes, .{
            .alloc = alloc,
            .vertex_fn = self.vertex_hlsl,
            .fragment_fn = self.fragment_hlsl,
            .step_fn = self.step_fn,
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

    pub fn init(alloc: Allocator, post_shaders: []const [:0]const u8) !Shaders {
        var pipelines: PipelineCollection = undefined;

        var initialized_pipelines: usize = 0;
        errdefer inline for (pipeline_descs, 0..) |pipeline, i| {
            if (i < initialized_pipelines) {
                @field(pipelines, pipeline[0]).deinit(alloc);
            }
        };

        inline for (pipeline_descs) |pipeline| {
            @field(pipelines, pipeline[0]) = try pipeline[1].initPipeline(alloc);
            initialized_pipelines += 1;
        }

        const post_pipelines: []const Pipeline = initPostPipelines(alloc, post_shaders) catch |err| err: {
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
    shaders: []const [:0]const u8,
) ![]const Pipeline {
    if (shaders.len == 0) return &.{};

    var pipelines = try alloc.alloc(Pipeline, shaders.len);
    errdefer alloc.free(pipelines);

    var count: usize = 0;
    errdefer for (pipelines[0..count]) |*pipeline| pipeline.deinit(alloc);

    for (shaders) |source| {
        pipelines[count] = try initPostPipeline(alloc, source);
        count += 1;
    }

    return pipelines;
}

fn initPostPipeline(alloc: Allocator, data: [:0]const u8) !Pipeline {
    return try Pipeline.init(null, .{
        .alloc = alloc,
        .vertex_fn = full_screen_vertex_hlsl,
        .fragment_fn = data,
    });
}

test "d3d12 built-in shaders compile to hlsl" {
    const testing = std.testing;
    var shaders = try Shaders.init(testing.allocator, &.{});
    defer shaders.deinit(testing.allocator);
    try testing.expect(shaders.pipelines.bg_color.vertex_source.len > 0);
    try testing.expect(shaders.pipelines.cell_text.fragment_source.len > 0);
}

const full_screen_vertex_hlsl =
    \\struct FullScreenVertexOut {
    \\    float4 position : SV_Position;
    \\};
    \\
    \\FullScreenVertexOut full_screen_vertex(uint vertex_id : SV_VertexID) {
    \\    FullScreenVertexOut outv;
    \\    float2 pos = (vertex_id == 0u) ? float2(-1.0, -3.0) :
    \\        ((vertex_id == 1u) ? float2(-1.0, 1.0) : float2(3.0, 1.0));
    \\    outv.position = float4(pos, 0.0, 1.0);
    \\    return outv;
    \\}
;

const cell_text_vertex_hlsl =
    \\struct CellTextVertexOut {
    \\    float4 position : SV_Position;
    \\};
    \\
    \\CellTextVertexOut cell_text_vertex(uint vertex_id : SV_VertexID) {
    \\    CellTextVertexOut outv;
    \\    float2 pos = (vertex_id == 0u) ? float2(-1.0, -3.0) :
    \\        ((vertex_id == 1u) ? float2(-1.0, 1.0) : float2(3.0, 1.0));
    \\    outv.position = float4(pos, 0.0, 1.0);
    \\    return outv;
    \\}
;

const image_vertex_hlsl =
    \\struct ImageVertexOut {
    \\    float4 position : SV_Position;
    \\};
    \\
    \\ImageVertexOut image_vertex(uint vertex_id : SV_VertexID) {
    \\    ImageVertexOut outv;
    \\    float2 pos = (vertex_id == 0u) ? float2(-1.0, -3.0) :
    \\        ((vertex_id == 1u) ? float2(-1.0, 1.0) : float2(3.0, 1.0));
    \\    outv.position = float4(pos, 0.0, 1.0);
    \\    return outv;
    \\}
;

const bg_image_vertex_hlsl =
    \\struct BgImageVertexOut {
    \\    float4 position : SV_Position;
    \\};
    \\
    \\BgImageVertexOut bg_image_vertex(uint vertex_id : SV_VertexID) {
    \\    BgImageVertexOut outv;
    \\    float2 pos = (vertex_id == 0u) ? float2(-1.0, -3.0) :
    \\        ((vertex_id == 1u) ? float2(-1.0, 1.0) : float2(3.0, 1.0));
    \\    outv.position = float4(pos, 0.0, 1.0);
    \\    return outv;
    \\}
;

const bg_color_fragment_hlsl =
    \\float4 bg_color_fragment() : SV_Target0 {
    \\    return float4(0.0, 0.0, 0.0, 1.0);
    \\}
;

const cell_bg_fragment_hlsl =
    \\float4 cell_bg_fragment() : SV_Target0 {
    \\    return float4(0.0, 0.0, 0.0, 0.0);
    \\}
;

const cell_text_fragment_hlsl =
    \\float4 cell_text_fragment() : SV_Target0 {
    \\    return float4(1.0, 1.0, 1.0, 1.0);
    \\}
;

const image_fragment_hlsl =
    \\float4 image_fragment() : SV_Target0 {
    \\    return float4(1.0, 1.0, 1.0, 1.0);
    \\}
;

const bg_image_fragment_hlsl =
    \\float4 bg_image_fragment() : SV_Target0 {
    \\    return float4(1.0, 1.0, 1.0, 1.0);
    \\}
;
