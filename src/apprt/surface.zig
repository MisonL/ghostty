const std = @import("std");
const Allocator = std.mem.Allocator;

const apprt = @import("../apprt.zig");
const build_config = @import("../build_config.zig");
const App = @import("../App.zig");
const Surface = @import("../Surface.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const Config = @import("../config.zig").Config;
const MessageData = @import("../datastruct/main.zig").MessageData;

/// The message types that can be sent to a single surface.
pub const Message = union(enum) {
    /// Represents a write request. Magic number comes from the max size
    /// we want this union to be.
    pub const WriteReq = MessageData(u8, 255);

    /// Set the title of the surface.
    /// TODO: we should change this to a "WriteReq" style structure in
    /// the termio message so that we can more efficiently send strings
    /// of any length
    set_title: [256]u8,

    /// Report the window title back to the terminal
    report_title: ReportTitleStyle,

    /// Set the mouse shape.
    set_mouse_shape: terminal.MouseShape,

    /// Read the clipboard and write to the pty.
    clipboard_read: apprt.Clipboard,

    /// Write the clipboard contents.
    clipboard_write: struct {
        clipboard_type: apprt.Clipboard,
        req: WriteReq,
    },

    /// Change the configuration to the given configuration. The pointer is
    /// not valid after receiving this message so any config must be used
    /// and derived immediately.
    change_config: *const Config,

    /// Close the surface. This will only close the current surface that
    /// receives this, not the full application.
    close: void,

    /// The child process running in the surface has exited. This may trigger
    /// a surface close, it may not. Additional details about the child
    /// command are given in the `ChildExited` struct.
    child_exited: ChildExited,

    /// Show a desktop notification.
    desktop_notification: struct {
        /// Desktop notification title.
        title: [63:0]u8,

        /// Desktop notification body.
        body: [255:0]u8,
    },

    /// Health status change for the renderer.
    renderer_health: renderer.Health,

    /// A software-rendered frame is ready to be presented by the apprt.
    software_frame_ready: SoftwareFrameReady,

    /// Tell the surface to present itself to the user. This may require raising
    /// a window and switching tabs.
    present_surface: void,

    /// Notifies the surface that password input has started within
    /// the terminal. This should always be followed by a false value
    /// unless the surface exits.
    password_input: bool,

    /// A terminal color was changed using OSC sequences.
    color_change: terminal.osc.color.ColoredTarget,

    /// Notifies the surface that a tick of the timer that is timing
    /// out selection scrolling has occurred. "selection scrolling"
    /// is when the user has clicked and dragged the mouse outside
    /// the viewport of the terminal and the terminal is scrolling
    /// the viewport to follow the mouse cursor.
    selection_scroll_tick: bool,

    /// The terminal has reported a change in the working directory.
    pwd_change: WriteReq,

    /// The terminal encountered a bell character.
    ring_bell,

    /// Report the progress of an action using a GUI element
    progress_report: terminal.osc.Command.ProgressReport,

    /// A command has started in the shell, start a timer.
    start_command,

    /// A command has finished in the shell, stop the timer and send out
    /// notifications as appropriate. The optional u8 is the exit code
    /// of the command.
    stop_command: ?u8,

    /// The scrollbar state changed for the surface.
    scrollbar: terminal.Scrollbar,

    /// Search progress update
    search_total: ?usize,

    /// Selected search index change
    search_selected: ?usize,

    pub const ReportTitleStyle = enum {
        csi_21_t,

        // This enum is a placeholder for future title styles.
    };

    pub const ChildExited = extern struct {
        exit_code: u32,
        runtime_ms: u64,

        /// Make this a valid gobject if we're in a GTK environment.
        pub const getGObjectType = switch (build_config.app_runtime) {
            .gtk,
            => @import("gobject").ext.defineBoxed(
                ChildExited,
                .{ .name = "GhosttyApprtChildExited" },
            ),
            else => void,
        };
    };

    pub const SoftwareFramePixelFormat = enum(c_int) {
        bgra8_premul,
        rgba8_premul,
    };

    pub const SoftwareFrameStorage = enum(c_int) {
        shared_cpu_bytes,
        native_texture_handle,
    };

    pub const SoftwareFrameDamageRect = extern struct {
        x_px: u32,
        y_px: u32,
        width_px: u32,
        height_px: u32,
    };

    /// Optional callback to release any owned payload associated with a
    /// software frame once it has been consumed.
    pub const SoftwareFrameReleaseFn =
        *const fn (
            ctx: ?*anyopaque,
            data: ?[*]const u8,
            data_len: usize,
            handle: ?*anyopaque,
        ) callconv(.c) void;

    pub const SoftwareFrameReady = extern struct {
        width_px: u32,
        height_px: u32,
        stride_bytes: u32,
        generation: u64,
        pixel_format: SoftwareFramePixelFormat,
        storage: SoftwareFrameStorage,

        /// Optional bytes payload when storage is shared_cpu_bytes.
        data: ?[*]const u8 = null,
        data_len: usize = 0,

        /// Optional native handle payload when storage is native_texture_handle.
        handle: ?*anyopaque = null,

        /// Optional damage rectangle payload to describe updated regions.
        damage_rects: ?[*]const SoftwareFrameDamageRect = null,
        damage_rects_len: usize = 0,

        /// Optional callback context and function used to release `data` and/or
        /// `handle` ownership after delivery to apprt.
        release_ctx: ?*anyopaque = null,
        release_fn: ?SoftwareFrameReleaseFn = null,

        /// Release any owned resources associated with this frame.
        pub inline fn release(self: SoftwareFrameReady) void {
            const release_fn = self.release_fn orelse return;
            release_fn(self.release_ctx, self.data, self.data_len, self.handle);
        }
    };
};

/// A surface mailbox.
pub const Mailbox = struct {
    surface: *Surface,
    app: App.Mailbox,

    /// Send a message to the surface.
    pub fn push(
        self: Mailbox,
        msg: Message,
        timeout: App.Mailbox.Queue.Timeout,
    ) App.Mailbox.Queue.Size {
        // Surface message sending is actually implemented on the app
        // thread, so we have to rewrap the message with our surface
        // pointer and send it to the app thread.
        return self.app.push(.{
            .surface_message = .{
                .surface = self.surface,
                .message = msg,
            },
        }, timeout);
    }
};

/// Context for new surface creation to determine inheritance behavior
pub const NewSurfaceContext = enum(c_int) {
    window = 0,
    tab = 1,
    split = 2,
};

pub fn shouldInheritWorkingDirectory(context: NewSurfaceContext, config: *const Config) bool {
    return switch (context) {
        .window => config.@"window-inherit-working-directory",
        .tab => config.@"tab-inherit-working-directory",
        .split => config.@"split-inherit-working-directory",
    };
}

test "SoftwareFrameReady.release invokes callback" {
    const testing = std.testing;
    var released = false;

    const cb = struct {
        fn release(
            ctx: ?*anyopaque,
            data: ?[*]const u8,
            data_len: usize,
            handle: ?*anyopaque,
        ) callconv(.c) void {
            _ = data;
            _ = data_len;
            _ = handle;
            const flag_ptr: *bool = @ptrCast(@alignCast(ctx.?));
            flag_ptr.* = true;
        }
    }.release;

    const frame: Message.SoftwareFrameReady = .{
        .width_px = 1,
        .height_px = 1,
        .stride_bytes = 4,
        .generation = 1,
        .pixel_format = .bgra8_premul,
        .storage = .shared_cpu_bytes,
        .data = null,
        .data_len = 0,
        .handle = null,
        .release_ctx = @ptrCast(&released),
        .release_fn = &cb,
    };

    frame.release();
    try testing.expect(released);
}

/// Returns a new config for a surface for the given app that should be
/// used for any new surfaces. The resulting config should be deinitialized
/// after the surface is initialized.
pub fn newConfig(
    app: *const App,
    config: *const Config,
    context: NewSurfaceContext,
) Allocator.Error!Config {
    // Create a shallow clone
    var copy = config.shallowClone(app.alloc);

    // Our allocator is our config's arena
    const alloc = copy._arena.?.allocator();

    // Get our previously focused surface for some inherited values.
    const prev = app.focusedSurface();
    if (prev) |p| {
        if (shouldInheritWorkingDirectory(context, config)) {
            if (try p.pwd(alloc)) |pwd| {
                copy.@"working-directory" = pwd;
            }
        }
    }

    return copy;
}
