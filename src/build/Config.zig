/// Build configuration. This is the configuration that is populated
/// during `zig build` to control the rest of the build process.
const Config = @This();

const std = @import("std");
const builtin = @import("builtin");

const ApprtRuntime = @import("../apprt/runtime.zig").Runtime;
const FontBackend = @import("../font/backend.zig").Backend;
const RendererBackend = @import("../renderer/backend.zig").Backend;
const TerminalBuildOptions = @import("../terminal/build_options.zig").Options;
const XCFrameworkTarget = @import("xcframework.zig").Target;
const WasmTarget = @import("../os/wasm/target.zig").Target;
const expandPath = @import("../os/path.zig").expand;

const gtk = @import("gtk.zig");
const GitVersion = @import("GitVersion.zig");

const software_renderer_cpu_min_macos: std.SemanticVersion = .{
    .major = 11,
    .minor = 0,
    .patch = 0,
};
const software_renderer_cpu_min_linux: std.SemanticVersion = .{
    .major = 5,
    .minor = 0,
    .patch = 0,
};
const software_renderer_cpu_mvp_help =
    "Enable the CPU software renderer MVP scaffold route. Disabled by default. Effective only for macOS >= 11 and Linux >= 5.0 unless legacy override is enabled. For legacy target bring-up examples: macOS 10.15 => zig build -Dtarget=aarch64-macos.10.15.0 -Dsoftware-renderer-cpu-mvp=true -Dsoftware-renderer-cpu-allow-legacy-os=true ; Linux 4.19 => zig build -Dtarget=x86_64-linux.4.19.0-gnu -Dsoftware-renderer-cpu-mvp=true -Dsoftware-renderer-cpu-allow-legacy-os=true. Even when effective, Ghostty may auto-fallback to the platform route when custom shaders are active in off/safe modes or when software-frame-transport-mode=native.";
const software_renderer_cpu_shader_mode_help =
    "CPU software renderer custom-shader mode: off/safe/full. off=always fallback to platform route while shaders are active; safe=use CPU route only when custom-shader execution capability is available and timeout budget is > 0, otherwise fallback to platform route; full=use CPU route only when custom-shader execution capability is available, otherwise fallback to platform route.";
const software_renderer_cpu_shader_backend_help =
    "CPU software renderer custom-shader execution backend: off|vulkan_swiftshader. off=disable CPU custom-shader execution and force platform-route fallback while shaders are active; vulkan_swiftshader=enable SwiftShader Vulkan execution when available (loader env precedence: VK_DRIVER_FILES > VK_ICD_FILENAMES > VK_ADD_DRIVER_FILES), otherwise fallback to platform route.";
const software_renderer_cpu_shader_timeout_help =
    "CPU software renderer custom-shader timeout budget in milliseconds for safe mode when CPU-route shader execution is enabled. In safe mode, timeout must be > 0; timeout 0 forces platform-route fallback for correctness. Default: 16.";
const software_renderer_cpu_shader_enable_minimal_runtime_help =
    "Enable staged minimal CPU custom-shader runtime success path. Default: false (strict gray rollout). When false, custom-shader execution capability remains unavailable even if backend probe/compile passes. When true, capability may become available in controlled conditions.";
const software_renderer_cpu_frame_damage_mode_help =
    "CPU software renderer frame-damage publishing mode: off|rects. off publishes full frames for each CPU-route update; rects tracks and reports damage rectangles (current stage still uses conservative full-frame composition).";
const software_renderer_cpu_damage_rect_cap_help =
    "Maximum number of tracked damage rectangles for CPU software renderer per frame (u16). Overflow degrades to one full-frame rect for correctness. In rects mode, value 0 is auto-clamped to 1. Default: 64.";
const software_renderer_cpu_publish_warning_threshold_help =
    "CPU software renderer publish latency warning threshold in milliseconds (u32). Frames above this value increment the warning streak when capability is ready. Default: 40.";
const software_renderer_cpu_publish_warning_consecutive_limit_help =
    "CPU software renderer publish latency warning streak limit before emitting a warning (u8). Value 0 is auto-clamped to 1. Default: 3.";

/// Standard build configuration options.
optimize: std.builtin.OptimizeMode,
target: std.Build.ResolvedTarget,
xcframework_target: XCFrameworkTarget = .universal,
wasm_target: WasmTarget,

/// Comptime interfaces
app_runtime: ApprtRuntime = .none,
renderer: RendererBackend = .opengl,
software_renderer_route_backend: RendererBackend = .opengl,
font_backend: FontBackend = .freetype,

/// Feature flags
x11: bool = false,
wayland: bool = false,
sentry: bool = true,
simd: bool = true,
i18n: bool = true,
wasm_shared: bool = true,
software_renderer_cpu_mvp: bool = false,
software_renderer_cpu_allow_legacy_os: bool = false,
software_renderer_cpu_effective: bool = false,
software_frame_transport_mode: SoftwareFrameTransportMode = .auto,
software_renderer_cpu_shader_mode: SoftwareRendererCpuShaderMode = .full,
software_renderer_cpu_shader_backend: SoftwareRendererCpuShaderBackend = .vulkan_swiftshader,
software_renderer_cpu_shader_timeout_ms: u32 = 16,
software_renderer_cpu_shader_enable_minimal_runtime: bool = false,
software_renderer_cpu_frame_damage_mode: SoftwareRendererCpuFrameDamageMode = .rects,
software_renderer_cpu_damage_rect_cap: u16 = 64,
software_renderer_cpu_publish_warning_threshold_ms: u32 = 40,
software_renderer_cpu_publish_warning_consecutive_limit: u8 = 3,

/// Ghostty exe properties
exe_entrypoint: ExeEntrypoint = .ghostty,
version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 },

/// Binary properties
pie: bool = false,
strip: bool = false,
patch_rpath: ?[]const u8 = null,

/// Artifacts
flatpak: bool = false,
snap: bool = false,
emit_bench: bool = false,
emit_docs: bool = false,
emit_exe: bool = false,
emit_helpgen: bool = false,
emit_macos_app: bool = false,
emit_terminfo: bool = false,
emit_termcap: bool = false,
emit_test_exe: bool = false,
emit_themes: bool = false,
emit_xcframework: bool = false,
emit_webdata: bool = false,
emit_unicode_table_gen: bool = false,

/// Environmental properties
env: std.process.EnvMap,

pub fn init(b: *std.Build, appVersion: []const u8) !Config {
    // Setup our standard Zig target and optimize options, i.e.
    // `-Doptimize` and `-Dtarget`.
    const optimize = b.standardOptimizeOption(.{});
    const target = target: {
        var result = b.standardTargetOptions(.{});

        // If we're building for macOS and we're on macOS, we need to
        // use a generic target to workaround compilation issues.
        if (result.result.os.tag == .macos and
            builtin.target.os.tag.isDarwin())
        {
            result = genericMacOSTarget(
                b,
                result.query.cpu_arch,
                result.query.os_version_min,
            );
        }

        // If we have no minimum OS version, we set the default based on
        // our tag. Not all tags have a minimum so this may be null.
        if (result.query.os_version_min == null) {
            result.query.os_version_min = osVersionMin(result.result.os.tag);
        }

        break :target result;
    };

    // This is set to true when we're building a system package. For now
    // this is trivially detected using the "system_package_mode" bool
    // but we may want to make this more sophisticated in the future.
    const system_package = b.graph.system_package_mode;

    // This specifies our target wasm runtime. For now only one semi-usable
    // one exists so this is hardcoded.
    const wasm_target: WasmTarget = .browser;

    // Determine whether GTK supports X11 and Wayland. This is always safe
    // to run even on non-Linux platforms because any failures result in
    // defaults.
    const gtk_targets = gtk.targets(b);

    // We use env vars throughout the build so we grab them immediately here.
    var env = try std.process.getEnvMap(b.allocator);
    errdefer env.deinit();

    var config: Config = .{
        .optimize = optimize,
        .target = target,
        .wasm_target = wasm_target,
        .env = env,
    };

    //---------------------------------------------------------------
    // Target-specific properties
    config.xcframework_target = b.option(
        XCFrameworkTarget,
        "xcframework-target",
        "The target for the xcframework.",
    ) orelse .universal;

    //---------------------------------------------------------------
    // Comptime Interfaces
    config.font_backend = b.option(
        FontBackend,
        "font-backend",
        "The font backend to use for discovery and rasterization.",
    ) orelse FontBackend.default(target.result, wasm_target);

    config.app_runtime = b.option(
        ApprtRuntime,
        "app-runtime",
        "The app runtime to use. Not all values supported on all platforms.",
    ) orelse ApprtRuntime.default(target.result);

    config.renderer = b.option(
        RendererBackend,
        "renderer",
        "The app runtime to use. Not all values supported on all platforms.",
    ) orelse RendererBackend.default(target.result, wasm_target);
    config.software_renderer_route_backend = softwareRendererRouteBackend(target.result);

    config.software_renderer_cpu_mvp = b.option(
        bool,
        "software-renderer-cpu-mvp",
        software_renderer_cpu_mvp_help,
    ) orelse false;
    config.software_renderer_cpu_allow_legacy_os = b.option(
        bool,
        "software-renderer-cpu-allow-legacy-os",
        "Allow CPU software renderer MVP on legacy OS targets even if platform support checks fail. Disabled by default; intended for experimental bring-up on older systems.",
    ) orelse false;
    config.software_renderer_cpu_effective = softwareRendererCpuEffective(
        target.result,
        config.software_renderer_cpu_mvp,
        config.software_renderer_cpu_allow_legacy_os,
    );

    config.software_frame_transport_mode = b.option(
        SoftwareFrameTransportMode,
        "software-frame-transport-mode",
        "Software frame transport mode for software renderer: auto/shared/native (native forces platform-route fallback for CPU route).",
    ) orelse .auto;
    config.software_renderer_cpu_shader_mode = b.option(
        SoftwareRendererCpuShaderMode,
        "software-renderer-cpu-shader-mode",
        software_renderer_cpu_shader_mode_help,
    ) orelse .full;
    config.software_renderer_cpu_shader_backend = b.option(
        SoftwareRendererCpuShaderBackend,
        "software-renderer-cpu-shader-backend",
        software_renderer_cpu_shader_backend_help,
    ) orelse .vulkan_swiftshader;
    config.software_renderer_cpu_shader_timeout_ms = b.option(
        u32,
        "software-renderer-cpu-shader-timeout-ms",
        software_renderer_cpu_shader_timeout_help,
    ) orelse 16;
    config.software_renderer_cpu_shader_enable_minimal_runtime = b.option(
        bool,
        "software-renderer-cpu-shader-enable-minimal-runtime",
        software_renderer_cpu_shader_enable_minimal_runtime_help,
    ) orelse false;
    config.software_renderer_cpu_frame_damage_mode = b.option(
        SoftwareRendererCpuFrameDamageMode,
        "software-renderer-cpu-frame-damage-mode",
        software_renderer_cpu_frame_damage_mode_help,
    ) orelse .rects;
    config.software_renderer_cpu_damage_rect_cap = b.option(
        u16,
        "software-renderer-cpu-damage-rect-cap",
        software_renderer_cpu_damage_rect_cap_help,
    ) orelse 64;
    config.software_renderer_cpu_damage_rect_cap = effectiveSoftwareRendererCpuDamageRectCap(
        config.software_renderer_cpu_frame_damage_mode,
        config.software_renderer_cpu_damage_rect_cap,
    );
    config.software_renderer_cpu_publish_warning_threshold_ms = b.option(
        u32,
        "software-renderer-cpu-publish-warning-threshold-ms",
        software_renderer_cpu_publish_warning_threshold_help,
    ) orelse 40;
    config.software_renderer_cpu_publish_warning_consecutive_limit = b.option(
        u8,
        "software-renderer-cpu-publish-warning-consecutive-limit",
        software_renderer_cpu_publish_warning_consecutive_limit_help,
    ) orelse 3;
    config.software_renderer_cpu_publish_warning_consecutive_limit =
        effectiveSoftwareRendererCpuPublishWarningConsecutiveLimit(
            config.software_renderer_cpu_publish_warning_consecutive_limit,
        );

    //---------------------------------------------------------------
    // Feature Flags

    config.flatpak = b.option(
        bool,
        "flatpak",
        "Build for Flatpak (integrates with Flatpak APIs). Only has an effect targeting Linux.",
    ) orelse false;

    config.snap = b.option(
        bool,
        "snap",
        "Build for Snap (do specific Snap operations). Only has an effect targeting Linux.",
    ) orelse false;

    config.sentry = b.option(
        bool,
        "sentry",
        "Build with Sentry crash reporting. Default for macOS is true, false for any other system.",
    ) orelse sentry: {
        switch (target.result.os.tag) {
            .macos, .ios => break :sentry true,

            // Note its false for linux because the crash reports on Linux
            // don't have much useful information.
            else => break :sentry false,
        }
    };

    config.simd = b.option(
        bool,
        "simd",
        "Build with SIMD-accelerated code paths. Results in significant performance improvements.",
    ) orelse simd: {
        // We can't build our SIMD dependencies for Wasm. Note that we may
        // still use SIMD features in the Wasm-builds.
        if (target.result.cpu.arch.isWasm()) break :simd false;

        break :simd true;
    };

    config.wayland = b.option(
        bool,
        "gtk-wayland",
        "Enables linking against Wayland libraries when using the GTK rendering backend.",
    ) orelse gtk_targets.wayland;

    config.x11 = b.option(
        bool,
        "gtk-x11",
        "Enables linking against X11 libraries when using the GTK rendering backend.",
    ) orelse gtk_targets.x11;

    config.i18n = b.option(
        bool,
        "i18n",
        "Enables gettext-based internationalization. Enabled by default only for macOS, and other Unix-like systems like Linux and FreeBSD when using glibc.",
    ) orelse switch (target.result.os.tag) {
        .macos, .ios => true,
        .linux, .freebsd => target.result.isGnuLibC(),
        else => false,
    };

    //---------------------------------------------------------------
    // Ghostty Exe Properties

    const version_string = b.option(
        []const u8,
        "version-string",
        "A specific version string to use for the build. " ++
            "If not specified, git will be used. This must be a semantic version.",
    );

    config.version = if (version_string) |v|
        // If an explicit version is given, we always use it.
        try std.SemanticVersion.parse(v)
    else version: {
        const app_version = try std.SemanticVersion.parse(appVersion);

        // Is ghostty a dependency? If so, skip git detection.
        // @src().file won't resolve from b.build_root unless ghostty
        // is the project being built.
        b.build_root.handle.access(@src().file, .{}) catch break :version .{
            .major = app_version.major,
            .minor = app_version.minor,
            .patch = app_version.patch,
        };

        // If no explicit version is given, we try to detect it from git.
        const vsn = GitVersion.detect(b) catch |err| switch (err) {
            // If Git isn't available we just make an unknown dev version.
            error.GitNotFound,
            error.GitNotRepository,
            => break :version .{
                .major = app_version.major,
                .minor = app_version.minor,
                .patch = app_version.patch,
                .pre = "dev",
                .build = "0000000",
            },

            else => return err,
        };
        if (vsn.tag) |tag| {
            // Tip releases behave just like any other pre-release so we skip.
            if (!std.mem.eql(u8, tag, "tip")) {
                const expected = b.fmt("v{d}.{d}.{d}", .{
                    app_version.major,
                    app_version.minor,
                    app_version.patch,
                });

                if (!std.mem.eql(u8, tag, expected)) {
                    @panic("tagged releases must be in vX.Y.Z format matching build.zig");
                }

                break :version .{
                    .major = app_version.major,
                    .minor = app_version.minor,
                    .patch = app_version.patch,
                };
            }
        }

        break :version .{
            .major = app_version.major,
            .minor = app_version.minor,
            .patch = app_version.patch,
            .pre = vsn.branch,
            .build = vsn.short_hash,
        };
    };

    //---------------------------------------------------------------
    // Binary Properties

    // On NixOS, the built binary from `zig build` needs to patch the rpath
    // into the built binary for it to be portable across the NixOS system
    // it was built for. We default this to true if we can detect we're in
    // a Nix shell and have LD_LIBRARY_PATH set.
    config.patch_rpath = b.option(
        []const u8,
        "patch-rpath",
        "Inject the LD_LIBRARY_PATH as the rpath in the built binary. " ++
            "This defaults to LD_LIBRARY_PATH if we're in a Nix shell environment on NixOS.",
    ) orelse patch_rpath: {
        // We only do the patching if we're targeting our own CPU and its Linux.
        if (!(target.result.os.tag == .linux) or !target.query.isNativeCpu()) break :patch_rpath null;

        // If we're in a nix shell we default to doing this.
        // Note: we purposely never deinit envmap because we leak the strings
        if (env.get("IN_NIX_SHELL") == null) break :patch_rpath null;
        break :patch_rpath env.get("LD_LIBRARY_PATH");
    };

    config.pie = b.option(
        bool,
        "pie",
        "Build a Position Independent Executable. Default true for system packages.",
    ) orelse system_package;

    config.strip = b.option(
        bool,
        "strip",
        "Strip the final executable. Default true for fast and small releases",
    ) orelse switch (optimize) {
        .Debug => false,
        .ReleaseSafe => false,
        .ReleaseFast, .ReleaseSmall => true,
    };

    //---------------------------------------------------------------
    // Artifacts to Emit

    config.emit_exe = b.option(
        bool,
        "emit-exe",
        "Build and install main executables with 'build'",
    ) orelse true;

    config.emit_test_exe = b.option(
        bool,
        "emit-test-exe",
        "Build and install test executables with 'build'",
    ) orelse false;

    config.emit_unicode_table_gen = b.option(
        bool,
        "emit-unicode-table-gen",
        "Build and install executables that generate unicode tables with 'build'",
    ) orelse false;

    config.emit_bench = b.option(
        bool,
        "emit-bench",
        "Build and install the benchmark executables.",
    ) orelse false;

    config.emit_helpgen = b.option(
        bool,
        "emit-helpgen",
        "Build and install the helpgen executable.",
    ) orelse false;

    config.emit_docs = b.option(
        bool,
        "emit-docs",
        "Build and install auto-generated documentation (requires pandoc)",
    ) orelse emit_docs: {
        // If we are emitting any other artifacts then we default to false.
        if (config.emit_bench or
            config.emit_test_exe or
            config.emit_helpgen) break :emit_docs false;

        // We always emit docs in system package mode.
        if (system_package) break :emit_docs true;

        // We only default to true if we can find pandoc.
        const path = expandPath(b.allocator, "pandoc") catch
            break :emit_docs false;
        defer if (path) |p| b.allocator.free(p);
        break :emit_docs path != null;
    };

    config.emit_terminfo = b.option(
        bool,
        "emit-terminfo",
        "Install Ghostty terminfo source file",
    ) orelse switch (target.result.os.tag) {
        .windows => true,
        else => switch (optimize) {
            .Debug => true,
            .ReleaseSafe, .ReleaseFast, .ReleaseSmall => false,
        },
    };

    config.emit_termcap = b.option(
        bool,
        "emit-termcap",
        "Install Ghostty termcap file",
    ) orelse switch (optimize) {
        .Debug => true,
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => false,
    };

    config.emit_themes = b.option(
        bool,
        "emit-themes",
        "Install bundled iTerm2-Color-Schemes Ghostty themes",
    ) orelse true;

    config.emit_webdata = b.option(
        bool,
        "emit-webdata",
        "Build the website data for the website.",
    ) orelse false;

    config.emit_xcframework = b.option(
        bool,
        "emit-xcframework",
        "Build and install the xcframework for the macOS library.",
    ) orelse builtin.target.os.tag.isDarwin() and
        target.result.os.tag == .macos and
        config.app_runtime == .none and
        (!config.emit_bench and
            !config.emit_test_exe and
            !config.emit_helpgen);

    config.emit_macos_app = b.option(
        bool,
        "emit-macos-app",
        "Build and install the macOS app bundle.",
    ) orelse config.emit_xcframework;

    //---------------------------------------------------------------
    // System Packages

    // These are all our dependencies that can be used with system
    // packages if they exist. We set them up here so that we can set
    // their defaults early. The first call configures the integration and
    // subsequent calls just return the configured value. This lets them
    // show up properly in `--help`.

    {
        // These dependencies we want to default false if we're on macOS.
        // On macOS we don't want to use system libraries because we
        // generally want a fat binary. This can be overridden with the
        // `-fsys` flag.
        for (&[_][]const u8{
            "freetype",
            "harfbuzz",
            "fontconfig",
            "libpng",
            "zlib",
            "oniguruma",
        }) |dep| {
            _ = b.systemIntegrationOption(
                dep,
                .{
                    // If we're not on darwin we want to use whatever the
                    // default is via the system package mode
                    .default = if (target.result.os.tag.isDarwin()) false else null,
                },
            );
        }

        // These default to false because they're rarely available as
        // system packages so we usually want to statically link them.
        for (&[_][]const u8{
            "glslang",
            "spirv-cross",
            "simdutf",
        }) |dep| {
            _ = b.systemIntegrationOption(dep, .{ .default = false });
        }

        // These are dynamic libraries we default to true, preferring
        // to use system packages over building and installing libs
        // as they require additional ldconfig of library paths or
        // patching the rpath of the program to discover the dynamic library
        // at runtime
        for (&[_][]const u8{"gtk4-layer-shell"}) |dep| {
            _ = b.systemIntegrationOption(dep, .{ .default = true });
        }
    }

    return config;
}

/// Configure the build options with our values.
pub fn addOptions(self: *const Config, step: *std.Build.Step.Options) !void {
    // We need to break these down individual because addOption doesn't
    // support all types.
    step.addOption(bool, "flatpak", self.flatpak);
    step.addOption(bool, "snap", self.snap);
    step.addOption(bool, "x11", self.x11);
    step.addOption(bool, "wayland", self.wayland);
    step.addOption(bool, "sentry", self.sentry);
    step.addOption(bool, "simd", self.simd);
    step.addOption(bool, "i18n", self.i18n);
    step.addOption(bool, "software_renderer_cpu_mvp", self.software_renderer_cpu_mvp);
    step.addOption(
        bool,
        "software_renderer_cpu_allow_legacy_os",
        self.software_renderer_cpu_allow_legacy_os,
    );
    step.addOption(bool, "software_renderer_cpu_effective", self.software_renderer_cpu_effective);
    step.addOption(
        SoftwareFrameTransportMode,
        "software_frame_transport_mode",
        self.software_frame_transport_mode,
    );
    step.addOption(
        SoftwareRendererCpuShaderMode,
        "software_renderer_cpu_shader_mode",
        self.software_renderer_cpu_shader_mode,
    );
    step.addOption(
        SoftwareRendererCpuShaderBackend,
        "software_renderer_cpu_shader_backend",
        self.software_renderer_cpu_shader_backend,
    );
    step.addOption(
        u32,
        "software_renderer_cpu_shader_timeout_ms",
        self.software_renderer_cpu_shader_timeout_ms,
    );
    step.addOption(
        bool,
        "software_renderer_cpu_shader_enable_minimal_runtime",
        self.software_renderer_cpu_shader_enable_minimal_runtime,
    );
    step.addOption(
        SoftwareRendererCpuFrameDamageMode,
        "software_renderer_cpu_frame_damage_mode",
        self.software_renderer_cpu_frame_damage_mode,
    );
    step.addOption(
        u16,
        "software_renderer_cpu_damage_rect_cap",
        self.software_renderer_cpu_damage_rect_cap,
    );
    step.addOption(
        u32,
        "software_renderer_cpu_publish_warning_threshold_ms",
        self.software_renderer_cpu_publish_warning_threshold_ms,
    );
    step.addOption(
        u8,
        "software_renderer_cpu_publish_warning_consecutive_limit",
        self.software_renderer_cpu_publish_warning_consecutive_limit,
    );
    step.addOption(
        u32,
        "software_renderer_cpu_min_macos_major",
        software_renderer_cpu_min_macos.major,
    );
    step.addOption(
        u32,
        "software_renderer_cpu_min_macos_minor",
        software_renderer_cpu_min_macos.minor,
    );
    step.addOption(
        u32,
        "software_renderer_cpu_min_linux_major",
        software_renderer_cpu_min_linux.major,
    );
    step.addOption(
        u32,
        "software_renderer_cpu_min_linux_minor",
        software_renderer_cpu_min_linux.minor,
    );
    step.addOption(ApprtRuntime, "app_runtime", self.app_runtime);
    step.addOption(FontBackend, "font_backend", self.font_backend);
    step.addOption(RendererBackend, "renderer", self.renderer);
    step.addOption(
        RendererBackend,
        "software_renderer_route_backend",
        self.software_renderer_route_backend,
    );
    step.addOption(ExeEntrypoint, "exe_entrypoint", self.exe_entrypoint);
    step.addOption(WasmTarget, "wasm_target", self.wasm_target);
    step.addOption(bool, "wasm_shared", self.wasm_shared);

    // Our version. We also add the string version so we don't need
    // to do any allocations at runtime. This has to be long enough to
    // accommodate realistic large branch names for dev versions.
    var buf: [1024]u8 = undefined;
    step.addOption(std.SemanticVersion, "app_version", self.version);
    step.addOption([:0]const u8, "app_version_string", try std.fmt.bufPrintZ(
        &buf,
        "{f}",
        .{self.version},
    ));
    step.addOption(
        ReleaseChannel,
        "release_channel",
        channel: {
            const pre = self.version.pre orelse break :channel .stable;
            if (pre.len == 0) break :channel .stable;
            break :channel .tip;
        },
    );
}

/// Returns the build options for the terminal module. This assumes a
/// Ghostty executable being built. Callers should modify this as needed.
pub fn terminalOptions(self: *const Config) TerminalBuildOptions {
    return .{
        .artifact = .ghostty,
        .simd = self.simd,
        .oniguruma = true,
        .c_abi = false,
        .slow_runtime_safety = switch (self.optimize) {
            .Debug => true,
            .ReleaseSafe,
            .ReleaseSmall,
            .ReleaseFast,
            => false,
        },
    };
}

/// Returns a baseline CPU target retaining all the other CPU configs.
pub fn baselineTarget(self: *const Config) std.Build.ResolvedTarget {
    // Set our cpu model as baseline. There may need to be other modifications
    // we need to make such as resetting CPU features but for now this works.
    var q = self.target.query;
    q.cpu_model = .baseline;

    // Same logic as build.resolveTargetQuery but we don't need to
    // handle the native case.
    return .{
        .query = q,
        .result = std.zig.system.resolveTargetQuery(q) catch
            @panic("unable to resolve baseline query"),
    };
}

/// Rehydrate our Config from the comptime options. Note that not all
/// options are available at comptime, so look closely at this implementation
/// to see what is and isn't available.
pub fn fromOptions() Config {
    // This function performs multiple comptime enum string mappings.
    // Keep a higher branch quota so adding build options remains stable.
    @setEvalBranchQuota(4000);

    const options = @import("build_options");
    const result: Config = .{
        // Unused at runtime.
        .optimize = undefined,
        .target = undefined,
        .env = undefined,

        .version = options.app_version,
        .flatpak = options.flatpak,
        .app_runtime = std.meta.stringToEnum(ApprtRuntime, @tagName(options.app_runtime)).?,
        .font_backend = std.meta.stringToEnum(FontBackend, @tagName(options.font_backend)).?,
        .renderer = std.meta.stringToEnum(RendererBackend, @tagName(options.renderer)).?,
        .software_renderer_route_backend = std.meta.stringToEnum(
            RendererBackend,
            @tagName(options.software_renderer_route_backend),
        ).?,
        .snap = options.snap,
        .software_renderer_cpu_mvp = options.software_renderer_cpu_mvp,
        .software_renderer_cpu_allow_legacy_os = options.software_renderer_cpu_allow_legacy_os,
        .software_renderer_cpu_effective = options.software_renderer_cpu_effective,
        .software_frame_transport_mode = std.meta.stringToEnum(
            SoftwareFrameTransportMode,
            @tagName(options.software_frame_transport_mode),
        ).?,
        .software_renderer_cpu_shader_mode = std.meta.stringToEnum(
            SoftwareRendererCpuShaderMode,
            @tagName(options.software_renderer_cpu_shader_mode),
        ).?,
        .software_renderer_cpu_shader_backend = std.meta.stringToEnum(
            SoftwareRendererCpuShaderBackend,
            @tagName(options.software_renderer_cpu_shader_backend),
        ).?,
        .software_renderer_cpu_shader_timeout_ms = options.software_renderer_cpu_shader_timeout_ms,
        .software_renderer_cpu_shader_enable_minimal_runtime = options.software_renderer_cpu_shader_enable_minimal_runtime,
        .software_renderer_cpu_frame_damage_mode = std.meta.stringToEnum(
            SoftwareRendererCpuFrameDamageMode,
            @tagName(options.software_renderer_cpu_frame_damage_mode),
        ).?,
        .software_renderer_cpu_damage_rect_cap = effectiveSoftwareRendererCpuDamageRectCap(
            std.meta.stringToEnum(
                SoftwareRendererCpuFrameDamageMode,
                @tagName(options.software_renderer_cpu_frame_damage_mode),
            ).?,
            options.software_renderer_cpu_damage_rect_cap,
        ),
        .software_renderer_cpu_publish_warning_threshold_ms = options.software_renderer_cpu_publish_warning_threshold_ms,
        .software_renderer_cpu_publish_warning_consecutive_limit = effectiveSoftwareRendererCpuPublishWarningConsecutiveLimit(
            options.software_renderer_cpu_publish_warning_consecutive_limit,
        ),
        .exe_entrypoint = std.meta.stringToEnum(ExeEntrypoint, @tagName(options.exe_entrypoint)).?,
        .wasm_target = std.meta.stringToEnum(WasmTarget, @tagName(options.wasm_target)).?,
        .wasm_shared = options.wasm_shared,
        .i18n = options.i18n,
    };
    std.debug.assert(!result.software_renderer_cpu_effective or result.software_renderer_cpu_mvp);
    return result;
}

fn softwareRendererCpuSupported(target: std.Target) bool {
    return switch (target.os.tag) {
        .macos => target.os.isAtLeast(.macos, software_renderer_cpu_min_macos) orelse false,
        .linux => target.os.isAtLeast(.linux, software_renderer_cpu_min_linux) orelse false,
        else => false,
    };
}

fn softwareRendererCpuEffective(
    target: std.Target,
    cpu_mvp: bool,
    allow_legacy_os: bool,
) bool {
    const legacy_override_effective =
        allow_legacy_os and softwareRendererCpuLegacyOverrideSupported(target);
    return cpu_mvp and (softwareRendererCpuSupported(target) or legacy_override_effective);
}

fn softwareRendererCpuLegacyOverrideSupported(target: std.Target) bool {
    return switch (target.os.tag) {
        .macos, .linux => true,
        else => false,
    };
}

fn softwareRendererRouteBackend(target: std.Target) RendererBackend {
    return RendererBackend.softwareRouteForOsTag(target.os.tag);
}

fn effectiveSoftwareRendererCpuDamageRectCap(
    mode: SoftwareRendererCpuFrameDamageMode,
    configured_cap: u16,
) u16 {
    return switch (mode) {
        .off => configured_cap,
        .rects => @max(@as(u16, 1), configured_cap),
    };
}

fn effectiveSoftwareRendererCpuPublishWarningConsecutiveLimit(configured_limit: u8) u8 {
    return @max(@as(u8, 1), configured_limit);
}

test "softwareRendererCpuSupported requires macOS 11+" {
    const stdx = std;
    const macos_10_15 = try stdx.zig.system.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .macos,
        .os_version_min = .{ .semver = .{ .major = 10, .minor = 15, .patch = 0 } },
    });
    const macos_11 = try stdx.zig.system.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .macos,
        .os_version_min = .{ .semver = .{ .major = 11, .minor = 0, .patch = 0 } },
    });

    try stdx.testing.expect(!softwareRendererCpuSupported(macos_10_15));
    try stdx.testing.expect(softwareRendererCpuSupported(macos_11));
}

test "softwareRendererCpuSupported requires Linux 5.0+" {
    const stdx = std;
    const linux_4_19 = try stdx.zig.system.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .os_version_min = .{ .semver = .{ .major = 4, .minor = 19, .patch = 0 } },
    });
    const linux_50 = try stdx.zig.system.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .os_version_min = .{ .semver = .{ .major = 5, .minor = 0, .patch = 0 } },
    });

    try stdx.testing.expect(!softwareRendererCpuSupported(linux_4_19));
    try stdx.testing.expect(softwareRendererCpuSupported(linux_50));
}

test "softwareRendererCpuEffective keeps legacy override disabled by default" {
    const stdx = std;
    const linux_4_19 = try stdx.zig.system.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .os_version_min = .{ .semver = .{ .major = 4, .minor = 19, .patch = 0 } },
    });
    const macos_10_15 = try stdx.zig.system.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .macos,
        .os_version_min = .{ .semver = .{ .major = 10, .minor = 15, .patch = 0 } },
    });

    try stdx.testing.expect(!softwareRendererCpuEffective(linux_4_19, true, false));
    try stdx.testing.expect(!softwareRendererCpuEffective(macos_10_15, true, false));
}

test "softwareRendererCpuEffective allows unsupported Linux/macOS targets when legacy override enabled" {
    const stdx = std;
    const linux_4_19 = try stdx.zig.system.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .os_version_min = .{ .semver = .{ .major = 4, .minor = 19, .patch = 0 } },
    });
    const macos_10_15 = try stdx.zig.system.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .macos,
        .os_version_min = .{ .semver = .{ .major = 10, .minor = 15, .patch = 0 } },
    });

    try stdx.testing.expect(softwareRendererCpuEffective(linux_4_19, true, true));
    try stdx.testing.expect(softwareRendererCpuEffective(macos_10_15, true, true));
}

test "softwareRendererCpuEffective ignores legacy override on unsupported OS targets" {
    const stdx = std;
    const windows = try stdx.zig.system.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
    });
    const freebsd = try stdx.zig.system.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freebsd,
    });

    try stdx.testing.expect(!softwareRendererCpuEffective(windows, true, true));
    try stdx.testing.expect(!softwareRendererCpuEffective(freebsd, true, true));
}

test "softwareRendererRouteBackend maps by target OS tag" {
    const stdx = std;
    const linux = try stdx.zig.system.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
    });
    const freebsd = try stdx.zig.system.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freebsd,
    });
    const macos = try stdx.zig.system.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .macos,
    });
    const ios = try stdx.zig.system.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .ios,
    });

    try stdx.testing.expectEqual(RendererBackend.opengl, softwareRendererRouteBackend(linux));
    try stdx.testing.expectEqual(RendererBackend.opengl, softwareRendererRouteBackend(freebsd));
    try stdx.testing.expectEqual(RendererBackend.metal, softwareRendererRouteBackend(macos));
    try stdx.testing.expectEqual(RendererBackend.metal, softwareRendererRouteBackend(ios));
}

test "softwareRendererCpuShaderMode string mapping" {
    const stdx = std;
    try stdx.testing.expectEqual(
        SoftwareRendererCpuShaderMode.off,
        std.meta.stringToEnum(SoftwareRendererCpuShaderMode, "off").?,
    );
    try stdx.testing.expectEqual(
        SoftwareRendererCpuShaderMode.safe,
        std.meta.stringToEnum(SoftwareRendererCpuShaderMode, "safe").?,
    );
    try stdx.testing.expectEqual(
        SoftwareRendererCpuShaderMode.full,
        std.meta.stringToEnum(SoftwareRendererCpuShaderMode, "full").?,
    );
    try stdx.testing.expect(
        std.meta.stringToEnum(SoftwareRendererCpuShaderMode, "invalid") == null,
    );
}

test "softwareRendererCpuShaderBackend string mapping" {
    const stdx = std;
    try stdx.testing.expectEqual(
        SoftwareRendererCpuShaderBackend.off,
        std.meta.stringToEnum(SoftwareRendererCpuShaderBackend, "off").?,
    );
    try stdx.testing.expectEqual(
        SoftwareRendererCpuShaderBackend.vulkan_swiftshader,
        std.meta.stringToEnum(SoftwareRendererCpuShaderBackend, "vulkan_swiftshader").?,
    );
    try stdx.testing.expect(
        std.meta.stringToEnum(SoftwareRendererCpuShaderBackend, "invalid") == null,
    );
}

test "softwareRendererCpuShader default values stay stable" {
    const config: Config = .{
        .optimize = .Debug,
        .target = undefined,
        .wasm_target = .browser,
        .env = undefined,
    };
    try std.testing.expectEqual(SoftwareRendererCpuShaderMode.full, config.software_renderer_cpu_shader_mode);
    try std.testing.expectEqual(
        SoftwareRendererCpuShaderBackend.vulkan_swiftshader,
        config.software_renderer_cpu_shader_backend,
    );
    try std.testing.expectEqual(@as(u32, 16), config.software_renderer_cpu_shader_timeout_ms);
    try std.testing.expect(!config.software_renderer_cpu_shader_enable_minimal_runtime);
    try std.testing.expectEqual(
        SoftwareRendererCpuFrameDamageMode.rects,
        config.software_renderer_cpu_frame_damage_mode,
    );
    try std.testing.expectEqual(@as(u16, 64), config.software_renderer_cpu_damage_rect_cap);
    try std.testing.expectEqual(@as(u32, 40), config.software_renderer_cpu_publish_warning_threshold_ms);
    try std.testing.expectEqual(@as(u8, 3), config.software_renderer_cpu_publish_warning_consecutive_limit);
}

test "softwareRendererCpuShader help text keeps full capability-gated fallback semantics" {
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            software_renderer_cpu_shader_mode_help,
            "safe=use CPU route only when custom-shader execution capability is available and timeout budget is > 0, otherwise fallback to platform route",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            software_renderer_cpu_shader_mode_help,
            "full=use CPU route only when custom-shader execution capability is available, otherwise fallback to platform route",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            software_renderer_cpu_shader_backend_help,
            "off|vulkan_swiftshader",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            software_renderer_cpu_shader_backend_help,
            "SwiftShader Vulkan execution",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            software_renderer_cpu_shader_backend_help,
            "VK_DRIVER_FILES > VK_ICD_FILENAMES > VK_ADD_DRIVER_FILES",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            software_renderer_cpu_shader_timeout_help,
            "In safe mode, timeout must be > 0; timeout 0 forces platform-route fallback for correctness",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            software_renderer_cpu_shader_enable_minimal_runtime_help,
            "Default: false",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            software_renderer_cpu_frame_damage_mode_help,
            "off publishes full frames",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            software_renderer_cpu_damage_rect_cap_help,
            "Overflow degrades to one full-frame rect",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            software_renderer_cpu_damage_rect_cap_help,
            "0 is auto-clamped to 1",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            software_renderer_cpu_publish_warning_threshold_help,
            "Default: 40",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            software_renderer_cpu_publish_warning_consecutive_limit_help,
            "0 is auto-clamped to 1",
        ) != null,
    );
}

test "effectiveSoftwareRendererCpuDamageRectCap keeps cap in off mode" {
    try std.testing.expectEqual(
        @as(u16, 0),
        effectiveSoftwareRendererCpuDamageRectCap(.off, 0),
    );
    try std.testing.expectEqual(
        @as(u16, 8),
        effectiveSoftwareRendererCpuDamageRectCap(.off, 8),
    );
}

test "effectiveSoftwareRendererCpuDamageRectCap clamps zero in rects mode" {
    try std.testing.expectEqual(
        @as(u16, 1),
        effectiveSoftwareRendererCpuDamageRectCap(.rects, 0),
    );
    try std.testing.expectEqual(
        @as(u16, 8),
        effectiveSoftwareRendererCpuDamageRectCap(.rects, 8),
    );
}

test "effectiveSoftwareRendererCpuPublishWarningConsecutiveLimit clamps zero to one" {
    try std.testing.expectEqual(
        @as(u8, 1),
        effectiveSoftwareRendererCpuPublishWarningConsecutiveLimit(0),
    );
    try std.testing.expectEqual(
        @as(u8, 7),
        effectiveSoftwareRendererCpuPublishWarningConsecutiveLimit(7),
    );
}

test "softwareRendererCpuFrameDamageMode string mapping" {
    const stdx = std;
    try stdx.testing.expectEqual(
        SoftwareRendererCpuFrameDamageMode.off,
        std.meta.stringToEnum(SoftwareRendererCpuFrameDamageMode, "off").?,
    );
    try stdx.testing.expectEqual(
        SoftwareRendererCpuFrameDamageMode.rects,
        std.meta.stringToEnum(SoftwareRendererCpuFrameDamageMode, "rects").?,
    );
    try stdx.testing.expect(
        std.meta.stringToEnum(SoftwareRendererCpuFrameDamageMode, "invalid") == null,
    );
}

test "softwareRendererCpuMvp help text keeps support threshold wording in sync" {
    try std.testing.expect(
        std.mem.indexOf(u8, software_renderer_cpu_mvp_help, "macOS >= 11") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, software_renderer_cpu_mvp_help, "Linux >= 5.0") != null,
    );
}

/// Returns the minimum OS version for the given OS tag. This shouldn't
/// be used generally, it should only be used for Darwin-based OS currently.
pub fn osVersionMin(tag: std.Target.Os.Tag) ?std.Target.Query.OsVersion {
    return switch (tag) {
        // We support back to the earliest officially supported version
        // of macOS by Apple. EOL versions are not supported.
        .macos => .{ .semver = .{
            .major = 13,
            .minor = 0,
            .patch = 0,
        } },

        // iOS 17 picked arbitrarily
        .ios => .{ .semver = .{
            .major = 17,
            .minor = 0,
            .patch = 0,
        } },

        // This should never happen currently. If we add a new target then
        // we should add a new case here.
        else => null,
    };
}

// Returns a ResolvedTarget for a mac with a `target.result.cpu.model.name` of `generic`.
// `b.standardTargetOptions()` returns a more specific cpu like `apple_a15`.
//
// This is used to workaround compilation issues on macOS.
// (see for example https://github.com/mitchellh/ghostty/issues/1640).
pub fn genericMacOSTarget(
    b: *std.Build,
    arch: ?std.Target.Cpu.Arch,
    os_version_min: ?std.Target.Query.OsVersion,
) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{
        .cpu_arch = arch orelse builtin.target.cpu.arch,
        .os_tag = .macos,
        .os_version_min = os_version_min orelse osVersionMin(.macos),
    });
}

/// The possible entrypoints for the exe artifact. This has no effect on
/// other artifact types (i.e. lib, wasm_module).
///
/// The whole existence of this enum is to workaround the fact that Zig
/// doesn't allow the main function to be in a file in a subdirctory
/// from the "root" of the module, and I don't want to pollute our root
/// directory with a bunch of individual zig files for each entrypoint.
///
/// Therefore, main.zig uses this to switch between the different entrypoints.
pub const ExeEntrypoint = enum {
    ghostty,
    helpgen,
    mdgen_ghostty_1,
    mdgen_ghostty_5,
    webgen_config,
    webgen_actions,
    webgen_commands,
};

/// Controls how software frames are transported from the renderer.
pub const SoftwareFrameTransportMode = enum {
    /// Preserve the historical runtime-selected transport behavior.
    auto,

    /// Prefer shared CPU bytes transport when available; otherwise fallback.
    shared,

    /// Force native handle transport (backend support required), which
    /// disables the software renderer CPU route and uses platform route.
    native,
};

/// Controls CPU-route behavior when custom shaders are active.
pub const SoftwareRendererCpuShaderMode = enum {
    /// Always fallback to the platform route while custom shaders are active.
    off,

    /// Use CPU route only when custom-shader execution capability is available
    /// and timeout budget is > 0; otherwise fallback to platform route.
    safe,

    /// Keep CPU route while custom shaders are active only when
    /// custom-shader execution capability is available.
    full,
};

/// Controls the CPU-route custom-shader execution backend.
pub const SoftwareRendererCpuShaderBackend = enum {
    /// Disable CPU-route shader execution backend.
    off,

    /// Execute custom-shader passes through SwiftShader Vulkan when available.
    vulkan_swiftshader,
};

/// Controls CPU-route frame publication damage behavior.
pub const SoftwareRendererCpuFrameDamageMode = enum {
    /// Disable damage tracking and treat each publish as full-frame.
    off,

    /// Track damage rectangles with overflow-safe degradation.
    rects,
};

/// The release channel for the build.
pub const ReleaseChannel = enum {
    /// Unstable builds on every commit.
    tip,

    /// Stable tagged releases.
    stable,
};
