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

生成时间：`2026-03-11T15:07:58.068Z`
基于提交：`63809d056`

### 统计

- 总条目：`261`
- comment-marker：`255`
- text-not-implemented：`3`
- compileError-unimplemented：`2`
- panic-not-implemented：`1`

### Top 路径前缀（前 20）

- `docs/final-product-backlog.md`：`128`
- `src/terminal`：`36`
- `src/apprt`：`22`
- `src/renderer`：`13`
- `src/font`：`11`
- `macos/Sources`：`7`
- `src/os`：`7`
- `src/input`：`6`
- `src/termio`：`5`
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

### 明细

| ID | 类别 | 位置 | 摘要 |
| --- | --- | --- | --- |
| FP-AUTO-0001 | comment-marker | docs/final-product-backlog.md:62:66 | \| FP-AUTO-0001 \| comment-marker \| flatpak/dependencies.yml:38:6 \| # TODO: Automate this with check-zig-cache.sh \| |
| FP-AUTO-0002 | comment-marker | docs/final-product-backlog.md:63:127 | \| FP-AUTO-0002 \| comment-marker \| macos/Sources/Features/Terminal/Window Styles/TitlebarTabsTahoeTerminalWindow.swift:129:12 \| // HACK: wait a tick before doing anything, to avoid edge cases during startup... :/ \| |
| FP-AUTO-0003 | comment-marker | docs/final-product-backlog.md:64:128 | \| FP-AUTO-0003 \| comment-marker \| macos/Sources/Features/Terminal/Window Styles/TitlebarTabsVenturaTerminalWindow.swift:341:4 \| // HACK: hide the "collapsed items" marker from the toolbar if it's present. \| |
| FP-AUTO-0004 | comment-marker | docs/final-product-backlog.md:65:128 | \| FP-AUTO-0004 \| comment-marker \| macos/Sources/Features/Terminal/Window Styles/TitlebarTabsVenturaTerminalWindow.swift:412:8 \| // HACK: wait a tick before doing anything, to avoid edge cases during startup... :/ \| |
| FP-AUTO-0005 | comment-marker | docs/final-product-backlog.md:66:85 | \| FP-AUTO-0005 \| comment-marker \| macos/Sources/Ghostty/Ghostty.Config.swift:82:12 \| // TODO: we'd probably do some config loading here... for now we'd \| |
| FP-AUTO-0006 | comment-marker | docs/final-product-backlog.md:67:104 | \| FP-AUTO-0006 \| comment-marker \| macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift:1145:16 \| // TODO(mitchellh): do we have to scale the x/y here by window scale factor? \| |
| FP-AUTO-0007 | comment-marker | docs/final-product-backlog.md:68:101 | \| FP-AUTO-0007 \| comment-marker \| macos/Sources/Ghostty/Surface View/SurfaceView_UIKit.swift:88:16 \| // TODO \| |
| FP-AUTO-0008 | comment-marker | docs/final-product-backlog.md:69:80 | \| FP-AUTO-0008 \| comment-marker \| macos/Sources/Helpers/Fullscreen.swift:96:8 \| // TODO: There are many requirements for native fullscreen we should \| |
| FP-AUTO-0009 | comment-marker | docs/final-product-backlog.md:70:61 | \| FP-AUTO-0009 \| comment-marker \| snap/snapcraft.yaml:79:4 \| # TODO: Remove -fno-sys=gtk4-layer-shell when we upgrade to a version that packages it Ubuntu 24.10+ \| |
| FP-AUTO-0010 | comment-marker | docs/final-product-backlog.md:72:63 | \| FP-AUTO-0011 \| comment-marker \| src/apprt/action.zig:557:4 \| // TODO: check non-exhaustive enums \| |
| FP-AUTO-0011 | comment-marker | docs/final-product-backlog.md:73:63 | \| FP-AUTO-0012 \| comment-marker \| src/apprt/action.zig:847:4 \| // TODO: check non-non-exhaustive enums \| |
| FP-AUTO-0012 | comment-marker | docs/final-product-backlog.md:74:79 | \| FP-AUTO-0013 \| comment-marker \| src/apprt/gtk/class/application.zig:2208:8 \| // TODO: use https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.OpenURI.html \| |
| FP-AUTO-0013 | comment-marker | docs/final-product-backlog.md:75:80 | \| FP-AUTO-0014 \| comment-marker \| src/apprt/gtk/class/application.zig:2509:16 \| // TODO: pass surface ID when we have that \| |
| FP-AUTO-0014 | comment-marker | docs/final-product-backlog.md:77:83 | \| FP-AUTO-0016 \| comment-marker \| src/apprt/gtk/class/command_palette.zig:585:16 \| // TODO: Replace with surface id whenever Ghostty adds one \| |
| FP-AUTO-0015 | comment-marker | docs/final-product-backlog.md:78:84 | \| FP-AUTO-0017 \| comment-marker \| src/apprt/gtk/class/global_shortcuts.zig:382:16 \| // TODO: XDG recommends updating the signal subscription if the actual \| |
| FP-AUTO-0016 | comment-marker | docs/final-product-backlog.md:79:75 | \| FP-AUTO-0018 \| comment-marker \| src/apprt/gtk/class/surface.zig:1012:8 \| // TODO: pass the surface with the action \| |
| FP-AUTO-0017 | comment-marker | docs/final-product-backlog.md:80:71 | \| FP-AUTO-0019 \| comment-marker \| src/apprt/gtk/class/tab.zig:206:16 \| // TODO: We should make our "no surfaces" state more aesthetically \| |
| FP-AUTO-0018 | comment-marker | docs/final-product-backlog.md:81:74 | \| FP-AUTO-0020 \| comment-marker \| src/apprt/gtk/class/window.zig:354:12 \| // TODO: accept the surface that toggled the command palette \| |
| FP-AUTO-0019 | comment-marker | docs/final-product-backlog.md:82:74 | \| FP-AUTO-0021 \| comment-marker \| src/apprt/gtk/class/window.zig:1523:8 \| // TODO: connect close page handler to tab to check for confirmation \| |
| FP-AUTO-0020 | comment-marker | docs/final-product-backlog.md:83:74 | \| FP-AUTO-0022 \| comment-marker \| src/apprt/gtk/class/window.zig:1916:4 \| /// TODO: accept the surface that toggled the command palette as a parameter \| |
| FP-AUTO-0021 | comment-marker | docs/final-product-backlog.md:84:74 | \| FP-AUTO-0023 \| comment-marker \| src/apprt/gtk/class/window.zig:1971:8 \| // TODO: accept the surface that toggled the command palette as a \| |
| FP-AUTO-0022 | comment-marker | docs/final-product-backlog.md:85:74 | \| FP-AUTO-0024 \| comment-marker \| src/apprt/gtk/class/window.zig:1988:8 \| // TODO: accept the surface that toggled the command palette as a \| |
| FP-AUTO-0023 | comment-marker | docs/final-product-backlog.md:86:64 | \| FP-AUTO-0025 \| comment-marker \| src/apprt/gtk/key.zig:534:4 \| // TODO: media keys \| |
| FP-AUTO-0024 | comment-marker | docs/final-product-backlog.md:87:75 | \| FP-AUTO-0026 \| comment-marker \| src/apprt/gtk/ui/1.2/surface.blp:106:6 \| // TODO: the tooltip doesn't actually work, but keep it here for now so \| |
| FP-AUTO-0025 | comment-marker | docs/final-product-backlog.md:88:76 | \| FP-AUTO-0027 \| comment-marker \| src/apprt/gtk/winproto/wayland.zig:30:8 \| // FIXME: replace with `zxdg_decoration_v1` once GTK merges \| |
| FP-AUTO-0026 | comment-marker | docs/final-product-backlog.md:89:76 | \| FP-AUTO-0028 \| comment-marker \| src/apprt/gtk/winproto/wayland.zig:46:8 \| /// FIXME: This is a temporary workaround - we should remove this when \| |
| FP-AUTO-0027 | comment-marker | docs/final-product-backlog.md:90:73 | \| FP-AUTO-0029 \| comment-marker \| src/apprt/gtk/winproto/x11.zig:253:8 \| // FIXME: This doesn't currently factor in rounded corners on Adwaita, \| |
| FP-AUTO-0028 | comment-marker | docs/final-product-backlog.md:91:73 | \| FP-AUTO-0030 \| comment-marker \| src/apprt/gtk/winproto/x11.zig:372:8 \| // FIXME: Maybe we should switch to libxcb one day. \| |
| FP-AUTO-0029 | comment-marker | docs/final-product-backlog.md:92:63 | \| FP-AUTO-0031 \| comment-marker \| src/apprt/surface.zig:20:4 \| /// TODO: we should change this to a "WriteReq" style structure in \| |
| FP-AUTO-0030 | comment-marker | docs/final-product-backlog.md:93:67 | \| FP-AUTO-0032 \| comment-marker \| src/build/SharedDeps.zig:647:8 \| // FIXME: replace with `zxdg_decoration_v1` once GTK merges https://gitlab.gnome.org/GNOME/gtk/-/merge_requests/6398 \| |
| FP-AUTO-0031 | comment-marker | docs/final-product-backlog.md:94:69 | \| FP-AUTO-0033 \| comment-marker \| src/build/UnicodeTables.zig:24:8 \| // TODO: x86_64 self-hosted crashes \| |
| FP-AUTO-0032 | comment-marker | docs/final-product-backlog.md:95:69 | \| FP-AUTO-0034 \| comment-marker \| src/build/UnicodeTables.zig:38:8 \| // TODO: x86_64 self-hosted crashes \| |
| FP-AUTO-0033 | comment-marker | docs/final-product-backlog.md:96:58 | \| FP-AUTO-0035 \| comment-marker \| src/cli/args.zig:14:1 \| // TODO: \| |
| FP-AUTO-0034 | comment-marker | docs/final-product-backlog.md:97:65 | \| FP-AUTO-0036 \| comment-marker \| src/cli/list_themes.zig:49:8 \| // TODO: use Unicode-aware comparison \| |
| FP-AUTO-0035 | comment-marker | docs/final-product-backlog.md:98:58 | \| FP-AUTO-0037 \| comment-marker \| src/Command.zig:280:4 \| // TODO: In the case of having FDs instead of pty, need to set up \| |
| FP-AUTO-0036 | comment-marker | docs/final-product-backlog.md:99:65 | \| FP-AUTO-0038 \| comment-marker \| src/config/Config.zig:1417:1 \| /// TODO: This can't currently be set! \| |
| FP-AUTO-0037 | comment-marker | docs/final-product-backlog.md:100:65 | \| FP-AUTO-0039 \| comment-marker \| src/config/Config.zig:3797:1 \| /// HACK: We set this with an `xterm` prefix because vim uses that to enable key \| |
| FP-AUTO-0038 | comment-marker | docs/final-product-backlog.md:101:65 | \| FP-AUTO-0040 \| comment-marker \| src/config/Config.zig:4620:8 \| // HACK: See comment above at definition \| |
| FP-AUTO-0039 | comment-marker | docs/final-product-backlog.md:102:60 | \| FP-AUTO-0041 \| comment-marker \| src/font/Atlas.zig:92:1 \| /// TODO: figure out optimal prealloc based on real world usage \| |
| FP-AUTO-0040 | comment-marker | docs/final-product-backlog.md:103:67 | \| FP-AUTO-0042 \| comment-marker \| src/font/Collection.zig:1185:4 \| // TODO(fontmem): test explicit/implicit \| |
| FP-AUTO-0041 | comment-marker | docs/final-product-backlog.md:104:67 | \| FP-AUTO-0043 \| comment-marker \| src/font/Collection.zig:1269:1 \| // TODO: Also test CJK fallback sizing, we don't currently have a CJK test font. \| |
| FP-AUTO-0042 | comment-marker | docs/final-product-backlog.md:105:66 | \| FP-AUTO-0044 \| comment-marker \| src/font/discovery.zig:1391:4 \| // FIXME: Disabled for now because SF Pro is not available in CI \| |
| FP-AUTO-0043 | comment-marker | docs/final-product-backlog.md:106:72 | \| FP-AUTO-0045 \| comment-marker \| src/font/face/web_canvas.zig:232:12 \| // TODO: this can't be right \| |
| FP-AUTO-0044 | comment-marker | docs/final-product-backlog.md:107:59 | \| FP-AUTO-0046 \| comment-marker \| src/font/main.zig:46:4 \| // TODO: we need to modify the build config for wasm builds. the issue \| |
| FP-AUTO-0045 | comment-marker | docs/final-product-backlog.md:108:59 | \| FP-AUTO-0047 \| comment-marker \| src/font/main.zig:71:1 \| /// TODO: Add user configuration for this instead of hard-coding it. \| |
| FP-AUTO-0046 | comment-marker | docs/final-product-backlog.md:109:72 | \| FP-AUTO-0048 \| comment-marker \| src/font/shaper/web_canvas.zig:82:8 \| // TODO: memory check that cell_buf can fit results \| |
| FP-AUTO-0047 | comment-marker | docs/final-product-backlog.md:110:107 | \| FP-AUTO-0049 \| comment-marker \| src/font/sprite/draw/symbols_for_legacy_computing_supplement.zig:247:1 \| /// TODO: These two characters should be easy, but it's not clear how they're \| |
| FP-AUTO-0048 | comment-marker | docs/final-product-backlog.md:111:96 | \| FP-AUTO-0050 \| comment-marker \| src/font/sprite/draw/symbols_for_legacy_computing.zig:739:4 \| // TODO: This doesn't align properly for most cell sizes, fix that. \| |
| FP-AUTO-0049 | comment-marker | docs/final-product-backlog.md:112:96 | \| FP-AUTO-0051 \| comment-marker \| src/font/sprite/draw/symbols_for_legacy_computing.zig:779:4 \| // TODO: This doesn't align properly for most cell sizes, fix that. \| |
| FP-AUTO-0050 | comment-marker | docs/final-product-backlog.md:113:65 | \| FP-AUTO-0052 \| comment-marker \| src/input/Binding.zig:102:12 \| // TODO: We should change this parser into a real state machine \| |
| FP-AUTO-0051 | comment-marker | docs/final-product-backlog.md:114:65 | \| FP-AUTO-0053 \| comment-marker \| src/input/keycodes.zig:215:4 \| // TODO(garykac): \| |
| FP-AUTO-0052 | comment-marker | docs/final-product-backlog.md:115:65 | \| FP-AUTO-0054 \| comment-marker \| src/input/keycodes.zig:288:4 \| // TODO(garykac): Verify Mac intl keyboard. \| |
| FP-AUTO-0053 | comment-marker | docs/final-product-backlog.md:116:65 | \| FP-AUTO-0055 \| comment-marker \| src/input/keycodes.zig:297:4 \| // TODO(garykac): CapsLock requires special handling for each platform. \| |
| FP-AUTO-0054 | comment-marker | docs/final-product-backlog.md:117:65 | \| FP-AUTO-0056 \| comment-marker \| src/input/keycodes.zig:531:4 \| // TODO(garykac): Many XF86 keys have multiple scancodes mapping to them. \| |
| FP-AUTO-0055 | comment-marker | docs/final-product-backlog.md:118:65 | \| FP-AUTO-0057 \| comment-marker \| src/input/keycodes.zig:536:4 \| // TODO(garykac): Find appropriate mappings for: \| |
| FP-AUTO-0056 | comment-marker | docs/final-product-backlog.md:119:69 | \| FP-AUTO-0058 \| comment-marker \| src/inspector/Inspector.zig:40:8 \| // TODO: This will have to be recalculated for different screen DPIs. \| |
| FP-AUTO-0057 | comment-marker | docs/final-product-backlog.md:120:76 | \| FP-AUTO-0059 \| comment-marker \| src/inspector/widgets/termio.zig:103:12 \| // TODO: Eventually \| |
| FP-AUTO-0058 | comment-marker | docs/final-product-backlog.md:121:60 | \| FP-AUTO-0060 \| comment-marker \| src/os/desktop.zig:60:8 \| // TODO: This should have some logic to detect this. Perhaps std.builtin.subsystem \| |
| FP-AUTO-0059 | comment-marker | docs/final-product-backlog.md:122:57 | \| FP-AUTO-0061 \| comment-marker \| src/os/file.zig:61:8 \| // TODO: what is a good fallback path on windows? \| |
| FP-AUTO-0060 | comment-marker | docs/final-product-backlog.md:125:59 | \| FP-AUTO-0064 \| comment-marker \| src/os/mach.zig:132:12 \| // TODO: if the next_mmap_addr_hint is within the remapped range, update it \| |
| FP-AUTO-0061 | comment-marker | docs/final-product-backlog.md:126:59 | \| FP-AUTO-0065 \| comment-marker \| src/os/mach.zig:139:12 \| // TODO: if the next_mmap_addr_hint is within the unmapped range, update it \| |
| FP-AUTO-0062 | comment-marker | docs/final-product-backlog.md:127:59 | \| FP-AUTO-0066 \| comment-marker \| src/os/shell.zig:92:16 \| // TODO: Actually use a buffer here \| |
| FP-AUTO-0063 | comment-marker | docs/final-product-backlog.md:128:59 | \| FP-AUTO-0067 \| comment-marker \| src/os/shell.zig:103:8 \| // TODO: This is a very naive implementation and does not really make \| |
| FP-AUTO-0064 | comment-marker | docs/final-product-backlog.md:129:53 | \| FP-AUTO-0068 \| comment-marker \| src/pty.zig:40:1 \| // TODO: This should be removed. This is only temporary until we have \| |
| FP-AUTO-0065 | comment-marker | docs/final-product-backlog.md:130:76 | \| FP-AUTO-0069 \| comment-marker \| src/renderer/metal/RenderPass.zig:158:8 \| // TODO: Maybe in the future add info to the pipeline struct which \| |
| FP-AUTO-0066 | comment-marker | docs/final-product-backlog.md:131:73 | \| FP-AUTO-0070 \| comment-marker \| src/renderer/metal/shaders.zig:232:4 \| /// TODO: Maybe put these in a packed struct, like for OpenGL. \| |
| FP-AUTO-0067 | comment-marker | docs/final-product-backlog.md:132:67 | \| FP-AUTO-0071 \| comment-marker \| src/renderer/OpenGL.zig:206:12 \| // TODO(mitchellh): this does nothing today to allow libghostty \| |
| FP-AUTO-0068 | comment-marker | docs/final-product-backlog.md:133:67 | \| FP-AUTO-0072 \| comment-marker \| src/renderer/OpenGL.zig:247:12 \| // TODO(mitchellh): this does nothing today to allow libghostty \| |
| FP-AUTO-0069 | comment-marker | docs/final-product-backlog.md:134:67 | \| FP-AUTO-0073 \| comment-marker \| src/renderer/OpenGL.zig:269:12 \| // TODO: see threadEnter \| |
| FP-AUTO-0070 | comment-marker | docs/final-product-backlog.md:135:66 | \| FP-AUTO-0074 \| comment-marker \| src/renderer/OpenGL.zig:513:8 \| // TODO: Generate mipmaps for image textures and use \| |
| FP-AUTO-0071 | comment-marker | docs/final-product-backlog.md:136:66 | \| FP-AUTO-0075 \| comment-marker \| src/renderer/OpenGL.zig:518:8 \| // TODO: Separate out background image options, use \| |
| FP-AUTO-0072 | comment-marker | docs/final-product-backlog.md:137:76 | \| FP-AUTO-0076 \| comment-marker \| src/renderer/opengl/RenderPass.zig:61:1 \| /// TODO: Errors are silently ignored in this function, maybe they shouldn't be? \| |
| FP-AUTO-0073 | comment-marker | docs/final-product-backlog.md:138:61 | \| FP-AUTO-0077 \| comment-marker \| src/renderer/row.zig:3:1 \| // TODO: Test neverExtendBg function \| |
| FP-AUTO-0074 | comment-marker | docs/final-product-backlog.md:139:76 | \| FP-AUTO-0078 \| comment-marker \| src/renderer/shaders/shaders.metal:54:1 \| // TODO: The color matrix should probably be computed \| |
| FP-AUTO-0075 | comment-marker | docs/final-product-backlog.md:140:77 | \| FP-AUTO-0079 \| comment-marker \| src/renderer/shaders/shaders.metal:495:2 \| // TODO: It might be a good idea to do a pass before this \| |
| FP-AUTO-0076 | comment-marker | docs/final-product-backlog.md:141:69 | \| FP-AUTO-0080 \| comment-marker \| src/renderer/shadertoy.zig:431:4 \| // TODO: Replace this with an aligned version of Writer.Allocating \| |
| FP-AUTO-0077 | comment-marker | docs/final-product-backlog.md:142:69 | \| FP-AUTO-0081 \| comment-marker \| src/renderer/shadertoy.zig:471:4 \| // TODO: Replace this with an aligned version of Writer.Allocating \| |
| FP-AUTO-0078 | comment-marker | docs/final-product-backlog.md:143:84 | \| FP-AUTO-0082 \| comment-marker \| src/shell-integration/bash/bash-preexec.sh:64:1 \| # TODO: Figure out how to restore PIPESTATUS before each precmd or preexec \| |
| FP-AUTO-0079 | comment-marker | docs/final-product-backlog.md:144:57 | \| FP-AUTO-0083 \| comment-marker \| src/simd/vt.cpp:88:4 \| // TODO(mitchellh): benchmark this vs decoding every time \| |
| FP-AUTO-0080 | comment-marker | docs/final-product-backlog.md:145:57 | \| FP-AUTO-0084 \| comment-marker \| src/simd/vt.zig:92:4 \| // TODO: many more test cases \| |
| FP-AUTO-0081 | comment-marker | docs/final-product-backlog.md:146:58 | \| FP-AUTO-0085 \| comment-marker \| src/simd/vt.zig:107:4 \| // TODO: many more test cases \| |
| FP-AUTO-0082 | comment-marker | docs/final-product-backlog.md:147:63 | \| FP-AUTO-0086 \| comment-marker \| src/surface_mouse.zig:60:4 \| // TODO: As we unravel mouse state, we can fix this to be more explicit. \| |
| FP-AUTO-0083 | comment-marker | docs/final-product-backlog.md:148:63 | \| FP-AUTO-0087 \| comment-marker \| src/surface_mouse.zig:77:4 \| // TODO: This could be updated eventually to be a true transition table if \| |
| FP-AUTO-0084 | comment-marker | docs/final-product-backlog.md:149:59 | \| FP-AUTO-0088 \| comment-marker \| src/Surface.zig:2125:4 \| // TODO: need to handle when scrolling and the cursor is not \| |
| FP-AUTO-0085 | comment-marker | docs/final-product-backlog.md:150:59 | \| FP-AUTO-0089 \| comment-marker \| src/Surface.zig:5086:4 \| // TODO(qwerasd): this can/should probably be refactored, it's a bit \| |
| FP-AUTO-0086 | comment-marker | docs/final-product-backlog.md:151:59 | \| FP-AUTO-0090 \| comment-marker \| src/Surface.zig:5098:4 \| // TODO: Clamp selection to the screen area, don't \| |
| FP-AUTO-0087 | comment-marker | docs/final-product-backlog.md:152:63 | \| FP-AUTO-0091 \| comment-marker \| src/synthetic/cli.zig:84:4 \| // TODO: Make this a command line option. \| |
| FP-AUTO-0088 | comment-marker | docs/final-product-backlog.md:153:70 | \| FP-AUTO-0092 \| comment-marker \| src/terminal/formatter.zig:915:20 \| // TODO: if unavailable, we should add to our trailing state \| |
| FP-AUTO-0089 | comment-marker | docs/final-product-backlog.md:154:69 | \| FP-AUTO-0093 \| comment-marker \| src/terminal/hash_map.zig:814:12 \| // TODO: replace with pointer subtraction once supported by zig \| |
| FP-AUTO-0090 | comment-marker | docs/final-product-backlog.md:155:81 | \| FP-AUTO-0094 \| comment-marker \| src/terminal/kitty/graphics_storage.zig:34:4 \| /// TODO: This isn't good enough, it's perfectly legal for programs \| |
| FP-AUTO-0091 | comment-marker | docs/final-product-backlog.md:156:65 | \| FP-AUTO-0095 \| comment-marker \| src/terminal/page.zig:926:24 \| // TODO(qwerasd): verify the assumption that `addWithId` \| |
| FP-AUTO-0092 | comment-marker | docs/final-product-backlog.md:157:68 | \| FP-AUTO-0096 \| comment-marker \| src/terminal/PageList.zig:939:1 \| /// TODO: docs \| |
| FP-AUTO-0093 | comment-marker | docs/final-product-backlog.md:158:69 | \| FP-AUTO-0097 \| comment-marker \| src/terminal/PageList.zig:5280:4 \| /// TODO: Unit tests. \| |
| FP-AUTO-0094 | comment-marker | docs/final-product-backlog.md:159:69 | \| FP-AUTO-0098 \| comment-marker \| src/terminal/PageList.zig:5307:4 \| /// TODO: Unit tests. \| |
| FP-AUTO-0095 | comment-marker | docs/final-product-backlog.md:160:71 | \| FP-AUTO-0099 \| comment-marker \| src/terminal/parse_table.zig:358:4 \| // TODO: enable this but it thinks we're in runtime right now \| |
| FP-AUTO-0096 | comment-marker | docs/final-product-backlog.md:161:67 | \| FP-AUTO-0100 \| comment-marker \| src/terminal/Screen.zig:586:12 \| // TODO: Should we increase the capacity further in this case? \| |
| FP-AUTO-0097 | comment-marker | docs/final-product-backlog.md:162:67 | \| FP-AUTO-0101 \| comment-marker \| src/terminal/Screen.zig:608:12 \| // TODO: Should we increase the capacity further in this case? \| |
| FP-AUTO-0098 | comment-marker | docs/final-product-backlog.md:163:67 | \| FP-AUTO-0102 \| comment-marker \| src/terminal/Screen.zig:1207:1 \| /// TODO: test \| |
| FP-AUTO-0099 | comment-marker | docs/final-product-backlog.md:164:68 | \| FP-AUTO-0103 \| comment-marker \| src/terminal/Screen.zig:2316:12 \| // FIXME: increaseCapacity should not do this. \| |
| FP-AUTO-0100 | comment-marker | docs/final-product-backlog.md:165:67 | \| FP-AUTO-0104 \| comment-marker \| src/terminal/Screen.zig:2740:1 \| /// TODO: test this \| |
| FP-AUTO-0101 | comment-marker | docs/final-product-backlog.md:166:72 | \| FP-AUTO-0105 \| comment-marker \| src/terminal/search/Thread.zig:33:1 \| // TODO: Some stuff that could be improved: \| |
| FP-AUTO-0102 | comment-marker | docs/final-product-backlog.md:167:66 | \| FP-AUTO-0106 \| comment-marker \| src/terminal/stream.zig:233:8 \| // TODO: Before shipping an ABI-compatible libghostty, verify this. \| |
| FP-AUTO-0103 | comment-marker | docs/final-product-backlog.md:168:67 | \| FP-AUTO-0107 \| comment-marker \| src/terminal/stream.zig:938:16 \| // TODO: test \| |
| FP-AUTO-0104 | comment-marker | docs/final-product-backlog.md:169:67 | \| FP-AUTO-0108 \| comment-marker \| src/terminal/stream.zig:959:16 \| // TODO: test \| |
| FP-AUTO-0105 | comment-marker | docs/final-product-backlog.md:170:68 | \| FP-AUTO-0109 \| comment-marker \| src/terminal/stream.zig:1074:16 \| // TODO: test \| |
| FP-AUTO-0106 | comment-marker | docs/final-product-backlog.md:171:68 | \| FP-AUTO-0110 \| comment-marker \| src/terminal/stream.zig:1092:16 \| // TODO: test \| |
| FP-AUTO-0107 | comment-marker | docs/final-product-backlog.md:172:68 | \| FP-AUTO-0111 \| comment-marker \| src/terminal/stream.zig:1337:16 \| // TODO: test \| |
| FP-AUTO-0108 | comment-marker | docs/final-product-backlog.md:173:68 | \| FP-AUTO-0112 \| comment-marker \| src/terminal/stream.zig:1488:16 \| // TODO: test \| |
| FP-AUTO-0109 | comment-marker | docs/final-product-backlog.md:174:68 | \| FP-AUTO-0113 \| comment-marker \| src/terminal/stream.zig:1587:24 \| // TODO: test \| |
| FP-AUTO-0110 | comment-marker | docs/final-product-backlog.md:175:68 | \| FP-AUTO-0114 \| comment-marker \| src/terminal/stream.zig:2082:16 \| // TODO: support slots '-', '.', '/' \| |
| FP-AUTO-0111 | comment-marker | docs/final-product-backlog.md:176:68 | \| FP-AUTO-0115 \| comment-marker \| src/terminal/Tabstops.zig:127:1 \| // TODO: needs interval to set new tabstops \| |
| FP-AUTO-0112 | comment-marker | docs/final-product-backlog.md:177:68 | \| FP-AUTO-0116 \| comment-marker \| src/terminal/Terminal.zig:677:4 \| // TODO: spacers should use a bgcolor only cell \| |
| FP-AUTO-0113 | comment-marker | docs/final-product-backlog.md:178:68 | \| FP-AUTO-0117 \| comment-marker \| src/terminal/Terminal.zig:680:8 \| // TODO: non-utf8 handling, gr \| |
| FP-AUTO-0114 | comment-marker | docs/final-product-backlog.md:179:69 | \| FP-AUTO-0118 \| comment-marker \| src/terminal/Terminal.zig:753:12 \| // TODO: this case was not handled in the old terminal implementation \| |
| FP-AUTO-0115 | comment-marker | docs/final-product-backlog.md:180:69 | \| FP-AUTO-0119 \| comment-marker \| src/terminal/Terminal.zig:1368:1 \| /// TODO: test \| |
| FP-AUTO-0116 | comment-marker | docs/final-product-backlog.md:181:69 | \| FP-AUTO-0120 \| comment-marker \| src/terminal/Terminal.zig:1373:1 \| /// TODO: test \| |
| FP-AUTO-0117 | comment-marker | docs/final-product-backlog.md:182:69 | \| FP-AUTO-0121 \| comment-marker \| src/terminal/Terminal.zig:1675:8 \| // TODO: Create an optimized version that can scroll N times \| |
| FP-AUTO-0118 | comment-marker | docs/final-product-backlog.md:183:69 | \| FP-AUTO-0122 \| comment-marker \| src/terminal/Terminal.zig:1771:1 \| // TODO(qwerasd): `insertLines` and `deleteLines` are 99% identical, \| |
| FP-AUTO-0119 | comment-marker | docs/final-product-backlog.md:184:69 | \| FP-AUTO-0123 \| comment-marker \| src/terminal/Terminal.zig:2328:4 \| // TODO(qwerasd): This isn't actually correct if you take in to account \| |
| FP-AUTO-0120 | comment-marker | docs/final-product-backlog.md:185:73 | \| FP-AUTO-0124 \| comment-marker \| src/terminal/tmux/control.zig:167:12 \| // TODO(tmuxcc): do this before merge? \| |
| FP-AUTO-0121 | comment-marker | docs/final-product-backlog.md:186:70 | \| FP-AUTO-0125 \| comment-marker \| src/terminal/tmux/viewer.zig:18:1 \| // TODO: A list of TODOs as I think about them. \| |
| FP-AUTO-0122 | comment-marker | docs/final-product-backlog.md:187:71 | \| FP-AUTO-0126 \| comment-marker \| src/terminal/tmux/viewer.zig:667:8 \| // TODO: errdefer cleanup \| |
| FP-AUTO-0123 | comment-marker | docs/final-product-backlog.md:188:73 | \| FP-AUTO-0127 \| comment-marker \| src/terminal/tmux/viewer.zig:1158:16 \| // TODO: We need to gracefully handle overflow of our \| |
| FP-AUTO-0124 | comment-marker | docs/final-product-backlog.md:189:66 | \| FP-AUTO-0128 \| comment-marker \| src/terminfo/ghostty.zig:10:8 \| // HACK: This is a hack on a hack...we use "xterm-ghostty" to prevent \| |
| FP-AUTO-0125 | comment-marker | docs/final-product-backlog.md:190:62 | \| FP-AUTO-0129 \| comment-marker \| src/termio/Exec.zig:327:4 \| // TODO: support on windows \| |
| FP-AUTO-0126 | comment-marker | docs/final-product-backlog.md:193:73 | \| FP-AUTO-0132 \| comment-marker \| src/termio/stream_handler.zig:447:28 \| // TODO \| |
| FP-AUTO-0127 | comment-marker | docs/final-product-backlog.md:201:64 | \| FP-AUTO-0140 \| comment-marker \| src/termio/Termio.zig:628:8 \| // TODO: fix this \| |
| FP-AUTO-0128 | comment-marker | docs/final-product-backlog.md:202:66 | \| FP-AUTO-0141 \| comment-marker \| src/unicode/grapheme.zig:85:1 \| /// TODO: this is hard to build with newer zig build, so \| |
| FP-AUTO-0129 | comment-marker | flatpak/dependencies.yml:38:6 | # TODO: Automate this with check-zig-cache.sh |
| FP-AUTO-0130 | comment-marker | macos/Sources/Features/Terminal/Window Styles/TitlebarTabsTahoeTerminalWindow.swift:129:12 | // HACK: wait a tick before doing anything, to avoid edge cases during startup... :/ |
| FP-AUTO-0131 | comment-marker | macos/Sources/Features/Terminal/Window Styles/TitlebarTabsVenturaTerminalWindow.swift:341:4 | // HACK: hide the "collapsed items" marker from the toolbar if it's present. |
| FP-AUTO-0132 | comment-marker | macos/Sources/Features/Terminal/Window Styles/TitlebarTabsVenturaTerminalWindow.swift:412:8 | // HACK: wait a tick before doing anything, to avoid edge cases during startup... :/ |
| FP-AUTO-0133 | comment-marker | macos/Sources/Ghostty/Ghostty.Config.swift:82:12 | // TODO: we'd probably do some config loading here... for now we'd |
| FP-AUTO-0134 | comment-marker | macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift:1145:16 | // TODO(mitchellh): do we have to scale the x/y here by window scale factor? |
| FP-AUTO-0135 | comment-marker | macos/Sources/Ghostty/Surface View/SurfaceView_UIKit.swift:88:16 | // TODO |
| FP-AUTO-0136 | comment-marker | macos/Sources/Helpers/Fullscreen.swift:96:8 | // TODO: There are many requirements for native fullscreen we should |
| FP-AUTO-0137 | comment-marker | snap/snapcraft.yaml:79:4 | # TODO: Remove -fno-sys=gtk4-layer-shell when we upgrade to a version that packages it Ubuntu 24.10+ |
| FP-AUTO-0138 | text-not-implemented | src/apprt/action.zig:61:47 | /// there is a compiler error if an action is not implemented. |
| FP-AUTO-0139 | comment-marker | src/apprt/action.zig:557:4 | // TODO: check non-exhaustive enums |
| FP-AUTO-0140 | comment-marker | src/apprt/action.zig:847:4 | // TODO: check non-non-exhaustive enums |
| FP-AUTO-0141 | comment-marker | src/apprt/gtk/class/application.zig:2208:8 | // TODO: use https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.OpenURI.html |
| FP-AUTO-0142 | comment-marker | src/apprt/gtk/class/application.zig:2509:16 | // TODO: pass surface ID when we have that |
| FP-AUTO-0143 | text-not-implemented | src/apprt/gtk/class/command_palette.zig:192:44 | // Filter out actions that are not implemented or don't make sense |
| FP-AUTO-0144 | comment-marker | src/apprt/gtk/class/command_palette.zig:585:16 | // TODO: Replace with surface id whenever Ghostty adds one |
| FP-AUTO-0145 | comment-marker | src/apprt/gtk/class/global_shortcuts.zig:382:16 | // TODO: XDG recommends updating the signal subscription if the actual |
| FP-AUTO-0146 | comment-marker | src/apprt/gtk/class/surface.zig:1012:8 | // TODO: pass the surface with the action |
| FP-AUTO-0147 | comment-marker | src/apprt/gtk/class/tab.zig:206:16 | // TODO: We should make our "no surfaces" state more aesthetically |
| FP-AUTO-0148 | comment-marker | src/apprt/gtk/class/window.zig:354:12 | // TODO: accept the surface that toggled the command palette |
| FP-AUTO-0149 | comment-marker | src/apprt/gtk/class/window.zig:1523:8 | // TODO: connect close page handler to tab to check for confirmation |
| FP-AUTO-0150 | comment-marker | src/apprt/gtk/class/window.zig:1916:4 | /// TODO: accept the surface that toggled the command palette as a parameter |
| FP-AUTO-0151 | comment-marker | src/apprt/gtk/class/window.zig:1971:8 | // TODO: accept the surface that toggled the command palette as a |
| FP-AUTO-0152 | comment-marker | src/apprt/gtk/class/window.zig:1988:8 | // TODO: accept the surface that toggled the command palette as a |
| FP-AUTO-0153 | comment-marker | src/apprt/gtk/key.zig:534:4 | // TODO: media keys |
| FP-AUTO-0154 | comment-marker | src/apprt/gtk/ui/1.2/surface.blp:106:6 | // TODO: the tooltip doesn't actually work, but keep it here for now so |
| FP-AUTO-0155 | comment-marker | src/apprt/gtk/winproto/wayland.zig:30:8 | // FIXME: replace with `zxdg_decoration_v1` once GTK merges |
| FP-AUTO-0156 | comment-marker | src/apprt/gtk/winproto/wayland.zig:46:8 | /// FIXME: This is a temporary workaround - we should remove this when |
| FP-AUTO-0157 | comment-marker | src/apprt/gtk/winproto/x11.zig:253:8 | // FIXME: This doesn't currently factor in rounded corners on Adwaita, |
| FP-AUTO-0158 | comment-marker | src/apprt/gtk/winproto/x11.zig:372:8 | // FIXME: Maybe we should switch to libxcb one day. |
| FP-AUTO-0159 | comment-marker | src/apprt/surface.zig:20:4 | /// TODO: we should change this to a "WriteReq" style structure in |
| FP-AUTO-0160 | comment-marker | src/build/SharedDeps.zig:647:8 | // FIXME: replace with `zxdg_decoration_v1` once GTK merges https://gitlab.gnome.org/GNOME/gtk/-/merge_requests/6398 |
| FP-AUTO-0161 | comment-marker | src/build/UnicodeTables.zig:24:8 | // TODO: x86_64 self-hosted crashes |
| FP-AUTO-0162 | comment-marker | src/build/UnicodeTables.zig:38:8 | // TODO: x86_64 self-hosted crashes |
| FP-AUTO-0163 | comment-marker | src/cli/args.zig:14:1 | // TODO: |
| FP-AUTO-0164 | comment-marker | src/cli/list_themes.zig:49:8 | // TODO: use Unicode-aware comparison |
| FP-AUTO-0165 | comment-marker | src/Command.zig:280:4 | // TODO: In the case of having FDs instead of pty, need to set up |
| FP-AUTO-0166 | comment-marker | src/config/Config.zig:1417:1 | /// TODO: This can't currently be set! |
| FP-AUTO-0167 | comment-marker | src/config/Config.zig:3797:1 | /// HACK: We set this with an `xterm` prefix because vim uses that to enable key |
| FP-AUTO-0168 | comment-marker | src/config/Config.zig:4620:8 | // HACK: See comment above at definition |
| FP-AUTO-0169 | comment-marker | src/font/Atlas.zig:92:1 | /// TODO: figure out optimal prealloc based on real world usage |
| FP-AUTO-0170 | comment-marker | src/font/Collection.zig:1185:4 | // TODO(fontmem): test explicit/implicit |
| FP-AUTO-0171 | comment-marker | src/font/Collection.zig:1269:1 | // TODO: Also test CJK fallback sizing, we don't currently have a CJK test font. |
| FP-AUTO-0172 | comment-marker | src/font/discovery.zig:1391:4 | // FIXME: Disabled for now because SF Pro is not available in CI |
| FP-AUTO-0173 | comment-marker | src/font/face/web_canvas.zig:232:12 | // TODO: this can't be right |
| FP-AUTO-0174 | comment-marker | src/font/main.zig:46:4 | // TODO: we need to modify the build config for wasm builds. the issue |
| FP-AUTO-0175 | comment-marker | src/font/main.zig:71:1 | /// TODO: Add user configuration for this instead of hard-coding it. |
| FP-AUTO-0176 | comment-marker | src/font/shaper/web_canvas.zig:82:8 | // TODO: memory check that cell_buf can fit results |
| FP-AUTO-0177 | comment-marker | src/font/sprite/draw/symbols_for_legacy_computing_supplement.zig:247:1 | /// TODO: These two characters should be easy, but it's not clear how they're |
| FP-AUTO-0178 | comment-marker | src/font/sprite/draw/symbols_for_legacy_computing.zig:739:4 | // TODO: This doesn't align properly for most cell sizes, fix that. |
| FP-AUTO-0179 | comment-marker | src/font/sprite/draw/symbols_for_legacy_computing.zig:779:4 | // TODO: This doesn't align properly for most cell sizes, fix that. |
| FP-AUTO-0180 | comment-marker | src/input/Binding.zig:102:12 | // TODO: We should change this parser into a real state machine |
| FP-AUTO-0181 | comment-marker | src/input/keycodes.zig:215:4 | // TODO(garykac): |
| FP-AUTO-0182 | comment-marker | src/input/keycodes.zig:288:4 | // TODO(garykac): Verify Mac intl keyboard. |
| FP-AUTO-0183 | comment-marker | src/input/keycodes.zig:297:4 | // TODO(garykac): CapsLock requires special handling for each platform. |
| FP-AUTO-0184 | comment-marker | src/input/keycodes.zig:531:4 | // TODO(garykac): Many XF86 keys have multiple scancodes mapping to them. |
| FP-AUTO-0185 | comment-marker | src/input/keycodes.zig:536:4 | // TODO(garykac): Find appropriate mappings for: |
| FP-AUTO-0186 | comment-marker | src/inspector/Inspector.zig:40:8 | // TODO: This will have to be recalculated for different screen DPIs. |
| FP-AUTO-0187 | comment-marker | src/inspector/widgets/termio.zig:103:12 | // TODO: Eventually |
| FP-AUTO-0188 | comment-marker | src/os/desktop.zig:60:8 | // TODO: This should have some logic to detect this. Perhaps std.builtin.subsystem |
| FP-AUTO-0189 | compileError-unimplemented | src/os/homedir.zig:22:17 | else => @compileError("unimplemented"), |
| FP-AUTO-0190 | compileError-unimplemented | src/os/homedir.zig:162:17 | else => @compileError("unimplemented"), |
| FP-AUTO-0191 | comment-marker | src/os/mach.zig:132:12 | // TODO: if the next_mmap_addr_hint is within the remapped range, update it |
| FP-AUTO-0192 | comment-marker | src/os/mach.zig:139:12 | // TODO: if the next_mmap_addr_hint is within the unmapped range, update it |
| FP-AUTO-0193 | comment-marker | src/os/shell.zig:92:16 | // TODO: Actually use a buffer here |
| FP-AUTO-0194 | comment-marker | src/os/shell.zig:103:8 | // TODO: This is a very naive implementation and does not really make |
| FP-AUTO-0195 | comment-marker | src/pty.zig:40:1 | // TODO: This should be removed. This is only temporary until we have |
| FP-AUTO-0196 | comment-marker | src/renderer/metal/RenderPass.zig:158:8 | // TODO: Maybe in the future add info to the pipeline struct which |
| FP-AUTO-0197 | comment-marker | src/renderer/metal/shaders.zig:232:4 | /// TODO: Maybe put these in a packed struct, like for OpenGL. |
| FP-AUTO-0198 | comment-marker | src/renderer/OpenGL.zig:206:12 | // TODO(mitchellh): this does nothing today to allow libghostty |
| FP-AUTO-0199 | comment-marker | src/renderer/OpenGL.zig:247:12 | // TODO(mitchellh): this does nothing today to allow libghostty |
| FP-AUTO-0200 | comment-marker | src/renderer/OpenGL.zig:269:12 | // TODO: see threadEnter |
| FP-AUTO-0201 | comment-marker | src/renderer/OpenGL.zig:513:8 | // TODO: Generate mipmaps for image textures and use |
| FP-AUTO-0202 | comment-marker | src/renderer/OpenGL.zig:518:8 | // TODO: Separate out background image options, use |
| FP-AUTO-0203 | comment-marker | src/renderer/opengl/RenderPass.zig:61:1 | /// TODO: Errors are silently ignored in this function, maybe they shouldn't be? |
| FP-AUTO-0204 | comment-marker | src/renderer/row.zig:3:1 | // TODO: Test neverExtendBg function |
| FP-AUTO-0205 | comment-marker | src/renderer/shaders/shaders.metal:54:1 | // TODO: The color matrix should probably be computed |
| FP-AUTO-0206 | comment-marker | src/renderer/shaders/shaders.metal:495:2 | // TODO: It might be a good idea to do a pass before this |
| FP-AUTO-0207 | comment-marker | src/renderer/shadertoy.zig:431:4 | // TODO: Replace this with an aligned version of Writer.Allocating |
| FP-AUTO-0208 | comment-marker | src/renderer/shadertoy.zig:471:4 | // TODO: Replace this with an aligned version of Writer.Allocating |
| FP-AUTO-0209 | comment-marker | src/shell-integration/bash/bash-preexec.sh:64:1 | # TODO: Figure out how to restore PIPESTATUS before each precmd or preexec |
| FP-AUTO-0210 | comment-marker | src/simd/vt.cpp:88:4 | // TODO(mitchellh): benchmark this vs decoding every time |
| FP-AUTO-0211 | comment-marker | src/simd/vt.zig:92:4 | // TODO: many more test cases |
| FP-AUTO-0212 | comment-marker | src/simd/vt.zig:107:4 | // TODO: many more test cases |
| FP-AUTO-0213 | comment-marker | src/surface_mouse.zig:60:4 | // TODO: As we unravel mouse state, we can fix this to be more explicit. |
| FP-AUTO-0214 | comment-marker | src/surface_mouse.zig:77:4 | // TODO: This could be updated eventually to be a true transition table if |
| FP-AUTO-0215 | comment-marker | src/Surface.zig:2125:4 | // TODO: need to handle when scrolling and the cursor is not |
| FP-AUTO-0216 | comment-marker | src/Surface.zig:5086:4 | // TODO(qwerasd): this can/should probably be refactored, it's a bit |
| FP-AUTO-0217 | comment-marker | src/Surface.zig:5098:4 | // TODO: Clamp selection to the screen area, don't |
| FP-AUTO-0218 | comment-marker | src/synthetic/cli.zig:84:4 | // TODO: Make this a command line option. |
| FP-AUTO-0219 | comment-marker | src/terminal/formatter.zig:915:20 | // TODO: if unavailable, we should add to our trailing state |
| FP-AUTO-0220 | comment-marker | src/terminal/hash_map.zig:814:12 | // TODO: replace with pointer subtraction once supported by zig |
| FP-AUTO-0221 | comment-marker | src/terminal/kitty/graphics_storage.zig:34:4 | /// TODO: This isn't good enough, it's perfectly legal for programs |
| FP-AUTO-0222 | comment-marker | src/terminal/page.zig:926:24 | // TODO(qwerasd): verify the assumption that `addWithId` |
| FP-AUTO-0223 | comment-marker | src/terminal/PageList.zig:939:1 | /// TODO: docs |
| FP-AUTO-0224 | comment-marker | src/terminal/PageList.zig:5280:4 | /// TODO: Unit tests. |
| FP-AUTO-0225 | comment-marker | src/terminal/PageList.zig:5307:4 | /// TODO: Unit tests. |
| FP-AUTO-0226 | comment-marker | src/terminal/parse_table.zig:358:4 | // TODO: enable this but it thinks we're in runtime right now |
| FP-AUTO-0227 | comment-marker | src/terminal/Screen.zig:586:12 | // TODO: Should we increase the capacity further in this case? |
| FP-AUTO-0228 | comment-marker | src/terminal/Screen.zig:608:12 | // TODO: Should we increase the capacity further in this case? |
| FP-AUTO-0229 | comment-marker | src/terminal/Screen.zig:1207:1 | /// TODO: test |
| FP-AUTO-0230 | comment-marker | src/terminal/Screen.zig:2316:12 | // FIXME: increaseCapacity should not do this. |
| FP-AUTO-0231 | comment-marker | src/terminal/Screen.zig:2740:1 | /// TODO: test this |
| FP-AUTO-0232 | comment-marker | src/terminal/search/Thread.zig:33:1 | // TODO: Some stuff that could be improved: |
| FP-AUTO-0233 | comment-marker | src/terminal/stream.zig:233:8 | // TODO: Before shipping an ABI-compatible libghostty, verify this. |
| FP-AUTO-0234 | comment-marker | src/terminal/stream.zig:938:16 | // TODO: test |
| FP-AUTO-0235 | comment-marker | src/terminal/stream.zig:959:16 | // TODO: test |
| FP-AUTO-0236 | comment-marker | src/terminal/stream.zig:1074:16 | // TODO: test |
| FP-AUTO-0237 | comment-marker | src/terminal/stream.zig:1092:16 | // TODO: test |
| FP-AUTO-0238 | comment-marker | src/terminal/stream.zig:1337:16 | // TODO: test |
| FP-AUTO-0239 | comment-marker | src/terminal/stream.zig:1488:16 | // TODO: test |
| FP-AUTO-0240 | comment-marker | src/terminal/stream.zig:1587:24 | // TODO: test |
| FP-AUTO-0241 | comment-marker | src/terminal/stream.zig:2082:16 | // TODO: support slots '-', '.', '/' |
| FP-AUTO-0242 | comment-marker | src/terminal/Tabstops.zig:127:1 | // TODO: needs interval to set new tabstops |
| FP-AUTO-0243 | comment-marker | src/terminal/Terminal.zig:750:4 | // TODO: spacers should use a bgcolor only cell |
| FP-AUTO-0244 | comment-marker | src/terminal/Terminal.zig:753:8 | // TODO: non-utf8 handling, gr |
| FP-AUTO-0245 | comment-marker | src/terminal/Terminal.zig:826:12 | // TODO: this case was not handled in the old terminal implementation |
| FP-AUTO-0246 | comment-marker | src/terminal/Terminal.zig:1441:1 | /// TODO: test |
| FP-AUTO-0247 | comment-marker | src/terminal/Terminal.zig:1446:1 | /// TODO: test |
| FP-AUTO-0248 | comment-marker | src/terminal/Terminal.zig:1748:8 | // TODO: Create an optimized version that can scroll N times |
| FP-AUTO-0249 | comment-marker | src/terminal/Terminal.zig:1844:1 | // TODO(qwerasd): `insertLines` and `deleteLines` are 99% identical, |
| FP-AUTO-0250 | comment-marker | src/terminal/Terminal.zig:2401:4 | // TODO(qwerasd): This isn't actually correct if you take in to account |
| FP-AUTO-0251 | comment-marker | src/terminal/tmux/control.zig:167:12 | // TODO(tmuxcc): do this before merge? |
| FP-AUTO-0252 | comment-marker | src/terminal/tmux/viewer.zig:18:1 | // TODO: A list of TODOs as I think about them. |
| FP-AUTO-0253 | comment-marker | src/terminal/tmux/viewer.zig:667:8 | // TODO: errdefer cleanup |
| FP-AUTO-0254 | comment-marker | src/terminal/tmux/viewer.zig:1158:16 | // TODO: We need to gracefully handle overflow of our |
| FP-AUTO-0255 | comment-marker | src/terminfo/ghostty.zig:10:8 | // HACK: This is a hack on a hack...we use "xterm-ghostty" to prevent |
| FP-AUTO-0256 | comment-marker | src/termio/Exec.zig:327:4 | // TODO: support on windows |
| FP-AUTO-0257 | panic-not-implemented | src/termio/Exec.zig:329:9 | @panic("termios timer not implemented on Windows"); |
| FP-AUTO-0258 | text-not-implemented | src/termio/Exec.zig:329:31 | @panic("termios timer not implemented on Windows"); |
| FP-AUTO-0259 | comment-marker | src/termio/stream_handler.zig:447:28 | // TODO |
| FP-AUTO-0260 | comment-marker | src/termio/Termio.zig:628:8 | // TODO: fix this |
| FP-AUTO-0261 | comment-marker | src/unicode/grapheme.zig:85:1 | /// TODO: this is hard to build with newer zig build, so |

<!-- AUTO-GENERATED:END -->

