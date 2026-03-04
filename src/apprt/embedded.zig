//! Application runtime for the embedded version of Ghostty. The embedded
//! version is when Ghostty is embedded within a parent host application,
//! rather than owning the application lifecycle itself. This is used for
//! example for the macOS build of Ghostty so that we can use a native
//! Swift+XCode-based application.

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const apprt = @import("../apprt.zig");
const build_config = @import("../build_config.zig");
const font = @import("../font/main.zig");
const input = @import("../input.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const software_presenter = @import("software_presenter.zig");
const lib = @import("../lib/main.zig");
const CoreApp = @import("../App.zig");
const CoreInspector = @import("../inspector/main.zig").Inspector;
const CoreSurface = @import("../Surface.zig");
const configpkg = @import("../config.zig");
const Config = configpkg.Config;

const log = std.log.scoped(.embedded_window);
const software_presenter_context_callback_missing = "callback_missing";
const software_presenter_context_native_unsupported = "native_unsupported";
const software_presenter_context_runtime_fallback = "runtime_fallback";

pub const resourcesDir = internal_os.resourcesDir;

fn softwarePresenterDecisionForEmbeddedConfig(
    is_software_build: bool,
    experimental: bool,
    requested: Config.SoftwareRendererPresenter,
    platform_tag: PlatformTag,
    software_frame_cb: ?App.SoftwareFrameCallback,
    software_frame_storage_support: u32,
    runtime_fallback: bool,
) software_presenter.Decision {
    const availability = softwarePresenterAvailabilityForEmbeddedConfig(
        platform_tag,
        software_frame_cb,
        software_frame_storage_support,
    );

    return software_presenter.decide(.{
        .is_software_build = is_software_build,
        .experimental = experimental,
        .requested = requested,
        .availability = availability,
        .runtime_fallback = runtime_fallback,
    });
}

fn softwareFrameStorageSupportMask(
    storage: apprt.surface.Message.SoftwareFrameStorage,
) u32 {
    return switch (storage) {
        .shared_cpu_bytes => @intFromEnum(CAPI.RuntimeSoftwareFrameStorageSupport.shared_cpu_bytes),
        .native_texture_handle => @intFromEnum(CAPI.RuntimeSoftwareFrameStorageSupport.native_texture_handle),
    };
}

fn runtimeSoftwareFrameStorageSupported(
    support: u32,
    storage: apprt.surface.Message.SoftwareFrameStorage,
) bool {
    return support & softwareFrameStorageSupportMask(storage) != 0;
}

fn softwareFrameStorageUnsupportedContext(
    storage: apprt.surface.Message.SoftwareFrameStorage,
) []const u8 {
    return switch (storage) {
        .shared_cpu_bytes => "storage_unsupported",
        .native_texture_handle => software_presenter_context_native_unsupported,
    };
}

const EmbeddedSoftwareRendererCpuFlags = struct {
    mvp: bool,
    effective: bool,
};

fn embeddedSoftwareRendererCpuFlagsFromBuildConfig() EmbeddedSoftwareRendererCpuFlags {
    return .{
        .mvp = build_config.software_renderer_cpu_mvp,
        .effective = comptime if (@hasDecl(build_config, "software_renderer_cpu_effective"))
            build_config.software_renderer_cpu_effective
        else
            build_config.software_renderer_cpu_mvp,
    };
}

fn softwarePresenterRequiredStorageForEmbeddedConfigWithCpuFlags(
    platform_tag: PlatformTag,
    cpu_flags: EmbeddedSoftwareRendererCpuFlags,
    transport_mode: build_config.SoftwareFrameTransportMode,
) apprt.surface.Message.SoftwareFrameStorage {
    assert(!cpu_flags.effective or cpu_flags.mvp);
    if (transport_mode == .native) {
        return .native_texture_handle;
    }
    if (cpu_flags.effective) {
        return .shared_cpu_bytes;
    }

    const os_tag: std.Target.Os.Tag = switch (platform_tag) {
        .macos => .macos,
        .ios => .ios,
    };
    return switch (renderer.Backend.softwareRouteForOsTag(os_tag)) {
        .metal => .native_texture_handle,
        else => .shared_cpu_bytes,
    };
}

fn softwarePresenterRequiredStorageForEmbeddedConfig(
    platform_tag: PlatformTag,
) apprt.surface.Message.SoftwareFrameStorage {
    return softwarePresenterRequiredStorageForEmbeddedConfigWithCpuFlags(
        platform_tag,
        embeddedSoftwareRendererCpuFlagsFromBuildConfig(),
        build_config.software_frame_transport_mode,
    );
}

fn softwarePresenterAvailabilityForEmbeddedConfig(
    platform_tag: PlatformTag,
    software_frame_cb: ?App.SoftwareFrameCallback,
    software_frame_storage_support: u32,
) software_presenter.Availability {
    if (software_frame_cb == null) return .runtime_capability_missing;
    if (!softwarePresenterStorageSupportedForEmbeddedConfig(
        platform_tag,
        software_frame_storage_support,
    )) {
        return .runtime_capability_missing;
    }

    return .available;
}

fn softwarePresenterCapabilityMissingContextForEmbeddedConfig(
    platform_tag: PlatformTag,
    software_frame_cb: ?App.SoftwareFrameCallback,
    software_frame_storage_support: u32,
) []const u8 {
    if (software_frame_cb == null) return software_presenter_context_callback_missing;

    const required_storage = softwarePresenterRequiredStorageForEmbeddedConfig(platform_tag);
    if (!runtimeSoftwareFrameStorageSupported(
        software_frame_storage_support,
        required_storage,
    )) {
        return softwareFrameStorageUnsupportedContext(required_storage);
    }

    return "runtime_capability_missing";
}

fn softwarePresenterUnavailableContextForEmbeddedConfig(
    reason: software_presenter.Reason,
    platform_tag: PlatformTag,
    software_frame_cb: ?App.SoftwareFrameCallback,
    software_frame_storage_support: u32,
) []const u8 {
    return switch (reason) {
        .runtime_too_old => "runtime_too_old",
        .runtime_capability_missing => softwarePresenterCapabilityMissingContextForEmbeddedConfig(
            platform_tag,
            software_frame_cb,
            software_frame_storage_support,
        ),
        .platform_route_unavailable => "platform_route_unavailable",
        else => "unavailable",
    };
}

fn softwarePresenterStorageSupportedForEmbeddedConfig(
    platform_tag: PlatformTag,
    software_frame_storage_support: u32,
) bool {
    return softwarePresenterStorageSupportedForEmbeddedConfigWithCpuFlags(
        platform_tag,
        software_frame_storage_support,
        embeddedSoftwareRendererCpuFlagsFromBuildConfig(),
        build_config.software_frame_transport_mode,
    );
}

fn softwarePresenterStorageSupportedForEmbeddedConfigWithCpuFlags(
    platform_tag: PlatformTag,
    software_frame_storage_support: u32,
    cpu_flags: EmbeddedSoftwareRendererCpuFlags,
    transport_mode: build_config.SoftwareFrameTransportMode,
) bool {
    const required_storage = softwarePresenterRequiredStorageForEmbeddedConfigWithCpuFlags(
        platform_tag,
        cpu_flags,
        transport_mode,
    );
    if (!runtimeSoftwareFrameStorageSupported(
        software_frame_storage_support,
        required_storage,
    )) {
        return false;
    }

    return true;
}

fn shouldResetSoftwareSnapshotRuntimeFallback(
    runtime_fallback: bool,
    experimental: bool,
    requested: Config.SoftwareRendererPresenter,
) bool {
    if (!runtime_fallback) return false;
    return !experimental or requested == .@"legacy-gl";
}

pub const App = struct {
    pub const runtime_config_version: u32 = 2;

    const AppUD = ?*anyopaque;
    const SurfaceUD = ?*anyopaque;
    const SoftwareFrameStorageSupport = u32;
    const SoftwareFrameCallback =
        *const fn (SurfaceUD, *const CAPI.RuntimeSoftwareFrame) callconv(.c) bool;
    const WakeupCallback = *const fn (AppUD) callconv(.c) void;
    const ActionCallback = *const fn (*App, apprt.Target.C, apprt.Action.C) callconv(.c) bool;
    const ReadClipboardCallback =
        *const fn (SurfaceUD, c_int, *apprt.ClipboardRequest) callconv(.c) void;
    const ConfirmReadClipboardCallback = *const fn (
        SurfaceUD,
        [*:0]const u8,
        *apprt.ClipboardRequest,
        apprt.ClipboardRequestType,
    ) callconv(.c) void;
    const WriteClipboardCallback = *const fn (
        SurfaceUD,
        c_int,
        [*]const CAPI.ClipboardContent,
        usize,
        bool,
    ) callconv(.c) void;
    const CloseSurfaceCallback = *const fn (SurfaceUD, bool) callconv(.c) void;

    /// C type: ghostty_runtime_config_s
    pub const Options = extern struct {
        struct_size: u32 = @sizeOf(Options),
        struct_version: u32 = runtime_config_version,

        /// Userdata that is passed to all the callbacks.
        userdata: AppUD = null,

        /// True if the selection clipboard is supported.
        supports_selection_clipboard: bool = false,

        /// Callback called to wakeup the event loop. This should trigger
        /// a full tick of the app loop.
        wakeup: ?WakeupCallback = null,

        /// Callback called to handle an action.
        action: ?ActionCallback = null,

        /// Read the clipboard value. The return value must be preserved
        /// by the host until the next call. If there is no valid clipboard
        /// value then this should return null.
        read_clipboard: ?ReadClipboardCallback = null,

        /// This may be called after a read clipboard call to request
        /// confirmation that the clipboard value is safe to read. The embedder
        /// must call complete_clipboard_request with the given request.
        confirm_read_clipboard: ?ConfirmReadClipboardCallback = null,

        /// Write the clipboard value.
        write_clipboard: ?WriteClipboardCallback = null,

        /// Software frame storage support bitmask and callback bridge.
        software_frame_storage_support: SoftwareFrameStorageSupport = 0,
        software_frame_cb: ?SoftwareFrameCallback = null,

        /// Close the current surface given by this function.
        close_surface: ?CloseSurfaceCallback = null,
    };

    pub const runtime_config_min_size: u32 = @offsetOf(
        Options,
        "software_frame_storage_support",
    );

    const ResolvedOptions = struct {
        userdata: AppUD = null,
        supports_selection_clipboard: bool = false,
        wakeup: WakeupCallback,
        action: ActionCallback,
        read_clipboard: ReadClipboardCallback,
        confirm_read_clipboard: ConfirmReadClipboardCallback,
        write_clipboard: WriteClipboardCallback,
        software_frame_storage_support: SoftwareFrameStorageSupport = 0,
        software_frame_cb: ?SoftwareFrameCallback = null,
        close_surface: ?CloseSurfaceCallback = null,
    };

    /// This is the key event sent for ghostty_surface_key and
    /// ghostty_app_key.
    pub const KeyEvent = struct {
        action: input.Action,
        mods: input.Mods,
        consumed_mods: input.Mods,
        keycode: u32,
        text: ?[:0]const u8,
        unshifted_codepoint: u32,
        composing: bool,

        /// Convert a libghostty key event into a core key event.
        fn core(self: KeyEvent) ?input.KeyEvent {
            const text: []const u8 = if (self.text) |v| v else "";
            const unshifted_codepoint: u21 = std.math.cast(
                u21,
                self.unshifted_codepoint,
            ) orelse 0;

            // We want to get the physical unmapped key to process keybinds.
            const physical_key = keycode: for (input.keycodes.entries) |entry| {
                if (entry.native == self.keycode) break :keycode entry.key;
            } else .unidentified;

            // Build our final key event
            return .{
                .action = self.action,
                .key = physical_key,
                .mods = self.mods,
                .consumed_mods = self.consumed_mods,
                .composing = self.composing,
                .utf8 = text,
                .unshifted_codepoint = unshifted_codepoint,
            };
        }
    };

    core_app: *CoreApp,
    opts: ResolvedOptions,
    keymap: input.Keymap,

    /// The configuration for the app. This is owned by this structure.
    config: Config,

    pub fn init(
        self: *App,
        core_app: *CoreApp,
        config: *const Config,
        opts: ResolvedOptions,
    ) !void {
        // We have to clone the config.
        const alloc = core_app.alloc;
        var config_clone = try config.clone(alloc);
        errdefer config_clone.deinit();

        var keymap = try input.Keymap.init();
        errdefer keymap.deinit();

        self.* = .{
            .core_app = core_app,
            .config = config_clone,
            .opts = opts,
            .keymap = keymap,
        };
    }

    pub fn terminate(self: *App) void {
        self.keymap.deinit();
        self.config.deinit();
    }

    /// Returns true if there are any global keybinds in the configuration.
    pub fn hasGlobalKeybinds(self: *const App) bool {
        var it = self.config.keybind.set.bindings.iterator();
        while (it.next()) |entry| {
            switch (entry.value_ptr.*) {
                .leader => {},
                inline .leaf, .leaf_chained => |leaf| if (leaf.flags.global) return true,
            }
        }

        return false;
    }

    /// The target of a key event. This is used to determine some subtly
    /// different behavior between app and surface key events.
    pub const KeyTarget = union(enum) {
        app,
        surface: *Surface,
    };

    /// See CoreApp.focusEvent
    pub fn focusEvent(self: *App, focused: bool) void {
        self.core_app.focusEvent(focused);
    }

    /// See CoreApp.keyEvent.
    pub fn keyEvent(
        self: *App,
        target: KeyTarget,
        event: KeyEvent,
    ) !bool {
        // Convert our C key event into a Zig one.
        const input_event: input.KeyEvent = event.core() orelse
            return false;

        // Invoke the core Ghostty logic to handle this input.
        const effect: CoreSurface.InputEffect = switch (target) {
            .app => if (self.core_app.keyEvent(
                self,
                input_event,
            )) .consumed else .ignored,

            .surface => |surface| try surface.core_surface.keyCallback(
                input_event,
            ),
        };

        return switch (effect) {
            .closed => true,
            .ignored => false,
            .consumed => true,
        };
    }

    /// This should be called whenever the keyboard layout was changed.
    pub fn reloadKeymap(self: *App) !void {
        // Reload the keymap
        try self.keymap.reload();
    }

    /// Loads the keyboard layout.
    ///
    /// Kind of expensive so this should be avoided if possible. When I say
    /// "kind of expensive" I mean that its not something you probably want
    /// to run on every keypress.
    pub fn keyboardLayout(self: *const App) input.KeyboardLayout {
        // We only support keyboard layout detection on macOS.
        if (comptime builtin.os.tag != .macos) return .unknown;

        // Any layout larger than this is not something we can handle.
        var buf: [256]u8 = undefined;
        const id = self.keymap.sourceId(&buf) catch |err| {
            comptime assert(@TypeOf(err) == error{OutOfMemory});
            return .unknown;
        };

        return input.KeyboardLayout.mapAppleId(id) orelse .unknown;
    }

    pub fn wakeup(self: *const App) void {
        self.opts.wakeup(self.opts.userdata);
    }

    pub fn wait(self: *const App) !void {
        _ = self;
    }

    /// Create a new surface for the app.
    fn newSurface(self: *App, opts: Surface.Options) !*Surface {
        // Grab a surface allocation because we're going to need it.
        var surface = try self.core_app.alloc.create(Surface);
        errdefer self.core_app.alloc.destroy(surface);

        // Create the surface
        try surface.init(self, opts);
        errdefer surface.deinit();

        return surface;
    }

    /// Close the given surface.
    pub fn closeSurface(self: *App, surface: *Surface) void {
        surface.deinit();
        self.core_app.alloc.destroy(surface);
    }

    pub fn redrawInspector(self: *App, surface: *Surface) void {
        _ = self;
        surface.queueInspectorRender();
    }

    /// Perform a given action. Returns `true` if the action was able to be
    /// performed, `false` otherwise.
    pub fn performAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        // Special case certain actions before they are sent to the
        // embedded apprt.
        self.performPreAction(target, action, value);

        log.debug("dispatching action target={t} action={} value={any}", .{
            target,
            action,
            value,
        });
        return self.opts.action(
            self,
            target.cval(),
            @unionInit(apprt.Action, @tagName(action), value).cval(),
        );
    }

    fn performPreAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) void {
        // Special case certain actions before they are sent to the embedder
        switch (action) {
            .set_title => switch (target) {
                .app => {},
                .surface => |surface| {
                    // Dupe the title so that we can store it. If we get an allocation
                    // error we just ignore it, since this only breaks a few minor things.
                    const alloc = self.core_app.alloc;
                    if (surface.rt_surface.title) |v| alloc.free(v);
                    surface.rt_surface.title = alloc.dupeZ(u8, value.title) catch null;
                },
            },

            .config_change => switch (target) {
                .surface => {},

                // For app updates, we update our core config. We need to
                // clone it because the caller owns the param.
                .app => if (value.config.clone(self.core_app.alloc)) |config| {
                    self.config.deinit();
                    self.config = config;
                } else |err| {
                    log.err("error updating app config err={}", .{err});
                },
            },

            else => {},
        }
    }

    /// Send the given IPC to a running Ghostty. Returns `true` if the action was
    /// able to be performed, `false` otherwise.
    ///
    /// Note that this is a static function. Since this is called from a CLI app (or
    /// some other process that is not Ghostty) there is no full-featured apprt App
    /// to use.
    pub fn performIpc(
        _: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        _: apprt.ipc.Action.Value(action),
    ) (Allocator.Error || std.posix.WriteError || apprt.ipc.Errors)!bool {
        switch (action) {
            .new_window => return false,
        }
    }
};

/// Platform-specific configuration for libghostty.
pub const Platform = union(PlatformTag) {
    macos: MacOS,
    ios: IOS,

    // If our build target for libghostty is not darwin then we do
    // not include macos support at all.
    pub const MacOS = if (builtin.target.os.tag.isDarwin()) struct {
        /// The view to render the surface on.
        nsview: objc.Object,
    } else void;

    pub const IOS = if (builtin.target.os.tag.isDarwin()) struct {
        /// The view to render the surface on.
        uiview: objc.Object,
    } else void;

    // The C ABI compatible version of this union. The tag is expected
    // to be stored elsewhere.
    pub const C = extern union {
        macos: extern struct {
            nsview: ?*anyopaque,
        },

        ios: extern struct {
            uiview: ?*anyopaque,
        },
    };

    /// Initialize a Platform a tag and configuration from the C ABI.
    pub fn init(tag_int: c_int, c_platform: C) !Platform {
        const tag = try std.meta.intToEnum(PlatformTag, tag_int);
        return switch (tag) {
            .macos => if (MacOS != void) macos: {
                const config = c_platform.macos;
                const nsview = objc.Object.fromId(config.nsview orelse
                    break :macos error.NSViewMustBeSet);
                break :macos .{ .macos = .{ .nsview = nsview } };
            } else error.UnsupportedPlatform,

            .ios => if (IOS != void) ios: {
                const config = c_platform.ios;
                const uiview = objc.Object.fromId(config.uiview orelse
                    break :ios error.UIViewMustBeSet);
                break :ios .{ .ios = .{ .uiview = uiview } };
            } else error.UnsupportedPlatform,
        };
    }
};

pub const PlatformTag = enum(c_int) {
    // "0" is reserved for invalid so we can detect unset values
    // from the C API.

    macos = 1,
    ios = 2,
};

pub const EnvVar = extern struct {
    /// The name of the environment variable.
    key: [*:0]const u8,

    /// The value of the environment variable.
    value: [*:0]const u8,
};

pub const Surface = struct {
    app: *App,
    platform: Platform,
    userdata: ?*anyopaque = null,
    core_surface: CoreSurface,
    content_scale: apprt.ContentScale,
    size: apprt.SurfaceSize,
    cursor_pos: apprt.CursorPos,
    inspector: ?*Inspector = null,

    /// The current title of the surface. The embedded apprt saves this so
    /// that getTitle works without the implementer needing to save it.
    title: ?[:0]const u8 = null,

    /// Runtime presenter decision tracking for software renderer compatibility.
    software_presenter_experimental: bool = false,
    software_presenter_requested: Config.SoftwareRendererPresenter = .auto,
    software_presenter_selected: Config.SoftwareRendererPresenter = .@"legacy-gl",
    software_presenter_reason: software_presenter.Reason = .not_software_build,
    software_snapshot_runtime_fallback: bool = false,
    software_frame_publishing_enabled: bool = false,
    software_frame_publishing_initialized: bool = false,
    software_frame_unavailable_logged: bool = false,

    /// Surface initialization options.
    pub const Options = extern struct {
        /// The platform that this surface is being initialized for and
        /// the associated platform-specific configuration.
        platform_tag: c_int = 0,
        platform: Platform.C = undefined,

        /// Userdata passed to some of the callbacks.
        userdata: ?*anyopaque = null,

        /// The scale factor of the screen.
        scale_factor: f64 = 1,

        /// The font size to inherit. If 0, default font size will be used.
        font_size: f32 = 0,

        /// The working directory to load into.
        working_directory: ?[*:0]const u8 = null,

        /// The command to run in the new surface. If this is set then
        /// the "wait-after-command" option is also automatically set to true,
        /// since this is used for scripting.
        ///
        /// This command always run in a shell (e.g. via `/bin/sh -c`),
        /// despite Ghostty allowing directly executed commands via config.
        /// This is a legacy thing and we should probably change it in the
        /// future once we have a concrete use case.
        command: ?[*:0]const u8 = null,

        /// Extra environment variables to set for the surface.
        env_vars: ?[*]EnvVar = null,
        env_var_count: usize = 0,

        /// Input to send to the command after it is started.
        initial_input: ?[*:0]const u8 = null,

        /// Wait after the command exits
        wait_after_command: bool = false,

        /// Context for the new surface
        context: apprt.surface.NewSurfaceContext = .window,
    };

    pub fn init(self: *Surface, app: *App, opts: Options) !void {
        self.* = .{
            .app = app,
            .platform = try .init(opts.platform_tag, opts.platform),
            .userdata = opts.userdata,
            .core_surface = undefined,
            .content_scale = .{
                .x = @floatCast(opts.scale_factor),
                .y = @floatCast(opts.scale_factor),
            },
            .size = .{ .width = 800, .height = 600 },
            .cursor_pos = .{ .x = -1, .y = -1 },
        };

        // Add ourselves to the list of surfaces on the app.
        try app.core_app.addSurface(self);
        errdefer app.core_app.deleteSurface(self);

        // Shallow copy the config so that we can modify it.
        var config = try apprt.surface.newConfig(app.core_app, &app.config, opts.context);
        defer config.deinit();

        // If we have a working directory from the options then we set it.
        if (opts.working_directory) |c_wd| {
            const wd = std.mem.sliceTo(c_wd, 0);
            if (wd.len > 0) wd: {
                var dir = std.fs.openDirAbsolute(wd, .{}) catch |err| {
                    log.warn(
                        "error opening requested working directory dir={s} err={}",
                        .{ wd, err },
                    );
                    break :wd;
                };
                defer dir.close();

                const stat = dir.stat() catch |err| {
                    log.warn(
                        "failed to stat requested working directory dir={s} err={}",
                        .{ wd, err },
                    );
                    break :wd;
                };

                if (stat.kind != .directory) {
                    log.warn(
                        "requested working directory is not a directory dir={s}",
                        .{wd},
                    );
                    break :wd;
                }

                config.@"working-directory" = wd;
            }
        }

        // If we have a command from the options then we set it.
        if (opts.command) |c_command| {
            const cmd = std.mem.sliceTo(c_command, 0);
            if (cmd.len > 0) {
                config.command = .{ .shell = cmd };
                config.@"wait-after-command" = true;
            }
        }

        // Apply any environment variables that were requested.
        if (opts.env_var_count > 0) {
            const alloc = config.arenaAlloc();
            for (opts.env_vars.?[0..opts.env_var_count]) |env_var| {
                const key = std.mem.sliceTo(env_var.key, 0);
                const value = std.mem.sliceTo(env_var.value, 0);
                try config.env.map.put(
                    alloc,
                    try alloc.dupeZ(u8, key),
                    try alloc.dupeZ(u8, value),
                );
            }
        }

        // If we have an initial input then we set it.
        if (opts.initial_input) |c_input| {
            const alloc = config.arenaAlloc();

            // We need to escape the string because the "raw" field
            // expects a Zig string.
            var buf: std.Io.Writer.Allocating = .init(alloc);
            defer buf.deinit();
            try std.zig.stringEscape(
                std.mem.sliceTo(c_input, 0),
                &buf.writer,
            );

            config.input.list.clearRetainingCapacity();
            try config.input.list.append(
                alloc,
                .{ .raw = try buf.toOwnedSliceSentinel(0) },
            );
        }

        // Wait after command
        if (opts.wait_after_command) {
            config.@"wait-after-command" = true;
        }

        // Initialize our surface right away. We're given a view that is
        // ready to use.
        try self.core_surface.init(
            app.core_app.alloc,
            &config,
            app.core_app,
            app,
            self,
        );
        errdefer self.core_surface.deinit();

        // If our options requested a specific font-size, set that.
        if (opts.font_size != 0) {
            var font_size = self.core_surface.font_size;
            font_size.points = opts.font_size;
            try self.core_surface.setFontSize(font_size);
        }

        self.refreshSoftwarePresenterSupport(&config);
    }

    fn refreshSoftwarePresenterSupport(self: *Surface, config: *const Config) void {
        self.refreshSoftwarePresenterSupportValues(
            config.@"software-renderer-experimental",
            config.@"software-renderer-presenter",
        );
    }

    fn refreshSoftwarePresenterSupportValues(
        self: *Surface,
        experimental: bool,
        requested: Config.SoftwareRendererPresenter,
    ) void {
        if (comptime build_config.renderer != .software) return;

        const platform_tag: PlatformTag = switch (self.platform) {
            .macos => .macos,
            .ios => .ios,
        };

        if (shouldResetSoftwareSnapshotRuntimeFallback(
            self.software_snapshot_runtime_fallback,
            experimental,
            requested,
        )) {
            self.software_snapshot_runtime_fallback = false;
        }

        const decision = softwarePresenterDecisionForEmbeddedConfig(
            true,
            experimental,
            requested,
            platform_tag,
            self.app.opts.software_frame_cb,
            self.app.opts.software_frame_storage_support,
            self.software_snapshot_runtime_fallback,
        );

        const changed =
            self.software_presenter_experimental != experimental or
            self.software_presenter_requested != decision.requested or
            self.software_presenter_selected != decision.selected or
            self.software_presenter_reason != decision.reason;
        const publish_changed =
            !self.software_frame_publishing_initialized or
            self.software_frame_publishing_enabled != decision.can_publish_software_frame;

        self.software_presenter_experimental = experimental;
        self.software_presenter_requested = decision.requested;
        self.software_presenter_selected = decision.selected;
        self.software_presenter_reason = decision.reason;
        self.software_frame_publishing_enabled = decision.can_publish_software_frame;
        if (publish_changed) {
            self.software_frame_publishing_initialized = true;
            self.core_surface.setSoftwareFramePublishingEnabled(decision.can_publish_software_frame);
        }

        if (!changed and !publish_changed) return;

        log.info(
            "software presenter runtime=embedded experimental={} requested={s} selected={s} reason={s} runtime_fallback={} can_publish={}",
            .{
                decision.experimental,
                @tagName(decision.requested),
                @tagName(decision.selected),
                @tagName(decision.reason),
                self.software_snapshot_runtime_fallback,
                decision.can_publish_software_frame,
            },
        );

        switch (decision.reason) {
            .runtime_too_old, .runtime_capability_missing, .platform_route_unavailable => {
                if (decision.requested == .snapshot) {
                    const context = softwarePresenterUnavailableContextForEmbeddedConfig(
                        decision.reason,
                        platform_tag,
                        self.app.opts.software_frame_cb,
                        self.app.opts.software_frame_storage_support,
                    );
                    log.warn(
                        "requested presenter=snapshot unavailable reason={s} context={s}; forcing legacy-gl compatibility path",
                        .{
                            @tagName(decision.reason),
                            context,
                        },
                    );
                }
            },
            else => {},
        }
    }

    fn disableSoftwareFramePublishingUnavailable(
        self: *Surface,
        context: []const u8,
    ) void {
        if (self.software_frame_publishing_enabled) {
            self.software_frame_publishing_enabled = false;
            self.software_frame_publishing_initialized = true;
            self.core_surface.setSoftwareFramePublishingEnabled(false);
        }

        if (self.software_frame_unavailable_logged) return;
        self.software_frame_unavailable_logged = true;
        log.warn(
            "embedded runtime software frame capability unavailable reason=runtime_capability_missing context={s}; disabled software frame publishing for this surface",
            .{context},
        );
    }

    fn activateSoftwareFrameSessionFallback(
        self: *Surface,
        context: []const u8,
    ) void {
        if (comptime build_config.renderer != .software) return;
        if (self.software_snapshot_runtime_fallback) return;

        self.software_snapshot_runtime_fallback = true;
        log.warn(
            "embedded runtime software presenter fallback reason={s} context={s}; forcing legacy-gl for this session",
            .{
                software_presenter_context_runtime_fallback,
                context,
            },
        );
        self.refreshSoftwarePresenterSupportValues(
            self.software_presenter_experimental,
            self.software_presenter_requested,
        );
    }

    pub fn deinit(self: *Surface) void {
        // Shut down our inspector
        self.freeInspector();

        // Free our title
        if (self.title) |v| self.app.core_app.alloc.free(v);

        // Remove ourselves from the list of known surfaces in the app.
        self.app.core_app.deleteSurface(self);

        // Clean up our core surface so that all the rendering and IO stop.
        self.core_surface.deinit();
    }

    /// Initialize the inspector instance. A surface can only have one
    /// inspector at any given time, so this will return the previous inspector
    /// if it was already initialized.
    pub fn initInspector(self: *Surface) !*Inspector {
        if (self.inspector) |v| return v;

        const alloc = self.app.core_app.alloc;
        const inspector = try alloc.create(Inspector);
        errdefer alloc.destroy(inspector);
        inspector.* = try .init(self);
        self.inspector = inspector;
        return inspector;
    }

    pub fn freeInspector(self: *Surface) void {
        if (self.inspector) |v| {
            v.deinit();
            self.app.core_app.alloc.destroy(v);
            self.inspector = null;
        }
    }

    pub fn core(self: *Surface) *CoreSurface {
        return &self.core_surface;
    }

    pub fn rtApp(self: *const Surface) *App {
        return self.app;
    }

    pub fn close(self: *const Surface, process_alive: bool) void {
        const func = self.app.opts.close_surface orelse {
            log.info("runtime embedder does not support closing a surface", .{});
            return;
        };

        func(self.userdata, process_alive);
    }

    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        return self.content_scale;
    }

    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        return self.size;
    }

    pub fn getTitle(self: *Surface) ?[:0]const u8 {
        return self.title;
    }

    pub fn supportsClipboard(
        self: *const Surface,
        clipboard_type: apprt.Clipboard,
    ) bool {
        return switch (clipboard_type) {
            .standard => true,
            .selection, .primary => self.app.opts.supports_selection_clipboard,
        };
    }

    pub fn clipboardRequest(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) !bool {
        // We need to allocate to get a pointer to store our clipboard request
        // so that it is stable until the read_clipboard callback and call
        // complete_clipboard_request. This sucks but clipboard requests aren't
        // high throughput so it's probably fine.
        const alloc = self.app.core_app.alloc;
        const state_ptr = try alloc.create(apprt.ClipboardRequest);
        errdefer alloc.destroy(state_ptr);
        state_ptr.* = state;

        self.app.opts.read_clipboard(
            self.userdata,
            @intCast(@intFromEnum(clipboard_type)),
            state_ptr,
        );

        // Embedded apprt can't synchronously check clipboard content types,
        // so we always return true to indicate the request was started.
        return true;
    }

    fn completeClipboardRequest(
        self: *Surface,
        str: [:0]const u8,
        state: *apprt.ClipboardRequest,
        confirmed: bool,
    ) void {
        const alloc = self.app.core_app.alloc;

        // Attempt to complete the request, but we may request
        // confirmation.
        self.core_surface.completeClipboardRequest(
            state.*,
            str,
            confirmed,
        ) catch |err| switch (err) {
            error.UnsafePaste,
            error.UnauthorizedPaste,
            => {
                self.app.opts.confirm_read_clipboard(
                    self.userdata,
                    str.ptr,
                    state,
                    state.*,
                );

                return;
            },

            else => log.err("error completing clipboard request err={}", .{err}),
        };

        // We don't defer this because the clipboard confirmation route
        // preserves the clipboard request.
        alloc.destroy(state);
    }

    pub fn setClipboard(
        self: *const Surface,
        clipboard_type: apprt.Clipboard,
        contents: []const apprt.ClipboardContent,
        confirm: bool,
    ) !void {
        const alloc = self.app.core_app.alloc;
        const array = try alloc.alloc(CAPI.ClipboardContent, contents.len);
        defer alloc.free(array);
        for (contents, 0..) |content, i| {
            array[i] = .{
                .mime = content.mime,
                .data = content.data,
            };
        }

        self.app.opts.write_clipboard(
            self.userdata,
            @intCast(@intFromEnum(clipboard_type)),
            array.ptr,
            array.len,
            confirm,
        );
    }

    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        return self.cursor_pos;
    }

    pub fn refresh(self: *Surface) void {
        self.core_surface.refreshCallback() catch |err| {
            log.err("error in refresh callback err={}", .{err});
            return;
        };
    }

    pub fn draw(self: *Surface) void {
        self.core_surface.draw() catch |err| {
            log.err("error in draw err={}", .{err});
            return;
        };
    }

    fn validateSoftwareFramePayload(
        frame: apprt.surface.Message.SoftwareFrameReady,
    ) error{InvalidSoftwareFrame}!void {
        switch (frame.storage) {
            .shared_cpu_bytes => {
                if (frame.data == null or frame.data_len == 0) {
                    return error.InvalidSoftwareFrame;
                }
            },
            .native_texture_handle => {
                if (frame.handle == null) return error.InvalidSoftwareFrame;
            },
        }

        if (frame.damage_rects_len > 0 and frame.damage_rects == null) {
            return error.InvalidSoftwareFrame;
        }
    }

    fn runtimeSoftwareFrameFromMessage(
        frame: apprt.surface.Message.SoftwareFrameReady,
    ) CAPI.RuntimeSoftwareFrame {
        return .{
            .width_px = frame.width_px,
            .height_px = frame.height_px,
            .stride_bytes = frame.stride_bytes,
            .generation = frame.generation,
            .pixel_format = frame.pixel_format,
            .storage = frame.storage,
            .data = frame.data,
            .data_len = frame.data_len,
            .handle = frame.handle,
            .damage_rects = frame.damage_rects,
            .damage_rects_len = frame.damage_rects_len,
        };
    }

    pub fn softwareFrameReady(
        self: *Surface,
        frame: apprt.surface.Message.SoftwareFrameReady,
    ) error{InvalidSoftwareFrame}!void {
        try validateSoftwareFramePayload(frame);

        if (!self.software_frame_publishing_enabled) return;

        const software_frame_cb = self.app.opts.software_frame_cb orelse {
            self.disableSoftwareFramePublishingUnavailable(software_presenter_context_callback_missing);
            return;
        };

        if (!runtimeSoftwareFrameStorageSupported(
            self.app.opts.software_frame_storage_support,
            frame.storage,
        )) {
            self.activateSoftwareFrameSessionFallback(
                softwareFrameStorageUnsupportedContext(frame.storage),
            );
            return error.InvalidSoftwareFrame;
        }

        const c_frame = runtimeSoftwareFrameFromMessage(frame);
        if (!software_frame_cb(self.userdata, &c_frame)) {
            self.activateSoftwareFrameSessionFallback("callback_returned_false");
        }
    }

    pub fn updateContentScale(self: *Surface, x: f64, y: f64) void {
        // We are an embedded API so the caller can send us all sorts of
        // garbage. We want to make sure that the float values are valid
        // and we don't want to support fractional scaling below 1.
        const x_scaled = @max(1, if (std.math.isNan(x)) 1 else x);
        const y_scaled = @max(1, if (std.math.isNan(y)) 1 else y);

        self.content_scale = .{
            .x = @floatCast(x_scaled),
            .y = @floatCast(y_scaled),
        };

        self.core_surface.contentScaleCallback(self.content_scale) catch |err| {
            log.err("error in content scale callback err={}", .{err});
            return;
        };
    }

    pub fn updateSize(self: *Surface, width: u32, height: u32) void {
        // Runtimes sometimes generate superfluous resize events even
        // if the size did not actually change (SwiftUI). We check
        // that the size actually changed from what we last recorded
        // since resizes are expensive.
        if (self.size.width == width and self.size.height == height) return;

        self.size = .{
            .width = width,
            .height = height,
        };

        // Call the primary callback.
        self.core_surface.sizeCallback(self.size) catch |err| {
            log.err("error in size callback err={}", .{err});
            return;
        };
    }

    pub fn colorSchemeCallback(self: *Surface, scheme: apprt.ColorScheme) void {
        self.core_surface.colorSchemeCallback(scheme) catch |err| {
            log.err("error setting color scheme err={}", .{err});
            return;
        };
    }

    pub fn mouseButtonCallback(
        self: *Surface,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: input.Mods,
    ) bool {
        return self.core_surface.mouseButtonCallback(action, button, mods) catch |err| {
            log.err("error in mouse button callback err={}", .{err});
            return false;
        };
    }

    pub fn mousePressureCallback(
        self: *Surface,
        stage: input.MousePressureStage,
        pressure: f64,
    ) void {
        self.core_surface.mousePressureCallback(stage, pressure) catch |err| {
            log.err("error in mouse pressure callback err={}", .{err});
            return;
        };
    }

    pub fn scrollCallback(
        self: *Surface,
        xoff: f64,
        yoff: f64,
        mods: input.ScrollMods,
    ) void {
        self.core_surface.scrollCallback(xoff, yoff, mods) catch |err| {
            log.err("error in scroll callback err={}", .{err});
            return;
        };
    }

    pub fn cursorPosCallback(
        self: *Surface,
        x: f64,
        y: f64,
        mods: input.Mods,
    ) void {
        // Convert our unscaled x/y to scaled.
        const pos = self.cursorPosToPixels(.{
            .x = @floatCast(x),
            .y = @floatCast(y),
        }) catch |err| {
            log.err(
                "error converting cursor pos to scaled pixels in cursor pos callback err={}",
                .{err},
            );
            return;
        };

        // There are cases where the platform reports a mouse motion event
        // without the cursor actually moving. For example, on macOS, updating
        // the window title can trigger a phantom mouse-move event at the same
        // coordinates. This can cause the mouse to incorrectly unhide when
        // mouse-hide-while-typing is enabled (commonly seen with TUI apps
        // like Zellij that frequently update the title). To prevent incorrect
        // behavior, we only continue with callback logic if the cursor has
        // actually moved.
        if (@abs(self.cursor_pos.x - pos.x) < 1 and
            @abs(self.cursor_pos.y - pos.y) < 1) return;

        self.cursor_pos = pos;

        self.core_surface.cursorPosCallback(self.cursor_pos, mods) catch |err| {
            log.err("error in cursor pos callback err={}", .{err});
            return;
        };
    }

    pub fn preeditCallback(self: *Surface, preedit_: ?[]const u8) void {
        _ = self.core_surface.preeditCallback(preedit_) catch |err| {
            log.err("error in preedit callback err={}", .{err});
            return;
        };
    }

    pub fn textCallback(self: *Surface, text: []const u8) void {
        _ = self.core_surface.textCallback(text) catch |err| {
            log.err("error in key callback err={}", .{err});
            return;
        };
    }

    pub fn focusCallback(self: *Surface, focused: bool) void {
        self.core_surface.focusCallback(focused) catch |err| {
            log.err("error in focus callback err={}", .{err});
            return;
        };
    }

    pub fn occlusionCallback(self: *Surface, visible: bool) void {
        self.core_surface.occlusionCallback(visible) catch |err| {
            log.err("error in occlusion callback err={}", .{err});
            return;
        };
    }

    fn queueInspectorRender(self: *Surface) void {
        _ = self.app.performAction(
            .{ .surface = &self.core_surface },
            .render_inspector,
            {},
        ) catch |err| {
            log.err("error rendering the inspector err={}", .{err});
            return;
        };
    }

    pub fn newSurfaceOptions(self: *const Surface, context: apprt.surface.NewSurfaceContext) apprt.Surface.Options {
        const font_size: f32 = font_size: {
            if (!self.app.config.@"window-inherit-font-size") break :font_size 0;
            break :font_size self.core_surface.font_size.points;
        };

        const working_directory: ?[*:0]const u8 = wd: {
            if (!apprt.surface.shouldInheritWorkingDirectory(context, &self.app.config)) break :wd null;
            const cwd = self.core_surface.pwd(self.app.core_app.alloc) catch null orelse break :wd null;
            defer self.app.core_app.alloc.free(cwd);
            break :wd self.app.core_app.alloc.dupeZ(u8, cwd) catch null;
        };

        return .{
            .font_size = font_size,
            .working_directory = working_directory,
            .context = context,
        };
    }

    pub fn defaultTermioEnv(self: *const Surface) !std.process.EnvMap {
        const alloc = self.app.core_app.alloc;
        var env = try internal_os.getEnvMap(alloc);
        errdefer env.deinit();

        if (comptime builtin.target.os.tag.isDarwin()) {
            if (env.get("__XCODE_BUILT_PRODUCTS_DIR_PATHS") != null) {
                env.remove("__XCODE_BUILT_PRODUCTS_DIR_PATHS");
                env.remove("__XPC_DYLD_LIBRARY_PATH");
                env.remove("DYLD_FRAMEWORK_PATH");
                env.remove("DYLD_INSERT_LIBRARIES");
                env.remove("DYLD_LIBRARY_PATH");
                env.remove("LD_LIBRARY_PATH");
                env.remove("SECURITYSESSIONID");
                env.remove("XPC_SERVICE_NAME");
            }

            // Remove this so that running `ghostty` within Ghostty works.
            env.remove("GHOSTTY_MAC_LAUNCH_SOURCE");

            // If we were launched from the desktop then we want to
            // remove the LANGUAGE env var so that we don't inherit
            // our translation settings for Ghostty. If we aren't from
            // the desktop then we didn't set our LANGUAGE var so we
            // don't need to remove it.
            if (internal_os.launchedFromDesktop()) env.remove("LANGUAGE");
        }

        return env;
    }

    /// The cursor position from the host directly is in screen coordinates but
    /// all our interface works in pixels.
    fn cursorPosToPixels(self: *const Surface, pos: apprt.CursorPos) !apprt.CursorPos {
        const scale = try self.getContentScale();
        return .{ .x = pos.x * scale.x, .y = pos.y * scale.y };
    }
};

/// Inspector is the state required for the terminal inspector. A terminal
/// inspector is 1:1 with a Surface.
pub const Inspector = struct {
    const cimgui = @import("dcimgui");

    surface: *Surface,
    ig_ctx: *cimgui.c.ImGuiContext,
    backend: ?Backend = null,
    content_scale: f64 = 1,

    /// Our previous instant used to calculate delta time for animations.
    instant: ?std.time.Instant = null,

    const Backend = enum {
        metal,

        pub fn deinit(self: Backend) void {
            switch (self) {
                .metal => if (builtin.target.os.tag.isDarwin()) cimgui.ImGui_ImplMetal_Shutdown(),
            }
        }
    };

    pub fn init(surface: *Surface) !Inspector {
        const ig_ctx = cimgui.c.ImGui_CreateContext(null) orelse return error.OutOfMemory;
        errdefer cimgui.c.ImGui_DestroyContext(ig_ctx);
        cimgui.c.ImGui_SetCurrentContext(ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        io.BackendPlatformName = "ghostty_embedded";

        // Setup our core inspector
        CoreInspector.setup();
        surface.core_surface.activateInspector() catch |err| {
            log.err("failed to activate inspector err={}", .{err});
        };

        return .{
            .surface = surface,
            .ig_ctx = ig_ctx,
        };
    }

    pub fn deinit(self: *Inspector) void {
        self.surface.core_surface.deactivateInspector();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        if (self.backend) |v| v.deinit();
        cimgui.c.ImGui_DestroyContext(self.ig_ctx);
    }

    /// Queue a render for the next frame.
    pub fn queueRender(self: *Inspector) void {
        self.surface.queueInspectorRender();
    }

    /// Initialize the inspector for a metal backend.
    pub fn initMetal(self: *Inspector, device: objc.Object) bool {
        defer device.msgSend(void, objc.sel("release"), .{});
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);

        if (self.backend) |v| {
            v.deinit();
            self.backend = null;
        }

        if (!cimgui.ImGui_ImplMetal_Init(device.value)) {
            log.warn("failed to initialize metal backend", .{});
            return false;
        }
        self.backend = .metal;

        log.debug("initialized metal backend", .{});
        return true;
    }

    pub fn renderMetal(
        self: *Inspector,
        command_buffer: objc.Object,
        desc: objc.Object,
    ) !void {
        defer {
            command_buffer.msgSend(void, objc.sel("release"), .{});
            desc.msgSend(void, objc.sel("release"), .{});
        }
        assert(self.backend == .metal);
        //log.debug("render", .{});

        // Setup our imgui frame. We need to render multiple frames to ensure
        // ImGui completes all its state processing. I don't know how to fix
        // this.
        for (0..2) |_| {
            cimgui.ImGui_ImplMetal_NewFrame(desc.value);
            try self.newFrame();
            cimgui.c.ImGui_NewFrame();

            // Build our UI
            render: {
                const surface = &self.surface.core_surface;
                const inspector = surface.inspector orelse break :render;
                inspector.render(surface);
            }

            // Render
            cimgui.c.ImGui_Render();
        }

        // MTLRenderCommandEncoder
        const encoder = command_buffer.msgSend(
            objc.Object,
            objc.sel("renderCommandEncoderWithDescriptor:"),
            .{desc.value},
        );
        defer encoder.msgSend(void, objc.sel("endEncoding"), .{});
        cimgui.ImGui_ImplMetal_RenderDrawData(
            cimgui.c.ImGui_GetDrawData(),
            command_buffer.value,
            encoder.value,
        );
    }

    pub fn updateContentScale(self: *Inspector, x: f64, y: f64) void {
        _ = y;
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);

        // Cache our scale because we use it for cursor position calculations.
        self.content_scale = x;

        // Setup a new style and scale it appropriately. We must use the
        // ImGuiStyle constructor to get proper default values (e.g.,
        // CurveTessellationTol) rather than zero-initialized values.
        var style: cimgui.c.ImGuiStyle = undefined;
        cimgui.ext.ImGuiStyle_ImGuiStyle(&style);
        cimgui.c.ImGuiStyle_ScaleAllSizes(&style, @floatCast(x));
        const active_style = cimgui.c.ImGui_GetStyle();
        active_style.* = style;
    }

    pub fn updateSize(self: *Inspector, width: u32, height: u32) void {
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        io.DisplaySize = .{ .x = @floatFromInt(width), .y = @floatFromInt(height) };
    }

    pub fn mouseButtonCallback(
        self: *Inspector,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: input.Mods,
    ) void {
        _ = mods;

        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

        const imgui_button = switch (button) {
            .left => cimgui.c.ImGuiMouseButton_Left,
            .middle => cimgui.c.ImGuiMouseButton_Middle,
            .right => cimgui.c.ImGuiMouseButton_Right,
            else => return, // unsupported
        };

        cimgui.c.ImGuiIO_AddMouseButtonEvent(io, imgui_button, action == .press);
    }

    pub fn scrollCallback(
        self: *Inspector,
        xoff: f64,
        yoff: f64,
        mods: input.ScrollMods,
    ) void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

        // For precision scrolling (trackpads), the values are in pixels which
        // scroll way too fast. Scale them down to approximate discrete wheel
        // notches. imgui expects 1.0 to scroll ~5 lines of text.
        const scale: f64 = if (mods.precision) 0.1 else 1.0;
        cimgui.c.ImGuiIO_AddMouseWheelEvent(
            io,
            @floatCast(xoff * scale),
            @floatCast(yoff * scale),
        );
    }

    pub fn cursorPosCallback(self: *Inspector, x: f64, y: f64) void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        cimgui.c.ImGuiIO_AddMousePosEvent(
            io,
            @floatCast(x * self.content_scale),
            @floatCast(y * self.content_scale),
        );
    }

    pub fn focusCallback(self: *Inspector, focused: bool) void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        cimgui.c.ImGuiIO_AddFocusEvent(io, focused);
    }

    pub fn textCallback(self: *Inspector, text: [:0]const u8) void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        cimgui.c.ImGuiIO_AddInputCharactersUTF8(io, text.ptr);
    }

    pub fn keyCallback(
        self: *Inspector,
        action: input.Action,
        key: input.Key,
        mods: input.Mods,
    ) !void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

        // Update all our modifiers
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftShift, mods.shift);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftCtrl, mods.ctrl);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftAlt, mods.alt);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftSuper, mods.super);

        // Send our keypress
        if (key.imguiKey()) |imgui_key| {
            cimgui.c.ImGuiIO_AddKeyEvent(
                io,
                imgui_key,
                action == .press or action == .repeat,
            );
        }
    }

    fn newFrame(self: *Inspector) !void {
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

        // Determine our delta time
        const now = try std.time.Instant.now();
        io.DeltaTime = if (self.instant) |prev| delta: {
            const since_ns: f64 = @floatFromInt(now.since(prev));
            const ns_per_s: f64 = @floatFromInt(std.time.ns_per_s);
            const since_s: f32 = @floatCast(since_ns / ns_per_s);
            break :delta @max(0.00001, since_s);
        } else (1.0 / 60.0);
        self.instant = now;
    }
};

// C API
pub const CAPI = struct {
    const global = &@import("../global.zig").state;

    /// This is the same as Surface.KeyEvent but this is the raw C API version.
    const KeyEvent = extern struct {
        action: input.Action,
        mods: c_int,
        consumed_mods: c_int,
        keycode: u32,
        text: ?[*:0]const u8,
        unshifted_codepoint: u32,
        composing: bool,

        /// Convert to Zig key event.
        fn keyEvent(self: KeyEvent) App.KeyEvent {
            return .{
                .action = self.action,
                .mods = @bitCast(@as(
                    input.Mods.Backing,
                    @truncate(@as(c_uint, @bitCast(self.mods))),
                )),
                .consumed_mods = @bitCast(@as(
                    input.Mods.Backing,
                    @truncate(@as(c_uint, @bitCast(self.consumed_mods))),
                )),
                .keycode = self.keycode,
                .text = if (self.text) |ptr| std.mem.sliceTo(ptr, 0) else null,
                .unshifted_codepoint = self.unshifted_codepoint,
                .composing = self.composing,
            };
        }
    };

    const SurfaceSize = extern struct {
        columns: u16,
        rows: u16,
        width_px: u32,
        height_px: u32,
        cell_width_px: u32,
        cell_height_px: u32,
    };

    // ghostty_clipboard_content_s
    const ClipboardContent = extern struct {
        mime: [*:0]const u8,
        data: [*:0]const u8,
    };

    // ghostty_runtime_software_frame_* C ABI mirrors.
    const RuntimeSoftwareFramePixelFormat = apprt.surface.Message.SoftwareFramePixelFormat;
    const RuntimeSoftwareFrameStorage = apprt.surface.Message.SoftwareFrameStorage;
    const RuntimeSoftwareDamageRect = apprt.surface.Message.SoftwareFrameDamageRect;
    const RuntimeSoftwareFrameStorageSupport = enum(u32) {
        none = 0,
        shared_cpu_bytes = 1 << 0,
        native_texture_handle = 1 << 1,
    };
    const RuntimeSoftwareFrame = extern struct {
        width_px: u32,
        height_px: u32,
        stride_bytes: u32,
        generation: u64,
        pixel_format: RuntimeSoftwareFramePixelFormat,
        storage: RuntimeSoftwareFrameStorage,
        data: ?[*]const u8 = null,
        data_len: usize = 0,
        handle: ?*anyopaque = null,
        damage_rects: ?[*]const RuntimeSoftwareDamageRect = null,
        damage_rects_len: usize = 0,
    };

    // ghostty_text_s
    const Text = extern struct {
        tl_px_x: f64,
        tl_px_y: f64,
        offset_start: u32,
        offset_len: u32,
        text: ?[*:0]const u8,
        text_len: usize,

        pub fn deinit(self: *Text) void {
            if (self.text) |ptr| {
                global.alloc.free(ptr[0..self.text_len :0]);
            }
        }
    };

    // ghostty_point_s
    const Point = extern struct {
        tag: Tag,
        coord_tag: CoordTag,
        x: u32,
        y: u32,

        const Tag = enum(c_int) {
            active = 0,
            viewport = 1,
            screen = 2,
            history = 3,
        };

        const CoordTag = enum(c_int) {
            exact = 0,
            top_left = 1,
            bottom_right = 2,
        };

        fn pin(
            self: Point,
            screen: *const terminal.Screen,
        ) ?terminal.Pin {
            // The core point tag.
            const tag: terminal.point.Tag = switch (self.tag) {
                inline else => |tag| @field(
                    terminal.point.Tag,
                    @tagName(tag),
                ),
            };

            // Clamp our point to the screen bounds.
            const clamped_x = @min(self.x, screen.pages.cols -| 1);
            const clamped_y = @min(self.y, screen.pages.rows -| 1);

            return switch (self.coord_tag) {
                // Exact coordinates require a specific pin.
                .exact => exact: {
                    const pt_x = std.math.cast(
                        terminal.size.CellCountInt,
                        clamped_x,
                    ) orelse std.math.maxInt(terminal.size.CellCountInt);

                    const pt: terminal.Point = switch (tag) {
                        inline else => |v| @unionInit(
                            terminal.Point,
                            @tagName(v),
                            .{ .x = pt_x, .y = clamped_y },
                        ),
                    };

                    break :exact screen.pages.pin(pt) orelse null;
                },

                .top_left => screen.pages.getTopLeft(tag),

                .bottom_right => screen.pages.getBottomRight(tag),
            };
        }
    };

    // ghostty_selection_s
    const Selection = extern struct {
        tl: Point,
        br: Point,
        rectangle: bool,

        fn core(
            self: Selection,
            screen: *const terminal.Screen,
        ) ?terminal.Selection {
            return .{
                .bounds = .{ .untracked = .{
                    .start = self.tl.pin(screen) orelse return null,
                    .end = self.br.pin(screen) orelse return null,
                } },
                .rectangle = self.rectangle,
            };
        }
    };

    // Reference the conditional exports based on target platform
    // so they're included in the C API.
    comptime {
        if (builtin.target.os.tag.isDarwin()) {
            _ = Darwin;
        }
    }

    pub const RuntimeOptionsError = error{InvalidRuntimeConfig};

    fn runtimeOptionsFieldEnd(comptime field: []const u8) usize {
        return @offsetOf(apprt.runtime.App.Options, field) +
            @sizeOf(@FieldType(apprt.runtime.App.Options, field));
    }

    fn runtimeOptionsSafeCopyLen(provided_size: usize) usize {
        const bounded_size = @min(provided_size, @sizeOf(apprt.runtime.App.Options));

        var copy_len = @as(usize, apprt.runtime.App.runtime_config_min_size);
        const storage_support_end = runtimeOptionsFieldEnd("software_frame_storage_support");
        if (bounded_size >= storage_support_end) copy_len = storage_support_end;

        const software_frame_cb_end = runtimeOptionsFieldEnd("software_frame_cb");
        if (bounded_size >= software_frame_cb_end) copy_len = software_frame_cb_end;

        const close_surface_end = runtimeOptionsFieldEnd("close_surface");
        if (bounded_size >= close_surface_end) copy_len = close_surface_end;

        return copy_len;
    }

    fn runtimeOptionsLoad(
        opts: *const apprt.runtime.App.Options,
    ) RuntimeOptionsError!apprt.runtime.App.Options {
        if (opts.struct_version != apprt.runtime.App.runtime_config_version) {
            return error.InvalidRuntimeConfig;
        }

        const provided_size = @as(usize, opts.struct_size);
        const min_size = @as(usize, apprt.runtime.App.runtime_config_min_size);
        if (provided_size < min_size) {
            return error.InvalidRuntimeConfig;
        }

        var loaded = std.mem.zeroes(apprt.runtime.App.Options);
        const copy_len = runtimeOptionsSafeCopyLen(provided_size);
        @memcpy(
            std.mem.asBytes(&loaded)[0..copy_len],
            std.mem.asBytes(opts)[0..copy_len],
        );
        return loaded;
    }

    fn runtimeOptionsResolve(
        opts: *const apprt.runtime.App.Options,
    ) RuntimeOptionsError!App.ResolvedOptions {
        const loaded = try runtimeOptionsLoad(opts);
        return .{
            .userdata = loaded.userdata,
            .supports_selection_clipboard = loaded.supports_selection_clipboard,
            .wakeup = loaded.wakeup orelse return error.InvalidRuntimeConfig,
            .action = loaded.action orelse return error.InvalidRuntimeConfig,
            .read_clipboard = loaded.read_clipboard orelse return error.InvalidRuntimeConfig,
            .confirm_read_clipboard = loaded.confirm_read_clipboard orelse return error.InvalidRuntimeConfig,
            .write_clipboard = loaded.write_clipboard orelse return error.InvalidRuntimeConfig,
            .software_frame_storage_support = loaded.software_frame_storage_support,
            .software_frame_cb = loaded.software_frame_cb,
            .close_surface = loaded.close_surface,
        };
    }

    /// Returns a zeroed runtime config with size/version initialized.
    export fn ghostty_runtime_config_new() apprt.runtime.App.Options {
        return .{};
    }

    /// Create a new app.
    export fn ghostty_app_new(
        opts: ?*const apprt.runtime.App.Options,
        config: ?*const Config,
    ) ?*App {
        const runtime_opts = opts orelse return null;
        const config_ptr = config orelse return null;
        const mapped_opts = runtimeOptionsResolve(runtime_opts) catch |err| {
            log.err("error validating runtime config err={}", .{err});
            return null;
        };
        return app_new_(mapped_opts, config_ptr) catch |err| {
            log.err("error initializing app err={}", .{err});
            return null;
        };
    }

    fn app_new_(
        opts: App.ResolvedOptions,
        config: *const Config,
    ) !*App {
        const core_app = try CoreApp.create(global.alloc);
        errdefer core_app.destroy();

        // Create our runtime app
        var app = try global.alloc.create(App);
        errdefer global.alloc.destroy(app);
        try app.init(core_app, config, opts);
        errdefer app.terminate();

        return app;
    }

    /// Tick the event loop. This should be called whenever the "wakeup"
    /// callback is invoked for the runtime.
    export fn ghostty_app_tick(v: *App) void {
        v.core_app.tick(v) catch |err| {
            log.err("error app tick err={}", .{err});
        };
    }

    /// Return the userdata associated with the app.
    export fn ghostty_app_userdata(v: *App) ?*anyopaque {
        return v.opts.userdata;
    }

    export fn ghostty_app_free(v: *App) void {
        const core_app = v.core_app;
        v.terminate();
        global.alloc.destroy(v);
        core_app.destroy();
    }

    /// Update the focused state of the app.
    export fn ghostty_app_set_focus(
        app: *App,
        focused: bool,
    ) void {
        app.focusEvent(focused);
    }

    /// Notify the app of a global keypress capture. This will return
    /// true if the key was captured by the app, in which case the caller
    /// should not process the key.
    export fn ghostty_app_key(
        app: *App,
        event: KeyEvent,
    ) bool {
        return app.keyEvent(.app, event.keyEvent()) catch |err| {
            log.warn("error processing key event err={}", .{err});
            return false;
        };
    }

    /// Returns true if the given key event would trigger a binding
    /// if it were sent to the surface right now. The "right now"
    /// is important because things like trigger sequences are only
    /// valid until the next key event.
    export fn ghostty_app_key_is_binding(
        app: *App,
        event: KeyEvent,
    ) bool {
        const core_event = event.keyEvent().core() orelse {
            log.warn("error processing key event", .{});
            return false;
        };

        return app.core_app.keyEventIsBinding(app, core_event);
    }

    /// Notify the app that the keyboard was changed. This causes the
    /// keyboard layout to be reloaded from the OS.
    export fn ghostty_app_keyboard_changed(v: *App) void {
        v.reloadKeymap() catch |err| {
            log.err("error reloading keyboard map err={}", .{err});
            return;
        };
    }

    /// Open the configuration.
    export fn ghostty_app_open_config(v: *App) void {
        _ = v.performAction(.app, .open_config, {}) catch |err| {
            log.err("error reloading config err={}", .{err});
            return;
        };
    }

    /// Update the configuration to the provided config. This will propagate
    /// to all surfaces as well.
    export fn ghostty_app_update_config(
        v: *App,
        config: *const Config,
    ) void {
        v.core_app.updateConfig(v, config) catch |err| {
            log.err("error updating config err={}", .{err});
            return;
        };
    }

    /// Returns true if the app needs to confirm quitting.
    export fn ghostty_app_needs_confirm_quit(v: *App) bool {
        return v.core_app.needsConfirmQuit();
    }

    /// Returns true if the app has global keybinds.
    export fn ghostty_app_has_global_keybinds(v: *App) bool {
        return v.hasGlobalKeybinds();
    }

    /// Update the color scheme of the app.
    export fn ghostty_app_set_color_scheme(v: *App, scheme_raw: c_int) void {
        const scheme = std.meta.intToEnum(apprt.ColorScheme, scheme_raw) catch {
            log.warn(
                "invalid color scheme to ghostty_surface_set_color_scheme value={}",
                .{scheme_raw},
            );
            return;
        };

        v.core_app.colorSchemeEvent(v, scheme) catch |err| {
            log.err("error setting color scheme err={}", .{err});
            return;
        };
    }

    /// Returns initial surface options.
    export fn ghostty_surface_config_new() apprt.Surface.Options {
        return .{};
    }

    /// Create a new surface as part of an app.
    export fn ghostty_surface_new(
        app: *App,
        opts: *const apprt.Surface.Options,
    ) ?*Surface {
        return surface_new_(app, opts) catch |err| {
            log.err("error initializing surface err={}", .{err});
            return null;
        };
    }

    fn surface_new_(
        app: *App,
        opts: *const apprt.Surface.Options,
    ) !*Surface {
        return try app.newSurface(opts.*);
    }

    export fn ghostty_surface_free(ptr: *Surface) void {
        ptr.app.closeSurface(ptr);
    }

    /// Returns the userdata associated with the surface.
    export fn ghostty_surface_userdata(surface: *Surface) ?*anyopaque {
        return surface.userdata;
    }

    /// Returns the app associated with a surface.
    export fn ghostty_surface_app(surface: *Surface) *App {
        return surface.app;
    }

    /// Returns the config to use for surfaces that inherit from this one.
    export fn ghostty_surface_inherited_config(
        surface: *Surface,
        source: apprt.surface.NewSurfaceContext,
    ) Surface.Options {
        return surface.newSurfaceOptions(source);
    }

    /// Update the configuration to the provided config for only this surface.
    export fn ghostty_surface_update_config(
        surface: *Surface,
        config: *const Config,
    ) void {
        surface.core_surface.updateConfig(config) catch |err| {
            log.err("error updating config err={}", .{err});
            return;
        };
        surface.refreshSoftwarePresenterSupport(config);
    }

    /// Returns true if the surface needs to confirm quitting.
    export fn ghostty_surface_needs_confirm_quit(surface: *Surface) bool {
        return surface.core_surface.needsConfirmQuit();
    }

    /// Returns true if the surface process has exited.
    export fn ghostty_surface_process_exited(surface: *Surface) bool {
        return surface.core_surface.child_exited;
    }

    /// Returns true if the surface has a selection.
    export fn ghostty_surface_has_selection(surface: *Surface) bool {
        return surface.core_surface.hasSelection();
    }

    /// Same as ghostty_surface_read_text but reads from the user selection,
    /// if any.
    export fn ghostty_surface_read_selection(
        surface: *Surface,
        result: *Text,
    ) bool {
        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lock();
        defer core_surface.renderer_state.mutex.unlock();

        // If we don't have a selection, do nothing.
        const core_sel = core_surface.io.terminal.screens.active.selection orelse return false;

        // Read the text from the selection.
        return readTextLocked(surface, core_sel, result);
    }

    /// Read some arbitrary text from the surface.
    ///
    /// This is an expensive operation so it shouldn't be called too
    /// often. We recommend that callers cache the result and throttle
    /// calls to this function.
    export fn ghostty_surface_read_text(
        surface: *Surface,
        sel: Selection,
        result: *Text,
    ) bool {
        surface.core_surface.renderer_state.mutex.lock();
        defer surface.core_surface.renderer_state.mutex.unlock();

        const core_sel = sel.core(
            surface.core_surface.renderer_state.terminal.screens.active,
        ) orelse return false;

        return readTextLocked(surface, core_sel, result);
    }

    fn readTextLocked(
        surface: *Surface,
        core_sel: terminal.Selection,
        result: *Text,
    ) bool {
        const core_surface = &surface.core_surface;

        // Get our text directly from the core surface.
        const text = core_surface.dumpTextLocked(
            global.alloc,
            core_sel,
        ) catch |err| {
            log.warn("error reading text err={}", .{err});
            return false;
        };

        const vp: CoreSurface.Text.Viewport = text.viewport orelse .{
            .tl_px_x = -1,
            .tl_px_y = -1,
            .offset_start = 0,
            .offset_len = 0,
        };

        result.* = .{
            .tl_px_x = vp.tl_px_x,
            .tl_px_y = vp.tl_px_y,
            .offset_start = vp.offset_start,
            .offset_len = vp.offset_len,
            .text = text.text.ptr,
            .text_len = text.text.len,
        };

        return true;
    }

    export fn ghostty_surface_free_text(ptr: *Text) void {
        ptr.deinit();
    }

    /// Tell the surface that it needs to schedule a render
    export fn ghostty_surface_refresh(surface: *Surface) void {
        surface.refresh();
    }

    /// Tell the surface that it needs to schedule a render
    /// call as soon as possible (NOW if possible).
    export fn ghostty_surface_draw(surface: *Surface) void {
        surface.draw();
    }

    /// Update the size of a surface. This will trigger resize notifications
    /// to the pty and the renderer.
    export fn ghostty_surface_set_size(surface: *Surface, w: u32, h: u32) void {
        surface.updateSize(w, h);
    }

    /// Return the size information a surface has.
    export fn ghostty_surface_size(surface: *Surface) SurfaceSize {
        const grid_size = surface.core_surface.size.grid();
        return .{
            .columns = grid_size.columns,
            .rows = grid_size.rows,
            .width_px = surface.core_surface.size.screen.width,
            .height_px = surface.core_surface.size.screen.height,
            .cell_width_px = surface.core_surface.size.cell.width,
            .cell_height_px = surface.core_surface.size.cell.height,
        };
    }

    /// Update the color scheme of the surface.
    export fn ghostty_surface_set_color_scheme(surface: *Surface, scheme_raw: c_int) void {
        const scheme = std.meta.intToEnum(apprt.ColorScheme, scheme_raw) catch {
            log.warn(
                "invalid color scheme to ghostty_surface_set_color_scheme value={}",
                .{scheme_raw},
            );
            return;
        };

        surface.colorSchemeCallback(scheme);
    }

    /// Update the content scale of the surface.
    export fn ghostty_surface_set_content_scale(surface: *Surface, x: f64, y: f64) void {
        surface.updateContentScale(x, y);
    }

    /// Update the focused state of a surface.
    export fn ghostty_surface_set_focus(surface: *Surface, focused: bool) void {
        surface.focusCallback(focused);
    }

    /// Update the occlusion state of a surface.
    export fn ghostty_surface_set_occlusion(surface: *Surface, visible: bool) void {
        surface.occlusionCallback(visible);
    }

    /// Filter the mods if necessary. This handles settings such as
    /// `macos-option-as-alt`. The filtered mods should be used for
    /// key translation but should NOT be sent back via the `_key`
    /// function -- the original mods should be used for that.
    export fn ghostty_surface_key_translation_mods(
        surface: *Surface,
        mods_raw: c_int,
    ) c_int {
        const mods: input.Mods = @bitCast(@as(
            input.Mods.Backing,
            @truncate(@as(c_uint, @bitCast(mods_raw))),
        ));
        const result = mods.translation(
            surface.core_surface.config.macos_option_as_alt orelse
                surface.app.keyboardLayout().detectOptionAsAlt(),
        );
        return @intCast(@as(input.Mods.Backing, @bitCast(result)));
    }

    /// Send this for raw keypresses (i.e. the keyDown event on macOS).
    /// This will handle the keymap translation and send the appropriate
    /// key and char events.
    export fn ghostty_surface_key(
        surface: *Surface,
        event: KeyEvent,
    ) bool {
        return surface.app.keyEvent(
            .{ .surface = surface },
            event.keyEvent(),
        ) catch |err| {
            log.warn("error processing key event err={}", .{err});
            return false;
        };
    }

    /// Returns true if the given key event would trigger a binding
    /// if it were sent to the surface right now. The "right now"
    /// is important because things like trigger sequences are only
    /// valid until the next key event.
    export fn ghostty_surface_key_is_binding(
        surface: *Surface,
        event: KeyEvent,
        c_flags: ?*input.Binding.Flags.C,
    ) bool {
        const core_event = event.keyEvent().core() orelse {
            log.warn("error processing key event", .{});
            return false;
        };

        const flags = surface.core_surface.keyEventIsBinding(
            core_event,
        ) orelse return false;
        if (c_flags) |ptr| ptr.* = flags.cval();
        return true;
    }

    /// Send raw text to the terminal. This is treated like a paste
    /// so this isn't useful for sending escape sequences. For that,
    /// individual key input should be used.
    export fn ghostty_surface_text(
        surface: *Surface,
        ptr: [*]const u8,
        len: usize,
    ) void {
        surface.textCallback(ptr[0..len]);
    }

    /// Set the preedit text for the surface. This is used for IME
    /// composition. If the length is 0, then the preedit text is cleared.
    export fn ghostty_surface_preedit(
        surface: *Surface,
        ptr: [*]const u8,
        len: usize,
    ) void {
        surface.preeditCallback(if (len == 0) null else ptr[0..len]);
    }

    /// Returns true if the surface currently has mouse capturing
    /// enabled.
    export fn ghostty_surface_mouse_captured(surface: *Surface) bool {
        return surface.core_surface.mouseCaptured();
    }

    /// Tell the surface that it needs to schedule a render
    export fn ghostty_surface_mouse_button(
        surface: *Surface,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: c_int,
    ) bool {
        return surface.mouseButtonCallback(
            action,
            button,
            @bitCast(@as(
                input.Mods.Backing,
                @truncate(@as(c_uint, @bitCast(mods))),
            )),
        );
    }

    /// Update the mouse position within the view.
    export fn ghostty_surface_mouse_pos(
        surface: *Surface,
        x: f64,
        y: f64,
        mods: c_int,
    ) void {
        surface.cursorPosCallback(
            x,
            y,
            @bitCast(@as(
                input.Mods.Backing,
                @truncate(@as(c_uint, @bitCast(mods))),
            )),
        );
    }

    export fn ghostty_surface_mouse_scroll(
        surface: *Surface,
        x: f64,
        y: f64,
        scroll_mods: c_int,
    ) void {
        surface.scrollCallback(
            x,
            y,
            @bitCast(@as(u8, @truncate(@as(c_uint, @bitCast(scroll_mods))))),
        );
    }

    export fn ghostty_surface_mouse_pressure(
        surface: *Surface,
        stage_raw: u32,
        pressure: f64,
    ) void {
        const stage = std.meta.intToEnum(
            input.MousePressureStage,
            stage_raw,
        ) catch {
            log.warn(
                "invalid mouse pressure stage value={}",
                .{stage_raw},
            );
            return;
        };

        surface.mousePressureCallback(stage, pressure);
    }

    export fn ghostty_surface_ime_point(
        surface: *Surface,
        x: *f64,
        y: *f64,
        width: *f64,
        height: *f64,
    ) void {
        const pos = surface.core_surface.imePoint();
        x.* = pos.x;
        y.* = pos.y;
        width.* = pos.width;
        height.* = pos.height;
    }

    /// Request that the surface become closed. This will go through the
    /// normal trigger process that a close surface input binding would.
    export fn ghostty_surface_request_close(ptr: *Surface) void {
        ptr.core_surface.close();
    }

    /// Request that the surface split in the given direction.
    export fn ghostty_surface_split(ptr: *Surface, direction: apprt.action.SplitDirection) void {
        _ = ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .new_split,
            direction,
        ) catch |err| {
            log.err("error creating new split err={}", .{err});
            return;
        };
    }

    /// Focus on the next split (if any).
    export fn ghostty_surface_split_focus(
        ptr: *Surface,
        direction: apprt.action.GotoSplit,
    ) void {
        _ = ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .goto_split,
            direction,
        ) catch |err| {
            log.err("error creating new split err={}", .{err});
            return;
        };
    }

    /// Resize the current split by moving the split divider in the given
    /// direction. `direction` specifies which direction the split divider will
    /// move relative to the focused split. `amount` is a fractional value
    /// between 0 and 1 that specifies by how much the divider will move.
    export fn ghostty_surface_split_resize(
        ptr: *Surface,
        direction: apprt.action.ResizeSplit.Direction,
        amount: u16,
    ) void {
        _ = ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .resize_split,
            .{ .direction = direction, .amount = amount },
        ) catch |err| {
            log.err("error resizing split err={}", .{err});
            return;
        };
    }

    /// Equalize the size of all splits in the current window.
    export fn ghostty_surface_split_equalize(ptr: *Surface) void {
        _ = ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .equalize_splits,
            {},
        ) catch |err| {
            log.err("error equalizing splits err={}", .{err});
            return;
        };
    }

    /// Invoke an action on the surface.
    export fn ghostty_surface_binding_action(
        ptr: *Surface,
        action_ptr: [*]const u8,
        action_len: usize,
    ) bool {
        const action_str = action_ptr[0..action_len];
        const action = input.Binding.Action.parse(action_str) catch |err| {
            log.err("error parsing binding action action={s} err={}", .{ action_str, err });
            return false;
        };

        return ptr.core_surface.performBindingAction(action) catch |err| {
            log.err("error performing binding action action={f} err={}", .{ action, err });
            return false;
        };
    }

    /// Complete a clipboard read request started via the read callback.
    /// This can only be called once for a given request. Once it is called
    /// with a request the request pointer will be invalidated.
    export fn ghostty_surface_complete_clipboard_request(
        ptr: *Surface,
        str: [*:0]const u8,
        state: *apprt.ClipboardRequest,
        confirmed: bool,
    ) void {
        ptr.completeClipboardRequest(
            std.mem.sliceTo(str, 0),
            state,
            confirmed,
        );
    }

    export fn ghostty_surface_inspector(ptr: *Surface) ?*Inspector {
        return ptr.initInspector() catch |err| {
            log.err("error initializing inspector err={}", .{err});
            return null;
        };
    }

    export fn ghostty_inspector_free(ptr: *Surface) void {
        ptr.freeInspector();
    }

    export fn ghostty_inspector_set_size(ptr: *Inspector, w: u32, h: u32) void {
        ptr.updateSize(w, h);
    }

    export fn ghostty_inspector_set_content_scale(ptr: *Inspector, x: f64, y: f64) void {
        ptr.updateContentScale(x, y);
    }

    export fn ghostty_inspector_mouse_button(
        ptr: *Inspector,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: c_int,
    ) void {
        ptr.mouseButtonCallback(
            action,
            button,
            @bitCast(@as(
                input.Mods.Backing,
                @truncate(@as(c_uint, @bitCast(mods))),
            )),
        );
    }

    export fn ghostty_inspector_mouse_pos(ptr: *Inspector, x: f64, y: f64) void {
        ptr.cursorPosCallback(x, y);
    }

    export fn ghostty_inspector_mouse_scroll(
        ptr: *Inspector,
        x: f64,
        y: f64,
        scroll_mods: c_int,
    ) void {
        ptr.scrollCallback(
            x,
            y,
            @bitCast(@as(u8, @truncate(@as(c_uint, @bitCast(scroll_mods))))),
        );
    }

    export fn ghostty_inspector_key(
        ptr: *Inspector,
        action: input.Action,
        key: input.Key,
        c_mods: c_int,
    ) void {
        ptr.keyCallback(
            action,
            key,
            @bitCast(@as(
                input.Mods.Backing,
                @truncate(@as(c_uint, @bitCast(c_mods))),
            )),
        ) catch |err| {
            log.err("error processing key event err={}", .{err});
            return;
        };
    }

    export fn ghostty_inspector_text(
        ptr: *Inspector,
        str: [*:0]const u8,
    ) void {
        ptr.textCallback(std.mem.sliceTo(str, 0));
    }

    export fn ghostty_inspector_set_focus(ptr: *Inspector, focused: bool) void {
        ptr.focusCallback(focused);
    }

    /// Sets the window background blur on macOS to the desired value.
    /// I do this in Zig as an extern function because I don't know how to
    /// call these functions in Swift.
    ///
    /// This uses an undocumented, non-public API because this is what
    /// every terminal appears to use, including Terminal.app.
    export fn ghostty_set_window_background_blur(
        app: *App,
        window: *anyopaque,
    ) void {
        // This is only supported on macOS
        if (comptime builtin.target.os.tag != .macos) return;

        const config = &app.config;

        // Do nothing if we don't have background transparency enabled
        if (config.@"background-opacity" >= 1.0) return;

        const nswindow = objc.Object.fromId(window);
        _ = CGSSetWindowBackgroundBlurRadius(
            CGSDefaultConnectionForThread(),
            nswindow.msgSend(usize, objc.sel("windowNumber"), .{}),
            @intCast(config.@"background-blur".cval()),
        );
    }

    /// See ghostty_set_window_background_blur
    extern "c" fn CGSSetWindowBackgroundBlurRadius(*anyopaque, usize, c_int) i32;
    extern "c" fn CGSDefaultConnectionForThread() *anyopaque;

    // Darwin-only C APIs.
    const Darwin = struct {
        export fn ghostty_surface_set_display_id(ptr: *Surface, display_id: u32) void {
            const surface = &ptr.core_surface;
            _ = surface.renderer_thread.mailbox.push(
                .{ .macos_display_id = display_id },
                .{ .forever = {} },
            );
            surface.renderer_thread.wakeup.notify() catch {};
        }

        /// This returns a CTFontRef that should be used for quicklook
        /// highlighted text. This is always the primary font in use
        /// regardless of the selected text. If coretext is not in use
        /// then this will return nothing.
        export fn ghostty_surface_quicklook_font(ptr: *Surface) ?*anyopaque {
            // For non-CoreText we just return null.
            if (comptime font.options.backend != .coretext) {
                return null;
            }

            // We'll need content scale so fail early if we can't get it.
            const content_scale = ptr.getContentScale() catch return null;

            // Get the shared font grid. We acquire a read lock to
            // read the font face. It should not be deferred since
            // we're loading the primary face.
            const grid = ptr.core_surface.renderer.font_grid;
            grid.lock.lockShared();
            defer grid.lock.unlockShared();

            const collection = &grid.resolver.collection;
            const face = collection.getFace(.{}) catch return null;

            // We need to unscale the content scale. We apply the
            // content scale to our font stack because we are rendering
            // at 1x but callers of this should be using scaled or apply
            // scale themselves.
            const size: f32 = size: {
                const num = face.font.copyAttribute(.size) orelse
                    break :size 12;
                defer num.release();
                var v: f32 = 12;
                _ = num.getValue(.float, &v);
                break :size v;
            };

            const copy = face.font.copyWithAttributes(
                size / content_scale.y,
                null,
                null,
            ) catch return null;

            return copy;
        }

        /// This returns the selected word for quicklook. This will populate
        /// the buffer with the word under the cursor and the selection
        /// info so that quicklook can be rendered.
        ///
        /// This does not modify the selection active on the surface (if any).
        export fn ghostty_surface_quicklook_word(
            ptr: *Surface,
            result: *Text,
        ) bool {
            const surface = &ptr.core_surface;
            surface.renderer_state.mutex.lock();
            defer surface.renderer_state.mutex.unlock();

            // Get our word selection
            const sel = sel: {
                const screen: *terminal.Screen = surface.renderer_state.terminal.screens.active;
                const pos = try ptr.getCursorPos();
                const pt_viewport = surface.posToViewport(pos.x, pos.y);
                const pin = screen.pages.pin(.{
                    .viewport = .{
                        .x = pt_viewport.x,
                        .y = pt_viewport.y,
                    },
                }) orelse {
                    if (comptime std.debug.runtime_safety) unreachable;
                    return false;
                };
                break :sel surface.io.terminal.screens.active.selectWord(
                    pin,
                    surface.config.selection_word_chars,
                ) orelse return false;
            };

            // Read the selection
            return readTextLocked(ptr, sel, result);
        }

        export fn ghostty_inspector_metal_init(ptr: *Inspector, device: objc.c.id) bool {
            return ptr.initMetal(.fromId(device));
        }

        export fn ghostty_inspector_metal_render(
            ptr: *Inspector,
            command_buffer: objc.c.id,
            descriptor: objc.c.id,
        ) void {
            return ptr.renderMetal(
                .fromId(command_buffer),
                .fromId(descriptor),
            ) catch |err| {
                log.err("error rendering inspector err={}", .{err});
                return;
            };
        }

        export fn ghostty_inspector_metal_shutdown(ptr: *Inspector) void {
            if (ptr.backend) |v| {
                v.deinit();
                ptr.backend = null;
            }
        }
    };
};

test "ghostty.h RuntimeSoftwareFramePixelFormat" {
    try lib.checkGhosttyHEnum(
        CAPI.RuntimeSoftwareFramePixelFormat,
        "GHOSTTY_RUNTIME_SOFTWARE_FRAME_PIXEL_FORMAT_",
    );
}

test "ghostty.h RuntimeSoftwareFrameStorage" {
    try lib.checkGhosttyHEnum(
        CAPI.RuntimeSoftwareFrameStorage,
        "GHOSTTY_RUNTIME_SOFTWARE_FRAME_STORAGE_",
    );
}

test "ghostty.h RuntimeSoftwareFrameStorageSupport" {
    try lib.checkGhosttyHEnum(
        CAPI.RuntimeSoftwareFrameStorageSupport,
        "GHOSTTY_RUNTIME_SOFTWARE_FRAME_STORAGE_SUPPORT_",
    );
}

test "ghostty.h RuntimeSoftwareDamageRect size matches" {
    const c = @import("ghostty.h");
    try std.testing.expectEqual(
        @sizeOf(c.ghostty_runtime_software_damage_rect_s),
        @sizeOf(CAPI.RuntimeSoftwareDamageRect),
    );
}

test "ghostty.h RuntimeSoftwareFrame size matches" {
    const c = @import("ghostty.h");
    try std.testing.expectEqual(
        @sizeOf(c.ghostty_runtime_software_frame_s),
        @sizeOf(CAPI.RuntimeSoftwareFrame),
    );
}

test "ghostty.h RuntimeConfig size matches" {
    const c = @import("ghostty.h");
    try std.testing.expectEqual(
        @sizeOf(c.ghostty_runtime_config_s),
        @sizeOf(App.Options),
    );
}

test "ghostty.h RuntimeConfig macros match Zig constants" {
    const c = @import("ghostty.h");
    try std.testing.expectEqual(
        App.runtime_config_version,
        c.GHOSTTY_RUNTIME_CONFIG_VERSION,
    );
    try std.testing.expectEqual(
        @as(u32, @sizeOf(App.Options)),
        c.GHOSTTY_RUNTIME_CONFIG_SIZE,
    );
    try std.testing.expectEqual(
        App.runtime_config_min_size,
        c.GHOSTTY_RUNTIME_CONFIG_MIN_SIZE,
    );
}

test "ghostty.h RuntimeConfig min size matches offset" {
    const c = @import("ghostty.h");
    try std.testing.expectEqual(
        @as(u32, @intCast(@offsetOf(
            c.ghostty_runtime_config_s,
            "software_frame_storage_support",
        ))),
        c.GHOSTTY_RUNTIME_CONFIG_MIN_SIZE,
    );
}

test "ghostty.h RuntimeConfig optional field offsets match" {
    const c = @import("ghostty.h");
    try std.testing.expectEqual(
        @as(u32, @intCast(@offsetOf(
            c.ghostty_runtime_config_s,
            "software_frame_storage_support",
        ))),
        @as(u32, @intCast(@offsetOf(
            App.Options,
            "software_frame_storage_support",
        ))),
    );
    try std.testing.expectEqual(
        @as(u32, @intCast(@offsetOf(
            c.ghostty_runtime_config_s,
            "software_frame_cb",
        ))),
        @as(u32, @intCast(@offsetOf(
            App.Options,
            "software_frame_cb",
        ))),
    );
    try std.testing.expectEqual(
        @as(u32, @intCast(@offsetOf(
            c.ghostty_runtime_config_s,
            "close_surface_cb",
        ))),
        @as(u32, @intCast(@offsetOf(
            App.Options,
            "close_surface",
        ))),
    );
}

test "ghostty_runtime_config_new initializes size and version" {
    const opts = CAPI.ghostty_runtime_config_new();
    try std.testing.expectEqual(@as(u32, @sizeOf(App.Options)), opts.struct_size);
    try std.testing.expectEqual(App.runtime_config_version, opts.struct_version);
}

test "runtimeSoftwareFrameFromMessage preserves payload and damage metadata" {
    const damage = [_]apprt.surface.Message.SoftwareFrameDamageRect{
        .{ .x_px = 1, .y_px = 2, .width_px = 3, .height_px = 4 },
    };
    const frame: apprt.surface.Message.SoftwareFrameReady = .{
        .width_px = 80,
        .height_px = 24,
        .stride_bytes = 320,
        .generation = 9,
        .pixel_format = .bgra8_premul,
        .storage = .shared_cpu_bytes,
        .data = @ptrFromInt(1),
        .data_len = 1024,
        .handle = null,
        .damage_rects = &damage,
        .damage_rects_len = damage.len,
    };

    const c_frame = Surface.runtimeSoftwareFrameFromMessage(frame);
    try std.testing.expectEqual(frame.width_px, c_frame.width_px);
    try std.testing.expectEqual(frame.height_px, c_frame.height_px);
    try std.testing.expectEqual(frame.stride_bytes, c_frame.stride_bytes);
    try std.testing.expectEqual(frame.generation, c_frame.generation);
    try std.testing.expectEqual(frame.pixel_format, c_frame.pixel_format);
    try std.testing.expectEqual(frame.storage, c_frame.storage);
    try std.testing.expect(c_frame.data == frame.data);
    try std.testing.expectEqual(frame.data_len, c_frame.data_len);
    try std.testing.expect(c_frame.handle == frame.handle);
    try std.testing.expect(c_frame.damage_rects == frame.damage_rects);
    try std.testing.expectEqual(frame.damage_rects_len, c_frame.damage_rects_len);
}

test "validateSoftwareFramePayload rejects damage metadata length without pointer" {
    const frame: apprt.surface.Message.SoftwareFrameReady = .{
        .width_px = 4,
        .height_px = 3,
        .stride_bytes = 16,
        .generation = 1,
        .pixel_format = .bgra8_premul,
        .storage = .shared_cpu_bytes,
        .data = @ptrFromInt(1),
        .data_len = 48,
        .damage_rects = null,
        .damage_rects_len = 1,
    };

    try std.testing.expectError(
        error.InvalidSoftwareFrame,
        Surface.validateSoftwareFramePayload(frame),
    );
}

fn testRuntimeWakeupNoop(_: ?*anyopaque) callconv(.c) void {}

fn testRuntimeActionNoop(
    _: *App,
    _: apprt.Target.C,
    _: apprt.Action.C,
) callconv(.c) bool {
    return true;
}

fn testRuntimeReadClipboardNoop(
    _: ?*anyopaque,
    _: c_int,
    _: *apprt.ClipboardRequest,
) callconv(.c) void {}

fn testRuntimeConfirmReadClipboardNoop(
    _: ?*anyopaque,
    _: [*:0]const u8,
    _: *apprt.ClipboardRequest,
    _: apprt.ClipboardRequestType,
) callconv(.c) void {}

fn testRuntimeWriteClipboardNoop(
    _: ?*anyopaque,
    _: c_int,
    _: [*]const CAPI.ClipboardContent,
    _: usize,
    _: bool,
) callconv(.c) void {}

fn testRuntimeCloseSurfaceNoop(_: ?*anyopaque, _: bool) callconv(.c) void {}

fn runtimeConfigFieldEnd(comptime field: []const u8) u32 {
    return @as(u32, @intCast(@offsetOf(App.Options, field))) +
        @as(u32, @intCast(@sizeOf(@FieldType(App.Options, field))));
}

fn testValidRuntimeConfig() App.Options {
    var opts = CAPI.ghostty_runtime_config_new();
    opts.wakeup = &testRuntimeWakeupNoop;
    opts.action = &testRuntimeActionNoop;
    opts.read_clipboard = &testRuntimeReadClipboardNoop;
    opts.confirm_read_clipboard = &testRuntimeConfirmReadClipboardNoop;
    opts.write_clipboard = &testRuntimeWriteClipboardNoop;
    return opts;
}

test "runtimeOptionsResolve rejects invalid version" {
    var opts = testValidRuntimeConfig();
    opts.struct_version = 0;

    try std.testing.expectError(
        error.InvalidRuntimeConfig,
        CAPI.runtimeOptionsResolve(&opts),
    );
}

test "runtimeOptionsResolve rejects size smaller than required prefix" {
    var opts = testValidRuntimeConfig();
    opts.struct_size = App.runtime_config_min_size - 1;

    try std.testing.expectError(
        error.InvalidRuntimeConfig,
        CAPI.runtimeOptionsResolve(&opts),
    );
}

test "runtimeOptionsResolve rejects missing required callback" {
    var opts = testValidRuntimeConfig();
    opts.action = null;

    try std.testing.expectError(
        error.InvalidRuntimeConfig,
        CAPI.runtimeOptionsResolve(&opts),
    );
}

test "runtimeOptionsResolve accepts forward-compatible larger declared size" {
    var opts = testValidRuntimeConfig();
    opts.struct_size = @sizeOf(App.Options) + 64;
    opts.software_frame_storage_support = @intFromEnum(
        CAPI.RuntimeSoftwareFrameStorageSupport.shared_cpu_bytes,
    );
    opts.software_frame_cb = &testSoftwareFrameCallbackSuccess;

    const mapped = try CAPI.runtimeOptionsResolve(&opts);
    try std.testing.expectEqual(
        opts.software_frame_storage_support,
        mapped.software_frame_storage_support,
    );
    try std.testing.expect(mapped.software_frame_cb == opts.software_frame_cb);
}

test "runtimeOptionsResolve maps optional fields when full struct is provided" {
    var opts = testValidRuntimeConfig();
    opts.software_frame_storage_support = @intFromEnum(
        CAPI.RuntimeSoftwareFrameStorageSupport.shared_cpu_bytes,
    );
    opts.software_frame_cb = &testSoftwareFrameCallbackSuccess;
    opts.close_surface = &testRuntimeCloseSurfaceNoop;

    const mapped = try CAPI.runtimeOptionsResolve(&opts);
    try std.testing.expectEqual(opts.userdata, mapped.userdata);
    try std.testing.expectEqual(
        opts.software_frame_storage_support,
        mapped.software_frame_storage_support,
    );
    try std.testing.expect(mapped.software_frame_cb == opts.software_frame_cb);
    try std.testing.expect(mapped.close_surface == opts.close_surface);
}

test "runtimeOptionsResolve supports prefix-only callers by defaulting optional fields" {
    var opts = testValidRuntimeConfig();
    opts.struct_size = App.runtime_config_min_size;
    opts.software_frame_storage_support = @intFromEnum(
        CAPI.RuntimeSoftwareFrameStorageSupport.shared_cpu_bytes,
    );
    opts.software_frame_cb = &testSoftwareFrameCallbackSuccess;
    opts.close_surface = &testRuntimeCloseSurfaceNoop;

    const mapped = try CAPI.runtimeOptionsResolve(&opts);
    try std.testing.expectEqual(@as(u32, 0), mapped.software_frame_storage_support);
    try std.testing.expect(mapped.software_frame_cb == null);
    try std.testing.expect(mapped.close_surface == null);
}

test "runtimeOptionsResolve ignores partial software frame storage support bytes" {
    var opts = testValidRuntimeConfig();
    opts.struct_size = App.runtime_config_min_size + 1;
    opts.software_frame_storage_support = @intFromEnum(
        CAPI.RuntimeSoftwareFrameStorageSupport.shared_cpu_bytes,
    );
    opts.software_frame_cb = &testSoftwareFrameCallbackSuccess;
    opts.close_surface = &testRuntimeCloseSurfaceNoop;

    const mapped = try CAPI.runtimeOptionsResolve(&opts);
    try std.testing.expectEqual(@as(u32, 0), mapped.software_frame_storage_support);
    try std.testing.expect(mapped.software_frame_cb == null);
    try std.testing.expect(mapped.close_surface == null);
}

test "runtimeOptionsResolve ignores partial software frame callback bytes" {
    var opts = testValidRuntimeConfig();
    opts.struct_size = runtimeConfigFieldEnd("software_frame_storage_support") + 1;
    opts.software_frame_storage_support = @intFromEnum(
        CAPI.RuntimeSoftwareFrameStorageSupport.shared_cpu_bytes,
    );
    opts.software_frame_cb = &testSoftwareFrameCallbackSuccess;
    opts.close_surface = &testRuntimeCloseSurfaceNoop;

    const mapped = try CAPI.runtimeOptionsResolve(&opts);
    try std.testing.expectEqual(
        opts.software_frame_storage_support,
        mapped.software_frame_storage_support,
    );
    try std.testing.expect(mapped.software_frame_cb == null);
    try std.testing.expect(mapped.close_surface == null);
}

test "runtimeOptionsResolve ignores partial close surface callback bytes" {
    var opts = testValidRuntimeConfig();
    opts.struct_size = runtimeConfigFieldEnd("software_frame_cb") + 1;
    opts.software_frame_storage_support = @intFromEnum(
        CAPI.RuntimeSoftwareFrameStorageSupport.shared_cpu_bytes,
    );
    opts.software_frame_cb = &testSoftwareFrameCallbackSuccess;
    opts.close_surface = &testRuntimeCloseSurfaceNoop;

    const mapped = try CAPI.runtimeOptionsResolve(&opts);
    try std.testing.expectEqual(
        opts.software_frame_storage_support,
        mapped.software_frame_storage_support,
    );
    try std.testing.expect(mapped.software_frame_cb == opts.software_frame_cb);
    try std.testing.expect(mapped.close_surface == null);
}

fn testSoftwareFrameCallbackSuccess(
    _: ?*anyopaque,
    _: *const CAPI.RuntimeSoftwareFrame,
) callconv(.c) bool {
    return true;
}

fn testRequiredStorageSupportMaskForMacos() u32 {
    return testRequiredStorageSupportMaskForPlatform(.macos);
}

fn testUnsupportedStorageSupportMaskForMacos() u32 {
    return testUnsupportedStorageSupportMaskForPlatform(.macos);
}

fn testRequiredStorageSupportMaskForIos() u32 {
    return testRequiredStorageSupportMaskForPlatform(.ios);
}

fn testUnsupportedStorageSupportMaskForIos() u32 {
    return testUnsupportedStorageSupportMaskForPlatform(.ios);
}

test "software presenter required storage for embedded runtime uses effective CPU switch instead of raw mvp toggle" {
    try std.testing.expectEqual(
        apprt.surface.Message.SoftwareFrameStorage.native_texture_handle,
        softwarePresenterRequiredStorageForEmbeddedConfigWithCpuFlags(.macos, .{
            .mvp = true,
            .effective = false,
        }, .auto),
    );
}

test "software presenter required storage for embedded runtime uses shared cpu bytes on macOS when effective cpu flag is true" {
    try std.testing.expectEqual(
        apprt.surface.Message.SoftwareFrameStorage.shared_cpu_bytes,
        softwarePresenterRequiredStorageForEmbeddedConfigWithCpuFlags(.macos, .{
            .mvp = true,
            .effective = true,
        }, .auto),
    );
}

test "software presenter required storage for embedded runtime uses native texture handle on macOS when mvp and effective are false" {
    try std.testing.expectEqual(
        apprt.surface.Message.SoftwareFrameStorage.native_texture_handle,
        softwarePresenterRequiredStorageForEmbeddedConfigWithCpuFlags(.macos, .{
            .mvp = false,
            .effective = false,
        }, .auto),
    );
}

test "software presenter required storage for embedded runtime on iOS uses native texture handle when mvp is true and effective is false" {
    try std.testing.expectEqual(
        apprt.surface.Message.SoftwareFrameStorage.native_texture_handle,
        softwarePresenterRequiredStorageForEmbeddedConfigWithCpuFlags(.ios, .{
            .mvp = true,
            .effective = false,
        }, .auto),
    );
}

test "software presenter required storage for embedded runtime on iOS uses shared cpu bytes when mvp and effective are true" {
    try std.testing.expectEqual(
        apprt.surface.Message.SoftwareFrameStorage.shared_cpu_bytes,
        softwarePresenterRequiredStorageForEmbeddedConfigWithCpuFlags(.ios, .{
            .mvp = true,
            .effective = true,
        }, .auto),
    );
}

test "software presenter required storage for embedded runtime on iOS uses native texture handle when mvp and effective are false" {
    try std.testing.expectEqual(
        apprt.surface.Message.SoftwareFrameStorage.native_texture_handle,
        softwarePresenterRequiredStorageForEmbeddedConfigWithCpuFlags(.ios, .{
            .mvp = false,
            .effective = false,
        }, .auto),
    );
}

test "software presenter required storage for embedded runtime uses native texture handle when transport mode is native" {
    try std.testing.expectEqual(
        apprt.surface.Message.SoftwareFrameStorage.native_texture_handle,
        softwarePresenterRequiredStorageForEmbeddedConfigWithCpuFlags(.macos, .{
            .mvp = true,
            .effective = true,
        }, .native),
    );
}

test "software presenter storage support for embedded runtime requires only required storage for auto cpu route on macOS" {
    const shared_only =
        softwareFrameStorageSupportMask(.shared_cpu_bytes);
    const shared_and_native =
        softwareFrameStorageSupportMask(.shared_cpu_bytes) |
        softwareFrameStorageSupportMask(.native_texture_handle);

    try std.testing.expect(
        softwarePresenterStorageSupportedForEmbeddedConfigWithCpuFlags(
            .macos,
            shared_only,
            .{
                .mvp = true,
                .effective = true,
            },
            .auto,
        ),
    );
    try std.testing.expect(
        softwarePresenterStorageSupportedForEmbeddedConfigWithCpuFlags(
            .macos,
            shared_and_native,
            .{
                .mvp = true,
                .effective = true,
            },
            .auto,
        ),
    );
}

test "software presenter storage support for embedded runtime keeps shared-only valid for forced shared transport on macOS" {
    const shared_only =
        softwareFrameStorageSupportMask(.shared_cpu_bytes);

    try std.testing.expect(
        softwarePresenterStorageSupportedForEmbeddedConfigWithCpuFlags(
            .macos,
            shared_only,
            .{
                .mvp = true,
                .effective = true,
            },
            .shared,
        ),
    );
}

fn testRequiredStorageForOsTagWithCpuFlags(
    os_tag: std.Target.Os.Tag,
    cpu_flags: EmbeddedSoftwareRendererCpuFlags,
    transport_mode: build_config.SoftwareFrameTransportMode,
) apprt.surface.Message.SoftwareFrameStorage {
    assert(!cpu_flags.effective or cpu_flags.mvp);
    if (transport_mode == .native) {
        return .native_texture_handle;
    }
    if (cpu_flags.effective) {
        return .shared_cpu_bytes;
    }

    return switch (renderer.Backend.softwareRouteForOsTag(os_tag)) {
        .metal => .native_texture_handle,
        else => .shared_cpu_bytes,
    };
}

test "software presenter required storage for embedded runtime uses shared cpu bytes on linux when mvp and effective are false" {
    try std.testing.expectEqual(
        apprt.surface.Message.SoftwareFrameStorage.shared_cpu_bytes,
        testRequiredStorageForOsTagWithCpuFlags(.linux, .{
            .mvp = false,
            .effective = false,
        }, .auto),
    );
}

fn testRequiredStorageSupportMaskForPlatform(platform: PlatformTag) u32 {
    return softwareFrameStorageSupportMask(
        softwarePresenterRequiredStorageForEmbeddedConfig(platform),
    );
}

fn testUnsupportedStorageSupportMaskForPlatform(platform: PlatformTag) u32 {
    return switch (softwarePresenterRequiredStorageForEmbeddedConfig(platform)) {
        .shared_cpu_bytes => @intFromEnum(CAPI.RuntimeSoftwareFrameStorageSupport.native_texture_handle),
        .native_texture_handle => @intFromEnum(CAPI.RuntimeSoftwareFrameStorageSupport.shared_cpu_bytes),
    };
}

test "software presenter decision for embedded runtime returns runtime_capability_missing without callback on macOS" {
    const decision = softwarePresenterDecisionForEmbeddedConfig(
        true,
        true,
        .snapshot,
        .macos,
        null,
        testRequiredStorageSupportMaskForMacos(),
        false,
    );

    try std.testing.expectEqual(
        software_presenter.Reason.runtime_capability_missing,
        decision.reason,
    );
    try std.testing.expectEqual(
        Config.SoftwareRendererPresenter.@"legacy-gl",
        decision.selected,
    );
    try std.testing.expect(!decision.can_publish_software_frame);
}

test "software presenter decision for embedded runtime selects snapshot with callback and required storage support" {
    const decision = softwarePresenterDecisionForEmbeddedConfig(
        true,
        true,
        .snapshot,
        .macos,
        &testSoftwareFrameCallbackSuccess,
        testRequiredStorageSupportMaskForMacos(),
        false,
    );

    try std.testing.expectEqual(
        software_presenter.Reason.snapshot_selected,
        decision.reason,
    );
    try std.testing.expectEqual(
        Config.SoftwareRendererPresenter.snapshot,
        decision.selected,
    );
    try std.testing.expect(decision.can_publish_software_frame);
}

test "software presenter decision for embedded runtime applies runtime_failed_session_fallback after callback failure" {
    const decision = softwarePresenterDecisionForEmbeddedConfig(
        true,
        true,
        .snapshot,
        .macos,
        &testSoftwareFrameCallbackSuccess,
        testRequiredStorageSupportMaskForMacos(),
        true,
    );

    try std.testing.expectEqual(
        software_presenter.Reason.runtime_failed_session_fallback,
        decision.reason,
    );
    try std.testing.expectEqual(
        Config.SoftwareRendererPresenter.@"legacy-gl",
        decision.selected,
    );
    try std.testing.expect(!decision.can_publish_software_frame);
}

test "software presenter decision for embedded runtime respects experimental disabled" {
    const decision = softwarePresenterDecisionForEmbeddedConfig(
        true,
        false,
        .snapshot,
        .macos,
        &testSoftwareFrameCallbackSuccess,
        testRequiredStorageSupportMaskForMacos(),
        false,
    );

    try std.testing.expectEqual(
        software_presenter.Reason.experimental_disabled,
        decision.reason,
    );
    try std.testing.expect(!decision.can_publish_software_frame);
}

test "software presenter decision for embedded runtime returns runtime_capability_missing when required storage support is absent" {
    const decision = softwarePresenterDecisionForEmbeddedConfig(
        true,
        true,
        .snapshot,
        .macos,
        &testSoftwareFrameCallbackSuccess,
        testUnsupportedStorageSupportMaskForMacos(),
        false,
    );

    try std.testing.expectEqual(
        software_presenter.Reason.runtime_capability_missing,
        decision.reason,
    );
    try std.testing.expectEqual(
        Config.SoftwareRendererPresenter.@"legacy-gl",
        decision.selected,
    );
    try std.testing.expect(!decision.can_publish_software_frame);
}

test "software presenter decision for embedded runtime returns runtime_capability_missing without callback on iOS" {
    const decision = softwarePresenterDecisionForEmbeddedConfig(
        true,
        true,
        .snapshot,
        .ios,
        null,
        testRequiredStorageSupportMaskForIos(),
        false,
    );

    try std.testing.expectEqual(
        software_presenter.Reason.runtime_capability_missing,
        decision.reason,
    );
    try std.testing.expectEqual(
        Config.SoftwareRendererPresenter.@"legacy-gl",
        decision.selected,
    );
    try std.testing.expect(!decision.can_publish_software_frame);
}

test "software presenter decision for embedded runtime selects snapshot on iOS with callback and required storage support" {
    const decision = softwarePresenterDecisionForEmbeddedConfig(
        true,
        true,
        .snapshot,
        .ios,
        &testSoftwareFrameCallbackSuccess,
        testRequiredStorageSupportMaskForIos(),
        false,
    );

    try std.testing.expectEqual(
        software_presenter.Reason.snapshot_selected,
        decision.reason,
    );
    try std.testing.expectEqual(
        Config.SoftwareRendererPresenter.snapshot,
        decision.selected,
    );
    try std.testing.expect(decision.can_publish_software_frame);
}

test "software presenter decision for embedded runtime returns runtime_capability_missing on iOS when required storage support is absent" {
    const decision = softwarePresenterDecisionForEmbeddedConfig(
        true,
        true,
        .snapshot,
        .ios,
        &testSoftwareFrameCallbackSuccess,
        testUnsupportedStorageSupportMaskForIos(),
        false,
    );

    try std.testing.expectEqual(
        software_presenter.Reason.runtime_capability_missing,
        decision.reason,
    );
    try std.testing.expectEqual(
        Config.SoftwareRendererPresenter.@"legacy-gl",
        decision.selected,
    );
    try std.testing.expect(!decision.can_publish_software_frame);
}

test "software presenter decision for embedded runtime applies runtime_failed_session_fallback on iOS" {
    const decision = softwarePresenterDecisionForEmbeddedConfig(
        true,
        true,
        .snapshot,
        .ios,
        &testSoftwareFrameCallbackSuccess,
        testRequiredStorageSupportMaskForIos(),
        true,
    );

    try std.testing.expectEqual(
        software_presenter.Reason.runtime_failed_session_fallback,
        decision.reason,
    );
    try std.testing.expectEqual(
        Config.SoftwareRendererPresenter.@"legacy-gl",
        decision.selected,
    );
    try std.testing.expect(!decision.can_publish_software_frame);
}
