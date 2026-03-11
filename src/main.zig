const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("build_config.zig");

// Zig 0.15 在 Windows 上的默认 panic 会尝试解析 PDB 以输出堆栈，但在本项目
// 的 CI 产物里该路径会失败（InvalidBlockIndex），导致完全拿不到任何地址帧。
// 这里为 Windows 额外输出原始指令地址，方便离线用 llvm-symbolizer 符号化。
pub const panic = std.debug.FullPanic(panicWithRawStackTrace);

fn panicWithRawStackTrace(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);

    if (builtin.os.tag == .windows) {
        var buf: [1024]u8 = undefined;
        const stderr = std.debug.lockStderrWriter(&buf);
        defer std.debug.unlockStderrWriter();

        stderr.print(
            "ci.win32.panic.first_trace_addr=0x{x}\n",
            .{first_trace_addr orelse 0},
        ) catch {};

        var addrs: [64]usize = undefined;
        var stack_trace: std.builtin.StackTrace = .{
            .instruction_addresses = addrs[0..],
            .index = 0,
        };

        std.debug.captureStackTrace(first_trace_addr, &stack_trace);
        if (stack_trace.index == 0) {
            std.debug.captureStackTrace(null, &stack_trace);
        }

        stderr.print(
            "ci.win32.panic.raw_stack_trace frames={d}\n",
            .{stack_trace.index},
        ) catch {};
        for (stack_trace.instruction_addresses[0..stack_trace.index], 0..) |addr, i| {
            stderr.print("ci.win32.panic.raw_stack_trace[{d}]=0x{x}\n", .{ i, addr }) catch {};
        }
    }

    std.debug.defaultPanic(msg, first_trace_addr);
}

/// See build_config.ExeEntrypoint for why we do this.
const entrypoint = switch (build_config.exe_entrypoint) {
    .ghostty => @import("main_ghostty.zig"),
    .helpgen => @import("helpgen.zig"),
    .mdgen_ghostty_1 => @import("build/mdgen/main_ghostty_1.zig"),
    .mdgen_ghostty_5 => @import("build/mdgen/main_ghostty_5.zig"),
    .webgen_config => @import("build/webgen/main_config.zig"),
    .webgen_actions => @import("build/webgen/main_actions.zig"),
    .webgen_commands => @import("build/webgen/main_commands.zig"),
};

/// The main entrypoint for the program.
pub const main = entrypoint.main;

/// Standard options such as logger overrides.
pub const std_options: std.Options = if (@hasDecl(entrypoint, "std_options"))
    entrypoint.std_options
else
    .{};

test {
    _ = entrypoint;
}
