# 最终成品待办清单

本文件用于收口“最终成品”所有待开发/待修复事项。分为两部分：
- **手工里程碑**：稳定维护，方便老板直接看进度与优先级。
- **自动扫描结果**：由脚本生成，覆盖本仓库一方代码中的 TODO/FIXME/HACK/XXX（注释语义）与 not implemented 等残留。

## 手工里程碑（请勿自动覆盖）

### P0（必须先变成稳定可用）
- Windows：ConPTY 读线程退出/断管错误码处理必须不崩溃（涉及 `src/termio/Exec.zig`）。
- Windows：D3D12 present 帧 pacing 不能每帧 `waitForGpuIdle` 强同步（涉及 `src/renderer/D3D12.zig`）。
- libghostty：`include/ghostty.h` 与 `include/ghostty/vt.h` 必须可同时 include（`GHOSTTY_SUCCESS` 冲突）。
- 终端协议：OSC 动态颜色 13-19/113-119 与 special colors（OSC 4/5/104/105）必须可用且有行为级测试。
- GTK：最小 Preferences/Settings 窗口与入口（配置概览 + 诊断 + 打开/重载 + 常用项写回）。
- macOS：Preferences 从“配置查看器”推进到“可搜索/更多可写项”，并修复菜单快捷键一致性问题。

### P1（用户可见功能补齐）
- Kitty 图像动画 action、tmux control mode 的 windows action、XTWINOPS 标题栈、charset slot `-./` 等（详见自动扫描结果与协议盘点）。

<!-- AUTO-GENERATED:START -->

## 自动扫描结果（由脚本生成）

生成时间：`2026-03-11T12:31:32.319Z`
基于提交：`b41e38a8e`

### 统计

- 总条目：`141`
- comment-marker：`128`
- text-not-implemented：`10`
- compileError-unimplemented：`2`
- panic-not-implemented：`1`

### Top 路径前缀（前 20）

- `src/terminal`：`36`
- `src/apprt`：`22`
- `src/renderer`：`13`
- `src/termio`：`12`
- `src/font`：`11`
- `src/os`：`8`
- `macos/Sources`：`7`
- `src/input`：`6`
- `src/build`：`3`
- `src/config`：`3`
- `src/simd`：`3`
- `src/Surface.zig`：`3`
- `src/cli`：`2`
- `src/inspector`：`2`
- `src/surface_mouse.zig`：`2`
- `flatpak/dependencies.yml`：`1`
- `snap/snapcraft.yaml`：`1`
- `src/Command.zig`：`1`
- `src/pty.zig`：`1`
- `src/shell-integration`：`1`

### 明细

| ID | 类别 | 位置 | 摘要 |
| --- | --- | --- | --- |
| FP-AUTO-0001 | comment-marker | flatpak/dependencies.yml:38:6 | # TODO: Automate this with check-zig-cache.sh |
| FP-AUTO-0002 | comment-marker | macos/Sources/Features/Terminal/Window Styles/TitlebarTabsTahoeTerminalWindow.swift:129:12 | // HACK: wait a tick before doing anything, to avoid edge cases during startup... :/ |
| FP-AUTO-0003 | comment-marker | macos/Sources/Features/Terminal/Window Styles/TitlebarTabsVenturaTerminalWindow.swift:341:4 | // HACK: hide the "collapsed items" marker from the toolbar if it's present. |
| FP-AUTO-0004 | comment-marker | macos/Sources/Features/Terminal/Window Styles/TitlebarTabsVenturaTerminalWindow.swift:412:8 | // HACK: wait a tick before doing anything, to avoid edge cases during startup... :/ |
| FP-AUTO-0005 | comment-marker | macos/Sources/Ghostty/Ghostty.Config.swift:82:12 | // TODO: we'd probably do some config loading here... for now we'd |
| FP-AUTO-0006 | comment-marker | macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift:1145:16 | // TODO(mitchellh): do we have to scale the x/y here by window scale factor? |
| FP-AUTO-0007 | comment-marker | macos/Sources/Ghostty/Surface View/SurfaceView_UIKit.swift:88:16 | // TODO |
| FP-AUTO-0008 | comment-marker | macos/Sources/Helpers/Fullscreen.swift:96:8 | // TODO: There are many requirements for native fullscreen we should |
| FP-AUTO-0009 | comment-marker | snap/snapcraft.yaml:79:4 | # TODO: Remove -fno-sys=gtk4-layer-shell when we upgrade to a version that packages it Ubuntu 24.10+ |
| FP-AUTO-0010 | text-not-implemented | src/apprt/action.zig:61:47 | /// there is a compiler error if an action is not implemented. |
| FP-AUTO-0011 | comment-marker | src/apprt/action.zig:557:4 | // TODO: check non-exhaustive enums |
| FP-AUTO-0012 | comment-marker | src/apprt/action.zig:847:4 | // TODO: check non-non-exhaustive enums |
| FP-AUTO-0013 | comment-marker | src/apprt/gtk/class/application.zig:2208:8 | // TODO: use https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.OpenURI.html |
| FP-AUTO-0014 | comment-marker | src/apprt/gtk/class/application.zig:2509:16 | // TODO: pass surface ID when we have that |
| FP-AUTO-0015 | text-not-implemented | src/apprt/gtk/class/command_palette.zig:192:44 | // Filter out actions that are not implemented or don't make sense |
| FP-AUTO-0016 | comment-marker | src/apprt/gtk/class/command_palette.zig:585:16 | // TODO: Replace with surface id whenever Ghostty adds one |
| FP-AUTO-0017 | comment-marker | src/apprt/gtk/class/global_shortcuts.zig:382:16 | // TODO: XDG recommends updating the signal subscription if the actual |
| FP-AUTO-0018 | comment-marker | src/apprt/gtk/class/surface.zig:1012:8 | // TODO: pass the surface with the action |
| FP-AUTO-0019 | comment-marker | src/apprt/gtk/class/tab.zig:206:16 | // TODO: We should make our "no surfaces" state more aesthetically |
| FP-AUTO-0020 | comment-marker | src/apprt/gtk/class/window.zig:354:12 | // TODO: accept the surface that toggled the command palette |
| FP-AUTO-0021 | comment-marker | src/apprt/gtk/class/window.zig:1523:8 | // TODO: connect close page handler to tab to check for confirmation |
| FP-AUTO-0022 | comment-marker | src/apprt/gtk/class/window.zig:1916:4 | /// TODO: accept the surface that toggled the command palette as a parameter |
| FP-AUTO-0023 | comment-marker | src/apprt/gtk/class/window.zig:1971:8 | // TODO: accept the surface that toggled the command palette as a |
| FP-AUTO-0024 | comment-marker | src/apprt/gtk/class/window.zig:1988:8 | // TODO: accept the surface that toggled the command palette as a |
| FP-AUTO-0025 | comment-marker | src/apprt/gtk/key.zig:534:4 | // TODO: media keys |
| FP-AUTO-0026 | comment-marker | src/apprt/gtk/ui/1.2/surface.blp:106:6 | // TODO: the tooltip doesn't actually work, but keep it here for now so |
| FP-AUTO-0027 | comment-marker | src/apprt/gtk/winproto/wayland.zig:30:8 | // FIXME: replace with `zxdg_decoration_v1` once GTK merges |
| FP-AUTO-0028 | comment-marker | src/apprt/gtk/winproto/wayland.zig:46:8 | /// FIXME: This is a temporary workaround - we should remove this when |
| FP-AUTO-0029 | comment-marker | src/apprt/gtk/winproto/x11.zig:253:8 | // FIXME: This doesn't currently factor in rounded corners on Adwaita, |
| FP-AUTO-0030 | comment-marker | src/apprt/gtk/winproto/x11.zig:372:8 | // FIXME: Maybe we should switch to libxcb one day. |
| FP-AUTO-0031 | comment-marker | src/apprt/surface.zig:20:4 | /// TODO: we should change this to a "WriteReq" style structure in |
| FP-AUTO-0032 | comment-marker | src/build/SharedDeps.zig:647:8 | // FIXME: replace with `zxdg_decoration_v1` once GTK merges https://gitlab.gnome.org/GNOME/gtk/-/merge_requests/6398 |
| FP-AUTO-0033 | comment-marker | src/build/UnicodeTables.zig:24:8 | // TODO: x86_64 self-hosted crashes |
| FP-AUTO-0034 | comment-marker | src/build/UnicodeTables.zig:38:8 | // TODO: x86_64 self-hosted crashes |
| FP-AUTO-0035 | comment-marker | src/cli/args.zig:14:1 | // TODO: |
| FP-AUTO-0036 | comment-marker | src/cli/list_themes.zig:49:8 | // TODO: use Unicode-aware comparison |
| FP-AUTO-0037 | comment-marker | src/Command.zig:280:4 | // TODO: In the case of having FDs instead of pty, need to set up |
| FP-AUTO-0038 | comment-marker | src/config/Config.zig:1417:1 | /// TODO: This can't currently be set! |
| FP-AUTO-0039 | comment-marker | src/config/Config.zig:3797:1 | /// HACK: We set this with an `xterm` prefix because vim uses that to enable key |
| FP-AUTO-0040 | comment-marker | src/config/Config.zig:4620:8 | // HACK: See comment above at definition |
| FP-AUTO-0041 | comment-marker | src/font/Atlas.zig:92:1 | /// TODO: figure out optimal prealloc based on real world usage |
| FP-AUTO-0042 | comment-marker | src/font/Collection.zig:1185:4 | // TODO(fontmem): test explicit/implicit |
| FP-AUTO-0043 | comment-marker | src/font/Collection.zig:1269:1 | // TODO: Also test CJK fallback sizing, we don't currently have a CJK test font. |
| FP-AUTO-0044 | comment-marker | src/font/discovery.zig:1391:4 | // FIXME: Disabled for now because SF Pro is not available in CI |
| FP-AUTO-0045 | comment-marker | src/font/face/web_canvas.zig:232:12 | // TODO: this can't be right |
| FP-AUTO-0046 | comment-marker | src/font/main.zig:46:4 | // TODO: we need to modify the build config for wasm builds. the issue |
| FP-AUTO-0047 | comment-marker | src/font/main.zig:71:1 | /// TODO: Add user configuration for this instead of hard-coding it. |
| FP-AUTO-0048 | comment-marker | src/font/shaper/web_canvas.zig:82:8 | // TODO: memory check that cell_buf can fit results |
| FP-AUTO-0049 | comment-marker | src/font/sprite/draw/symbols_for_legacy_computing_supplement.zig:247:1 | /// TODO: These two characters should be easy, but it's not clear how they're |
| FP-AUTO-0050 | comment-marker | src/font/sprite/draw/symbols_for_legacy_computing.zig:739:4 | // TODO: This doesn't align properly for most cell sizes, fix that. |
| FP-AUTO-0051 | comment-marker | src/font/sprite/draw/symbols_for_legacy_computing.zig:779:4 | // TODO: This doesn't align properly for most cell sizes, fix that. |
| FP-AUTO-0052 | comment-marker | src/input/Binding.zig:102:12 | // TODO: We should change this parser into a real state machine |
| FP-AUTO-0053 | comment-marker | src/input/keycodes.zig:215:4 | // TODO(garykac): |
| FP-AUTO-0054 | comment-marker | src/input/keycodes.zig:288:4 | // TODO(garykac): Verify Mac intl keyboard. |
| FP-AUTO-0055 | comment-marker | src/input/keycodes.zig:297:4 | // TODO(garykac): CapsLock requires special handling for each platform. |
| FP-AUTO-0056 | comment-marker | src/input/keycodes.zig:531:4 | // TODO(garykac): Many XF86 keys have multiple scancodes mapping to them. |
| FP-AUTO-0057 | comment-marker | src/input/keycodes.zig:536:4 | // TODO(garykac): Find appropriate mappings for: |
| FP-AUTO-0058 | comment-marker | src/inspector/Inspector.zig:40:8 | // TODO: This will have to be recalculated for different screen DPIs. |
| FP-AUTO-0059 | comment-marker | src/inspector/widgets/termio.zig:103:12 | // TODO: Eventually |
| FP-AUTO-0060 | comment-marker | src/os/desktop.zig:60:8 | // TODO: This should have some logic to detect this. Perhaps std.builtin.subsystem |
| FP-AUTO-0061 | comment-marker | src/os/file.zig:61:8 | // TODO: what is a good fallback path on windows? |
| FP-AUTO-0062 | compileError-unimplemented | src/os/homedir.zig:22:17 | else => @compileError("unimplemented"), |
| FP-AUTO-0063 | compileError-unimplemented | src/os/homedir.zig:126:17 | else => @compileError("unimplemented"), |
| FP-AUTO-0064 | comment-marker | src/os/mach.zig:132:12 | // TODO: if the next_mmap_addr_hint is within the remapped range, update it |
| FP-AUTO-0065 | comment-marker | src/os/mach.zig:139:12 | // TODO: if the next_mmap_addr_hint is within the unmapped range, update it |
| FP-AUTO-0066 | comment-marker | src/os/shell.zig:92:16 | // TODO: Actually use a buffer here |
| FP-AUTO-0067 | comment-marker | src/os/shell.zig:103:8 | // TODO: This is a very naive implementation and does not really make |
| FP-AUTO-0068 | comment-marker | src/pty.zig:40:1 | // TODO: This should be removed. This is only temporary until we have |
| FP-AUTO-0069 | comment-marker | src/renderer/metal/RenderPass.zig:158:8 | // TODO: Maybe in the future add info to the pipeline struct which |
| FP-AUTO-0070 | comment-marker | src/renderer/metal/shaders.zig:232:4 | /// TODO: Maybe put these in a packed struct, like for OpenGL. |
| FP-AUTO-0071 | comment-marker | src/renderer/OpenGL.zig:206:12 | // TODO(mitchellh): this does nothing today to allow libghostty |
| FP-AUTO-0072 | comment-marker | src/renderer/OpenGL.zig:247:12 | // TODO(mitchellh): this does nothing today to allow libghostty |
| FP-AUTO-0073 | comment-marker | src/renderer/OpenGL.zig:269:12 | // TODO: see threadEnter |
| FP-AUTO-0074 | comment-marker | src/renderer/OpenGL.zig:513:8 | // TODO: Generate mipmaps for image textures and use |
| FP-AUTO-0075 | comment-marker | src/renderer/OpenGL.zig:518:8 | // TODO: Separate out background image options, use |
| FP-AUTO-0076 | comment-marker | src/renderer/opengl/RenderPass.zig:61:1 | /// TODO: Errors are silently ignored in this function, maybe they shouldn't be? |
| FP-AUTO-0077 | comment-marker | src/renderer/row.zig:3:1 | // TODO: Test neverExtendBg function |
| FP-AUTO-0078 | comment-marker | src/renderer/shaders/shaders.metal:54:1 | // TODO: The color matrix should probably be computed |
| FP-AUTO-0079 | comment-marker | src/renderer/shaders/shaders.metal:495:2 | // TODO: It might be a good idea to do a pass before this |
| FP-AUTO-0080 | comment-marker | src/renderer/shadertoy.zig:431:4 | // TODO: Replace this with an aligned version of Writer.Allocating |
| FP-AUTO-0081 | comment-marker | src/renderer/shadertoy.zig:471:4 | // TODO: Replace this with an aligned version of Writer.Allocating |
| FP-AUTO-0082 | comment-marker | src/shell-integration/bash/bash-preexec.sh:64:1 | # TODO: Figure out how to restore PIPESTATUS before each precmd or preexec |
| FP-AUTO-0083 | comment-marker | src/simd/vt.cpp:88:4 | // TODO(mitchellh): benchmark this vs decoding every time |
| FP-AUTO-0084 | comment-marker | src/simd/vt.zig:92:4 | // TODO: many more test cases |
| FP-AUTO-0085 | comment-marker | src/simd/vt.zig:107:4 | // TODO: many more test cases |
| FP-AUTO-0086 | comment-marker | src/surface_mouse.zig:60:4 | // TODO: As we unravel mouse state, we can fix this to be more explicit. |
| FP-AUTO-0087 | comment-marker | src/surface_mouse.zig:77:4 | // TODO: This could be updated eventually to be a true transition table if |
| FP-AUTO-0088 | comment-marker | src/Surface.zig:2125:4 | // TODO: need to handle when scrolling and the cursor is not |
| FP-AUTO-0089 | comment-marker | src/Surface.zig:5086:4 | // TODO(qwerasd): this can/should probably be refactored, it's a bit |
| FP-AUTO-0090 | comment-marker | src/Surface.zig:5098:4 | // TODO: Clamp selection to the screen area, don't |
| FP-AUTO-0091 | comment-marker | src/synthetic/cli.zig:84:4 | // TODO: Make this a command line option. |
| FP-AUTO-0092 | comment-marker | src/terminal/formatter.zig:915:20 | // TODO: if unavailable, we should add to our trailing state |
| FP-AUTO-0093 | comment-marker | src/terminal/hash_map.zig:814:12 | // TODO: replace with pointer subtraction once supported by zig |
| FP-AUTO-0094 | comment-marker | src/terminal/kitty/graphics_storage.zig:34:4 | /// TODO: This isn't good enough, it's perfectly legal for programs |
| FP-AUTO-0095 | comment-marker | src/terminal/page.zig:926:24 | // TODO(qwerasd): verify the assumption that `addWithId` |
| FP-AUTO-0096 | comment-marker | src/terminal/PageList.zig:939:1 | /// TODO: docs |
| FP-AUTO-0097 | comment-marker | src/terminal/PageList.zig:5280:4 | /// TODO: Unit tests. |
| FP-AUTO-0098 | comment-marker | src/terminal/PageList.zig:5307:4 | /// TODO: Unit tests. |
| FP-AUTO-0099 | comment-marker | src/terminal/parse_table.zig:358:4 | // TODO: enable this but it thinks we're in runtime right now |
| FP-AUTO-0100 | comment-marker | src/terminal/Screen.zig:586:12 | // TODO: Should we increase the capacity further in this case? |
| FP-AUTO-0101 | comment-marker | src/terminal/Screen.zig:608:12 | // TODO: Should we increase the capacity further in this case? |
| FP-AUTO-0102 | comment-marker | src/terminal/Screen.zig:1207:1 | /// TODO: test |
| FP-AUTO-0103 | comment-marker | src/terminal/Screen.zig:2316:12 | // FIXME: increaseCapacity should not do this. |
| FP-AUTO-0104 | comment-marker | src/terminal/Screen.zig:2740:1 | /// TODO: test this |
| FP-AUTO-0105 | comment-marker | src/terminal/search/Thread.zig:33:1 | // TODO: Some stuff that could be improved: |
| FP-AUTO-0106 | comment-marker | src/terminal/stream.zig:233:8 | // TODO: Before shipping an ABI-compatible libghostty, verify this. |
| FP-AUTO-0107 | comment-marker | src/terminal/stream.zig:938:16 | // TODO: test |
| FP-AUTO-0108 | comment-marker | src/terminal/stream.zig:959:16 | // TODO: test |
| FP-AUTO-0109 | comment-marker | src/terminal/stream.zig:1074:16 | // TODO: test |
| FP-AUTO-0110 | comment-marker | src/terminal/stream.zig:1092:16 | // TODO: test |
| FP-AUTO-0111 | comment-marker | src/terminal/stream.zig:1337:16 | // TODO: test |
| FP-AUTO-0112 | comment-marker | src/terminal/stream.zig:1488:16 | // TODO: test |
| FP-AUTO-0113 | comment-marker | src/terminal/stream.zig:1587:24 | // TODO: test |
| FP-AUTO-0114 | comment-marker | src/terminal/stream.zig:2082:16 | // TODO: support slots '-', '.', '/' |
| FP-AUTO-0115 | comment-marker | src/terminal/Tabstops.zig:127:1 | // TODO: needs interval to set new tabstops |
| FP-AUTO-0116 | comment-marker | src/terminal/Terminal.zig:677:4 | // TODO: spacers should use a bgcolor only cell |
| FP-AUTO-0117 | comment-marker | src/terminal/Terminal.zig:680:8 | // TODO: non-utf8 handling, gr |
| FP-AUTO-0118 | comment-marker | src/terminal/Terminal.zig:753:12 | // TODO: this case was not handled in the old terminal implementation |
| FP-AUTO-0119 | comment-marker | src/terminal/Terminal.zig:1368:1 | /// TODO: test |
| FP-AUTO-0120 | comment-marker | src/terminal/Terminal.zig:1373:1 | /// TODO: test |
| FP-AUTO-0121 | comment-marker | src/terminal/Terminal.zig:1675:8 | // TODO: Create an optimized version that can scroll N times |
| FP-AUTO-0122 | comment-marker | src/terminal/Terminal.zig:1771:1 | // TODO(qwerasd): `insertLines` and `deleteLines` are 99% identical, |
| FP-AUTO-0123 | comment-marker | src/terminal/Terminal.zig:2328:4 | // TODO(qwerasd): This isn't actually correct if you take in to account |
| FP-AUTO-0124 | comment-marker | src/terminal/tmux/control.zig:167:12 | // TODO(tmuxcc): do this before merge? |
| FP-AUTO-0125 | comment-marker | src/terminal/tmux/viewer.zig:18:1 | // TODO: A list of TODOs as I think about them. |
| FP-AUTO-0126 | comment-marker | src/terminal/tmux/viewer.zig:667:8 | // TODO: errdefer cleanup |
| FP-AUTO-0127 | comment-marker | src/terminal/tmux/viewer.zig:1158:16 | // TODO: We need to gracefully handle overflow of our |
| FP-AUTO-0128 | comment-marker | src/terminfo/ghostty.zig:10:8 | // HACK: This is a hack on a hack...we use "xterm-ghostty" to prevent |
| FP-AUTO-0129 | comment-marker | src/termio/Exec.zig:327:4 | // TODO: support on windows |
| FP-AUTO-0130 | panic-not-implemented | src/termio/Exec.zig:329:9 | @panic("termios timer not implemented on Windows"); |
| FP-AUTO-0131 | text-not-implemented | src/termio/Exec.zig:329:31 | @panic("termios timer not implemented on Windows"); |
| FP-AUTO-0132 | comment-marker | src/termio/stream_handler.zig:447:28 | // TODO |
| FP-AUTO-0133 | text-not-implemented | src/termio/stream_handler.zig:1243:68 | => log.info("setting dynamic color {s} not implemented", .{ |
| FP-AUTO-0134 | text-not-implemented | src/termio/stream_handler.zig:1247:70 | .special => log.info("setting special colors not implemented", .{}), |
| FP-AUTO-0135 | text-not-implemented | src/termio/stream_handler.zig:1307:66 | => log.warn("resetting dynamic color {s} not implemented", .{ |
| FP-AUTO-0136 | text-not-implemented | src/termio/stream_handler.zig:1311:68 | .special => log.info("resetting special colors not implemented", .{}), |
| FP-AUTO-0137 | text-not-implemented | src/termio/stream_handler.zig:1331:51 | "resetting all special colors not implemented", |
| FP-AUTO-0138 | text-not-implemented | src/termio/stream_handler.zig:1354:66 | "reporting dynamic color {s} not implemented", |
| FP-AUTO-0139 | text-not-implemented | src/termio/stream_handler.zig:1361:64 | log.info("reporting special colors not implemented", .{}); |
| FP-AUTO-0140 | comment-marker | src/termio/Termio.zig:628:8 | // TODO: fix this |
| FP-AUTO-0141 | comment-marker | src/unicode/grapheme.zig:85:1 | /// TODO: this is hard to build with newer zig build, so |

<!-- AUTO-GENERATED:END -->

