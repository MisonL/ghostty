const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

pub const c = if (builtin.target.os.tag == .windows) @cImport({
    @cInclude("windows.h");
    @cInclude("dxgi1_4.h");
    @cInclude("d3d12.h");
    @cInclude("dwrite.h");
}) else struct {};

// Export any constants or functions we need from the Windows API so
// we can just import one file.
pub const kernel32 = windows.kernel32;
pub const unexpectedError = windows.unexpectedError;
pub const OpenFile = windows.OpenFile;
pub const CloseHandle = windows.CloseHandle;
pub const GetCurrentProcessId = windows.GetCurrentProcessId;
pub const SetHandleInformation = windows.SetHandleInformation;
pub const DWORD = windows.DWORD;
pub const FILE_ATTRIBUTE_NORMAL = windows.FILE_ATTRIBUTE_NORMAL;
pub const FILE_FLAG_OVERLAPPED = windows.FILE_FLAG_OVERLAPPED;
pub const FILE_SHARE_READ = windows.FILE_SHARE_READ;
pub const GENERIC_READ = windows.GENERIC_READ;
pub const HANDLE = windows.HANDLE;
pub const HANDLE_FLAG_INHERIT = windows.HANDLE_FLAG_INHERIT;
pub const INFINITE = windows.INFINITE;
pub const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
pub const OPEN_EXISTING = windows.OPEN_EXISTING;
pub const PIPE_ACCESS_OUTBOUND = windows.PIPE_ACCESS_OUTBOUND;
pub const PIPE_TYPE_BYTE = windows.PIPE_TYPE_BYTE;
pub const PROCESS_INFORMATION = windows.PROCESS_INFORMATION;
pub const S_OK = windows.S_OK;
pub const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
pub const STARTUPINFOW = windows.STARTUPINFOW;
pub const STARTF_USESTDHANDLES = windows.STARTF_USESTDHANDLES;
pub const SYNCHRONIZE = windows.SYNCHRONIZE;
pub const WAIT_FAILED = windows.WAIT_FAILED;
pub const FALSE = windows.FALSE;
pub const TRUE = windows.TRUE;
pub const S_FALSE: windows.HRESULT = 1;

pub const exp = struct {
    pub const HPCON = windows.LPVOID;

    pub const CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    pub const EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    pub const LPPROC_THREAD_ATTRIBUTE_LIST = ?*anyopaque;
    pub const FILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000;

    pub const STATUS_PENDING = 0x00000103;
    pub const STILL_ACTIVE = STATUS_PENDING;

    pub const STARTUPINFOEX = extern struct {
        StartupInfo: windows.STARTUPINFOW,
        lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
    };

    pub const kernel32 = struct {
        pub extern "kernel32" fn CreatePipe(
            hReadPipe: *windows.HANDLE,
            hWritePipe: *windows.HANDLE,
            lpPipeAttributes: ?*const windows.SECURITY_ATTRIBUTES,
            nSize: windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn CreatePseudoConsole(
            size: windows.COORD,
            hInput: windows.HANDLE,
            hOutput: windows.HANDLE,
            dwFlags: windows.DWORD,
            phPC: *HPCON,
        ) callconv(.winapi) windows.HRESULT;
        pub extern "kernel32" fn ResizePseudoConsole(hPC: HPCON, size: windows.COORD) callconv(.winapi) windows.HRESULT;
        pub extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;
        pub extern "kernel32" fn InitializeProcThreadAttributeList(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwAttributeCount: windows.DWORD,
            dwFlags: windows.DWORD,
            lpSize: *windows.SIZE_T,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn UpdateProcThreadAttribute(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwFlags: windows.DWORD,
            Attribute: windows.DWORD_PTR,
            lpValue: windows.PVOID,
            cbSize: windows.SIZE_T,
            lpPreviousValue: ?windows.PVOID,
            lpReturnSize: ?*windows.SIZE_T,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn PeekNamedPipe(
            hNamedPipe: windows.HANDLE,
            lpBuffer: ?windows.LPVOID,
            nBufferSize: windows.DWORD,
            lpBytesRead: ?*windows.DWORD,
            lpTotalBytesAvail: ?*windows.DWORD,
            lpBytesLeftThisMessage: ?*windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
        // Duplicated here because lpCommandLine is not marked optional in zig std
        pub extern "kernel32" fn CreateProcessW(
            lpApplicationName: ?windows.LPWSTR,
            lpCommandLine: ?windows.LPWSTR,
            lpProcessAttributes: ?*windows.SECURITY_ATTRIBUTES,
            lpThreadAttributes: ?*windows.SECURITY_ATTRIBUTES,
            bInheritHandles: windows.BOOL,
            dwCreationFlags: windows.DWORD,
            lpEnvironment: ?*anyopaque,
            lpCurrentDirectory: ?windows.LPWSTR,
            lpStartupInfo: *windows.STARTUPINFOW,
            lpProcessInformation: *windows.PROCESS_INFORMATION,
        ) callconv(.winapi) windows.BOOL;
    };

    pub const PROC_THREAD_ATTRIBUTE_NUMBER = 0x0000FFFF;
    pub const PROC_THREAD_ATTRIBUTE_THREAD = 0x00010000;
    pub const PROC_THREAD_ATTRIBUTE_INPUT = 0x00020000;
    pub const PROC_THREAD_ATTRIBUTE_ADDITIVE = 0x00040000;

    pub const ProcThreadAttributeNumber = enum(windows.DWORD) {
        ProcThreadAttributePseudoConsole = 22,
        _,
    };

    /// Corresponds to the ProcThreadAttributeValue define in WinBase.h
    pub fn ProcThreadAttributeValue(
        comptime attribute: ProcThreadAttributeNumber,
        comptime thread: bool,
        comptime input: bool,
        comptime additive: bool,
    ) windows.DWORD {
        return (@intFromEnum(attribute) & PROC_THREAD_ATTRIBUTE_NUMBER) |
            (if (thread) PROC_THREAD_ATTRIBUTE_THREAD else 0) |
            (if (input) PROC_THREAD_ATTRIBUTE_INPUT else 0) |
            (if (additive) PROC_THREAD_ATTRIBUTE_ADDITIVE else 0);
    }

    pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = ProcThreadAttributeValue(.ProcThreadAttributePseudoConsole, false, true, false);
};

pub const com = struct {
    pub const COINIT_APARTMENTTHREADED: u32 =
        if (builtin.target.os.tag == .windows)
            @intCast(c.COINIT_APARTMENTTHREADED)
        else
            0x2;
    pub const RPC_E_CHANGED_MODE: windows.HRESULT = @bitCast(@as(u32, 0x80010106));

    pub extern "ole32" fn CoInitializeEx(
        pv_reserved: ?*anyopaque,
        coinit: u32,
    ) callconv(.winapi) windows.HRESULT;

    pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;

    pub fn initApartmentThreaded() error{ComInitFailed}!bool {
        const hr = CoInitializeEx(null, COINIT_APARTMENTTHREADED);
        if (hr == S_OK or hr == S_FALSE) return true;
        if (hr == RPC_E_CHANGED_MODE) return false;
        return error.ComInitFailed;
    }

    pub fn uninitIfOwned(owned: bool) void {
        if (!owned) return;
        CoUninitialize();
    }
};

pub const graphics = struct {
    pub const HRESULT = windows.HRESULT;

    pub const IUnknown = extern struct {
        lpVtbl: *const VTable,

        pub const VTable = extern struct {
            QueryInterface: *const fn (*IUnknown, *const windows.GUID, ?*?*anyopaque) callconv(.winapi) HRESULT,
            AddRef: *const fn (*IUnknown) callconv(.winapi) u32,
            Release: *const fn (*IUnknown) callconv(.winapi) u32,
        };
    };

    pub const IDXGIFactory4 = opaque {};
    pub const IDXGISwapChain1 = opaque {};
    pub const IDXGISwapChain3 = opaque {};
    pub const ID3D12Device = opaque {};
    pub const ID3D12CommandQueue = opaque {};
    pub const ID3D12CommandAllocator = opaque {};
    pub const ID3D12GraphicsCommandList = opaque {};
    pub const ID3D12CommandList = opaque {};
    pub const ID3D12DescriptorHeap = opaque {};
    pub const ID3D12Fence = opaque {};
    pub const ID3D12Resource = opaque {};
    pub const ID3D12RootSignature = opaque {};
    pub const ID3D12PipelineState = opaque {};
    pub const IDWriteFactory = extern struct {
        lpVtbl: *const VTable,

        pub const VTable = extern struct {
            QueryInterface: *const fn (*IDWriteFactory, *const windows.GUID, ?*?*anyopaque) callconv(.winapi) HRESULT,
            AddRef: *const fn (*IDWriteFactory) callconv(.winapi) u32,
            Release: *const fn (*IDWriteFactory) callconv(.winapi) u32,
            GetSystemFontCollection: *const fn (*IDWriteFactory, ?*?*IDWriteFontCollection, windows.BOOL) callconv(.winapi) HRESULT,
        };
    };
    pub const IDWriteFontCollection = extern struct {
        lpVtbl: *const VTable,

        pub const VTable = extern struct {
            QueryInterface: *const fn (*IDWriteFontCollection, *const windows.GUID, ?*?*anyopaque) callconv(.winapi) HRESULT,
            AddRef: *const fn (*IDWriteFontCollection) callconv(.winapi) u32,
            Release: *const fn (*IDWriteFontCollection) callconv(.winapi) u32,
            GetFontFamilyCount: *const fn (*IDWriteFontCollection) callconv(.winapi) u32,
            GetFontFamily: *const fn (*IDWriteFontCollection, u32, ?*?*IDWriteFontFamily) callconv(.winapi) HRESULT,
            FindFamilyName: *const anyopaque,
            GetFontFromFontFace: *const anyopaque,
        };
    };
    pub const IDWriteFontFamily = extern struct {
        lpVtbl: *const VTable,

        pub const VTable = extern struct {
            QueryInterface: *const fn (*IDWriteFontFamily, *const windows.GUID, ?*?*anyopaque) callconv(.winapi) HRESULT,
            AddRef: *const fn (*IDWriteFontFamily) callconv(.winapi) u32,
            Release: *const fn (*IDWriteFontFamily) callconv(.winapi) u32,
            GetFontCollection: *const anyopaque,
            GetFontCount: *const fn (*IDWriteFontFamily) callconv(.winapi) u32,
            GetFont: *const fn (*IDWriteFontFamily, u32, ?*?*IDWriteFont) callconv(.winapi) HRESULT,
        };
    };
    pub const IDWriteFont = extern struct {
        lpVtbl: *const VTable,

        pub const VTable = extern struct {
            QueryInterface: *const fn (*IDWriteFont, *const windows.GUID, ?*?*anyopaque) callconv(.winapi) HRESULT,
            AddRef: *const fn (*IDWriteFont) callconv(.winapi) u32,
            Release: *const fn (*IDWriteFont) callconv(.winapi) u32,
            GetFontFamily: *const anyopaque,
            GetWeight: *const anyopaque,
            GetStretch: *const anyopaque,
            GetStyle: *const anyopaque,
            IsSymbolFont: *const anyopaque,
            GetFaceNames: *const anyopaque,
            GetInformationalStrings: *const anyopaque,
            GetSimulations: *const anyopaque,
            GetMetrics: *const anyopaque,
            HasCharacter: *const anyopaque,
            CreateFontFace: *const fn (*IDWriteFont, ?*?*IDWriteFontFace) callconv(.winapi) HRESULT,
        };
    };
    pub const IDWriteFontFace = extern struct {
        lpVtbl: *const VTable,

        pub const VTable = extern struct {
            QueryInterface: *const fn (*IDWriteFontFace, *const windows.GUID, ?*?*anyopaque) callconv(.winapi) HRESULT,
            AddRef: *const fn (*IDWriteFontFace) callconv(.winapi) u32,
            Release: *const fn (*IDWriteFontFace) callconv(.winapi) u32,
            GetType: *const anyopaque,
            GetFiles: *const fn (*IDWriteFontFace, *u32, ?[*]?*IDWriteFontFile) callconv(.winapi) HRESULT,
            GetIndex: *const fn (*IDWriteFontFace) callconv(.winapi) u32,
        };
    };
    pub const IDWriteFontFile = extern struct {
        lpVtbl: *const VTable,

        pub const VTable = extern struct {
            QueryInterface: *const fn (*IDWriteFontFile, *const windows.GUID, ?*?*anyopaque) callconv(.winapi) HRESULT,
            AddRef: *const fn (*IDWriteFontFile) callconv(.winapi) u32,
            Release: *const fn (*IDWriteFontFile) callconv(.winapi) u32,
            GetReferenceKey: *const fn (*IDWriteFontFile, ?*u32) callconv(.winapi) ?*const anyopaque,
            GetLoader: *const fn (*IDWriteFontFile, ?*?*IDWriteFontFileLoader) callconv(.winapi) HRESULT,
            Analyze: *const anyopaque,
        };
    };
    pub const IDWriteFontFileLoader = extern struct {
        lpVtbl: *const VTable,

        pub const VTable = extern struct {
            QueryInterface: *const fn (*IDWriteFontFileLoader, *const windows.GUID, ?*?*anyopaque) callconv(.winapi) HRESULT,
            AddRef: *const fn (*IDWriteFontFileLoader) callconv(.winapi) u32,
            Release: *const fn (*IDWriteFontFileLoader) callconv(.winapi) u32,
            CreateStreamFromKey: *const anyopaque,
        };
    };
    pub const IDWriteLocalFontFileLoader = extern struct {
        lpVtbl: *const VTable,

        pub const VTable = extern struct {
            QueryInterface: *const fn (*IDWriteLocalFontFileLoader, *const windows.GUID, ?*?*anyopaque) callconv(.winapi) HRESULT,
            AddRef: *const fn (*IDWriteLocalFontFileLoader) callconv(.winapi) u32,
            Release: *const fn (*IDWriteLocalFontFileLoader) callconv(.winapi) u32,
            CreateStreamFromKey: *const anyopaque,
            GetFilePathLengthFromKey: *const fn (*IDWriteLocalFontFileLoader, ?*const anyopaque, u32, *u32) callconv(.winapi) HRESULT,
            GetFilePathFromKey: *const fn (*IDWriteLocalFontFileLoader, ?*const anyopaque, u32, [*:0]u16, u32) callconv(.winapi) HRESULT,
            GetLastWriteTimeFromKey: *const anyopaque,
        };
    };

    pub const DWRITE_FACTORY_TYPE = enum(c_int) {
        shared = 0,
        isolated = 1,
    };

    pub const D3D_FEATURE_LEVEL = enum(u32) {
        @"11_0" = 0xb000,
        @"12_0" = 0xc000,
        @"12_1" = 0xc100,
    };

    pub const IID_IDXGIFactory4 = windows.GUID.parse("{1bc6ea02-ef36-464f-bf0c-21ca39e5168a}");
    pub const IID_ID3D12Device = windows.GUID.parse("{189819f1-1db6-4b57-be54-1821339b85f7}");
    pub const IID_ID3D12RootSignature = windows.GUID.parse("{c54a6b66-72df-4ee8-8be5-a946a1429214}");
    pub const IID_ID3D12PipelineState = windows.GUID.parse("{765a30f3-f624-4c6f-a828-ace948622445}");
    pub const IID_IDWriteFactory = windows.GUID.parse("{b859ee5a-d838-4b5b-a2e8-1adc7d93db48}");
    pub const IID_IDWriteLocalFontFileLoader = windows.GUID.parse("{b2d9f3ec-c9fe-4a11-a2ec-d86208f7c0a2}");

    pub extern "dxgi" fn CreateDXGIFactory1(
        riid: *const windows.GUID,
        factory: ?*?*anyopaque,
    ) callconv(.winapi) HRESULT;

    pub extern "d3d12" fn D3D12CreateDevice(
        adapter: ?*IUnknown,
        minimum_feature_level: D3D_FEATURE_LEVEL,
        riid: *const windows.GUID,
        device: ?*?*anyopaque,
    ) callconv(.winapi) HRESULT;

    pub extern "dwrite" fn DWriteCreateFactory(
        factory_type: DWRITE_FACTORY_TYPE,
        riid: *const windows.GUID,
        factory: ?*?*IUnknown,
    ) callconv(.winapi) HRESULT;

    pub fn succeeded(hr: HRESULT) bool {
        return hr >= 0;
    }

    pub fn release(ptr: ?*anyopaque) void {
        const raw = ptr orelse return;
        const unknown: *IUnknown = @ptrFromInt(@intFromPtr(raw));
        _ = unknown.lpVtbl.Release(unknown);
    }
};
