const std = @import("std");
const WasmTarget = @import("../os/wasm/target.zig").Target;

/// Possible implementations, used for build options.
pub const Backend = enum {
    opengl,
    software,
    metal,
    webgl,

    /// Returns the backend that `software` maps to for the given OS.
    /// This is transitional while the dedicated CPU renderer is being built.
    pub fn softwareRouteForOsTag(os_tag: std.Target.Os.Tag) Backend {
        return switch (os_tag) {
            .macos, .ios, .tvos, .watchos, .visionos => .metal,
            else => .opengl,
        };
    }

    /// Returns the backend that is actually used on the provided target.
    /// For most backends this is the backend itself; `software` is routed.
    pub fn effective(
        self: Backend,
        target: std.Target,
    ) Backend {
        return switch (self) {
            .software => softwareRouteForOsTag(target.os.tag),
            else => self,
        };
    }

    pub fn default(
        target: std.Target,
        wasm_target: WasmTarget,
    ) Backend {
        if (target.cpu.arch == .wasm32) {
            return switch (wasm_target) {
                .browser => .webgl,
            };
        }

        if (target.os.tag.isDarwin()) return .metal;
        return .opengl;
    }
};

test "softwareRouteForOsTag routes Darwin tags to metal" {
    const testing = std.testing;

    const darwin_tags = [_]std.Target.Os.Tag{
        .macos,
        .ios,
        .tvos,
        .watchos,
        .visionos,
    };

    for (darwin_tags) |os_tag| {
        try testing.expectEqual(Backend.metal, Backend.softwareRouteForOsTag(os_tag));
    }
}

test "softwareRouteForOsTag routes windows/linux/freebsd to opengl" {
    const testing = std.testing;

    const desktop_tags = [_]std.Target.Os.Tag{
        .windows,
        .linux,
        .freebsd,
    };

    for (desktop_tags) |os_tag| {
        try testing.expectEqual(Backend.opengl, Backend.softwareRouteForOsTag(os_tag));
    }
}

test "softwareRouteForOsTag keeps macos software path off OpenGL" {
    const testing = std.testing;
    const macos_route = Backend.softwareRouteForOsTag(.macos);

    try testing.expect(macos_route != .opengl);
    try testing.expectEqual(Backend.metal, macos_route);
}
