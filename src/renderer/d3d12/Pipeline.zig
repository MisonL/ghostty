const Self = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;
const internal_os = @import("../../os/main.zig");
const winos = internal_os.windows;

pub const Options = struct {
    alloc: Allocator,
    vertex_source: [:0]const u8,
    fragment_source: [:0]const u8,
    vertex_entry: [:0]const u8,
    fragment_entry: [:0]const u8,
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
vertex_entry: [:0]const u8,
fragment_entry: [:0]const u8,
vertex_blob: ShaderBlob = .{},
fragment_blob: ShaderBlob = .{},
vertex_stride: usize,
step_fn: StepFunction,
blending_enabled: bool,

pub fn init(comptime VertexAttributes: ?type, opts: Options) !Self {
    var result: Self = .{
        .vertex_source = try opts.alloc.dupeZ(u8, opts.vertex_source),
        .fragment_source = try opts.alloc.dupeZ(u8, opts.fragment_source),
        .vertex_entry = try opts.alloc.dupeZ(u8, opts.vertex_entry),
        .fragment_entry = try opts.alloc.dupeZ(u8, opts.fragment_entry),
        .vertex_stride = if (VertexAttributes) |VA| @sizeOf(VA) else 0,
        .step_fn = opts.step_fn,
        .blending_enabled = opts.blending_enabled,
    };
    errdefer result.deinit(opts.alloc);

    if (builtin.target.os.tag == .windows) {
        result.vertex_blob = try compileShader(
            result.vertex_source,
            result.vertex_entry,
            "vs_5_0",
        );
        errdefer result.vertex_blob.deinit();
        result.fragment_blob = try compileShader(
            result.fragment_source,
            result.fragment_entry,
            "ps_5_0",
        );
    }

    return result;
}

pub fn deinit(self: *const Self, alloc: Allocator) void {
    self.vertex_blob.deinit();
    self.fragment_blob.deinit();
    alloc.free(self.vertex_source);
    alloc.free(self.fragment_source);
    alloc.free(self.vertex_entry);
    alloc.free(self.fragment_entry);
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
