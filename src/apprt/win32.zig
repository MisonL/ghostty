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
const terminal = @import("../terminal/main.zig");
const winos = internal_os.windows;

pub const resourcesDir = internal_os.resourcesDir;
pub const must_draw_from_app_thread = false;

const log = std.log.scoped(.win32_apprt);
const swap_chain_buffer_count: usize = 2;
const software_upload_row_pitch_alignment: u32 = 256;
const ipc_pipe_prefix = "\\\\.\\pipe\\ghostty-win32-";
var trace_win32_init_enabled: bool = false;

const CiSmokeMode = enum {
    disabled,
    native,
    core_draw,
};

fn ciSmokeMode() CiSmokeMode {
    const alloc = std.heap.page_allocator;
    const mode_value = std.process.getEnvVarOwned(alloc, "GHOSTTY_CI_WIN32_SMOKE_MODE") catch null;
    defer if (mode_value) |value| alloc.free(value);
    if (mode_value) |value| {
        if (std.ascii.eqlIgnoreCase(value, "core-draw")) return .core_draw;
        if (std.ascii.eqlIgnoreCase(value, "native")) return .native;
    }

    const value = std.process.getEnvVarOwned(alloc, "GHOSTTY_CI_WIN32_SMOKE") catch
        return .disabled;
    defer alloc.free(value);
    if (value.len == 0 or std.mem.eql(u8, value, "0")) return .disabled;
    if (std.ascii.eqlIgnoreCase(value, "core-draw")) return .core_draw;
    return .native;
}

fn shouldTraceWin32Init() bool {
    return trace_win32_init_enabled;
}

inline fn traceWin32InitStep(comptime step: []const u8) void {
    if (!shouldTraceWin32Init()) return;
    std.debug.print("info(win32_apprt): ci.win32.surface_init.step=" ++ step ++ "\n", .{});
}

fn traceWin32WindowProc(msg: win.UINT, step: []const u8) void {
    if (!shouldTraceWin32Init()) return;
    std.debug.print(
        "info(win32_apprt): ci.win32.window_proc.msg=0x{x} step={s}\n",
        .{ msg, step },
    );
}

fn shouldTraceHandledWin32Message(msg: win.UINT) bool {
    return switch (msg) {
        win.WM_SHOWWINDOW,
        win.WM_WINDOWPOSCHANGING,
        win.WM_WINDOWPOSCHANGED,
        win.WM_ACTIVATEAPP,
        win.WM_NCACTIVATE,
        win.WM_GETICON,
        win.WM_ACTIVATE,
        win.WM_IME_SETCONTEXT,
        win.WM_IME_NOTIFY,
        win.WM_SETFOCUS,
        win.WM_NCPAINT,
        win.WM_ERASEBKGND,
        => true,
        else => false,
    };
}

fn nativePtr(comptime T: type, raw: anytype) T {
    return @ptrFromInt(@intFromPtr(raw));
}

const win = struct {
    const UINT = u32;
    const DWORD = u32;
    const WORD = u16;
    const SHORT = i16;
    const LONG = i32;
    const BYTE = u8;
    const BOOL = i32;
    const INT = i32;
    const LPARAM = isize;
    const WPARAM = usize;
    const LRESULT = isize;
    const LONG_PTR = isize;
    const ATOM = u16;
    const HINSTANCE = ?*anyopaque;
    const HWND = ?windows.HWND;
    const HICON = ?*anyopaque;
    const HCURSOR = ?*anyopaque;
    const HBRUSH = ?*anyopaque;
    const HMENU = ?*anyopaque;
    const HDC = ?*anyopaque;
    const HMONITOR = ?*anyopaque;
    const HGLRC = ?*anyopaque;
    const HANDLE = ?*anyopaque;
    const HGLOBAL = ?*anyopaque;
    const HKL = ?*anyopaque;
    const HIMC = ?*anyopaque;
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

    const COMPOSITIONFORM = extern struct {
        dwStyle: DWORD,
        ptCurrentPos: POINT,
        rcArea: RECT,
    };

    const MONITORINFO = extern struct {
        cbSize: DWORD,
        rcMonitor: RECT,
        rcWork: RECT,
        dwFlags: DWORD,
    };

    const MINMAXINFO = extern struct {
        ptReserved: POINT,
        ptMaxSize: POINT,
        ptMaxPosition: POINT,
        ptMinTrackSize: POINT,
        ptMaxTrackSize: POINT,
    };

    pub extern "kernel32" fn GetModuleHandleW(lpModuleName: LPCWSTR) callconv(.winapi) HINSTANCE;
    pub extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
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
    pub extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *winos.c.PAINTSTRUCT) callconv(.winapi) HDC;
    pub extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const winos.c.PAINTSTRUCT) callconv(.winapi) BOOL;
    pub extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.winapi) i32;
    pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
    pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
    pub extern "user32" fn PostMessageW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;
    pub extern "user32" fn PostThreadMessageW(idThread: DWORD, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;
    pub extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(.winapi) void;
    pub extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: i32, dwNewLong: LONG_PTR) callconv(.winapi) LONG_PTR;
    pub extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: i32) callconv(.winapi) LONG_PTR;
    pub extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: LPCWSTR) callconv(.winapi) BOOL;
    pub extern "user32" fn InvalidateRect(hWnd: HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.winapi) BOOL;
    pub extern "user32" fn GetDC(hWnd: HWND) callconv(.winapi) HDC;
    pub extern "user32" fn ReleaseDC(hWnd: HWND, hDC: HDC) callconv(.winapi) i32;
    pub extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
    pub extern "user32" fn GetDpiForWindow(hWnd: HWND) callconv(.winapi) UINT;
    pub extern "user32" fn SetWindowPos(
        hWnd: HWND,
        hWndInsertAfter: HWND,
        X: i32,
        Y: i32,
        cx: i32,
        cy: i32,
        uFlags: UINT,
    ) callconv(.winapi) BOOL;
    pub extern "user32" fn IsZoomed(hWnd: HWND) callconv(.winapi) BOOL;
    pub extern "user32" fn MonitorFromWindow(hwnd: HWND, dwFlags: DWORD) callconv(.winapi) HMONITOR;
    pub extern "user32" fn GetMonitorInfoW(hMonitor: HMONITOR, lpmi: *MONITORINFO) callconv(.winapi) BOOL;
    pub extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.winapi) BOOL;
    pub extern "user32" fn BringWindowToTop(hWnd: HWND) callconv(.winapi) BOOL;
    pub extern "user32" fn LoadCursorW(hInstance: HINSTANCE, lpCursorName: LPCWSTR) callconv(.winapi) HCURSOR;
    pub extern "user32" fn SetCursor(hCursor: HCURSOR) callconv(.winapi) HCURSOR;
    pub extern "user32" fn ShowCursor(bShow: BOOL) callconv(.winapi) i32;
    pub extern "user32" fn MessageBeep(uType: UINT) callconv(.winapi) BOOL;
    pub extern "user32" fn GetKeyState(nVirtKey: i32) callconv(.winapi) SHORT;
    pub extern "user32" fn GetKeyboardState(lpKeyState: [*]BYTE) callconv(.winapi) BOOL;
    pub extern "user32" fn GetKeyboardLayout(idThread: DWORD) callconv(.winapi) HKL;
    pub extern "user32" fn GetKeyboardLayoutNameW(pwszKLID: [*:0]u16) callconv(.winapi) BOOL;
    pub extern "user32" fn MapVirtualKeyExW(uCode: UINT, uMapType: UINT, dwhkl: HKL) callconv(.winapi) UINT;
    pub extern "user32" fn ToUnicodeEx(
        wVirtKey: UINT,
        wScanCode: UINT,
        lpKeyState: [*]const BYTE,
        pwszBuff: [*]u16,
        cchBuff: INT,
        wFlags: UINT,
        dwhkl: HKL,
    ) callconv(.winapi) INT;
    pub extern "user32" fn MessageBoxW(hWnd: HWND, lpText: LPCWSTR, lpCaption: LPCWSTR, uType: UINT) callconv(.winapi) INT;
    pub extern "user32" fn OpenClipboard(hWndNewOwner: HWND) callconv(.winapi) BOOL;
    pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
    pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
    pub extern "user32" fn IsClipboardFormatAvailable(format: UINT) callconv(.winapi) BOOL;
    pub extern "user32" fn GetClipboardData(uFormat: UINT) callconv(.winapi) HANDLE;
    pub extern "user32" fn SetClipboardData(uFormat: UINT, hMem: HANDLE) callconv(.winapi) HANDLE;

    pub extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: usize) callconv(.winapi) HGLOBAL;
    pub extern "kernel32" fn GlobalLock(hMem: HGLOBAL) callconv(.winapi) LPVOID;
    pub extern "kernel32" fn GlobalUnlock(hMem: HGLOBAL) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GlobalSize(hMem: HGLOBAL) callconv(.winapi) usize;
    pub extern "kernel32" fn GlobalFree(hMem: HGLOBAL) callconv(.winapi) HGLOBAL;
    pub extern "kernel32" fn WaitNamedPipeW(lpNamedPipeName: LPCWSTR, nTimeOut: DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn ConnectNamedPipe(hNamedPipe: HANDLE, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
    pub extern "imm32" fn ImmGetContext(hWnd: HWND) callconv(.winapi) HIMC;
    pub extern "imm32" fn ImmReleaseContext(hWnd: HWND, hIMC: HIMC) callconv(.winapi) BOOL;
    pub extern "imm32" fn ImmGetCompositionStringW(hIMC: HIMC, dwIndex: DWORD, lpBuf: LPVOID, dwBufLen: DWORD) callconv(.winapi) LONG;
    pub extern "imm32" fn ImmSetCompositionWindow(hIMC: HIMC, lpCompForm: *const COMPOSITIONFORM) callconv(.winapi) BOOL;

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
    pub const SW_HIDE = 0;
    pub const SW_SHOW = 5;
    pub const WM_NCCREATE = 0x0081;
    pub const WM_CLOSE = 0x0010;
    pub const WM_DESTROY = 0x0002;
    pub const WM_SIZE = 0x0005;
    pub const WM_GETMINMAXINFO = 0x0024;
    pub const WM_SHOWWINDOW = 0x0018;
    pub const WM_WINDOWPOSCHANGING = 0x0046;
    pub const WM_WINDOWPOSCHANGED = 0x0047;
    pub const WM_ACTIVATE = 0x0006;
    pub const WM_ACTIVATEAPP = 0x001C;
    pub const WM_SETFOCUS = 0x0007;
    pub const WM_KILLFOCUS = 0x0008;
    pub const WM_PAINT = 0x000F;
    pub const WM_SETCURSOR = 0x0020;
    pub const WM_NCACTIVATE = 0x0086;
    pub const WM_NCPAINT = 0x0085;
    pub const WM_GETICON = 0x007F;
    pub const WM_ERASEBKGND = 0x0014;
    pub const WM_CHAR = 0x0102;
    pub const WM_KEYDOWN = 0x0100;
    pub const WM_KEYUP = 0x0101;
    pub const WM_SYSKEYDOWN = 0x0104;
    pub const WM_SYSKEYUP = 0x0105;
    pub const WM_INPUTLANGCHANGE = 0x0051;
    pub const WM_IME_SETCONTEXT = 0x0281;
    pub const WM_IME_NOTIFY = 0x0282;
    pub const WM_IME_STARTCOMPOSITION = 0x010D;
    pub const WM_IME_ENDCOMPOSITION = 0x010E;
    pub const WM_IME_COMPOSITION = 0x010F;
    pub const WM_MOUSEMOVE = 0x0200;
    pub const WM_LBUTTONDOWN = 0x0201;
    pub const WM_LBUTTONUP = 0x0202;
    pub const WM_RBUTTONDOWN = 0x0204;
    pub const WM_RBUTTONUP = 0x0205;
    pub const WM_MBUTTONDOWN = 0x0207;
    pub const WM_MBUTTONUP = 0x0208;
    pub const WM_MOUSEWHEEL = 0x020A;
    pub const WM_XBUTTONDOWN = 0x020B;
    pub const WM_XBUTTONUP = 0x020C;
    pub const WM_MOUSEHWHEEL = 0x020E;
    pub const WM_DPICHANGED = 0x02E0;
    pub const WM_APP = 0x8000;
    pub const WM_GHOSTTY_WAKEUP = WM_APP + 1;
    pub const WM_GHOSTTY_QUIT_TIMER = WM_APP + 2;
    pub const GWLP_USERDATA = -21;
    pub const GWL_STYLE = -16;
    pub const CF_UNICODETEXT = 13;
    pub const GMEM_MOVEABLE = 0x0002;
    pub const WHEEL_DELTA: SHORT = 120;
    pub const MK_SHIFT = 0x0004;
    pub const MK_CONTROL = 0x0008;
    pub const XBUTTON1 = 0x0001;
    pub const XBUTTON2 = 0x0002;
    pub const VK_MENU = 0x12;
    pub const VK_CONTROL = 0x11;
    pub const VK_SHIFT = 0x10;
    pub const VK_LSHIFT = 0xA0;
    pub const VK_RSHIFT = 0xA1;
    pub const VK_LCONTROL = 0xA2;
    pub const VK_RCONTROL = 0xA3;
    pub const VK_LMENU = 0xA4;
    pub const VK_RMENU = 0xA5;
    pub const VK_LWIN = 0x5B;
    pub const VK_RWIN = 0x5C;
    pub const VK_CAPITAL = 0x14;
    pub const VK_NUMLOCK = 0x90;
    pub const IDC_ARROW: WORD = 32512;
    pub const IDC_IBEAM: WORD = 32513;
    pub const IDC_WAIT: WORD = 32514;
    pub const IDC_CROSS: WORD = 32515;
    pub const IDC_UPARROW: WORD = 32516;
    pub const IDC_SIZENWSE: WORD = 32642;
    pub const IDC_SIZENESW: WORD = 32643;
    pub const IDC_SIZEWE: WORD = 32644;
    pub const IDC_SIZENS: WORD = 32645;
    pub const IDC_SIZEALL: WORD = 32646;
    pub const IDC_NO: WORD = 32648;
    pub const IDC_HAND: WORD = 32649;
    pub const IDC_APPSTARTING: WORD = 32650;
    pub const SW_MAXIMIZE = 3;
    pub const SW_RESTORE = 9;
    pub const HWND_TOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
    pub const HWND_NOTOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));
    pub const MONITOR_DEFAULTTONEAREST = 2;
    pub const SWP_NOSIZE = 0x0001;
    pub const SWP_NOMOVE = 0x0002;
    pub const SWP_NOZORDER = 0x0004;
    pub const SWP_NOOWNERZORDER = 0x0200;
    pub const SWP_FRAMECHANGED = 0x0020;
    pub const SWP_SHOWWINDOW = 0x0040;
    pub const WS_VISIBLE = 0x10000000;
    pub const WS_POPUP = 0x80000000;
    pub const MB_OK = 0x00000000;
    pub const MAPVK_VK_TO_VSC = 0x0;
    pub const MAPVK_VK_TO_CHAR = 0x2;
    pub const GCS_COMPSTR = 0x0008;
    pub const GCS_RESULTSTR = 0x0800;
    pub const CFS_POINT = 0x0002;
    pub const MB_OKCANCEL = 0x00000001;
    pub const MB_ICONWARNING = 0x00000030;
    pub const IDOK = 1;
    pub const USER_DEFAULT_SCREEN_DPI: UINT = 96;

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

    pub fn signedHighWordWPARAM(value: WPARAM) i16 {
        return @bitCast(@as(u16, @truncate(value >> 16)));
    }

    pub fn lowWordWPARAM(value: WPARAM) u16 {
        return @truncate(value);
    }

    pub fn highWordWPARAM(value: WPARAM) u16 {
        return @truncate(value >> 16);
    }

    pub fn keyScanCode(value: LPARAM) u32 {
        return @intCast((@as(usize, @bitCast(value)) >> 16) & 0xFF);
    }

    pub fn keyIsExtended(value: LPARAM) bool {
        return ((@as(usize, @bitCast(value)) >> 24) & 0x01) != 0;
    }

    pub fn keyWasDown(value: LPARAM) bool {
        return ((@as(usize, @bitCast(value)) >> 30) & 0x01) != 0;
    }

    pub fn makeIntResource(id: WORD) LPCWSTR {
        return @ptrFromInt(@as(usize, id));
    }
};

pub const App = struct {
    core_app: *CoreApp,
    config: configpkg.Config,
    ci_smoke_mode: CiSmokeMode,
    thread_id: win.DWORD = 0,
    quit_timer_generation: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    ci_smoke_window_ready_logged: bool = false,
    ci_smoke_core_surface_ready_logged: bool = false,
    ci_smoke_core_draw_ready_logged: bool = false,
    ci_smoke_native_draw_ready_logged: bool = false,
    ci_smoke_software_frame_ready_logged: bool = false,
    ci_smoke_present_ok_logged: bool = false,
    keyboard_layout: input.KeyboardLayout = .unknown,
    hinstance: win.HINSTANCE,
    class_name: [:0]const u16,
    title: [:0]const u16,
    ipc_pipe_name_utf8: [:0]const u8,
    ipc_pipe_name_utf16: [:0]const u16,
    ipc_thread: ?std.Thread = null,
    ipc_shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    surfaces: std.ArrayListUnmanaged(*Surface) = .{},
    pending_window_requests: std.ArrayListUnmanaged(PendingWindowRequest) = .{},
    pending_window_requests_mutex: std.Thread.Mutex = .{},
    warned_container_actions: bool = false,
    warned_inspector_actions: bool = false,
    warned_notification_actions: bool = false,
    warned_secure_input_actions: bool = false,
    warned_osk_actions: bool = false,
    warned_misc_actions: bool = false,

    pub fn init(self: *App, core_app: *CoreApp, opts: struct {}) !void {
        _ = opts;

        const smoke_mode = ciSmokeMode();
        const trace_win32_init = trace_win32_init: {
            if (smoke_mode != .disabled) break :trace_win32_init true;
            const alloc = std.heap.page_allocator;
            const label = std.process.getEnvVarOwned(alloc, "GHOSTTY_CI_INTERACTION_LABEL") catch null;
            defer if (label) |value| alloc.free(value);
            break :trace_win32_init if (label) |value| value.len > 0 else false;
        };
        trace_win32_init_enabled = trace_win32_init;
        self.* = .{
            .core_app = core_app,
            .config = .{},
            .ci_smoke_mode = smoke_mode,
            .hinstance = win.GetModuleHandleW(null),
            .class_name = try std.unicode.utf8ToUtf16LeAllocZ(core_app.alloc, "GhosttyWin32Runtime"),
            .title = try std.unicode.utf8ToUtf16LeAllocZ(core_app.alloc, "Ghostty Windows Runtime Scaffold"),
            .ipc_pipe_name_utf8 = undefined,
            .ipc_pipe_name_utf16 = undefined,
            .keyboard_layout = detectKeyboardLayout(),
        };
        errdefer core_app.alloc.free(self.class_name);
        errdefer core_app.alloc.free(self.title);

        self.config = if (smoke_mode != .disabled)
            try configpkg.Config.default(core_app.alloc)
        else
            try configpkg.Config.load(core_app.alloc);
        errdefer self.config.deinit();

        self.ipc_pipe_name_utf8 = try buildPipeNameUtf8(core_app.alloc, &self.config);
        errdefer core_app.alloc.free(self.ipc_pipe_name_utf8);
        self.ipc_pipe_name_utf16 = try std.unicode.utf8ToUtf16LeAllocZ(
            core_app.alloc,
            self.ipc_pipe_name_utf8,
        );
        errdefer core_app.alloc.free(self.ipc_pipe_name_utf16);

        try self.registerWindowClass();

        if (smoke_mode == .disabled) {
            self.ipc_thread = try std.Thread.spawn(.{}, ipcThreadMain, .{self});
        }
    }

    pub fn run(self: *App) !void {
        self.thread_id = win.GetCurrentThreadId();
        try self.createWindow(.{});

        var msg: win.MSG = undefined;
        while (true) {
            const status = win.GetMessageW(&msg, null, 0, 0);
            if (status == -1) return error.Unexpected;
            if (status == 0) break;
            if (msg.hwnd == null) {
                switch (msg.message) {
                    win.WM_GHOSTTY_WAKEUP => {
                        try self.drainPendingWindowRequests();
                        try self.core_app.tick(self);
                        continue;
                    },
                    win.WM_GHOSTTY_QUIT_TIMER => {
                        self.handleQuitTimer(@intCast(msg.wParam));
                        continue;
                    },
                    else => {},
                }
            }
            _ = win.TranslateMessage(&msg);
            _ = win.DispatchMessageW(&msg);
            try self.drainPendingWindowRequests();
            try self.core_app.tick(self);
        }
    }

    pub fn terminate(self: *App) void {
        self.stopIpcServer();

        while (self.surfaces.pop()) |surface| {
            surface.deinit();
            self.core_app.alloc.destroy(surface);
        }
        for (self.pending_window_requests.items) |*request| {
            request.deinit(self.core_app.alloc);
        }
        self.pending_window_requests.deinit(self.core_app.alloc);
        self.surfaces.deinit(self.core_app.alloc);
        _ = win.UnregisterClassW(self.class_name.ptr, self.hinstance);
        self.config.deinit();
        self.core_app.alloc.free(self.ipc_pipe_name_utf16);
        self.core_app.alloc.free(self.ipc_pipe_name_utf8);
        self.core_app.alloc.free(self.title);
        self.core_app.alloc.free(self.class_name);
    }

    pub fn wakeup(self: *App) void {
        if (self.surfaces.items.len > 0) {
            const hwnd = self.surfaces.items[0].hwnd;
            _ = win.PostMessageW(hwnd, win.WM_GHOSTTY_WAKEUP, 0, 0);
        } else if (self.thread_id != 0) {
            _ = win.PostThreadMessageW(self.thread_id, win.WM_GHOSTTY_WAKEUP, 0, 0);
        }
    }

    pub fn keyboardLayout(self: *const App) input.KeyboardLayout {
        return self.keyboard_layout;
    }

    pub fn performAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        const surface = self.targetSurface(target);
        return switch (action) {
            .quit => blk: {
                for (self.surfaces.items) |rt_surface| {
                    _ = win.PostMessageW(rt_surface.hwnd, win.WM_CLOSE, 0, 0);
                }
                break :blk true;
            },
            .close_window => blk: {
                if (surface) |rt_surface| _ = win.PostMessageW(rt_surface.hwnd, win.WM_CLOSE, 0, 0);
                break :blk true;
            },
            .close_all_windows => blk: {
                for (self.surfaces.items) |rt_surface| {
                    _ = win.PostMessageW(rt_surface.hwnd, win.WM_CLOSE, 0, 0);
                }
                break :blk true;
            },
            .new_window => blk: {
                try self.createWindow(.{
                    .parent = switch (target) {
                        .surface => |core_surface| core_surface,
                        .app => null,
                    },
                });
                break :blk true;
            },
            .render => blk: {
                if (surface) |rt_surface| _ = win.InvalidateRect(rt_surface.hwnd, null, 0);
                break :blk true;
            },
            .present_terminal => blk: {
                if (surface) |rt_surface| rt_surface.presentTerminal();
                break :blk true;
            },
            .set_title => blk: {
                if (surface) |rt_surface| try rt_surface.setTitle(value.title);
                break :blk true;
            },
            .reload_config => blk: {
                var config = try configpkg.Config.load(self.core_app.alloc);
                defer config.deinit();
                try self.core_app.updateConfig(self, &config);
                break :blk true;
            },
            .open_url => blk: {
                internal_os.open(self.core_app.alloc, value.kind, value.url) catch |err| {
                    log.warn("win32 open_url fallback failed err={}", .{err});
                };
                break :blk true;
            },
            .toggle_maximize => blk: {
                if (surface) |rt_surface| rt_surface.toggleMaximize();
                break :blk true;
            },
            .toggle_visibility => blk: {
                switch (target) {
                    .app => self.toggleAllWindowsVisibility(),
                    .surface => if (surface) |rt_surface| rt_surface.toggleVisibility(),
                }
                break :blk true;
            },
            .toggle_fullscreen => blk: {
                if (surface) |rt_surface| try rt_surface.toggleFullscreen(value);
                break :blk true;
            },
            .toggle_window_decorations => blk: {
                if (surface) |rt_surface| try rt_surface.toggleWindowDecorations();
                break :blk true;
            },
            .float_window => blk: {
                if (surface) |rt_surface| try rt_surface.setFloatWindow(value);
                break :blk true;
            },
            .mouse_shape => blk: {
                if (surface) |rt_surface| rt_surface.setMouseShape(value);
                break :blk true;
            },
            .mouse_visibility => blk: {
                if (surface) |rt_surface| rt_surface.setMouseVisibility(value);
                break :blk true;
            },
            .ring_bell => blk: {
                _ = win.MessageBeep(0);
                break :blk true;
            },
            .desktop_notification,
            .progress_report,
            .command_finished,
            => blk: {
                self.warnOnce(&self.warned_notification_actions, action, "Win32 当前使用最小 fallback 处理通知类 action");
                break :blk true;
            },
            .show_child_exited => false,
            .scrollbar => true,
            .readonly,
            .pwd,
            .renderer_health,
            .color_change,
            => true,
            .secure_input => blk: {
                self.warnOnce(&self.warned_secure_input_actions, action, "Win32 secure-input 仍为最小 no-op fallback");
                break :blk true;
            },
            .show_on_screen_keyboard => blk: {
                self.openOnScreenKeyboard();
                break :blk true;
            },
            .new_tab,
            .close_tab,
            .goto_tab,
            .move_tab,
            .new_split,
            .goto_split,
            .resize_split,
            .equalize_splits,
            .toggle_split_zoom,
            .toggle_tab_overview,
            .inspector,
            .render_inspector,
            .show_gtk_inspector,
            .toggle_command_palette,
            => blk: {
                self.warnOnce(&self.warned_container_actions, action, "Win32 当前仅支持单窗口 runtime，不支持 tabs/splits/inspector 容器动作");
                break :blk true;
            },
            .goto_window => blk: {
                break :blk self.gotoWindow(switch (target) {
                    .surface => surface,
                    .app => self.focusedOrFirstSurface(),
                }, value);
            },
            .cell_size, .size_limit, .config_change => blk: {
                break :blk switch (action) {
                    .cell_size => true,
                    .size_limit => if (surface) |rt_surface| blk2: {
                        rt_surface.setSizeLimit(value);
                        break :blk2 true;
                    } else true,
                    .config_change => blk2: {
                        switch (target) {
                            .app => {
                                const cloned = try value.config.clone(self.core_app.alloc);
                                self.config.deinit();
                                self.config = cloned;
                            },
                            .surface => {},
                        }
                        break :blk2 true;
                    },
                    else => unreachable,
                };
            },
            .toggle_background_opacity,
            .check_for_updates,
            .undo,
            .redo,
            .toggle_quick_terminal,
            .prompt_title,
            .mouse_over_link,
            .initial_size,
            .key_sequence,
            .key_table,
            .start_search,
            .end_search,
            .search_total,
            .search_selected,
            .copy_title_to_clipboard,
            .reset_window_size,
            => blk: {
                break :blk switch (action) {
                    .initial_size => if (surface) |rt_surface| blk2: {
                        rt_surface.applyInitialSize(value);
                        break :blk2 true;
                    } else true,
                    .copy_title_to_clipboard => if (surface) |rt_surface|
                        rt_surface.copyTitleToClipboard()
                    else
                        false,
                    .reset_window_size => if (surface) |rt_surface| blk2: {
                        break :blk2 rt_surface.resetWindowSize();
                    } else false,
                    .prompt_title,
                    .toggle_background_opacity,
                    .check_for_updates,
                    .undo,
                    .redo,
                    .toggle_quick_terminal,
                    .key_sequence,
                    .key_table,
                    .start_search,
                    .end_search,
                    .search_total,
                    .search_selected,
                    => blk2: {
                        self.warnOnce(&self.warned_misc_actions, action, "Win32 当前对该 action 仅提供最小 no-op fallback");
                        break :blk2 true;
                    },
                    .mouse_over_link,
                    => true,
                    else => unreachable,
                };
            },
            .open_config => blk: {
                try self.openConfigFile();
                break :blk true;
            },
            .quit_timer => blk: {
                self.updateQuitTimer(value);
                break :blk true;
            },
        };
    }

    pub fn performIpc(
        alloc: Allocator,
        target: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        value: apprt.ipc.Action.Value(action),
    ) (Allocator.Error || std.os.windows.WriteFileError || apprt.ipc.Errors || error{ InvalidIPCMessage, InvalidUtf8, Unexpected })!bool {
        switch (action) {
            .new_window => return try sendIpcNewWindowRequest(alloc, target, value),
        }
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

    fn createWindow(self: *App, request: PendingWindowRequest) !void {
        var config = try self.deriveWindowConfig(request.parent);
        defer config.deinit();
        if (request.arguments) |arguments| {
            const alloc = config.arenaAlloc();
            const copied = try alloc.alloc([:0]const u8, arguments.len);
            for (arguments, 0..) |argument, i| {
                copied[i] = try alloc.dupeZ(u8, argument);
            }
            config.@"initial-command" = .{ .direct = copied };
        }
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
        traceWin32InitStep("create_window.create_window_ex.ready");
        if (hwnd == null) return error.Unexpected;
        errdefer _ = win.DestroyWindow(hwnd);

        traceWin32InitStep("create_window.runtime_surface_alloc.begin");
        const surface = try self.core_app.alloc.create(Surface);
        traceWin32InitStep("create_window.runtime_surface_alloc.ready");
        errdefer self.core_app.alloc.destroy(surface);
        surface.* = .{};
        traceWin32InitStep("create_window.runtime_surface_init.begin");
        try surface.init(self, hwnd, 1280, 800, &config);
        traceWin32InitStep("create_window.runtime_surface_init.ready");
        errdefer surface.deinit();
        traceWin32InitStep("create_window.runtime_surface_list_append.begin");
        try self.surfaces.append(self.core_app.alloc, surface);
        traceWin32InitStep("create_window.runtime_surface_list_append.ready");

        traceWin32InitStep("create_window.show_window.begin");
        _ = win.ShowWindow(hwnd, win.SW_SHOW);
        traceWin32InitStep("create_window.show_window.ready");
        traceWin32InitStep("create_window.update_window.begin");
        _ = win.UpdateWindow(hwnd);
        traceWin32InitStep("create_window.update_window.ready");
        if (self.ci_smoke_mode != .disabled and !self.ci_smoke_window_ready_logged) {
            self.ci_smoke_window_ready_logged = true;
            log.info("ci.win32.window_ready", .{});
        }
        if (self.ci_smoke_mode == .core_draw and !self.ci_smoke_core_surface_ready_logged) {
            self.ci_smoke_core_surface_ready_logged = true;
            log.info("ci.win32.core_surface_ready", .{});
        }
        if (self.ci_smoke_mode != .disabled) {
            try surface.runCiSmoke();
        }
    }

    fn deriveWindowConfig(self: *App, parent: ?*CoreSurface) !configpkg.Config {
        var config = try apprt.surface.newConfig(
            self.core_app,
            &self.config,
            .window,
        );

        const inheritance = try Surface.collectWindowInheritance(
            config.arenaAlloc(),
            &self.config,
            parent orelse self.core_app.focusedSurface(),
        );
        try Surface.applyWindowInheritance(&config, config.arenaAlloc(), inheritance);

        return config;
    }

    fn focusedOrFirstSurface(self: *App) ?*Surface {
        if (self.core_app.focusedSurface()) |core_surface| {
            if (self.findRuntimeSurface(core_surface)) |surface| return surface;
        }
        return if (self.surfaces.items.len > 0) self.surfaces.items[0] else null;
    }

    fn toggleAllWindowsVisibility(self: *App) void {
        var any_visible = false;
        for (self.surfaces.items) |surface| {
            if (surface.isVisible()) {
                any_visible = true;
                break;
            }
        }
        for (self.surfaces.items) |surface| {
            surface.setVisible(!any_visible);
        }
    }

    fn gotoWindow(
        self: *App,
        current: ?*Surface,
        direction: apprt.action.GotoWindow,
    ) bool {
        if (self.surfaces.items.len <= 1) return false;

        const current_surface = current orelse self.focusedOrFirstSurface() orelse return false;
        const start_index = self.indexOfSurface(current_surface) orelse return false;
        const total = self.surfaces.items.len;

        var step: usize = 1;
        while (step < total) : (step += 1) {
            const index = switch (direction) {
                .next => (start_index + step) % total,
                .previous => (start_index + total - (step % total)) % total,
            };
            const candidate = self.surfaces.items[index];
            if (!candidate.isVisible()) continue;
            candidate.presentTerminal();
            return true;
        }

        return false;
    }

    fn indexOfSurface(self: *App, target: *Surface) ?usize {
        for (self.surfaces.items, 0..) |surface, i| {
            if (surface == target) return i;
        }
        return null;
    }

    fn updateQuitTimer(self: *App, value: apprt.action.QuitTimer) void {
        const generation = self.quit_timer_generation.fetchAdd(1, .seq_cst) + 1;
        switch (value) {
            .stop => return,
            .start => {
                if (!self.config.@"quit-after-last-window-closed") return;
                if (self.surfaces.items.len != 0) return;
                if (self.config.@"quit-after-last-window-closed-delay") |delay| {
                    const delay_ns = delay.asMilliseconds() * std.time.ns_per_ms;
                    const timer_generation = generation;
                    const thread = std.Thread.spawn(.{}, quitTimerThreadMain, .{
                        self,
                        timer_generation,
                        delay_ns,
                    }) catch return;
                    thread.detach();
                    return;
                }
                self.handleQuitTimer(generation);
            },
        }
    }

    fn handleQuitTimer(self: *App, generation: u32) void {
        if (self.quit_timer_generation.load(.seq_cst) != generation) return;
        if (!self.config.@"quit-after-last-window-closed") return;
        if (self.surfaces.items.len != 0) return;
        win.PostQuitMessage(0);
    }

    fn handleMessage(
        self: *App,
        hwnd: win.HWND,
        msg: win.UINT,
        w_param: win.WPARAM,
        l_param: win.LPARAM,
    ) win.LRESULT {
        const surface = self.findSurfaceByHwnd(hwnd);
        if (surface == null and shouldTraceWin32Init()) {
            std.debug.print(
                "info(win32_apprt): ci.win32.handle_message.msg=0x{x} surface=none\n",
                .{msg},
            );
        } else if (surface != null and shouldTraceWin32Init() and shouldTraceHandledWin32Message(msg)) {
            std.debug.print(
                "info(win32_apprt): ci.win32.handle_message.msg=0x{x} surface=ready step=begin\n",
                .{msg},
            );
        }
        const result: win.LRESULT = switch (msg) {
            win.WM_CLOSE => blk: {
                _ = win.DestroyWindow(hwnd);
                break :blk 0;
            },
            win.WM_DESTROY => blk: {
                if (surface) |rt_surface| {
                    self.removeSurface(rt_surface);
                    rt_surface.deinit();
                    self.core_app.alloc.destroy(rt_surface);
                    if (self.ci_smoke_mode != .disabled and self.surfaces.items.len == 0) {
                        win.PostQuitMessage(0);
                    }
                }
                break :blk 0;
            },
            win.WM_SIZE => blk: {
                if (surface) |rt_surface| rt_surface.updateSize(
                    @intCast(win.lowWord(l_param)),
                    @intCast(win.highWord(l_param)),
                );
                break :blk 0;
            },
            win.WM_GETMINMAXINFO => blk: {
                if (surface) |rt_surface| {
                    const info: *win.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(l_param)));
                    rt_surface.applyMinMaxInfo(info);
                    break :blk 0;
                }
                break :blk win.DefWindowProcW(hwnd, msg, w_param, l_param);
            },
            win.WM_SETFOCUS => blk: {
                if (surface) |rt_surface| rt_surface.updateFocus(true);
                break :blk 0;
            },
            win.WM_KILLFOCUS => blk: {
                if (surface) |rt_surface| rt_surface.updateFocus(false);
                break :blk 0;
            },
            win.WM_SHOWWINDOW,
            win.WM_WINDOWPOSCHANGING,
            win.WM_WINDOWPOSCHANGED,
            win.WM_ACTIVATEAPP,
            win.WM_NCACTIVATE,
            win.WM_GETICON,
            win.WM_ACTIVATE,
            win.WM_IME_SETCONTEXT,
            win.WM_IME_NOTIFY,
            win.WM_NCPAINT,
            win.WM_ERASEBKGND,
            => blk: {
                if (surface == null) break :blk 0;
                break :blk win.DefWindowProcW(hwnd, msg, w_param, l_param);
            },
            win.WM_MOUSEMOVE => blk: {
                if (surface) |rt_surface| {
                    rt_surface.updateCursorPos(
                        @floatFromInt(win.signedLowWord(l_param)),
                        @floatFromInt(win.signedHighWord(l_param)),
                    );
                    rt_surface.applyCursor();
                }
                break :blk 0;
            },
            win.WM_SETCURSOR => blk: {
                if (surface) |rt_surface| {
                    rt_surface.applyCursor();
                    break :blk 1;
                }
                break :blk win.DefWindowProcW(hwnd, msg, w_param, l_param);
            },
            win.WM_LBUTTONDOWN,
            win.WM_LBUTTONUP,
            win.WM_RBUTTONDOWN,
            win.WM_RBUTTONUP,
            win.WM_MBUTTONDOWN,
            win.WM_MBUTTONUP,
            win.WM_XBUTTONDOWN,
            win.WM_XBUTTONUP,
            => blk: {
                if (surface) |rt_surface| {
                    rt_surface.updateCursorPos(
                        @floatFromInt(win.signedLowWord(l_param)),
                        @floatFromInt(win.signedHighWord(l_param)),
                    );
                    _ = rt_surface.mouseButtonCallback(
                        messageMouseButtonState(msg),
                        messageMouseButton(msg, w_param),
                        messageMods(),
                    );
                }
                break :blk 0;
            },
            win.WM_MOUSEWHEEL => blk: {
                if (surface) |rt_surface| {
                    const delta = @as(f64, @floatFromInt(win.signedHighWordWPARAM(w_param))) /
                        @as(f64, @floatFromInt(win.WHEEL_DELTA));
                    rt_surface.scrollCallback(0, delta, .{});
                }
                break :blk 0;
            },
            win.WM_MOUSEHWHEEL => blk: {
                if (surface) |rt_surface| {
                    const delta = @as(f64, @floatFromInt(win.signedHighWordWPARAM(w_param))) /
                        @as(f64, @floatFromInt(win.WHEEL_DELTA));
                    rt_surface.scrollCallback(delta, 0, .{});
                }
                break :blk 0;
            },
            win.WM_DPICHANGED => blk: {
                if (surface) |rt_surface| {
                    rt_surface.updateContentScale(
                        @as(f32, @floatFromInt(win.lowWordWPARAM(w_param))) / @as(f32, @floatFromInt(win.USER_DEFAULT_SCREEN_DPI)),
                        @as(f32, @floatFromInt(win.highWordWPARAM(w_param))) / @as(f32, @floatFromInt(win.USER_DEFAULT_SCREEN_DPI)),
                    );
                    const suggested: *const win.RECT = @ptrFromInt(@as(usize, @bitCast(l_param)));
                    _ = win.SetWindowPos(
                        hwnd,
                        null,
                        suggested.left,
                        suggested.top,
                        suggested.right - suggested.left,
                        suggested.bottom - suggested.top,
                        win.SWP_NOZORDER | win.SWP_NOOWNERZORDER,
                    );
                }
                break :blk 0;
            },
            win.WM_CHAR => blk: {
                if (surface) |rt_surface| {
                    if (!rt_surface.consumeSuppressedCharMessage()) {
                        rt_surface.cacheLastChar(@intCast(w_param));
                    }
                }
                break :blk 0;
            },
            win.WM_KEYDOWN,
            win.WM_KEYUP,
            win.WM_SYSKEYDOWN,
            win.WM_SYSKEYUP,
            => blk: {
                if (surface) |rt_surface| rt_surface.keyCallback(
                    messageKeyAction(msg, l_param),
                    @intCast(w_param),
                    messageKey(l_param),
                    messageMods(),
                );
                break :blk 0;
            },
            win.WM_INPUTLANGCHANGE => blk: {
                self.keyboard_layout = detectKeyboardLayout();
                break :blk win.DefWindowProcW(hwnd, msg, w_param, l_param);
            },
            win.WM_IME_STARTCOMPOSITION => blk: {
                if (surface) |rt_surface| rt_surface.updateImeWindow();
                break :blk 0;
            },
            win.WM_IME_COMPOSITION => blk: {
                if (surface) |rt_surface| rt_surface.handleImeComposition(l_param);
                break :blk 0;
            },
            win.WM_IME_ENDCOMPOSITION => blk: {
                if (surface) |rt_surface| rt_surface.handleImeEndComposition();
                break :blk 0;
            },
            win.WM_PAINT => blk: {
                var ps: winos.c.PAINTSTRUCT = std.mem.zeroes(winos.c.PAINTSTRUCT);
                _ = win.BeginPaint(hwnd, &ps);
                defer _ = win.EndPaint(hwnd, &ps);

                if (surface) |rt_surface| rt_surface.markDirty();
                break :blk 0;
            },
            win.WM_GHOSTTY_WAKEUP => blk: {
                self.drainPendingWindowRequests() catch |err| {
                    log.err("error draining win32 pending window requests err={}", .{err});
                };
                break :blk 0;
            },
            else => win.DefWindowProcW(hwnd, msg, w_param, l_param),
        };
        if (surface != null and shouldTraceWin32Init() and shouldTraceHandledWin32Message(msg)) {
            std.debug.print(
                "info(win32_apprt): ci.win32.handle_message.msg=0x{x} surface=ready step=ready\n",
                .{msg},
            );
        }
        return result;
    }

    fn fromWindow(hwnd: win.HWND) ?*App {
        const ptr = win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA);
        if (shouldTraceWin32Init()) {
            std.debug.print(
                "info(win32_apprt): ci.win32.from_window.ptr=0x{x}\n",
                .{@as(usize, @bitCast(ptr))},
            );
        }
        if (ptr == 0) return null;
        return @ptrFromInt(@as(usize, @intCast(ptr)));
    }

    fn findSurfaceByHwnd(self: *App, hwnd: win.HWND) ?*Surface {
        for (self.surfaces.items) |surface| {
            if (surface.hwnd == hwnd) return surface;
        }

        return null;
    }

    fn findRuntimeSurface(self: *App, core_surface: *CoreSurface) ?*Surface {
        for (self.surfaces.items) |surface| {
            if (surface.core_surface == core_surface) return surface;
        }

        return null;
    }

    fn removeSurface(self: *App, surface: *Surface) void {
        var i: usize = 0;
        while (i < self.surfaces.items.len) : (i += 1) {
            if (self.surfaces.items[i] == surface) {
                _ = self.surfaces.swapRemove(i);
                return;
            }
        }
    }

    fn targetSurface(self: *App, target: apprt.Target) ?*Surface {
        return switch (target) {
            .surface => |core_surface| self.findRuntimeSurface(core_surface),
            .app => if (self.surfaces.items.len > 0) self.surfaces.items[0] else null,
        };
    }

    fn warnOnce(
        self: *App,
        warned: *bool,
        comptime action: apprt.Action.Key,
        message: []const u8,
    ) void {
        _ = self;
        if (warned.*) return;
        warned.* = true;
        log.warn("{s} action={s}", .{ message, @tagName(action) });
    }

    fn drainPendingWindowRequests(self: *App) !void {
        var ready: std.ArrayListUnmanaged(PendingWindowRequest) = .{};
        defer {
            for (ready.items) |*request| request.deinit(self.core_app.alloc);
            ready.deinit(self.core_app.alloc);
        }

        self.pending_window_requests_mutex.lock();
        std.mem.swap(
            std.ArrayListUnmanaged(PendingWindowRequest),
            &ready,
            &self.pending_window_requests,
        );
        self.pending_window_requests_mutex.unlock();

        for (ready.items) |*request| {
            try self.createWindow(request.*);
        }
    }

    fn stopIpcServer(self: *App) void {
        self.ipc_shutdown.store(true, .seq_cst);
        pokePipeServer(self.ipc_pipe_name_utf16) catch {};
        if (self.ipc_thread) |thread| thread.join();
        self.ipc_thread = null;
    }

    fn openConfigFile(self: *App) !void {
        const paths = self.config.@"config-file".value.items;
        if (paths.len == 0) return error.FileNotFound;

        const path = switch (paths[0]) {
            .required => |v| v,
            .optional => |v| v,
        };
        var child = std.process.Child.init(
            &.{ "explorer.exe", path },
            self.core_app.alloc,
        );
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
    }

    fn openOnScreenKeyboard(self: *App) void {
        var child = std.process.Child.init(&.{"osk.exe"}, self.core_app.alloc);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch {
            self.warnOnce(&self.warned_osk_actions, .show_on_screen_keyboard, "Win32 无法启动 on-screen keyboard");
        };
    }

    fn messageMouseButtonState(msg: win.UINT) input.MouseButtonState {
        return switch (msg) {
            win.WM_LBUTTONDOWN,
            win.WM_RBUTTONDOWN,
            win.WM_MBUTTONDOWN,
            win.WM_XBUTTONDOWN,
            => .press,
            else => .release,
        };
    }

    fn messageMouseButton(msg: win.UINT, w_param: win.WPARAM) input.MouseButton {
        return switch (msg) {
            win.WM_LBUTTONDOWN,
            win.WM_LBUTTONUP,
            => .left,
            win.WM_RBUTTONDOWN,
            win.WM_RBUTTONUP,
            => .right,
            win.WM_MBUTTONDOWN,
            win.WM_MBUTTONUP,
            => .middle,
            win.WM_XBUTTONDOWN,
            win.WM_XBUTTONUP,
            => switch (win.highWord(@bitCast(@as(win.LPARAM, @intCast(w_param))))) {
                win.XBUTTON1 => .four,
                win.XBUTTON2 => .five,
                else => .unknown,
            },
            else => .unknown,
        };
    }

    fn messageMods() input.Mods {
        return .{
            .shift = keyStatePressed(win.VK_SHIFT),
            .ctrl = keyStatePressed(win.VK_CONTROL),
            .alt = keyStatePressed(win.VK_MENU),
            .super = keyStatePressed(win.VK_LWIN) or keyStatePressed(win.VK_RWIN),
            .caps_lock = keyStateToggled(win.VK_CAPITAL),
            .num_lock = keyStateToggled(win.VK_NUMLOCK),
        };
    }

    fn messageKeyAction(msg: win.UINT, l_param: win.LPARAM) input.Action {
        return switch (msg) {
            win.WM_KEYUP, win.WM_SYSKEYUP => .release,
            else => if (win.keyWasDown(l_param)) .repeat else .press,
        };
    }

    fn messageKey(l_param: win.LPARAM) input.Key {
        const scan_code = win.keyScanCode(l_param);
        if (scan_code == 0) return .unidentified;
        const native_code: u32 = if (win.keyIsExtended(l_param))
            0xE000 | scan_code
        else
            scan_code;

        for (input.keycodes.entries) |entry| {
            if (entry.native == native_code) return entry.key;
        }

        return .unidentified;
    }

    fn keyStatePressed(vk: i32) bool {
        return (win.GetKeyState(vk) & @as(win.SHORT, @bitCast(@as(u16, 0x8000)))) != 0;
    }

    fn keyStateToggled(vk: i32) bool {
        return (win.GetKeyState(vk) & 0x0001) != 0;
    }

    fn detectKeyboardLayout() input.KeyboardLayout {
        var klid: [9:0]u16 = [_:0]u16{0} ** 9;
        if (win.GetKeyboardLayoutNameW(&klid) == 0) return .unknown;

        var buf: [8]u8 = undefined;
        for (&buf, 0..) |*slot, i| {
            slot.* = @intCast(klid[i] & 0xFF);
        }

        if (std.mem.eql(u8, &buf, "00000409")) return .us_standard;
        if (std.mem.eql(u8, &buf, "00020409")) return .us_international;
        return .unknown;
    }

    fn windowProc(
        hwnd: win.HWND,
        msg: win.UINT,
        w_param: win.WPARAM,
        l_param: win.LPARAM,
    ) callconv(.winapi) win.LRESULT {
        if (msg == win.WM_NCCREATE) {
            traceWin32WindowProc(msg, "wm_nccreate.begin");
            const create_struct: *const win.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(l_param)));
            const app: *App = @ptrFromInt(@intFromPtr(create_struct.lpCreateParams.?));
            _ = win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, @intCast(@intFromPtr(app)));
            traceWin32WindowProc(msg, "wm_nccreate.ready");
        }

        traceWin32WindowProc(msg, "from_window.begin");
        const app = fromWindow(hwnd) orelse return win.DefWindowProcW(hwnd, msg, w_param, l_param);
        traceWin32WindowProc(msg, "from_window.ready");
        return app.handleMessage(hwnd, msg, w_param, l_param);
    }
};

const PendingWindowRequest = struct {
    parent: ?*CoreSurface = null,
    arguments: ?[][:0]const u8 = null,

    fn clone(self: PendingWindowRequest, alloc: Allocator) !PendingWindowRequest {
        var result: PendingWindowRequest = .{
            .parent = self.parent,
        };
        if (self.arguments) |arguments| {
            const copied = try alloc.alloc([:0]const u8, arguments.len);
            @memset(copied, "");
            errdefer {
                for (copied) |argument| {
                    if (argument.len != 0) alloc.free(argument);
                }
                alloc.free(copied);
            }
            for (arguments, 0..) |argument, i| {
                copied[i] = try alloc.dupeZ(u8, argument);
            }
            result.arguments = copied;
        }

        return result;
    }

    fn deinit(self: *PendingWindowRequest, alloc: Allocator) void {
        if (self.arguments) |arguments| {
            for (arguments) |argument| alloc.free(argument);
            alloc.free(arguments);
        }
        self.* = undefined;
    }
};

fn buildPipeNameUtf8(alloc: Allocator, config: *const configpkg.Config) ![:0]const u8 {
    var builder: std.ArrayListUnmanaged(u8) = .empty;
    errdefer builder.deinit(alloc);

    try builder.appendSlice(alloc, ipc_pipe_prefix);
    const raw_name = config.class orelse "default";
    for (raw_name) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') {
            try builder.append(alloc, std.ascii.toLower(c));
        } else {
            try builder.append(alloc, '_');
        }
    }

    return try builder.toOwnedSliceSentinel(alloc, 0);
}

fn sendIpcNewWindowRequest(
    alloc: Allocator,
    target: apprt.ipc.Target,
    value: apprt.ipc.Action.NewWindow,
) (Allocator.Error || std.os.windows.WriteFileError || apprt.ipc.Errors || error{InvalidUtf8})!bool {
    const pipe_name_utf8 = try pipeNameForTarget(alloc, target);
    defer alloc.free(pipe_name_utf8);

    const pipe_name_utf16 = try std.unicode.utf8ToUtf16LeAllocZ(alloc, pipe_name_utf8);
    defer alloc.free(pipe_name_utf16);

    _ = win.WaitNamedPipeW(pipe_name_utf16.ptr, 1500);

    const handle = std.os.windows.kernel32.CreateFileW(
        pipe_name_utf16.ptr,
        std.os.windows.GENERIC_WRITE,
        0,
        null,
        std.os.windows.OPEN_EXISTING,
        0,
        null,
    );
    if (handle == std.os.windows.INVALID_HANDLE_VALUE) {
        var buf: [256]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&buf);
        const stderr = &stderr_writer.interface;
        stderr.print(
            "Windows IPC 连接失败，未找到运行中的实例: {s}\n",
            .{pipe_name_utf8},
        ) catch {};
        stderr.flush() catch {};
        return error.IPCFailed;
    }
    defer std.os.windows.CloseHandle(handle);

    const payload = try encodeIpcNewWindowPayload(alloc, value.arguments);
    defer alloc.free(payload);

    _ = try std.os.windows.WriteFile(handle, payload, null);
    _ = std.os.windows.kernel32.FlushFileBuffers(handle);
    return true;
}

fn pipeNameForTarget(alloc: Allocator, target: apprt.ipc.Target) ![:0]const u8 {
    const raw_name = switch (target) {
        .class => |class| class,
        .detect => "default",
    };

    var builder: std.ArrayListUnmanaged(u8) = .empty;
    errdefer builder.deinit(alloc);
    try builder.appendSlice(alloc, ipc_pipe_prefix);
    for (raw_name) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') {
            try builder.append(alloc, std.ascii.toLower(c));
        } else {
            try builder.append(alloc, '_');
        }
    }

    return try builder.toOwnedSliceSentinel(alloc, 0);
}

fn encodeIpcNewWindowPayload(
    alloc: Allocator,
    arguments: ?[][:0]const u8,
) ![]u8 {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    errdefer bytes.deinit(alloc);

    try appendU32(&bytes, alloc, 1);
    try appendU32(&bytes, alloc, if (arguments) |argv| @intCast(argv.len) else 0);
    if (arguments) |argv| {
        for (argv) |argument| {
            try appendU32(&bytes, alloc, @intCast(argument.len));
            try bytes.appendSlice(alloc, argument);
        }
    }

    return try bytes.toOwnedSlice(alloc);
}

fn decodeIpcNewWindowPayload(alloc: Allocator, payload: []const u8) !PendingWindowRequest {
    var cursor: usize = 0;
    const version = try readU32(payload, &cursor);
    if (version != 1) return error.InvalidIPCMessage;

    const argc = try readU32(payload, &cursor);
    if (argc == 0) return .{};

    const args = try alloc.alloc([:0]const u8, argc);
    @memset(args, "");
    errdefer {
        for (args) |argument| {
            if (argument.len != 0) alloc.free(argument);
        }
        alloc.free(args);
    }
    for (args, 0..) |*slot, i| {
        _ = i;
        const len = try readU32(payload, &cursor);
        if (cursor + len > payload.len) return error.InvalidIPCMessage;
        slot.* = try alloc.dupeZ(u8, payload[cursor .. cursor + len]);
        cursor += len;
    }

    return .{ .arguments = args };
}

fn appendU32(list: *std.ArrayListUnmanaged(u8), alloc: Allocator, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try list.appendSlice(alloc, &buf);
}

fn readU32(bytes: []const u8, cursor: *usize) !u32 {
    if (cursor.* + 4 > bytes.len) return error.InvalidIPCMessage;
    defer cursor.* += 4;
    return std.mem.readInt(u32, bytes[cursor.* .. cursor.* + 4][0..4], .little);
}

fn pokePipeServer(pipe_name_utf16: [:0]const u16) !void {
    const handle = std.os.windows.kernel32.CreateFileW(
        pipe_name_utf16.ptr,
        std.os.windows.GENERIC_WRITE,
        0,
        null,
        std.os.windows.OPEN_EXISTING,
        0,
        null,
    );
    if (handle == std.os.windows.INVALID_HANDLE_VALUE) return;
    defer std.os.windows.CloseHandle(handle);
}

fn ipcThreadMain(app: *App) void {
    ipcThreadMainFallible(app) catch |err| {
        log.err("win32 ipc server terminated err={}", .{err});
    };
}

fn quitTimerThreadMain(app: *App, generation: u32, delay_ns: u64) void {
    std.Thread.sleep(delay_ns);
    if (app.quit_timer_generation.load(.seq_cst) != generation) return;
    if (app.thread_id == 0) return;
    _ = win.PostThreadMessageW(app.thread_id, win.WM_GHOSTTY_QUIT_TIMER, generation, 0);
}

fn ipcThreadMainFallible(app: *App) !void {
    while (!app.ipc_shutdown.load(.seq_cst)) {
        const pipe = std.os.windows.kernel32.CreateNamedPipeW(
            app.ipc_pipe_name_utf16.ptr,
            std.os.windows.PIPE_ACCESS_INBOUND,
            std.os.windows.PIPE_TYPE_BYTE | std.os.windows.PIPE_READMODE_BYTE | std.os.windows.PIPE_WAIT,
            1,
            4096,
            4096,
            0,
            null,
        );
        if (pipe == std.os.windows.INVALID_HANDLE_VALUE) return;
        defer std.os.windows.CloseHandle(pipe);

        if (win.ConnectNamedPipe(pipe, null) == 0) {
            const err = std.os.windows.GetLastError();
            if (err != .PIPE_CONNECTED and !app.ipc_shutdown.load(.seq_cst)) {
                return error.Unexpected;
            }
        }

        var payload: std.ArrayListUnmanaged(u8) = .empty;
        defer payload.deinit(app.core_app.alloc);
        var buf: [512]u8 = undefined;
        while (true) {
            const read = std.os.windows.ReadFile(pipe, &buf, null) catch |err| switch (err) {
                error.BrokenPipe => break,
                else => return err,
            };
            if (read == 0) break;
            try payload.appendSlice(app.core_app.alloc, buf[0..read]);
            if (read < buf.len) break;
        }

        if (app.ipc_shutdown.load(.seq_cst) or payload.items.len == 0) continue;
        var request = try decodeIpcNewWindowPayload(app.core_app.alloc, payload.items);
        errdefer request.deinit(app.core_app.alloc);

        app.pending_window_requests_mutex.lock();
        defer app.pending_window_requests_mutex.unlock();
        try app.pending_window_requests.append(app.core_app.alloc, request);
        app.wakeup();
    }
}

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
    last_text_input: [16]u8 = [_]u8{0} ** 16,
    last_text_input_len: u8 = 0,
    suppress_char_messages: u8 = 0,
    mouse_hidden: bool = false,
    mouse_shape: terminal.MouseShape = .text,
    topmost: bool = false,
    fullscreen: bool = false,
    decorations_enabled: bool = true,
    min_width_px: u32 = 0,
    min_height_px: u32 = 0,
    saved_window_style: win.LONG_PTR = 0,
    saved_window_rect: win.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    graphics: GraphicsState = .{},

    pub const GraphicsState = struct {
        d3d12_device: ?*winos.c.ID3D12Device = null,
        dxgi_factory: ?*winos.c.IDXGIFactory4 = null,
        command_queue: ?*winos.c.ID3D12CommandQueue = null,
        command_allocator: ?*winos.c.ID3D12CommandAllocator = null,
        command_list: ?*winos.c.ID3D12GraphicsCommandList = null,
        swap_chain: ?*winos.c.IDXGISwapChain3 = null,
        rtv_heap: ?*winos.c.ID3D12DescriptorHeap = null,
        srv_heap: ?*winos.c.ID3D12DescriptorHeap = null,
        backbuffers: [swap_chain_buffer_count]?*winos.c.ID3D12Resource = .{null} ** swap_chain_buffer_count,
        rtv_descriptor_size: u32 = 0,
        rtv_heap_start_ptr: u64 = 0,
        software_upload: ?*winos.c.ID3D12Resource = null,
        software_upload_capacity: u64 = 0,
        software_upload_row_pitch: u32 = 0,
        fence: ?*winos.c.ID3D12Fence = null,
        fence_event: ?winos.HANDLE = null,
        fence_value: u64 = 0,
        dwrite_factory: ?*winos.graphics.IDWriteFactory = null,
        frame_index: u32 = 0,
        last_present_generation: u64 = 0,
    };

    pub fn init(
        self: *Surface,
        app: *App,
        hwnd: win.HWND,
        width: u32,
        height: u32,
        config: *const configpkg.Config,
    ) !void {
        self.* = .{
            .app = app,
            .hwnd = hwnd,
            .size = .{ .width = width, .height = height },
        };
        traceWin32InitStep("surface.init.enter");
        self.updateContentScaleFromWindow();
        traceWin32InitStep("surface.init.content_scale.ready");
        traceWin32InitStep("surface.init.graphics.begin");
        try self.initGraphics();
        traceWin32InitStep("surface.init.graphics.ready");
        errdefer self.deinitGraphics();

        if (app.ci_smoke_mode == .native) return;

        traceWin32InitStep("surface.init.add_surface.begin");
        try app.core_app.addSurface(self);
        traceWin32InitStep("surface.init.add_surface.ready");
        errdefer app.core_app.deleteSurface(self);

        traceWin32InitStep("surface.init.core_surface_alloc.begin");
        const core_surface = try app.core_app.alloc.create(CoreSurface);
        traceWin32InitStep("surface.init.core_surface_alloc.ready");
        errdefer app.core_app.alloc.destroy(core_surface);

        traceWin32InitStep("surface.init.core_surface_init.begin");
        try core_surface.init(
            app.core_app.alloc,
            config,
            app.core_app,
            app,
            self,
        );
        traceWin32InitStep("surface.init.core_surface_init.ready");
        errdefer core_surface.deinit();

        self.core_surface = core_surface;
    }

    fn runCiSmoke(self: *Surface) !void {
        if (self.app.ci_smoke_mode == .disabled) return;
        switch (self.app.ci_smoke_mode) {
            .disabled => {},
            .native => {
                if (!self.app.ci_smoke_native_draw_ready_logged) {
                    self.app.ci_smoke_native_draw_ready_logged = true;
                    log.info("ci.win32.native_draw_ready", .{});
                }

                try self.recordNativeClear();
                const sc = self.graphics.swap_chain.?;
                if (sc.lpVtbl[0].Present.?(sc, 1, 0) != winos.S_OK) {
                    return error.Unexpected;
                }
                if (!self.app.ci_smoke_present_ok_logged) {
                    self.app.ci_smoke_present_ok_logged = true;
                    log.info("ci.win32.present_ok", .{});
                }
                try self.waitForGpuIdle();
                self.graphics.frame_index = sc.lpVtbl[0].GetCurrentBackBufferIndex.?(sc);
            },
            .core_draw => {
                const core_surface = self.core_surface orelse return error.Unexpected;
                try core_surface.refreshCallback();
                try core_surface.draw();
                if (!self.app.ci_smoke_native_draw_ready_logged) {
                    self.app.ci_smoke_native_draw_ready_logged = true;
                    log.info("ci.win32.native_draw_ready", .{});
                }
                if (!self.app.ci_smoke_core_draw_ready_logged) {
                    self.app.ci_smoke_core_draw_ready_logged = true;
                    log.info("ci.win32.core_draw_ready", .{});
                }
                if (!self.app.ci_smoke_present_ok_logged) {
                    self.app.ci_smoke_present_ok_logged = true;
                    log.info("ci.win32.present_ok", .{});
                }
            },
        }
        _ = win.PostMessageW(self.hwnd, win.WM_CLOSE, 0, 0);
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
        winos.graphics.release(@ptrCast(self.graphics.command_list));
        self.graphics.command_list = null;
        winos.graphics.release(@ptrCast(self.graphics.command_allocator));
        self.graphics.command_allocator = null;
        winos.graphics.release(@ptrCast(self.graphics.software_upload));
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

        var raw_factory: ?*winos.c.IDXGIFactory4 = null;
        traceWin32InitStep("surface.init.graphics.dxgi_factory.begin");
        if (winos.graphics.CreateDXGIFactory1(
            &winos.graphics.IID_IDXGIFactory4,
            @ptrCast(&raw_factory),
        ) != winos.S_OK) return error.Unexpected;
        self.graphics.dxgi_factory = raw_factory.?;
        traceWin32InitStep("surface.init.graphics.dxgi_factory.ready");
        var raw_device: ?*winos.c.ID3D12Device = null;
        traceWin32InitStep("surface.init.graphics.d3d12_device.begin");
        if (winos.graphics.D3D12CreateDevice(
            null,
            .@"11_0",
            &winos.graphics.IID_ID3D12Device,
            @ptrCast(&raw_device),
        ) != winos.S_OK) return error.Unexpected;
        self.graphics.d3d12_device = raw_device.?;
        traceWin32InitStep("surface.init.graphics.d3d12_device.ready");

        var queue_desc: winos.c.D3D12_COMMAND_QUEUE_DESC = std.mem.zeroes(winos.c.D3D12_COMMAND_QUEUE_DESC);
        queue_desc.Type = winos.c.D3D12_COMMAND_LIST_TYPE_DIRECT;
        queue_desc.Flags = winos.c.D3D12_COMMAND_QUEUE_FLAG_NONE;
        queue_desc.Priority = 0;
        queue_desc.NodeMask = 0;

        const device = self.graphics.d3d12_device.?;

        var raw_queue: ?*winos.c.ID3D12CommandQueue = null;
        traceWin32InitStep("surface.init.graphics.command_queue.begin");
        if (device.lpVtbl[0].CreateCommandQueue.?(
            device,
            &queue_desc,
            &winos.c.IID_ID3D12CommandQueue,
            @ptrCast(&raw_queue),
        ) != winos.S_OK) return error.Unexpected;
        self.graphics.command_queue = raw_queue.?;
        traceWin32InitStep("surface.init.graphics.command_queue.ready");

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

        const factory = self.graphics.dxgi_factory.?;
        const command_queue = self.graphics.command_queue.?;
        const CreateSwapChainForHwndFn = *const fn (
            *winos.c.IDXGIFactory4,
            ?*anyopaque,
            windows.HWND,
            *const winos.c.DXGI_SWAP_CHAIN_DESC1,
            ?*const winos.c.DXGI_SWAP_CHAIN_FULLSCREEN_DESC,
            ?*anyopaque,
            ?*?*winos.c.IDXGISwapChain1,
        ) callconv(.winapi) winos.graphics.HRESULT;
        const create_swap_chain_for_hwnd: CreateSwapChainForHwndFn =
            @ptrCast(factory.lpVtbl[0].CreateSwapChainForHwnd.?);

        var swap_chain1: ?*winos.c.IDXGISwapChain1 = null;
        traceWin32InitStep("surface.init.graphics.swap_chain.begin");
        if (create_swap_chain_for_hwnd(
            factory,
            @ptrCast(command_queue),
            self.hwnd.?,
            &swap_chain_desc,
            null,
            null,
            &swap_chain1,
        ) != winos.S_OK) return error.Unexpected;

        var raw_swap_chain3: ?*winos.c.IDXGISwapChain3 = null;
        if (swap_chain1.?.lpVtbl[0].QueryInterface.?(
            @ptrCast(swap_chain1.?),
            &winos.c.IID_IDXGISwapChain3,
            @ptrCast(&raw_swap_chain3),
        ) != winos.S_OK) return error.Unexpected;
        self.graphics.swap_chain = raw_swap_chain3.?;
        const swap_chain3 = self.graphics.swap_chain.?;
        self.graphics.frame_index = swap_chain3.lpVtbl[0].GetCurrentBackBufferIndex.?(swap_chain3);
        winos.graphics.release(@ptrCast(swap_chain1.?));
        traceWin32InitStep("surface.init.graphics.swap_chain.ready");

        var rtv_heap_desc: winos.c.D3D12_DESCRIPTOR_HEAP_DESC = std.mem.zeroes(winos.c.D3D12_DESCRIPTOR_HEAP_DESC);
        rtv_heap_desc.Type = winos.c.D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
        rtv_heap_desc.NumDescriptors = 2;
        rtv_heap_desc.Flags = winos.c.D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
        rtv_heap_desc.NodeMask = 0;

        var raw_rtv_heap: ?*winos.c.ID3D12DescriptorHeap = null;
        traceWin32InitStep("surface.init.graphics.rtv_heap.begin");
        if (device.lpVtbl[0].CreateDescriptorHeap.?(
            device,
            &rtv_heap_desc,
            &winos.c.IID_ID3D12DescriptorHeap,
            @ptrCast(&raw_rtv_heap),
        ) != winos.S_OK) return error.Unexpected;
        self.graphics.rtv_heap = raw_rtv_heap.?;
        self.graphics.rtv_descriptor_size = device.lpVtbl[0].GetDescriptorHandleIncrementSize.?(device, winos.c.D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
        traceWin32InitStep("surface.init.graphics.rtv_heap.ready");

        var raw_command_allocator: ?*winos.c.ID3D12CommandAllocator = null;
        traceWin32InitStep("surface.init.graphics.command_allocator.begin");
        if (device.lpVtbl[0].CreateCommandAllocator.?(
            device,
            winos.c.D3D12_COMMAND_LIST_TYPE_DIRECT,
            &winos.c.IID_ID3D12CommandAllocator,
            @ptrCast(&raw_command_allocator),
        ) != winos.S_OK) return error.Unexpected;
        self.graphics.command_allocator = raw_command_allocator.?;
        traceWin32InitStep("surface.init.graphics.command_allocator.ready");

        const command_allocator = self.graphics.command_allocator.?;

        var raw_command_list: ?*winos.c.ID3D12GraphicsCommandList = null;
        traceWin32InitStep("surface.init.graphics.command_list.begin");
        if (device.lpVtbl[0].CreateCommandList.?(
            device,
            0,
            winos.c.D3D12_COMMAND_LIST_TYPE_DIRECT,
            command_allocator,
            null,
            &winos.c.IID_ID3D12GraphicsCommandList,
            @ptrCast(&raw_command_list),
        ) != winos.S_OK) return error.Unexpected;
        self.graphics.command_list = raw_command_list.?;
        traceWin32InitStep("surface.init.graphics.command_list.ready");

        const command_list = self.graphics.command_list.?;
        if (command_list.lpVtbl[0].Close.?(command_list) != winos.S_OK) return error.Unexpected;
        var raw_fence: ?*winos.c.ID3D12Fence = null;
        traceWin32InitStep("surface.init.graphics.fence.begin");
        if (device.lpVtbl[0].CreateFence.?(
            device,
            0,
            winos.c.D3D12_FENCE_FLAG_NONE,
            &winos.c.IID_ID3D12Fence,
            @ptrCast(&raw_fence),
        ) != winos.S_OK) return error.Unexpected;
        self.graphics.fence = raw_fence.?;
        traceWin32InitStep("surface.init.graphics.fence.ready");
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
        if (clipboard_type != .standard) return false;
        const surface = self.core_surface orelse return false;

        if (win.OpenClipboard(self.hwnd) == 0) return false;
        defer _ = win.CloseClipboard();

        if (win.IsClipboardFormatAvailable(win.CF_UNICODETEXT) == 0) return false;
        const handle = win.GetClipboardData(win.CF_UNICODETEXT);
        if (handle == null) return false;

        const bytes_len = win.GlobalSize(@ptrCast(handle));
        if (bytes_len < 2) return false;

        const raw = win.GlobalLock(@ptrCast(handle)) orelse return false;
        defer _ = win.GlobalUnlock(@ptrCast(handle));

        const bytes: [*]const u8 = @ptrCast(raw);
        const utf16_len = bytes_len / 2;
        var utf16 = try self.app.core_app.alloc.alloc(u16, utf16_len);
        defer self.app.core_app.alloc.free(utf16);

        var i: usize = 0;
        var used: usize = 0;
        while (i + 1 < bytes_len) : (i += 2) {
            const code_unit =
                @as(u16, bytes[i]) |
                (@as(u16, bytes[i + 1]) << 8);
            if (code_unit == 0) break;
            utf16[used] = code_unit;
            used += 1;
        }

        const utf8 = try std.unicode.utf16LeToUtf8AllocZ(self.app.core_app.alloc, utf16[0..used]);
        defer self.app.core_app.alloc.free(utf8);

        surface.completeClipboardRequest(
            state,
            utf8,
            false,
        ) catch |err| switch (err) {
            error.UnsafePaste,
            error.UnauthorizedPaste,
            => {
                if (!self.confirmClipboardAccess("允许将系统剪贴板内容粘贴到 Ghostty 吗？")) {
                    log.warn("win32 clipboard request denied by user err={}", .{err});
                    return false;
                }
                try surface.completeClipboardRequest(state, utf8, true);
            },
            else => return err,
        };

        return true;
    }

    pub fn setClipboard(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        contents: []const apprt.ClipboardContent,
        confirm: bool,
    ) !void {
        if (clipboard_type != .standard) return;
        if (confirm and !self.confirmClipboardAccess("允许 Ghostty 写入系统剪贴板吗？")) return;

        var text: ?[:0]const u8 = null;
        for (contents) |content| {
            if (std.mem.eql(u8, content.mime, "text/plain")) {
                text = content.data;
                break;
            }
        }
        if (text == null and contents.len > 0) text = contents[0].data;
        const data = text orelse return;

        const utf16 = try std.unicode.utf8ToUtf16LeAllocZ(self.app.core_app.alloc, data);
        defer self.app.core_app.alloc.free(utf16);

        if (win.OpenClipboard(self.hwnd) == 0) return error.Unexpected;
        defer _ = win.CloseClipboard();

        if (win.EmptyClipboard() == 0) return error.Unexpected;

        const bytes_len = utf16.len * @sizeOf(u16);
        const mem = win.GlobalAlloc(win.GMEM_MOVEABLE, bytes_len) orelse return error.OutOfMemory;
        errdefer _ = win.GlobalFree(mem);

        const dst = win.GlobalLock(mem) orelse return error.OutOfMemory;
        defer _ = win.GlobalUnlock(mem);
        @memcpy(@as([*]u8, @ptrCast(dst))[0..bytes_len], std.mem.sliceAsBytes(utf16));

        if (win.SetClipboardData(win.CF_UNICODETEXT, mem) == null) {
            return error.Unexpected;
        }
    }

    fn copyTitleToClipboard(self: *Surface) bool {
        const title = self.title orelse return false;
        self.setClipboard(.standard, &.{.{
            .mime = "text/plain",
            .data = title,
        }}, false) catch return false;
        return true;
    }

    fn confirmClipboardAccess(self: *Surface, prompt_utf8: []const u8) bool {
        const prompt = std.unicode.utf8ToUtf16LeAllocZ(self.app.core_app.alloc, prompt_utf8) catch
            return false;
        defer self.app.core_app.alloc.free(prompt);
        const title = std.unicode.utf8ToUtf16LeAllocZ(self.app.core_app.alloc, "Ghostty") catch
            return false;
        defer self.app.core_app.alloc.free(title);

        return win.MessageBoxW(
            self.hwnd,
            prompt.ptr,
            title.ptr,
            win.MB_OKCANCEL | win.MB_ICONWARNING,
        ) == win.IDOK;
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

        if (self.app.ci_smoke_mode != .disabled and !self.app.ci_smoke_software_frame_ready_logged) {
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

    fn presentTerminal(self: *Surface) void {
        _ = win.ShowWindow(self.hwnd, if (self.fullscreen or win.IsZoomed(self.hwnd) != 0) win.SW_RESTORE else win.SW_SHOW);
        _ = win.BringWindowToTop(self.hwnd);
        _ = win.SetForegroundWindow(self.hwnd);
    }

    fn isVisible(self: *const Surface) bool {
        return (win.GetWindowLongPtrW(self.hwnd, win.GWL_STYLE) & @as(win.LONG_PTR, win.WS_VISIBLE)) != 0;
    }

    fn setVisible(self: *Surface, visible: bool) void {
        _ = win.ShowWindow(self.hwnd, if (visible) win.SW_SHOW else win.SW_HIDE);
    }

    fn toggleMaximize(self: *Surface) void {
        _ = win.ShowWindow(self.hwnd, if (win.IsZoomed(self.hwnd) != 0) win.SW_RESTORE else win.SW_MAXIMIZE);
    }

    fn toggleVisibility(self: *Surface) void {
        self.setVisible(!self.isVisible());
    }

    fn toggleFullscreen(self: *Surface, _: apprt.action.Fullscreen) !void {
        const style = win.GetWindowLongPtrW(self.hwnd, win.GWL_STYLE);
        if (!self.fullscreen) {
            self.saved_window_style = style;
            if (win.GetWindowRect(self.hwnd, &self.saved_window_rect) == 0) return error.Unexpected;

            const monitor = win.MonitorFromWindow(self.hwnd, win.MONITOR_DEFAULTTONEAREST) orelse
                return error.Unexpected;
            var monitor_info: win.MONITORINFO = .{
                .cbSize = @sizeOf(win.MONITORINFO),
                .rcMonitor = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
                .rcWork = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
                .dwFlags = 0,
            };
            if (win.GetMonitorInfoW(monitor, &monitor_info) == 0) return error.Unexpected;

            const fullscreen_style = style & ~@as(win.LONG_PTR, win.WS_OVERLAPPEDWINDOW);
            _ = win.SetWindowLongPtrW(self.hwnd, win.GWL_STYLE, fullscreen_style | win.WS_VISIBLE);
            _ = win.SetWindowPos(
                self.hwnd,
                if (self.topmost) win.HWND_TOPMOST else null,
                monitor_info.rcMonitor.left,
                monitor_info.rcMonitor.top,
                monitor_info.rcMonitor.right - monitor_info.rcMonitor.left,
                monitor_info.rcMonitor.bottom - monitor_info.rcMonitor.top,
                win.SWP_FRAMECHANGED | win.SWP_SHOWWINDOW,
            );
            self.fullscreen = true;
            return;
        }

        const restored_style = if (self.decorations_enabled)
            self.saved_window_style
        else
            (self.saved_window_style & ~@as(win.LONG_PTR, win.WS_OVERLAPPEDWINDOW)) | win.WS_VISIBLE;
        _ = win.SetWindowLongPtrW(self.hwnd, win.GWL_STYLE, restored_style);
        _ = win.SetWindowPos(
            self.hwnd,
            if (self.topmost) win.HWND_TOPMOST else win.HWND_NOTOPMOST,
            self.saved_window_rect.left,
            self.saved_window_rect.top,
            self.saved_window_rect.right - self.saved_window_rect.left,
            self.saved_window_rect.bottom - self.saved_window_rect.top,
            win.SWP_FRAMECHANGED | win.SWP_SHOWWINDOW,
        );
        self.fullscreen = false;
    }

    fn toggleWindowDecorations(self: *Surface) !void {
        self.decorations_enabled = !self.decorations_enabled;
        if (self.fullscreen) return;

        const style = win.GetWindowLongPtrW(self.hwnd, win.GWL_STYLE);
        const new_style = if (self.decorations_enabled)
            style | @as(win.LONG_PTR, win.WS_OVERLAPPEDWINDOW)
        else
            (style & ~@as(win.LONG_PTR, win.WS_OVERLAPPEDWINDOW)) | win.WS_VISIBLE;
        _ = win.SetWindowLongPtrW(self.hwnd, win.GWL_STYLE, new_style);
        _ = win.SetWindowPos(
            self.hwnd,
            null,
            0,
            0,
            0,
            0,
            win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOZORDER | win.SWP_NOOWNERZORDER | win.SWP_FRAMECHANGED,
        );
    }

    fn setFloatWindow(self: *Surface, value: apprt.action.FloatWindow) !void {
        self.topmost = switch (value) {
            .on => true,
            .off => false,
            .toggle => !self.topmost,
        };
        _ = win.SetWindowPos(
            self.hwnd,
            if (self.topmost) win.HWND_TOPMOST else win.HWND_NOTOPMOST,
            0,
            0,
            0,
            0,
            win.SWP_NOMOVE | win.SWP_NOSIZE,
        );
    }

    fn setMouseShape(self: *Surface, shape: terminal.MouseShape) void {
        self.mouse_shape = shape;
        self.applyCursor();
    }

    fn setMouseVisibility(self: *Surface, value: apprt.action.MouseVisibility) void {
        self.mouse_hidden = value == .hidden;
        _ = win.ShowCursor(if (self.mouse_hidden) 0 else 1);
        self.applyCursor();
    }

    fn applyInitialSize(self: *Surface, value: apprt.action.InitialSize) void {
        if (value.width == 0 or value.height == 0) return;
        _ = win.SetWindowPos(
            self.hwnd,
            null,
            0,
            0,
            @intCast(value.width),
            @intCast(value.height),
            win.SWP_NOMOVE | win.SWP_NOZORDER,
        );
    }

    fn resetWindowSize(self: *Surface) bool {
        const core_surface = self.core_surface orelse return false;
        if (core_surface.config.window_height == 0 or core_surface.config.window_width == 0) {
            return false;
        }
        if (self.content_scale.x == 0 or self.content_scale.y == 0) return false;

        const width_px = @max(core_surface.config.window_width, 10) * core_surface.size.cell.width;
        const height_px = @max(core_surface.config.window_height, 4) * core_surface.size.cell.height;
        const final_width: u32 =
            @as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(width_px)) / self.content_scale.x))) +
            core_surface.size.padding.left +
            core_surface.size.padding.right;
        const final_height: u32 =
            @as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(height_px)) / self.content_scale.y))) +
            core_surface.size.padding.top +
            core_surface.size.padding.bottom;
        self.applyInitialSize(.{ .width = final_width, .height = final_height });
        return true;
    }

    fn setSizeLimit(self: *Surface, value: apprt.action.SizeLimit) void {
        self.min_width_px = value.min_width;
        self.min_height_px = value.min_height;
    }

    fn applyMinMaxInfo(self: *Surface, info: *win.MINMAXINFO) void {
        if (self.min_width_px > 0) info.ptMinTrackSize.x = @intCast(self.min_width_px);
        if (self.min_height_px > 0) info.ptMinTrackSize.y = @intCast(self.min_height_px);
    }

    fn applyCursor(self: *Surface) void {
        if (self.mouse_hidden) {
            _ = win.SetCursor(null);
            return;
        }
        _ = win.SetCursor(win.LoadCursorW(null, cursorResource(self.mouse_shape)));
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

    fn updateContentScaleFromWindow(self: *Surface) void {
        const dpi = win.GetDpiForWindow(self.hwnd);
        if (dpi == 0) return;
        self.updateContentScale(
            @as(f32, @floatFromInt(dpi)) / @as(f32, @floatFromInt(win.USER_DEFAULT_SCREEN_DPI)),
            @as(f32, @floatFromInt(dpi)) / @as(f32, @floatFromInt(win.USER_DEFAULT_SCREEN_DPI)),
        );
    }

    fn updateContentScale(self: *Surface, x: f32, y: f32) void {
        if (x <= 0 or y <= 0) return;
        self.content_scale = .{ .x = x, .y = y };
        if (self.core_surface) |core_surface| {
            core_surface.contentScaleCallback(self.content_scale) catch |err| {
                log.err("error in win32 content scale callback err={}", .{err});
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
        self.textInputCallback(buf[0..len], false);
    }

    fn keyCallback(
        self: *Surface,
        action: input.Action,
        virtual_key: u32,
        key: input.Key,
        mods: input.Mods,
    ) void {
        if (self.core_surface) |core_surface| {
            const translation = if (action == .press or action == .repeat)
                self.translateKeyEvent(virtual_key, mods)
            else
                KeyTranslation{};
            _ = core_surface.keyCallback(.{
                .action = action,
                .key = key,
                .mods = mods,
                .consumed_mods = translation.consumed_mods,
                .composing = false,
                .utf8 = translation.text(),
                .unshifted_codepoint = translation.unshifted_codepoint,
            }) catch |err| {
                log.err("error in win32 key callback err={}", .{err});
                return;
            };
        }
    }

    fn mouseButtonCallback(
        self: *Surface,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: input.Mods,
    ) void {
        if (self.core_surface) |core_surface| {
            _ = core_surface.mouseButtonCallback(action, button, mods) catch |err| {
                log.err("error in win32 mouse button callback err={}", .{err});
                return;
            };
        }
    }

    fn scrollCallback(
        self: *Surface,
        xoff: f64,
        yoff: f64,
        mods: input.ScrollMods,
    ) void {
        if (self.core_surface) |core_surface| {
            core_surface.scrollCallback(xoff, yoff, mods) catch |err| {
                log.err("error in win32 scroll callback err={}", .{err});
                return;
            };
        }
    }

    fn textInputCallback(self: *Surface, text: []const u8, composing: bool) void {
        @memset(&self.last_text_input, 0);
        const len = @min(text.len, self.last_text_input.len);
        @memcpy(self.last_text_input[0..len], text[0..len]);
        self.last_text_input_len = @intCast(len);

        if (self.core_surface) |core_surface| {
            _ = core_surface.keyCallback(.{
                .action = .press,
                .key = .unidentified,
                .mods = .{},
                .consumed_mods = .{},
                .composing = composing,
                .utf8 = self.last_text_input[0..len],
            }) catch |err| {
                log.err("error in win32 text input callback err={}", .{err});
                return;
            };
        }
    }

    fn updateImeWindow(self: *Surface) void {
        const himc = win.ImmGetContext(self.hwnd) orelse return;
        defer _ = win.ImmReleaseContext(self.hwnd, himc);

        const core_surface = self.core_surface orelse return;
        const ime = core_surface.imePoint();
        var form: win.COMPOSITIONFORM = .{
            .dwStyle = win.CFS_POINT,
            .ptCurrentPos = .{
                .x = @intFromFloat(ime.x),
                .y = @intFromFloat(ime.y),
            },
            .rcArea = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        };
        _ = win.ImmSetCompositionWindow(himc, &form);
    }

    fn handleImeComposition(self: *Surface, l_param: win.LPARAM) void {
        const himc = win.ImmGetContext(self.hwnd) orelse return;
        defer _ = win.ImmReleaseContext(self.hwnd, himc);
        self.updateImeWindow();

        if ((@as(usize, @bitCast(l_param)) & win.GCS_COMPSTR) != 0) {
            self.emitImeString(himc, win.GCS_COMPSTR, true);
        }
        if ((@as(usize, @bitCast(l_param)) & win.GCS_RESULTSTR) != 0) {
            self.emitImeString(himc, win.GCS_RESULTSTR, false);
        }
    }

    fn handleImeEndComposition(self: *Surface) void {
        self.textInputCallback("", false);
    }

    fn emitImeString(self: *Surface, himc: win.HIMC, kind: win.DWORD, composing: bool) void {
        const len_bytes = win.ImmGetCompositionStringW(himc, kind, null, 0);
        if (len_bytes <= 0) return;

        const code_units = @divExact(@as(usize, @intCast(len_bytes)), @sizeOf(u16));
        const utf16 = self.app.core_app.alloc.alloc(u16, code_units) catch return;
        defer self.app.core_app.alloc.free(utf16);
        if (win.ImmGetCompositionStringW(
            himc,
            kind,
            utf16.ptr,
            @intCast(len_bytes),
        ) < 0) return;

        const utf8 = std.unicode.utf16LeToUtf8Alloc(self.app.core_app.alloc, utf16) catch return;
        defer self.app.core_app.alloc.free(utf8);
        if (!composing) {
            self.suppress_char_messages +|= @intCast(@min(code_units, std.math.maxInt(u8)));
        }
        self.textInputCallback(utf8, composing);
    }

    fn consumeSuppressedCharMessage(self: *Surface) bool {
        if (self.suppress_char_messages == 0) return false;
        self.suppress_char_messages -= 1;
        return true;
    }

    fn unshiftedCodepoint(self: *Surface, virtual_key: u32) u21 {
        _ = self;
        var key_state: [256]u8 = [_]u8{0} ** 256;
        if (win.GetKeyboardState(&key_state) == 0) return 0;

        key_state[win.VK_SHIFT] = 0;
        key_state[win.VK_LSHIFT] = 0;
        key_state[win.VK_RSHIFT] = 0;
        key_state[win.VK_CONTROL] = 0;
        key_state[win.VK_LCONTROL] = 0;
        key_state[win.VK_RCONTROL] = 0;
        key_state[win.VK_MENU] = 0;
        key_state[win.VK_LMENU] = 0;
        key_state[win.VK_RMENU] = 0;

        const layout = win.GetKeyboardLayout(0);
        const scan_code = win.MapVirtualKeyExW(virtual_key, win.MAPVK_VK_TO_VSC, layout);
        if (scan_code == 0) return 0;

        var utf16: [4]u16 = [_]u16{0} ** 4;
        const written = win.ToUnicodeEx(
            virtual_key,
            scan_code,
            &key_state,
            &utf16,
            utf16.len,
            0,
            layout,
        );
        if (written <= 0) return 0;

        const cp = utf16[0];
        if (cp >= 0xD800 and cp <= 0xDFFF) return 0;
        return @intCast(cp);
    }

    const KeyTranslation = struct {
        bytes: [16]u8 = [_]u8{0} ** 16,
        len: u8 = 0,
        consumed_mods: input.Mods = .{},
        unshifted_codepoint: u21 = 0,
        suppress_char_messages: u8 = 0,

        fn text(self: *const KeyTranslation) []const u8 {
            return self.bytes[0..self.len];
        }
    };

    fn translateKeyEvent(
        self: *Surface,
        virtual_key: u32,
        mods: input.Mods,
    ) KeyTranslation {
        var result: KeyTranslation = .{
            .unshifted_codepoint = self.unshiftedCodepoint(virtual_key),
        };

        var key_state: [256]u8 = [_]u8{0} ** 256;
        if (win.GetKeyboardState(&key_state) == 0) return result;

        const layout = win.GetKeyboardLayout(0);
        const scan_code = win.MapVirtualKeyExW(virtual_key, win.MAPVK_VK_TO_VSC, layout);
        if (scan_code == 0) return result;

        var utf16: [8]u16 = [_]u16{0} ** 8;
        const written = win.ToUnicodeEx(
            virtual_key,
            scan_code,
            &key_state,
            &utf16,
            utf16.len,
            0,
            layout,
        );
        if (written <= 0) return result;

        const units: usize = @intCast(written);
        const utf8 = std.unicode.utf16LeToUtf8(result.bytes[0..], utf16[0..units]) catch
            return result;
        result.len = @intCast(utf8);
        result.suppress_char_messages = suppressCharMessageCount(units);
        result.consumed_mods = translatedTextConsumedMods(
            mods,
            result.text(),
            result.unshifted_codepoint,
            (win.GetKeyState(win.VK_RMENU) & @as(win.SHORT, @bitCast(@as(u16, 0x8000)))) != 0,
        );

        self.suppress_char_messages = result.suppress_char_messages;
        return result;
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

        const sc = self.graphics.swap_chain.?;
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

        const device = self.graphics.d3d12_device.?;
        const heap = self.graphics.rtv_heap.?;
        const sc = self.graphics.swap_chain.?;

        var handle: winos.c.D3D12_CPU_DESCRIPTOR_HANDLE = std.mem.zeroes(winos.c.D3D12_CPU_DESCRIPTOR_HANDLE);
        _ = heap.lpVtbl[0].GetCPUDescriptorHandleForHeapStart.?(heap, &handle);
        self.graphics.rtv_heap_start_ptr = handle.ptr;

        for (0..swap_chain_buffer_count) |i| {
            var raw_resource: ?*winos.c.ID3D12Resource = null;
            if (sc.lpVtbl[0].GetBuffer.?(
                sc,
                @intCast(i),
                &winos.c.IID_ID3D12Resource,
                @ptrCast(&raw_resource),
            ) != winos.S_OK) return error.Unexpected;

            self.graphics.backbuffers[i] = raw_resource.?;
            const resource = raw_resource.?;
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
            winos.graphics.release(@ptrCast(backbuffer.*));
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

        const allocator = self.graphics.command_allocator.?;
        const command_list = self.graphics.command_list.?;
        const queue = self.graphics.command_queue.?;
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

        const queue = self.graphics.command_queue.?;
        const fence = self.graphics.fence.?;

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
        return self.graphics.backbuffers[index];
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

        const allocator = self.graphics.command_allocator.?;
        const command_list = self.graphics.command_list.?;
        const queue = self.graphics.command_queue.?;
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

        const sc = self.graphics.swap_chain.?;
        if (sc.lpVtbl[0].Present.?(sc, 1, 0) != winos.S_OK) {
            return error.Unexpected;
        }
        if (self.app.ci_smoke_mode != .disabled and !self.app.ci_smoke_present_ok_logged) {
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
                return resource;
            }

            winos.graphics.release(@ptrCast(resource));
            self.graphics.software_upload = null;
        }

        const device = self.graphics.d3d12_device.?;
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

        var raw_resource: ?*winos.c.ID3D12Resource = null;
        if (device.lpVtbl[0].CreateCommittedResource.?(
            device,
            &heap_props,
            winos.c.D3D12_HEAP_FLAG_NONE,
            &desc,
            winos.c.D3D12_RESOURCE_STATE_GENERIC_READ,
            null,
            &winos.c.IID_ID3D12Resource,
            @ptrCast(&raw_resource),
        ) != winos.S_OK) return error.Unexpected;

        self.graphics.software_upload = raw_resource.?;
        self.graphics.software_upload_capacity = upload_size;
        self.graphics.software_upload_row_pitch = row_pitch;
        return raw_resource.?;
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

    const WindowInheritance = struct {
        working_directory: ?[]const u8 = null,
        font_size: ?f32 = null,
    };

    fn collectWindowInheritance(
        alloc: Allocator,
        config: *const configpkg.Config,
        source: ?*CoreSurface,
    ) !WindowInheritance {
        const surface = source orelse return .{};
        return .{
            .working_directory = if (apprt.surface.shouldInheritWorkingDirectory(.window, config))
                try surface.pwd(alloc)
            else
                null,
            .font_size = if (config.@"window-inherit-font-size")
                surface.font_size.points
            else
                null,
        };
    }

    fn applyWindowInheritance(
        config: *configpkg.Config,
        alloc: Allocator,
        inheritance: WindowInheritance,
    ) !void {
        if (inheritance.working_directory) |pwd| {
            config.@"working-directory" = try alloc.dupe(u8, pwd);
        }
        if (inheritance.font_size) |font_size| {
            config.@"font-size" = font_size;
        }
    }

    fn suppressCharMessageCount(units: usize) u8 {
        return @intCast(@min(units, std.math.maxInt(u8)));
    }

    fn translatedTextConsumedMods(
        mods: input.Mods,
        text: []const u8,
        unshifted_codepoint: u21,
        right_alt_down: bool,
    ) input.Mods {
        var result: input.Mods = .{};

        if (mods.shift and unshifted_codepoint != 0 and text.len > 0) {
            if (text[0] >= 'A' and text[0] <= 'Z') result.shift = true;
        }

        if (mods.ctrl and mods.alt and right_alt_down and text.len > 0) {
            result.ctrl = true;
            result.alt = true;
        }

        return result;
    }

    fn cursorResource(shape: terminal.MouseShape) win.LPCWSTR {
        return switch (shape) {
            .default, .context_menu, .help, .pointer, .alias, .copy, .grab, .grabbing, .zoom_in, .zoom_out => win.makeIntResource(win.IDC_HAND),
            .progress => win.makeIntResource(win.IDC_APPSTARTING),
            .wait => win.makeIntResource(win.IDC_WAIT),
            .cell, .text, .vertical_text => win.makeIntResource(win.IDC_IBEAM),
            .crosshair => win.makeIntResource(win.IDC_CROSS),
            .move, .all_scroll => win.makeIntResource(win.IDC_SIZEALL),
            .no_drop, .not_allowed => win.makeIntResource(win.IDC_NO),
            .col_resize, .e_resize, .w_resize, .ew_resize => win.makeIntResource(win.IDC_SIZEWE),
            .row_resize, .n_resize, .s_resize, .ns_resize => win.makeIntResource(win.IDC_SIZENS),
            .ne_resize, .sw_resize, .nesw_resize => win.makeIntResource(win.IDC_SIZENESW),
            .nw_resize, .se_resize, .nwse_resize => win.makeIntResource(win.IDC_SIZENWSE),
        };
    }

    test "win32 ipc payload round trip preserves arguments" {
        const testing = std.testing;

        const payload = try encodeIpcNewWindowPayload(testing.allocator, &.{
            "cmd",
            "/c",
            "echo ghostty",
        });
        defer testing.allocator.free(payload);

        var request = try decodeIpcNewWindowPayload(testing.allocator, payload);
        defer request.deinit(testing.allocator);

        try testing.expect(request.arguments != null);
        const arguments = request.arguments.?;
        try testing.expectEqual(@as(usize, 3), arguments.len);
        try testing.expectEqualStrings("cmd", arguments[0]);
        try testing.expectEqualStrings("/c", arguments[1]);
        try testing.expectEqualStrings("echo ghostty", arguments[2]);
    }

    test "win32 translated text consumed mods handles shift and altgr" {
        const testing = std.testing;

        const shift_result = translatedTextConsumedMods(
            .{ .shift = true },
            "A",
            'a',
            false,
        );
        try testing.expect(shift_result.shift);
        try testing.expect(!shift_result.ctrl);
        try testing.expect(!shift_result.alt);

        const altgr_result = translatedTextConsumedMods(
            .{ .ctrl = true, .alt = true },
            "@",
            '@',
            true,
        );
        try testing.expect(altgr_result.ctrl);
        try testing.expect(altgr_result.alt);
    }

    test "win32 suppress char message count saturates" {
        const testing = std.testing;
        try testing.expectEqual(@as(u8, 0), suppressCharMessageCount(0));
        try testing.expectEqual(@as(u8, 3), suppressCharMessageCount(3));
        try testing.expectEqual(std.math.maxInt(u8), suppressCharMessageCount(1024));
    }

    test "win32 apply window inheritance updates config" {
        const testing = std.testing;

        var config = try configpkg.Config.default(testing.allocator);
        defer config.deinit();

        try applyWindowInheritance(&config, config.arenaAlloc(), .{
            .working_directory = "/tmp/ghostty-win32",
            .font_size = 18,
        });

        try testing.expect(config.@"working-directory" != null);
        try testing.expectEqualStrings("/tmp/ghostty-win32", config.@"working-directory".?);
        try testing.expectEqual(@as(f32, 18), config.@"font-size");
    }
};
