const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    alloc: Allocator,
    vertex_fn: [:0]const u8,
    fragment_fn: [:0]const u8,
    step_fn: StepFunction = .per_vertex,
    blending_enabled: bool = true,
};

pub const StepFunction = enum {
    constant,
    per_vertex,
    per_instance,
};

vertex_source: [:0]const u8,
fragment_source: [:0]const u8,
vertex_stride: usize,
step_fn: StepFunction,
blending_enabled: bool,

pub fn init(comptime VertexAttributes: ?type, opts: Options) !Self {
    return .{
        .vertex_source = try opts.alloc.dupeZ(u8, opts.vertex_fn),
        .fragment_source = try opts.alloc.dupeZ(u8, opts.fragment_fn),
        .vertex_stride = if (VertexAttributes) |VA| @sizeOf(VA) else 0,
        .step_fn = opts.step_fn,
        .blending_enabled = opts.blending_enabled,
    };
}

pub fn deinit(self: *const Self, alloc: Allocator) void {
    alloc.free(self.vertex_source);
    alloc.free(self.fragment_source);
}
