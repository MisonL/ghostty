const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const run_step = b.step("run", "Run the software-host demo");

    const exe_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &.{"main.c"},
    });

    if (b.lazyDependency("ghostty", .{
        .@"app-runtime" = "none",
        .renderer = "software",
        .@"software-renderer-cpu-mvp" = true,
        .@"software-frame-transport-mode" = "shared",
    })) |dep| {
        exe_mod.linkLibrary(dep.artifact("ghostty"));
    }

    const exe = b.addExecutable(.{
        .name = "c_libghostty_software_host",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);
}
