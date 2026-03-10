const std = @import("std");
const internal_os = @import("../../os/main.zig");
const winos = internal_os.windows;

pub const Options = struct {
    device: ?*winos.graphics.ID3D12Device = null,
    defer_release_ctx: ?*anyopaque = null,
    defer_release_fn: ?*const fn (?*anyopaque, *winos.graphics.ID3D12Resource, bool) void = null,
};

pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        opts: Options,
        buffer: ?*winos.graphics.ID3D12Resource = null,
        mapped: ?[*]u8 = null,
        len: usize = 0,
        capacity_bytes: usize = 0,

        pub fn init(opts: Options, len: usize) !Self {
            var self: Self = .{ .opts = opts };
            errdefer self.deinit();
            try self.ensureCapacity(if (len == 0) 1 else len);
            self.len = len;
            return self;
        }

        pub fn initFill(opts: Options, data: []const T) !Self {
            var self = try init(opts, data.len);
            errdefer self.deinit();
            try self.sync(data);
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.buffer) |buffer| {
                const native = nativePtr(*winos.c.ID3D12Resource, buffer);
                if (self.opts.defer_release_fn) |defer_release| {
                    defer_release(
                        self.opts.defer_release_ctx,
                        buffer,
                        self.mapped != null,
                    );
                } else {
                    if (self.mapped != null) native.lpVtbl[0].Unmap.?(
                        native,
                        0,
                        null,
                    );
                    winos.graphics.release(@ptrCast(buffer));
                }
            }
            self.* = undefined;
        }

        pub fn gpuVirtualAddress(self: *const Self) u64 {
            const buffer = self.buffer orelse return 0;
            const native = nativePtr(*winos.c.ID3D12Resource, buffer);
            return native.lpVtbl[0].GetGPUVirtualAddress.?(native);
        }

        pub fn vertexBufferView(self: *const Self) !winos.c.D3D12_VERTEX_BUFFER_VIEW {
            const size_bytes = try std.math.mul(usize, self.len, @sizeOf(T));
            const size_in_bytes = std.math.cast(winos.c.UINT, size_bytes) orelse return error.Overflow;
            return .{
                .BufferLocation = self.gpuVirtualAddress(),
                .SizeInBytes = size_in_bytes,
                .StrideInBytes = @sizeOf(T),
            };
        }

        pub fn sync(self: *Self, data: []const T) !void {
            try self.ensureCapacity(if (data.len == 0) 1 else data.len);
            self.len = data.len;
            if (data.len == 0) return;

            const byte_len = try std.math.mul(usize, data.len, @sizeOf(T));
            const dst = self.mapped.?[0..byte_len];
            const src: [*]const u8 = @ptrCast(data.ptr);
            @memcpy(dst, src[0..byte_len]);
        }

        pub fn syncFromArrayLists(
            self: *Self,
            lists: []const std.ArrayListUnmanaged(T),
        ) !u32 {
            var total_len: usize = 0;
            for (lists) |list| total_len = try std.math.add(usize, total_len, list.items.len);

            try self.ensureCapacity(if (total_len == 0) 1 else total_len);
            self.len = total_len;
            if (total_len == 0) return 0;

            var write_off: usize = 0;
            const dst = self.mapped.?;
            for (lists) |list| {
                if (list.items.len == 0) continue;
                const byte_len = try std.math.mul(usize, list.items.len, @sizeOf(T));
                const end_off = try std.math.add(usize, write_off, byte_len);
                const src: [*]const u8 = @ptrCast(list.items.ptr);
                @memcpy(dst[write_off..end_off], src[0..byte_len]);
                write_off = end_off;
            }

            return std.math.cast(u32, total_len) orelse return error.Overflow;
        }

        fn ensureCapacity(self: *Self, len: usize) !void {
            const required_bytes = try std.math.mul(usize, len, @sizeOf(T));
            if (required_bytes <= self.capacity_bytes) return;

            const new_capacity_bytes = if (self.capacity_bytes == 0)
                required_bytes
            else
                @max(required_bytes, std.math.mul(usize, self.capacity_bytes, 2) catch required_bytes);
            const resource = try createUploadResource(self.opts, new_capacity_bytes);
            errdefer winos.graphics.release(@ptrCast(resource));

            const native = nativePtr(*winos.c.ID3D12Resource, resource);
            var mapped: ?*anyopaque = null;
            if (native.lpVtbl[0].Map.?(
                native,
                0,
                null,
                &mapped,
            ) != winos.S_OK or mapped == null) {
                return error.D3D12BufferMapFailed;
            }
            errdefer native.lpVtbl[0].Unmap.?(
                native,
                0,
                null,
            );

            if (self.buffer) |old_buffer| {
                const old_native = nativePtr(*winos.c.ID3D12Resource, old_buffer);
                if (self.mapped) |old_mapped| {
                    @memcpy(
                        @as([*]u8, @ptrCast(mapped.?))[0..self.capacity_bytes],
                        old_mapped[0..self.capacity_bytes],
                    );
                    old_native.lpVtbl[0].Unmap.?(
                        old_native,
                        0,
                        null,
                    );
                }
                winos.graphics.release(@ptrCast(old_buffer));
            }

            self.buffer = resource;
            self.mapped = @ptrCast(mapped.?);
            self.capacity_bytes = new_capacity_bytes;
        }
    };
}

fn createUploadResource(
    opts: Options,
    size_bytes: usize,
) !*winos.graphics.ID3D12Resource {
    const raw_device = opts.device orelse return error.D3D12DeviceUnavailable;
    const device = nativePtr(*winos.c.ID3D12Device, raw_device);

    var heap_props: winos.c.D3D12_HEAP_PROPERTIES =
        std.mem.zeroes(winos.c.D3D12_HEAP_PROPERTIES);
    heap_props.Type = winos.c.D3D12_HEAP_TYPE_UPLOAD;
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
        winos.c.D3D12_RESOURCE_STATE_GENERIC_READ,
        null,
        &winos.c.IID_ID3D12Resource,
        &raw_resource,
    ) != winos.S_OK or raw_resource == null) {
        return error.D3D12BufferCreateFailed;
    }

    return @ptrCast(raw_resource.?);
}

fn nativePtr(comptime T: type, raw: anytype) T {
    return @ptrFromInt(@intFromPtr(raw));
}
