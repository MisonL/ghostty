const std = @import("std");

/// Runtime is the runtime to use for Ghostty. All runtimes do not provide
/// equivalent feature sets.
pub const Runtime = enum {
    /// Will not produce an executable at all when `zig build` is called.
    /// This is only useful if you're only interested in the lib only (macOS).
    none,

    /// GTK4. Rich windowed application. This uses a full GObject-based
    /// approach to building the application.
    gtk,

    /// Experimental Win32 runtime scaffold. This is not yet the default
    /// runtime because the full terminal surface integration is still
    /// being brought up.
    win32,

    pub fn default(target: std.Target) Runtime {
        return switch (target.os.tag) {
            // The Linux and FreeBSD default is GTK because it is a full
            // featured application.
            .linux, .freebsd => .gtk,
            // Windows runtime is still experimental; keep the library-only
            // default until the terminal surface path is complete.
            .windows => .none,
            // Otherwise, we do NONE so we don't create an exe and we create
            // libghostty. On macOS, Xcode is used to build the app that links
            // to libghostty.
            else => .none,
        };
    }
};

test {
    _ = Runtime;
}
