//! Experimental Win32 runtime scaffold.
//!
//! This establishes the minimum apprt shape for a native Windows
//! application loop so the project can iterate on a real runtime instead of
//! continuing to route Windows through `app_runtime = none`.
//!
//! Current stage:
//! - one top-level Win32 window
//! - event loop / wakeup path
//! - action dispatch skeleton
//! - explicit opt-in via `-Dapp-runtime=win32`
//!
//! Current rendering status:
//! - real CoreSurface lifecycle is wired up
//! - DXGI/D3D12 device + swapchain objects are initialized
//! - first-frame native clear/present scaffold is in progress
//! - text/glyph rendering is not yet native D3D12

const std = @import("std");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;
const input = @import("../input.zig");
const apprt = @import("../apprt.zig");
const CoreApp = @import("../App.zig");
const CoreSurface = @import("../Surface.zig");
const configpkg = @import("../config.zig");
const internal_os = @import("../os/main.zig");
const winos = internal_os.windows;

pub const resourcesDir = internal_os.resourcesDir;
pub const must_draw_from_app_thread = false;

const log = std.log.scoped(.win32_apprt);
const swap_chain_buffer_count: usize = 2;
const software_upload_row_pitch_alignment: u32 = 256;

fn ciSmokeEnabled() bool {
    const alloc = std.heap.page_allocator;
    const value = std.process.getEnvVarOwned(alloc, "GHOSTTY_CI_WIN32_SMOKE") catch
        return false;
    defer alloc.free(value);
    return value.len > 0 and !std.mem.eql(u8, value, "0");
}

fn nativePtr(comptime T: type, raw: anytype) T {
    return @ptrFromInt(@intFromPtr(raw));
}

const win = struct {
    const UINT = u32;
    const DWORD = u32;
    const WORD = u16;
    const BOOL = i32;
    const LPARAM = isize;
    const WPARAM = usize;
    const LRESULT = isize;
    const LONG_PTR = isize;
    const ATOM = u16;
    const HINSTANCE = ?*anyopaque;
    const HWND = ?*anyopaque;
    const HICON = ?*anyopaque;
    const HCURSOR = ?*anyopaque;
    const HBRUSH = ?*anyopaque;
    const HMENU = ?*anyopaque;
    const HDC = ?*anyopaque;
    const HGLRC = ?*anyopaque;
    const LPCWSTR = ?[*:0]const u16;
    const LPVOID = ?*anyopaque;
    const BOOL_TRUE: BOOL = 1;

    const RECT = extern struct {
        left: i32,
        top: i32,
        right: i32,
        bottom: i32,
    };

    const POINT = extern struct {
        x: i32,
        y: i32,
    };

    const MSG = extern struct {
        hwnd: HWND,
        message: UINT,
        wParam: WPARAM,
        lParam: LPARAM,
        time: DWORD,
        pt: POINT,
        lPrivate: DWORD,
    };

    const CREATESTRUCTW = extern struct {
        lpCreateParams: LPVOID,
        hInstance: HINSTANCE,
        hMenu: HMENU,
        hwndParent: HWND,
        cy: i32,
        cx: i32,
        y: i32,
        x: i32,
        style: i32,
        lpszName: LPCWSTR,
        lpszClass: LPCWSTR,
        dwExStyle: DWORD,
    };

    const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

    const WNDCLASSW = extern struct {
        style: UINT,
        lpfnWndProc: WNDPROC,
        cbClsExtra: i32,
        cbWndExtra: i32,
        hInstance: HINSTANCE,
        hIcon: HICON,
        hCursor: HCURSOR,
        hbrBackground: HBRUSH,
        lpszMenuName: LPCWSTR,
        lpszClassName: LPCWSTR,
    };

    pub extern "kernel32" fn GetModuleHandleW(lpModuleName: LPCWSTR) callconv(.winapi) HINSTANCE;
    pub extern "user32" fn RegisterClassW(lpWndClass: *const WNDCLASSW) callconv(.winapi) ATOM;
    pub extern "user32" fn UnregisterClassW(lpClassName: LPCWSTR, hInstance: HINSTANCE) callconv(.winapi) BOOL;
    pub extern "user32" fn CreateWindowExW(
        dwExStyle: DWORD,
        lpClassName: LPCWSTR,
        lpWindowName: LPCWSTR,
        dwStyle: DWORD,
        X: i32,
        Y: i32,
        nWidth: i32,
        nHeight: i32,
        hWndParent: HWND,
        hMenu: HMENU,
        hInstance: HINSTANCE,
        lpParam: LPVOID,
    ) callconv(.winapi) HWND;
    pub extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
    pub extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
    pub extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: i32) callconv(.winapi) BOOL;
    pub extern "user32" fn UpdateWindow(hWnd: HWND) callconv(.winapi) BOOL;
    pub extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.winapi) i32;
    pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
    pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
    pub extern "user32" fn PostMessageW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;
    pub extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(.winapi) void;
    pub extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: i32, dwNewLong: LONG_PTR) callconv(.winapi) LONG_PTR;
    pub extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: i32) callconv(.winapi) LONG_PTR;
    pub extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: LPCWSTR) callconv(.winapi) BOOL;
    pub extern "user32" fn InvalidateRect(hWnd: HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.winapi) BOOL;
    pub extern "user32" fn GetDC(hWnd: HWND) callconv(.winapi) HDC;
    pub extern "user32" fn ReleaseDC(hWnd: HWND, hDC: HDC) callconv(.winapi) i32;

    pub const CS_VREDRAW = 0x0001;
    pub const CS_HREDRAW = 0x0002;
    pub const CS_OWNDC = 0x0020;
    pub const WS_OVERLAPPED = 0x00000000;
    pub const WS_CAPTION = 0x00C00000;
    pub const WS_SYSMENU = 0x00080000;
    pub const WS_THICKFRAME = 0x00040000;
    pub const WS_MINIMIZEBOX = 0x00020000;
    pub const WS_MAXIMIZEBOX = 0x00010000;
    pub const WS_OVERLAPPEDWINDOW = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;
    pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
    pub const SW_SHOW = 5;
    pub const WM_NCCREATE = 0x0081;
    pub const WM_CLOSE = 0x0010;
    pub const WM_DESTROY = 0x0002;
    pub const WM_SIZE = 0x0005;
    pub const WM_SETFOCUS = 0x0007;
    pub const WM_KILLFOCUS = 0x0008;
    pub const WM_PAINT = 0x000F;
    pub const WM_CHAR = 0x0102;
    pub const WM_MOUSEMOVE = 0x0200;
    pub const WM_APP = 0x8000;
    pub const WM_GHOSTTY_WAKEUP = WM_APP + 1;
    pub const GWLP_USERDATA = -21;

    pub fn lowWord(value: LPARAM) u16 {
        return @truncate(@as(usize, @bitCast(value)));
    }

    pub fn highWord(value: LPARAM) u16 {
        return @truncate(@as(usize, @bitCast(value)) >> 16);
    }

    pub fn signedLowWord(value: LPARAM) i16 {
        return @bitCast(lowWord(value));
    }

    pub fn signedHighWord(value: LPARAM) i16 {
        return @bitCast(highWord(value));
    }
};

pub const App = struct {
    core_app: *CoreApp,
    config: configpkg.Config,
    ci_smoke_enabled: bool,
    ci_smoke_window_ready_logged: bool = false,
    ci_smoke_software_frame_ready_logged: bool = false,
    ci_smoke_present_ok_logged: bool = false,
    hinstance: win.HINSTANCE,
    class_name: [:0]const u16,
    title: [:0]const u16,
    window: ?Window = null,
    surface: ?*Surface = null,

    pub fn init(self: *App, core_app: *CoreApp, opts: struct {}) !void {
        _ = opts;

        self.* = .{
            .core_app = core_app,
            .config = .{},
            .ci_smoke_enabled = ciSmokeEnabled(),
            .hinstance = win.GetModuleHandleW(null),
            .class_name = try std.unicode.utf8ToUtf16LeAllocZ(core_app.alloc, "GhosttyWin32Runtime"),
            .title = try std.unicode.utf8ToUtf16LeAllocZ(core_app.alloc, "Ghostty Windows Runtime Scaffold"),
        };
        errdefer core_app.alloc.free(self.class_name);
        errdefer core_app.alloc.free(self.title);

        self.config = try configpkg.Config.load(core_app.alloc);
        errdefer self.config.deinit();

        try self.registerWindowClass();
    }

    pub fn run(self: *App) !void {
        try self.ensureWindow();

        var msg: win.MSG = undefined;
        while (true) {
            const status = win.GetMessageW(&msg, null, 0, 0);
            if (status == -1) return error.Unexpected;
            if (status == 0) break;
            _ = win.TranslateMessage(&msg);
            _ = win.DispatchMessageW(&msg);
            try self.core_app.tick(self);
        }
    }

    pub fn terminate(self: *App) void {
        if (self.surface) |surface| {
            surface.deinit();
            self.core_app.alloc.destroy(surface);
            self.surface = null;
        }
        if (self.window) |*window| {
            if (window.hwnd != null) _ = win.DestroyWindow(window.hwnd);
            self.window = null;
        }
        _ = win.UnregisterClassW(self.class_name.ptr, self.hinstance);
        self.config.deinit();
        self.core_app.alloc.free(self.title);
        self.core_app.alloc.free(self.class_name);
    }

    pub fn wakeup(self: *App) void {
        if (self.window) |window| {
            _ = win.PostMessageW(window.hwnd, win.WM_GHOSTTY_WAKEUP, 0, 0);
        }
    }

    pub fn keyboardLayout(self: *const App) input.KeyboardLayout {
        _ = self;
        return .unknown;
    }

    pub fn performAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        _ = target;

        return switch (action) {
            .quit => blk: {
                if (self.window) |window| _ = win.PostMessageW(window.hwnd, win.WM_CLOSE, 0, 0);
                break :blk true;
            },
            .new_window => blk: {
                try self.ensureWindow();
                break :blk true;
            },
            .render => blk: {
                if (self.window) |window| _ = win.InvalidateRect(window.hwnd, null, 0);
                break :blk true;
            },
            .set_title => blk: {
                if (self.surface) |surface| try surface.setTitle(value.title);
                break :blk true;
            },
            .cell_size,
            .size_limit,
            .config_change,
            => true,
            .open_config => false,
            .quit_timer => true,
            else => false,
        };
    }

    pub fn performIpc(
        _: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        _: apprt.ipc.Action.Value(action),
    ) !bool {
        return false;
    }

    fn registerWindowClass(self: *App) !void {
        const klass: win.WNDCLASSW = .{
            .style = win.CS_HREDRAW | win.CS_VREDRAW | win.CS_OWNDC,
            .lpfnWndProc = windowProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = self.hinstance,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = self.class_name.ptr,
        };

        if (win.RegisterClassW(&klass) == 0) return error.Unexpected;
    }

    fn ensureWindow(self: *App) !void {
        if (self.window != null) return;

        const hwnd = win.CreateWindowExW(
            0,
            self.class_name.ptr,
            self.title.ptr,
            win.WS_OVERLAPPEDWINDOW,
            win.CW_USEDEFAULT,
            win.CW_USEDEFAULT,
            1280,
            800,
            null,
            null,
            self.hinstance,
            self,
        );
        if (hwnd == null) return error.Unexpected;
        errdefer _ = win.DestroyWindow(hwnd);

        self.window = .{
            .hwnd = hwnd,
            .hdc = win.GetDC(hwnd),
        };
        if (self.window.?.hdc == null) return error.Unexpected;
        errdefer {
            if (self.window) |window| {
                if (window.hdc != null) _ = win.ReleaseDC(hwnd, window.hdc);
            }
            self.window = null;
        }

        const surface = try self.core_app.alloc.create(Surface);
        errdefer self.core_app.alloc.destroy(surface);
        surface.* = .{};
        try surface.init(self, hwnd, 1280, 800);
        self.surface = surface;

        _ = win.ShowWindow(hwnd, win.SW_SHOW);
        _ = win.UpdateWindow(hwnd);
        if (self.ci_smoke_enabled and !self.ci_smoke_window_ready_logged) {
            self.ci_smoke_window_ready_logged = true;
            log.info("ci.win32.window_ready", .{});
        }
    }

    fn handleMessage(
        self: *App,
        hwnd: win.HWND,
        msg: win.UINT,
        w_param: win.WPARAM,
        l_param: win.LPARAM,
    ) win.LRESULT {
        return switch (msg) {
            win.WM_CLOSE => blk: {
                _ = win.DestroyWindow(hwnd);
                break :blk 0;
            },
            win.WM_DESTROY => blk: {
                if (self.window) |window| {
                    if (window.hdc != null) _ = win.ReleaseDC(hwnd, window.hdc);
                }
                win.PostQuitMessage(0);
                break :blk 0;
            },
            win.WM_SIZE => blk: {
                if (self.surface) |surface| surface.updateSize(
                    @intCast(win.lowWord(l_param)),
                    @intCast(win.highWord(l_param)),
                );
                break :blk 0;
            },
            win.WM_SETFOCUS => blk: {
                if (self.surface) |surface| surface.updateFocus(true);
                break :blk 0;
            },
            win.WM_KILLFOCUS => blk: {
                if (self.surface) |surface| surface.updateFocus(false);
                break :blk 0;
            },
            win.WM_MOUSEMOVE => blk: {
                if (self.surface) |surface| surface.updateCursorPos(
                    @floatFromInt(win.signedLowWord(l_param)),
                    @floatFromInt(win.signedHighWord(l_param)),
                );
                break :blk 0;
            },
            win.WM_CHAR => blk: {
                if (self.surface) |surface| surface.cacheLastChar(@intCast(w_param));
                break :blk 0;
            },
            win.WM_PAINT => blk: {
                var ps: winos.c.PAINTSTRUCT = std.mem.zeroes(winos.c.PAINTSTRUCT);
                _ = winos.c.BeginPaint(@ptrFromInt(@intFromPtr(hwnd.?)), &ps);
                defer _ = winos.c.EndPaint(@ptrFromInt(@intFromPtr(hwnd.?)), &ps);

                if (self.surface) |surface| surface.markDirty();
                break :blk 0;
            },
            win.WM_GHOSTTY_WAKEUP => blk: {
                self.core_app.tick(self) catch |err| {
                    log.err("error ticking core app err={}", .{err});
                };
                break :blk 0;
            },
            else => win.DefWindowProcW(hwnd, msg, w_param, l_param),
        };
    }

    fn fromWindow(hwnd: win.HWND) ?*App {
        const ptr = win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA);
        if (ptr == 0) return null;
        return @ptrFromInt(@as(usize, @intCast(ptr)));
    }

    fn windowProc(
        hwnd: win.HWND,
        msg: win.UINT,
        w_param: win.WPARAM,
        l_param: win.LPARAM,
    ) callconv(.winapi) win.LRESULT {
        if (msg == win.WM_NCCREATE) {
            const create_struct: *const win.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(l_param)));
            const app: *App = @ptrFromInt(@intFromPtr(create_struct.lpCreateParams.?));
            _ = win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, @intCast(@intFromPtr(app)));
        }

        const app = fromWindow(hwnd) orelse return win.DefWindowProcW(hwnd, msg, w_param, l_param);
        return app.handleMessage(hwnd, msg, w_param, l_param);
    }

    const Window = struct {
        hwnd: win.HWND,
        hdc: win.HDC,
    };
};

pub const Surface = struct {
    app: *App = undefined,
    hwnd: win.HWND = null,
    core_surface: ?*CoreSurface = null,
    title: ?[:0]const u8 = null,
    content_scale: apprt.ContentScale = .{ .x = 1, .y = 1 },
    size: apprt.SurfaceSize = .{ .width = 0, .height = 0 },
    cursor_pos: apprt.CursorPos = .{ .x = -1, .y = -1 },
    focused: bool = false,
    dirty: bool = true,
    last_text_input: [4]u8 = .{ 0, 0, 0, 0 },
    last_text_input_len: u8 = 0,
    graphics: GraphicsState = .{},

    pub const GraphicsState = struct {
        d3d12_device: ?*winos.graphics.ID3D12Device = null,
        dxgi_factory: ?*winos.graphics.IDXGIFactory4 = null,
        command_queue: ?*winos.graphics.ID3D12CommandQueue = null,
        command_allocator: ?*anyopaque = null,
        command_list: ?*anyopaque = null,
        swap_chain: ?*winos.graphics.IDXGISwapChain3 = null,
        rtv_heap: ?*winos.graphics.ID3D12DescriptorHeap = null,
        srv_heap: ?*winos.graphics.ID3D12DescriptorHeap = null,
        backbuffers: [swap_chain_buffer_count]?*anyopaque = .{null} ** swap_chain_buffer_count,
        rtv_descriptor_size: u32 = 0,
        rtv_heap_start_ptr: u64 = 0,
        software_upload: ?*anyopaque = null,
        software_upload_capacity: u64 = 0,
        software_upload_row_pitch: u32 = 0,
        fence: ?*winos.graphics.ID3D12Fence = null,
        fence_event: ?winos.HANDLE = null,
        fence_value: u64 = 0,
        dwrite_factory: ?*winos.graphics.IDWriteFactory = null,
        frame_index: u32 = 0,
        last_present_generation: u64 = 0,
    };

    pub fn init(self: *Surface, app: *App, hwnd: win.HWND, width: u32, height: u32) !void {
        self.* = .{
            .app = app,
            .hwnd = hwnd,
            .size = .{ .width = width, .height = height },
        };
        try self.initGraphics();
        errdefer self.deinitGraphics();

        try app.core_app.addSurface(self);
        errdefer app.core_app.deleteSurface(self);

        const core_surface = try app.core_app.alloc.create(CoreSurface);
        errdefer app.core_app.alloc.destroy(core_surface);

        try core_surface.init(
            app.core_app.alloc,
            &app.config,
            app.core_app,
            app,
            self,
        );
        errdefer core_surface.deinit();

        self.core_surface = core_surface;
    }

    pub fn deinit(self: *Surface) void {
        if (self.title) |title| self.app.core_app.alloc.free(title);
        if (self.core_surface) |core_surface| {
            self.app.core_app.deleteSurface(self);
            core_surface.deinit();
            self.app.core_app.alloc.destroy(core_surface);
        }
        self.deinitGraphics();
        self.* = undefined;
    }

    fn deinitGraphics(self: *Surface) void {
        self.waitForGpuIdle() catch |err| {
            log.warn("error waiting for D3D12 idle during teardown err={}", .{err});
        };
        self.destroyBackbuffers();
        winos.graphics.release(self.graphics.command_list);
        self.graphics.command_list = null;
        winos.graphics.release(self.graphics.command_allocator);
        self.graphics.command_allocator = null;
        winos.graphics.release(self.graphics.software_upload);
        self.graphics.software_upload = null;
        winos.graphics.release(@ptrCast(self.graphics.swap_chain));
        self.graphics.swap_chain = null;
        winos.graphics.release(@ptrCast(self.graphics.command_queue));
        self.graphics.command_queue = null;
        winos.graphics.release(@ptrCast(self.graphics.rtv_heap));
        self.graphics.rtv_heap = null;
        winos.graphics.release(@ptrCast(self.graphics.srv_heap));
        self.graphics.srv_heap = null;
        winos.graphics.release(@ptrCast(self.graphics.fence));
        self.graphics.fence = null;
        if (self.graphics.fence_event != null) {
            _ = winos.CloseHandle(self.graphics.fence_event.?);
            self.graphics.fence_event = null;
        }
        winos.graphics.release(@ptrCast(self.graphics.d3d12_device));
        self.graphics.d3d12_device = null;
        winos.graphics.release(@ptrCast(self.graphics.dxgi_factory));
        self.graphics.dxgi_factory = null;
        winos.graphics.release(@ptrCast(self.graphics.dwrite_factory));
        self.graphics.dwrite_factory = null;
        self.graphics.rtv_descriptor_size = 0;
        self.graphics.rtv_heap_start_ptr = 0;
        self.graphics.software_upload_capacity = 0;
        self.graphics.software_upload_row_pitch = 0;
        self.graphics.fence_value = 0;
        self.graphics.frame_index = 0;
    }

    fn initGraphics(self: *Surface) !void {
        if (comptime @import("builtin").target.os.tag != .windows) return;

        var raw_factory: ?*anyopaque = null;
        if (winos.graphics.CreateDXGIFactory1(
            &winos.graphics.IID_IDXGIFactory4,
            &raw_factory,
        ) != winos.S_OK) return error.Unexpected;
        self.graphics.dxgi_factory = @ptrCast(raw_factory.?);

        var raw_device: ?*anyopaque = null;
        if (winos.graphics.D3D12CreateDevice(
            null,
            .@"11_0",
            &winos.graphics.IID_ID3D12Device,
            &raw_device,
        ) != winos.S_OK) return error.Unexpected;
        self.graphics.d3d12_device = @ptrCast(raw_device.?);

        var raw_dwrite: ?*winos.graphics.IUnknown = null;
        if (winos.graphics.DWriteCreateFactory(
            .shared,
            &winos.graphics.IID_IDWriteFactory,
            &raw_dwrite,
        ) == winos.S_OK and raw_dwrite != null) {
            self.graphics.dwrite_factory = @ptrCast(raw_dwrite);
        }

        var queue_desc: winos.c.D3D12_COMMAND_QUEUE_DESC = std.mem.zeroes(winos.c.D3D12_COMMAND_QUEUE_DESC);
        queue_desc.Type = winos.c.D3D12_COMMAND_LIST_TYPE_DIRECT;
        queue_desc.Flags = winos.c.D3D12_COMMAND_QUEUE_FLAG_NONE;
        queue_desc.Priority = 0;
        queue_desc.NodeMask = 0;

        const device: *winos.c.ID3D12Device = @ptrFromInt(@intFromPtr(self.graphics.d3d12_device.?));

        var raw_queue: ?*anyopaque = null;
        if (device.lpVtbl[0].CreateCommandQueue.?(
            device,
            &queue_desc,
            &winos.c.IID_ID3D12CommandQueue,
            &raw_queue,
        ) != winos.S_OK) return error.Unexpected;
        self.graphics.command_queue = @ptrCast(raw_queue.?);

        var swap_chain_desc: winos.c.DXGI_SWAP_CHAIN_DESC1 = std.mem.zeroes(winos.c.DXGI_SWAP_CHAIN_DESC1);
        swap_chain_desc.Width = self.size.width;
        swap_chain_desc.Height = self.size.height;
        swap_chain_desc.Format = winos.c.DXGI_FORMAT_B8G8R8A8_UNORM;
        swap_chain_desc.Stereo = winos.FALSE;
        swap_chain_desc.SampleDesc = .{ .Count = 1, .Quality = 0 };
        swap_chain_desc.BufferUsage = winos.c.DXGI_USAGE_RENDER_TARGET_OUTPUT;
        swap_chain_desc.BufferCount = 2;
        swap_chain_desc.Scaling = winos.c.DXGI_SCALING_STRETCH;
        swap_chain_desc.SwapEffect = winos.c.DXGI_SWAP_EFFECT_FLIP_DISCARD;
        swap_chain_desc.AlphaMode = winos.c.DXGI_ALPHA_MODE_IGNORE;
        swap_chain_desc.Flags = 0;

        const factory: *winos.c.IDXGIFactory4 = @ptrFromInt(@intFromPtr(self.graphics.dxgi_factory.?));
        const command_queue: *winos.c.ID3D12CommandQueue = @ptrFromInt(@intFromPtr(self.graphics.command_queue.?));

        var swap_chain1: ?*winos.c.IDXGISwapChain1 = null;
        if (factory.lpVtbl[0].CreateSwapChainForHwnd.?(
            factory,
            @ptrFromInt(@intFromPtr(command_queue)),
            @ptrFromInt(@intFromPtr(self.hwnd.?)),
            &swap_chain_desc,
            null,
            null,
            &swap_chain1,
        ) != winos.S_OK) return error.Unexpected;

        var raw_swap_chain3: ?*anyopaque = null;
        if (swap_chain1.?.lpVtbl[0].QueryInterface.?(
            @ptrCast(swap_chain1.?),
            &winos.c.IID_IDXGISwapChain3,
            &raw_swap_chain3,
        ) != winos.S_OK) return error.Unexpected;
        self.graphics.swap_chain = @ptrCast(raw_swap_chain3.?);
        const swap_chain3: *winos.c.IDXGISwapChain3 = @ptrFromInt(@intFromPtr(self.graphics.swap_chain.?));
        self.graphics.frame_index = swap_chain3.lpVtbl[0].GetCurrentBackBufferIndex.?(swap_chain3);
        winos.graphics.release(@ptrCast(swap_chain1));

        var rtv_heap_desc: winos.c.D3D12_DESCRIPTOR_HEAP_DESC = std.mem.zeroes(winos.c.D3D12_DESCRIPTOR_HEAP_DESC);
        rtv_heap_desc.Type = winos.c.D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
        rtv_heap_desc.NumDescriptors = 2;
        rtv_heap_desc.Flags = winos.c.D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
        rtv_heap_desc.NodeMask = 0;

        var raw_rtv_heap: ?*anyopaque = null;
        if (device.lpVtbl[0].CreateDescriptorHeap.?(
            device,
            &rtv_heap_desc,
            &winos.c.IID_ID3D12DescriptorHeap,
            &raw_rtv_heap,
        ) != winos.S_OK) return error.Unexpected;
        self.graphics.rtv_heap = @ptrCast(raw_rtv_heap.?);
        self.graphics.rtv_descriptor_size = device.lpVtbl[0].GetDescriptorHandleIncrementSize.?(device, winos.c.D3D12_DESCRIPTOR_HEAP_TYPE_RTV);

        var raw_command_allocator: ?*anyopaque = null;
        if (device.lpVtbl[0].CreateCommandAllocator.?(
            device,
            winos.c.D3D12_COMMAND_LIST_TYPE_DIRECT,
            &winos.c.IID_ID3D12CommandAllocator,
            &raw_command_allocator,
        ) != winos.S_OK) return error.Unexpected;
        self.graphics.command_allocator = raw_command_allocator.?;

        const command_allocator: *winos.c.ID3D12CommandAllocator = @ptrFromInt(@intFromPtr(self.graphics.command_allocator.?));

        var raw_command_list: ?*anyopaque = null;
        if (device.lpVtbl[0].CreateCommandList.?(
            device,
            0,
            winos.c.D3D12_COMMAND_LIST_TYPE_DIRECT,
            command_allocator,
            null,
            &winos.c.IID_ID3D12GraphicsCommandList,
            &raw_command_list,
        ) != winos.S_OK) return error.Unexpected;
        self.graphics.command_list = raw_command_list.?;

        const command_list: *winos.c.ID3D12GraphicsCommandList = @ptrFromInt(@intFromPtr(self.graphics.command_list.?));
        if (command_list.lpVtbl[0].Close.?(command_list) != winos.S_OK) return error.Unexpected;

        var raw_fence: ?*anyopaque = null;
        if (device.lpVtbl[0].CreateFence.?(
            device,
            0,
            winos.c.D3D12_FENCE_FLAG_NONE,
            &winos.c.IID_ID3D12Fence,
            &raw_fence,
        ) != winos.S_OK) return error.Unexpected;
        self.graphics.fence = @ptrCast(raw_fence.?);
        self.graphics.fence_value = 0;
        self.graphics.fence_event = winos.c.CreateEventW(null, winos.FALSE, winos.FALSE, null);
        if (self.graphics.fence_event == null) return error.Unexpected;

        try self.createBackbuffers();
    }

    pub fn core(self: *Surface) *CoreSurface {
        return if (self.core_surface) |core_surface|
            core_surface
        else
            @panic("win32 surface core is not initialized yet");
    }

    pub fn rtApp(self: *const Surface) *App {
        return self.app;
    }

    pub fn close(self: *const Surface, process_active: bool) void {
        _ = process_active;
        if (self.hwnd != null) _ = win.DestroyWindow(self.hwnd);
    }

    pub fn getTitle(self: *Surface) ?[:0]const u8 {
        return self.title;
    }

    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        return self.content_scale;
    }

    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        return self.size;
    }

    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        return self.cursor_pos;
    }

    pub fn supportsClipboard(self: *const Surface, clipboard_type: apprt.Clipboard) bool {
        _ = self;
        return clipboard_type == .standard;
    }

    pub fn clipboardRequest(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) !bool {
        _ = self;
        _ = clipboard_type;
        _ = state;
        return false;
    }

    pub fn setClipboard(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        contents: []const apprt.ClipboardContent,
        confirm: bool,
    ) !void {
        _ = self;
        _ = clipboard_type;
        _ = contents;
        _ = confirm;
    }

    pub fn defaultTermioEnv(self: *Surface) !std.process.EnvMap {
        return try internal_os.getEnvMap(self.app.core_app.alloc);
    }

    pub fn softwareFrameReady(
        self: *Surface,
        frame: apprt.surface.Message.SoftwareFrameReady,
    ) !void {
        defer frame.release();

        try validateSoftwareFramePayload(frame);
        validateSoftwareFrameDamageMetadata(frame) catch |err| {
            log.warn("software frame damage metadata rejected err={}", .{err});
        };

        if (frame.generation <= self.graphics.last_present_generation) return;
        if (frame.storage != .shared_cpu_bytes) return error.InvalidSoftwareFrame;

        if (self.app.ci_smoke_enabled and !self.app.ci_smoke_software_frame_ready_logged) {
            self.app.ci_smoke_software_frame_ready_logged = true;
            log.info("ci.win32.software_frame_ready", .{});
        }

        if (frame.width_px != self.size.width or frame.height_px != self.size.height) {
            self.size = .{
                .width = frame.width_px,
                .height = frame.height_px,
            };
            try self.resizeSwapChain(frame.width_px, frame.height_px);
        }

        const required_len = try softwareFrameRequiredLen(frame);
        const shared_bytes = try softwareFrameSharedBytes(frame, required_len);
        try self.presentSoftwareFrame(frame, shared_bytes);
    }

    pub fn prepareNativePresent(self: *Surface) !void {
        try self.recordNativeClear();
    }

    pub fn finishNativePresent(self: *Surface) !void {
        try self.waitForGpuIdle();
        if (self.graphics.swap_chain) |swap_chain| {
            const sc: *winos.c.IDXGISwapChain3 =
                nativePtr(*winos.c.IDXGISwapChain3, swap_chain);
            self.graphics.frame_index = sc.lpVtbl[0].GetCurrentBackBufferIndex.?(sc);
        }
    }

    fn setTitle(self: *Surface, title: []const u8) !void {
        if (self.title) |existing| self.app.core_app.alloc.free(existing);
        self.title = try self.app.core_app.alloc.dupeZ(u8, title);

        const title_w = try std.unicode.utf8ToUtf16LeAllocZ(
            self.app.core_app.alloc,
            title,
        );
        defer self.app.core_app.alloc.free(title_w);
        _ = win.SetWindowTextW(self.hwnd, title_w.ptr);
    }

    fn updateSize(self: *Surface, width: u32, height: u32) void {
        self.size = .{ .width = width, .height = height };
        self.dirty = true;
        if (width != 0 and height != 0) {
            self.resizeSwapChain(width, height) catch |err| {
                log.err("error resizing D3D12 swapchain err={}", .{err});
            };
        }
        if (self.core_surface) |core_surface| {
            core_surface.sizeCallback(self.size) catch |err| {
                log.err("error in win32 size callback err={}", .{err});
            };
        }
    }

    fn updateFocus(self: *Surface, focused: bool) void {
        self.focused = focused;
        if (self.core_surface) |core_surface| {
            core_surface.focusCallback(focused) catch |err| {
                log.err("error in win32 focus callback err={}", .{err});
            };
        }
    }

    fn updateCursorPos(self: *Surface, x: f32, y: f32) void {
        self.cursor_pos = .{ .x = x, .y = y };
        if (self.core_surface) |core_surface| {
            core_surface.cursorPosCallback(self.cursor_pos, null) catch |err| {
                log.err("error in win32 cursor callback err={}", .{err});
            };
        }
    }

    fn cacheLastChar(self: *Surface, codepoint: u32) void {
        var buf: [4]u8 = undefined;
        const cp = std.math.cast(u21, codepoint) orelse return;
        const len = std.unicode.utf8Encode(cp, &buf) catch return;
        @memset(&self.last_text_input, 0);
        @memcpy(self.last_text_input[0..len], buf[0..len]);
        self.last_text_input_len = @intCast(len);
        if (self.core_surface) |core_surface| {
            core_surface.textCallback(self.last_text_input[0..len]) catch |err| {
                log.err("error in win32 text callback err={}", .{err});
            };
        }
    }

    fn markDirty(self: *Surface) void {
        self.dirty = true;
        if (self.core_surface) |core_surface| {
            core_surface.refreshCallback() catch |err| {
                log.err("error in win32 refresh callback err={}", .{err});
                return;
            };
            core_surface.draw() catch |err| {
                log.err("error in win32 draw err={}", .{err});
            };
        }
    }

    fn resizeSwapChain(self: *Surface, width: u32, height: u32) !void {
        if (self.graphics.swap_chain == null or width == 0 or height == 0) return;

        try self.waitForGpuIdle();
        self.destroyBackbuffers();

        const sc: *winos.c.IDXGISwapChain3 =
            nativePtr(*winos.c.IDXGISwapChain3, self.graphics.swap_chain.?);
        if (sc.lpVtbl[0].ResizeBuffers.?(
            sc,
            swap_chain_buffer_count,
            width,
            height,
            winos.c.DXGI_FORMAT_B8G8R8A8_UNORM,
            0,
        ) != winos.S_OK) return error.Unexpected;

        self.graphics.frame_index = sc.lpVtbl[0].GetCurrentBackBufferIndex.?(sc);
        try self.createBackbuffers();
    }

    fn createBackbuffers(self: *Surface) !void {
        if (self.graphics.swap_chain == null or self.graphics.rtv_heap == null) return;

        const device: *winos.c.ID3D12Device =
            nativePtr(*winos.c.ID3D12Device, self.graphics.d3d12_device.?);
        const heap: *winos.c.ID3D12DescriptorHeap =
            nativePtr(*winos.c.ID3D12DescriptorHeap, self.graphics.rtv_heap.?);
        const sc: *winos.c.IDXGISwapChain3 =
            nativePtr(*winos.c.IDXGISwapChain3, self.graphics.swap_chain.?);

        var handle: winos.c.D3D12_CPU_DESCRIPTOR_HANDLE = std.mem.zeroes(winos.c.D3D12_CPU_DESCRIPTOR_HANDLE);
        _ = heap.lpVtbl[0].GetCPUDescriptorHandleForHeapStart.?(heap, &handle);
        self.graphics.rtv_heap_start_ptr = handle.ptr;

        for (0..swap_chain_buffer_count) |i| {
            var raw_resource: ?*anyopaque = null;
            if (sc.lpVtbl[0].GetBuffer.?(
                sc,
                @intCast(i),
                &winos.c.IID_ID3D12Resource,
                &raw_resource,
            ) != winos.S_OK) return error.Unexpected;

            self.graphics.backbuffers[i] = raw_resource.?;
            const resource: *winos.c.ID3D12Resource =
                nativePtr(*winos.c.ID3D12Resource, raw_resource.?);
            const rtv_handle = self.rtvHandleForIndex(i);
            device.lpVtbl[0].CreateRenderTargetView.?(
                device,
                resource,
                null,
                rtv_handle,
            );
        }
    }

    fn destroyBackbuffers(self: *Surface) void {
        for (&self.graphics.backbuffers) |*backbuffer| {
            winos.graphics.release(backbuffer.*);
            backbuffer.* = null;
        }
    }

    fn recordNativeClear(self: *Surface) !void {
        if (self.size.width == 0 or self.size.height == 0) return;
        if (self.graphics.command_allocator == null or
            self.graphics.command_list == null or
            self.graphics.command_queue == null or
            self.graphics.swap_chain == null)
        {
            return;
        }

        const allocator: *winos.c.ID3D12CommandAllocator =
            nativePtr(*winos.c.ID3D12CommandAllocator, self.graphics.command_allocator.?);
        const command_list: *winos.c.ID3D12GraphicsCommandList =
            nativePtr(*winos.c.ID3D12GraphicsCommandList, self.graphics.command_list.?);
        const queue: *winos.c.ID3D12CommandQueue =
            nativePtr(*winos.c.ID3D12CommandQueue, self.graphics.command_queue.?);
        const backbuffer = self.currentBackbufferResource() orelse return error.Unexpected;

        if (allocator.lpVtbl[0].Reset.?(allocator) != winos.S_OK) return error.Unexpected;
        if (command_list.lpVtbl[0].Reset.?(
            command_list,
            allocator,
            null,
        ) != winos.S_OK) return error.Unexpected;

        var barrier = transitionBarrier(
            backbuffer,
            winos.c.D3D12_RESOURCE_STATE_PRESENT,
            winos.c.D3D12_RESOURCE_STATE_RENDER_TARGET,
        );
        command_list.lpVtbl[0].ResourceBarrier.?(
            command_list,
            1,
            &barrier,
        );

        var rtv_handle = self.rtvHandleForIndex(self.graphics.frame_index);
        command_list.lpVtbl[0].OMSetRenderTargets.?(
            command_list,
            1,
            &rtv_handle,
            winos.FALSE,
            null,
        );

        const clear_color = self.nativeClearColor();
        command_list.lpVtbl[0].ClearRenderTargetView.?(
            command_list,
            rtv_handle,
            &clear_color,
            0,
            null,
        );

        barrier = transitionBarrier(
            backbuffer,
            winos.c.D3D12_RESOURCE_STATE_RENDER_TARGET,
            winos.c.D3D12_RESOURCE_STATE_PRESENT,
        );
        command_list.lpVtbl[0].ResourceBarrier.?(
            command_list,
            1,
            &barrier,
        );

        if (command_list.lpVtbl[0].Close.?(command_list) != winos.S_OK) return error.Unexpected;

        const command_lists = [_][*c]winos.c.ID3D12CommandList{
            @ptrCast(command_list),
        };
        queue.lpVtbl[0].ExecuteCommandLists.?(
            queue,
            1,
            @ptrCast(&command_lists),
        );
    }

    fn waitForGpuIdle(self: *Surface) !void {
        if (self.graphics.command_queue == null or
            self.graphics.fence == null or
            self.graphics.fence_event == null)
        {
            return;
        }

        const queue: *winos.c.ID3D12CommandQueue =
            nativePtr(*winos.c.ID3D12CommandQueue, self.graphics.command_queue.?);
        const fence: *winos.c.ID3D12Fence =
            nativePtr(*winos.c.ID3D12Fence, self.graphics.fence.?);

        self.graphics.fence_value += 1;
        const wait_value = self.graphics.fence_value;
        if (queue.lpVtbl[0].Signal.?(
            queue,
            fence,
            wait_value,
        ) != winos.S_OK) return error.Unexpected;

        if (fence.lpVtbl[0].GetCompletedValue.?(fence) < wait_value) {
            if (fence.lpVtbl[0].SetEventOnCompletion.?(
                fence,
                wait_value,
                self.graphics.fence_event.?,
            ) != winos.S_OK) return error.Unexpected;
            if (winos.c.WaitForSingleObject(self.graphics.fence_event.?, winos.INFINITE) == winos.WAIT_FAILED)
                return error.Unexpected;
        }
    }

    fn currentBackbufferResource(self: *Surface) ?*winos.c.ID3D12Resource {
        const index: usize = @intCast(self.graphics.frame_index);
        if (index >= self.graphics.backbuffers.len) return null;
        return if (self.graphics.backbuffers[index]) |backbuffer|
            nativePtr(*winos.c.ID3D12Resource, backbuffer)
        else
            null;
    }

    fn rtvHandleForIndex(self: *Surface, index: usize) winos.c.D3D12_CPU_DESCRIPTOR_HANDLE {
        return .{
            .ptr = self.graphics.rtv_heap_start_ptr +
                (@as(u64, @intCast(index)) * @as(u64, self.graphics.rtv_descriptor_size)),
        };
    }

    fn nativeClearColor(self: *const Surface) [4]f32 {
        const bg = self.app.config.background;
        return .{
            @as(f32, @floatFromInt(bg.r)) / 255.0,
            @as(f32, @floatFromInt(bg.g)) / 255.0,
            @as(f32, @floatFromInt(bg.b)) / 255.0,
            1.0,
        };
    }

    fn transitionBarrier(
        resource: *winos.c.ID3D12Resource,
        before: winos.c.D3D12_RESOURCE_STATES,
        after: winos.c.D3D12_RESOURCE_STATES,
    ) winos.c.D3D12_RESOURCE_BARRIER {
        return .{
            .Type = winos.c.D3D12_RESOURCE_BARRIER_TYPE_TRANSITION,
            .Flags = winos.c.D3D12_RESOURCE_BARRIER_FLAG_NONE,
            .unnamed_0 = .{
                .Transition = .{
                    .pResource = nativePtr([*c]winos.c.ID3D12Resource, resource),
                    .Subresource = winos.c.D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
                    .StateBefore = before,
                    .StateAfter = after,
                },
            },
        };
    }

    fn validateSoftwareFramePayload(
        frame: apprt.surface.Message.SoftwareFrameReady,
    ) error{InvalidSoftwareFrame}!void {
        const required_len = try softwareFrameRequiredLen(frame);
        switch (frame.storage) {
            .shared_cpu_bytes => {
                _ = try softwareFrameSharedBytes(frame, required_len);
            },
            .native_texture_handle => {
                if (frame.handle == null) return error.InvalidSoftwareFrame;
            },
        }
    }

    fn softwareFrameBytesPerPixel(
        pixel_format: apprt.surface.Message.SoftwareFramePixelFormat,
    ) usize {
        _ = pixel_format;
        return 4;
    }

    fn softwareFrameRequiredLen(
        frame: apprt.surface.Message.SoftwareFrameReady,
    ) error{InvalidSoftwareFrame}!usize {
        if (frame.width_px == 0 or frame.height_px == 0) {
            return error.InvalidSoftwareFrame;
        }

        const width = std.math.cast(usize, frame.width_px) orelse return error.InvalidSoftwareFrame;
        const height = std.math.cast(usize, frame.height_px) orelse return error.InvalidSoftwareFrame;
        const stride = std.math.cast(usize, frame.stride_bytes) orelse return error.InvalidSoftwareFrame;
        if (stride == 0) return error.InvalidSoftwareFrame;

        const min_stride = std.math.mul(
            usize,
            width,
            softwareFrameBytesPerPixel(frame.pixel_format),
        ) catch return error.InvalidSoftwareFrame;
        if (stride < min_stride) return error.InvalidSoftwareFrame;

        return std.math.mul(
            usize,
            stride,
            height,
        ) catch return error.InvalidSoftwareFrame;
    }

    fn softwareFrameSharedBytes(
        frame: apprt.surface.Message.SoftwareFrameReady,
        required_len: usize,
    ) error{InvalidSoftwareFrame}![]const u8 {
        const data = frame.data orelse return error.InvalidSoftwareFrame;
        if (frame.data_len < required_len) return error.InvalidSoftwareFrame;
        return data[0..required_len];
    }

    fn validateSoftwareFrameDamageMetadata(
        frame: apprt.surface.Message.SoftwareFrameReady,
    ) error{InvalidSoftwareFrame}!void {
        if (frame.damage_rects_len == 0) return;

        const damage_rects = frame.damage_rects orelse return error.InvalidSoftwareFrame;
        const frame_w = @as(u64, frame.width_px);
        const frame_h = @as(u64, frame.height_px);
        for (damage_rects[0..frame.damage_rects_len]) |rect| {
            if (rect.width_px == 0 or rect.height_px == 0) {
                return error.InvalidSoftwareFrame;
            }
            if (rect.x_px >= frame.width_px or rect.y_px >= frame.height_px) {
                return error.InvalidSoftwareFrame;
            }
            const x1 = @as(u64, rect.x_px) + @as(u64, rect.width_px);
            const y1 = @as(u64, rect.y_px) + @as(u64, rect.height_px);
            if (x1 > frame_w or y1 > frame_h) {
                return error.InvalidSoftwareFrame;
            }
        }
    }

    fn presentSoftwareFrame(
        self: *Surface,
        frame: apprt.surface.Message.SoftwareFrameReady,
        shared_bytes: []const u8,
    ) !void {
        const upload = try self.ensureSoftwareUploadBuffer(frame.width_px, frame.height_px);
        try self.waitForGpuIdle();
        try self.copySoftwareFrameToUpload(frame, shared_bytes, upload);

        const allocator: *winos.c.ID3D12CommandAllocator =
            nativePtr(*winos.c.ID3D12CommandAllocator, self.graphics.command_allocator.?);
        const command_list: *winos.c.ID3D12GraphicsCommandList =
            nativePtr(*winos.c.ID3D12GraphicsCommandList, self.graphics.command_list.?);
        const queue: *winos.c.ID3D12CommandQueue =
            nativePtr(*winos.c.ID3D12CommandQueue, self.graphics.command_queue.?);
        const backbuffer = self.currentBackbufferResource() orelse return error.Unexpected;

        if (allocator.lpVtbl[0].Reset.?(allocator) != winos.S_OK) return error.Unexpected;
        if (command_list.lpVtbl[0].Reset.?(
            command_list,
            allocator,
            null,
        ) != winos.S_OK) return error.Unexpected;

        var barrier = transitionBarrier(
            backbuffer,
            winos.c.D3D12_RESOURCE_STATE_PRESENT,
            winos.c.D3D12_RESOURCE_STATE_COPY_DEST,
        );
        command_list.lpVtbl[0].ResourceBarrier.?(
            command_list,
            1,
            &barrier,
        );

        const src_location = self.softwareUploadCopyLocation(frame, upload);
        const dst_location: winos.c.D3D12_TEXTURE_COPY_LOCATION = .{
            .pResource = nativePtr([*c]winos.c.ID3D12Resource, backbuffer),
            .Type = winos.c.D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX,
            .unnamed_0 = .{ .SubresourceIndex = 0 },
        };
        command_list.lpVtbl[0].CopyTextureRegion.?(
            command_list,
            &dst_location,
            0,
            0,
            0,
            &src_location,
            null,
        );

        barrier = transitionBarrier(
            backbuffer,
            winos.c.D3D12_RESOURCE_STATE_COPY_DEST,
            winos.c.D3D12_RESOURCE_STATE_PRESENT,
        );
        command_list.lpVtbl[0].ResourceBarrier.?(
            command_list,
            1,
            &barrier,
        );

        if (command_list.lpVtbl[0].Close.?(command_list) != winos.S_OK) return error.Unexpected;

        const command_lists = [_][*c]winos.c.ID3D12CommandList{
            @ptrCast(command_list),
        };
        queue.lpVtbl[0].ExecuteCommandLists.?(
            queue,
            1,
            @ptrCast(&command_lists),
        );

        const sc: *winos.c.IDXGISwapChain3 =
            nativePtr(*winos.c.IDXGISwapChain3, self.graphics.swap_chain.?);
        if (sc.lpVtbl[0].Present.?(sc, 1, 0) != winos.S_OK) {
            return error.Unexpected;
        }
        if (self.app.ci_smoke_enabled and !self.app.ci_smoke_present_ok_logged) {
            self.app.ci_smoke_present_ok_logged = true;
            log.info("ci.win32.present_ok", .{});
        }

        try self.waitForGpuIdle();
        self.graphics.frame_index = sc.lpVtbl[0].GetCurrentBackBufferIndex.?(sc);
        self.graphics.last_present_generation = frame.generation;
    }

    fn ensureSoftwareUploadBuffer(
        self: *Surface,
        width_px: u32,
        height_px: u32,
    ) !*winos.c.ID3D12Resource {
        const row_pitch = alignedSoftwareRowPitch(width_px) catch return error.OutOfMemory;
        const upload_size = std.math.mul(
            u64,
            row_pitch,
            height_px,
        ) catch return error.OutOfMemory;

        if (self.graphics.software_upload) |resource| {
            if (self.graphics.software_upload_capacity >= upload_size and
                self.graphics.software_upload_row_pitch == row_pitch)
            {
                return nativePtr(*winos.c.ID3D12Resource, resource);
            }

            winos.graphics.release(resource);
            self.graphics.software_upload = null;
        }

        const device: *winos.c.ID3D12Device =
            nativePtr(*winos.c.ID3D12Device, self.graphics.d3d12_device.?);
        var heap_props: winos.c.D3D12_HEAP_PROPERTIES = std.mem.zeroes(winos.c.D3D12_HEAP_PROPERTIES);
        heap_props.Type = winos.c.D3D12_HEAP_TYPE_UPLOAD;
        heap_props.CreationNodeMask = 1;
        heap_props.VisibleNodeMask = 1;

        var desc: winos.c.D3D12_RESOURCE_DESC = std.mem.zeroes(winos.c.D3D12_RESOURCE_DESC);
        desc.Dimension = winos.c.D3D12_RESOURCE_DIMENSION_BUFFER;
        desc.Width = upload_size;
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
        ) != winos.S_OK) return error.Unexpected;

        self.graphics.software_upload = raw_resource.?;
        self.graphics.software_upload_capacity = upload_size;
        self.graphics.software_upload_row_pitch = row_pitch;
        return nativePtr(*winos.c.ID3D12Resource, raw_resource.?);
    }

    fn copySoftwareFrameToUpload(
        self: *Surface,
        frame: apprt.surface.Message.SoftwareFrameReady,
        shared_bytes: []const u8,
        resource: *winos.c.ID3D12Resource,
    ) !void {
        var mapped: ?*anyopaque = null;
        if (resource.lpVtbl[0].Map.?(
            resource,
            0,
            null,
            &mapped,
        ) != winos.S_OK) return error.Unexpected;
        defer resource.lpVtbl[0].Unmap.?(
            resource,
            0,
            null,
        );

        const dst: [*]u8 = @ptrCast(mapped.?);
        const src_stride: usize = @intCast(frame.stride_bytes);
        const dst_stride: usize = @intCast(self.graphics.software_upload_row_pitch);
        const copy_width = std.math.mul(
            usize,
            @as(usize, @intCast(frame.width_px)),
            4,
        ) catch return error.OutOfMemory;

        for (0..frame.height_px) |row| {
            const src_off = @as(usize, @intCast(row)) * src_stride;
            const dst_off = @as(usize, @intCast(row)) * dst_stride;
            const src_row = shared_bytes[src_off .. src_off + copy_width];
            const dst_row = dst[dst_off .. dst_off + dst_stride];
            switch (frame.pixel_format) {
                .bgra8_premul => {
                    @memcpy(dst_row[0..copy_width], src_row);
                },
                .rgba8_premul => {
                    var px: usize = 0;
                    while (px < copy_width) : (px += 4) {
                        dst_row[px + 0] = src_row[px + 2];
                        dst_row[px + 1] = src_row[px + 1];
                        dst_row[px + 2] = src_row[px + 0];
                        dst_row[px + 3] = src_row[px + 3];
                    }
                },
            }
            if (dst_stride > copy_width) {
                @memset(dst_row[copy_width..dst_stride], 0);
            }
        }
    }

    fn softwareUploadCopyLocation(
        self: *const Surface,
        frame: apprt.surface.Message.SoftwareFrameReady,
        resource: *winos.c.ID3D12Resource,
    ) winos.c.D3D12_TEXTURE_COPY_LOCATION {
        return .{
            .pResource = nativePtr([*c]winos.c.ID3D12Resource, resource),
            .Type = winos.c.D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT,
            .unnamed_0 = .{
                .PlacedFootprint = .{
                    .Offset = 0,
                    .Footprint = .{
                        .Format = winos.c.DXGI_FORMAT_B8G8R8A8_UNORM,
                        .Width = frame.width_px,
                        .Height = frame.height_px,
                        .Depth = 1,
                        .RowPitch = self.graphics.software_upload_row_pitch,
                    },
                },
            },
        };
    }

    fn alignedSoftwareRowPitch(width_px: u32) !u32 {
        const raw_pitch = std.math.mul(u32, width_px, 4) catch return error.OutOfMemory;
        const aligned = std.mem.alignForward(u32, raw_pitch, software_upload_row_pitch_alignment);
        return aligned;
    }
};
