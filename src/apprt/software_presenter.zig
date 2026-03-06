const configpkg = @import("../config.zig");

pub const RequestedPresenter = configpkg.Config.SoftwareRendererPresenter;

pub const Availability = enum {
    available,
    runtime_too_old,
    runtime_capability_missing,
    platform_route_unavailable,
};

pub const Reason = enum {
    not_software_build,
    experimental_disabled,
    forced_legacy_gl,
    runtime_too_old,
    runtime_capability_missing,
    platform_route_unavailable,
    runtime_failed_session_fallback,
    snapshot_selected,
};

pub const Input = struct {
    is_software_build: bool,
    experimental: bool,
    requested: RequestedPresenter,
    availability: Availability,
    runtime_fallback: bool,
};

pub const Decision = struct {
    requested: RequestedPresenter,
    selected: RequestedPresenter,
    reason: Reason,
    experimental: bool,
    can_publish_software_frame: bool,
    degraded: bool,
};

pub fn decide(input: Input) Decision {
    if (!input.is_software_build) {
        return .{
            .requested = .@"legacy-gl",
            .selected = .@"legacy-gl",
            .reason = .not_software_build,
            .experimental = false,
            .can_publish_software_frame = false,
            .degraded = false,
        };
    }

    if (!input.experimental) {
        return .{
            .requested = input.requested,
            .selected = .@"legacy-gl",
            .reason = .experimental_disabled,
            .experimental = false,
            .can_publish_software_frame = false,
            .degraded = false,
        };
    }

    if (input.requested == .@"legacy-gl") {
        return .{
            .requested = input.requested,
            .selected = .@"legacy-gl",
            .reason = .forced_legacy_gl,
            .experimental = true,
            .can_publish_software_frame = false,
            .degraded = false,
        };
    }

    // Runtime fallback is session-scoped: once a snapshot/publish path fails,
    // keep the compatibility route pinned until the caller explicitly resets it.
    if (input.runtime_fallback) {
        return .{
            .requested = input.requested,
            .selected = .@"legacy-gl",
            .reason = .runtime_failed_session_fallback,
            .experimental = true,
            .can_publish_software_frame = false,
            .degraded = true,
        };
    }

    if (input.availability != .available) {
        const reason: Reason = switch (input.availability) {
            .available => unreachable,
            .runtime_too_old => .runtime_too_old,
            .runtime_capability_missing => .runtime_capability_missing,
            .platform_route_unavailable => .platform_route_unavailable,
        };
        return .{
            .requested = input.requested,
            .selected = .@"legacy-gl",
            .reason = reason,
            .experimental = true,
            .can_publish_software_frame = false,
            .degraded = true,
        };
    }

    return .{
        .requested = input.requested,
        .selected = .snapshot,
        .reason = .snapshot_selected,
        .experimental = true,
        .can_publish_software_frame = true,
        .degraded = false,
    };
}

test "decide returns not_software_build when renderer is not software build" {
    const std = @import("std");
    const decision = decide(.{
        .is_software_build = false,
        .experimental = true,
        .requested = .snapshot,
        .availability = .available,
        .runtime_fallback = false,
    });

    try std.testing.expectEqual(Reason.not_software_build, decision.reason);
    try std.testing.expectEqual(RequestedPresenter.@"legacy-gl", decision.selected);
    try std.testing.expect(!decision.can_publish_software_frame);
}

test "decide returns experimental_disabled when feature flag is disabled" {
    const std = @import("std");
    const decision = decide(.{
        .is_software_build = true,
        .experimental = false,
        .requested = .snapshot,
        .availability = .available,
        .runtime_fallback = false,
    });

    try std.testing.expectEqual(Reason.experimental_disabled, decision.reason);
    try std.testing.expectEqual(RequestedPresenter.@"legacy-gl", decision.selected);
    try std.testing.expect(!decision.can_publish_software_frame);
}

test "decide returns runtime_too_old when runtime availability requires newer versions" {
    const std = @import("std");
    const decision = decide(.{
        .is_software_build = true,
        .experimental = true,
        .requested = .snapshot,
        .availability = .runtime_too_old,
        .runtime_fallback = false,
    });

    try std.testing.expectEqual(Reason.runtime_too_old, decision.reason);
    try std.testing.expect(decision.degraded);
}

test "decide returns runtime_capability_missing when runtime lacks presenter support" {
    const std = @import("std");
    const decision = decide(.{
        .is_software_build = true,
        .experimental = true,
        .requested = .auto,
        .availability = .runtime_capability_missing,
        .runtime_fallback = false,
    });

    try std.testing.expectEqual(Reason.runtime_capability_missing, decision.reason);
    try std.testing.expect(decision.degraded);
}

test "decide returns runtime_failed_session_fallback when runtime fallback is active" {
    const std = @import("std");
    const decision = decide(.{
        .is_software_build = true,
        .experimental = true,
        .requested = .snapshot,
        .availability = .available,
        .runtime_fallback = true,
    });

    try std.testing.expectEqual(Reason.runtime_failed_session_fallback, decision.reason);
    try std.testing.expect(decision.degraded);
}

test "decide keeps runtime_failed_session_fallback sticky when availability later degrades" {
    const std = @import("std");
    const decision = decide(.{
        .is_software_build = true,
        .experimental = true,
        .requested = .snapshot,
        .availability = .runtime_capability_missing,
        .runtime_fallback = true,
    });

    try std.testing.expectEqual(Reason.runtime_failed_session_fallback, decision.reason);
    try std.testing.expectEqual(RequestedPresenter.@"legacy-gl", decision.selected);
    try std.testing.expect(!decision.can_publish_software_frame);
    try std.testing.expect(decision.degraded);
}

test "decide selects snapshot when available with experimental enabled" {
    const std = @import("std");
    const decision = decide(.{
        .is_software_build = true,
        .experimental = true,
        .requested = .snapshot,
        .availability = .available,
        .runtime_fallback = false,
    });

    try std.testing.expectEqual(Reason.snapshot_selected, decision.reason);
    try std.testing.expectEqual(RequestedPresenter.snapshot, decision.selected);
    try std.testing.expect(decision.can_publish_software_frame);
}
