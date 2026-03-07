//! GhosttyFrameData generates a compressed file and zig module which contains (and exposes) the
//! Ghostty animation frames for use in `ghostty +boo`
const GhosttyFrameData = @This();

const std = @import("std");
const Config = @import("Config.zig");
const DistResource = @import("GhosttyDist.zig").Resource;

/// The output path for the compressed framedata zig file
output: std.Build.LazyPath,

pub fn init(b: *std.Build, cfg: *const Config) !GhosttyFrameData {
    if (cfg.ci_windows_smoke_minimal and cfg.target.result.os.tag == .windows) {
        const wf = b.addWriteFiles();
        const zig_file = wf.add("framedata.zig",
            \\//! This file is auto-generated. Do not edit.
            \\
            \\pub const compressed = "";
            \\
        );
        return .{ .output = zig_file };
    }

    const dist = distResources(b);

    // Generate the Zig source file that embeds the compressed data
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(dist.framedata.path(b), "framedata.compressed");
    const zig_file = wf.add("framedata.zig",
        \\//! This file is auto-generated. Do not edit.
        \\
        \\pub const compressed = @embedFile("framedata.compressed");
        \\
    );

    return .{ .output = zig_file };
}

/// Add the "framedata" import.
pub fn addImport(self: *const GhosttyFrameData, step: *std.Build.Step.Compile) void {
    self.output.addStepDependencies(&step.step);
    step.root_module.addAnonymousImport("framedata", .{
        .root_source_file = self.output,
    });
}

/// Creates the framedata resources that can be prebuilt for our dist build.
pub fn distResources(b: *std.Build) struct {
    framedata: DistResource,
} {
    const exe = b.addExecutable(.{
        .name = "framegen",
        .root_module = b.createModule(.{
            .target = b.graph.host,
        }),
    });
    exe.addCSourceFile(.{
        .file = b.path("src/build/framegen/main.c"),
        .flags = &.{},
    });
    exe.linkLibC();

    if (b.systemIntegrationOption("zlib", .{})) {
        exe.linkSystemLibrary2("zlib", .{
            .preferred_link_mode = .dynamic,
            .search_strategy = .mode_first,
        });
    } else {
        if (b.lazyDependency("zlib", .{
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        })) |zlib_dep| {
            exe.linkLibrary(zlib_dep.artifact("z"));
        }
    }

    const run = b.addRunArtifact(exe);
    // Use a cwd-relative LazyPath that carries an absolute path from the
    // owning build root. This keeps dependency builds (such as the
    // libghostty software-host example) working while still avoiding the
    // native Windows RunStep path assertion issues we hit with plain src_path
    // arguments in CI.
    run.addDirectoryArg(.{
        .cwd_relative = b.pathFromRoot("src/build/framegen/frames"),
    });
    const compressed_file = run.addOutputFileArg("framedata.compressed");

    return .{
        .framedata = .{
            .dist = "src/build/framegen/framedata.compressed",
            .generated = compressed_file,
        },
    };
}
