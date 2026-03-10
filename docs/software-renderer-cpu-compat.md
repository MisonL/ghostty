# 软件渲染 CPU 兼容与排障手册

本文面向软件渲染 CPU 路由（software renderer CPU route）的兼容验证与排障，重点覆盖：

- 构建 gate 与运行时 gate 的边界；
- 当前支持矩阵（Linux/macOS 与其他平台状态）；
- `allow-legacy-os` 的真实作用范围；
- capability `unobserved` 的语义；
- shader capability 重探测节奏参数与老设备调优建议；
- CI 脚本关键环境变量及优先级。

## 1. 构建 gate 与运行时 gate

### 1.1 构建 gate（编译期）

CPU 路由是否“构建生效”由编译参数决定，核心条件：

- `-Dsoftware-renderer-cpu-mvp=true`
- 目标系统版本满足最小门槛，或显式开启 `-Dsoftware-renderer-cpu-allow-legacy-os=true`

当前最小门槛：

- macOS `11.0.0`
- Linux `5.0.0`

构建 gate 的结果会体现在 `options.zig` 导出的 `software_renderer_cpu_effective`，也会在兼容脚本日志里显示 `expected-build-cpu-effective=...`。

### 1.2 运行时 gate（启动/渲染期）

即使构建 gate 通过，运行时仍可能自动回退到平台路由（OpenGL/Metal）。常见触发条件：

- `software-renderer-experimental=false`
- `software-renderer-presenter=legacy-gl`
- 软件帧发布能力不可用（日志中表现为 `reason=runtime_publishing_disabled`）
- `-Dsoftware-frame-transport-mode=native`
- 激活 `custom-shader` 且：
  - `-Dsoftware-renderer-cpu-shader-mode=off`
  - 或 `safe/full` 下 capability 不可用
  - 或 `safe` 且 `-Dsoftware-renderer-cpu-shader-timeout-ms=0`

结论：构建 gate 决定“有没有资格进入 CPU 路由”，运行时 gate 决定“当前帧是否真的走 CPU 路由”。

## 2. 支持矩阵（当前实现）

### 2.1 构建期 CPU route 生效矩阵（`software_renderer_cpu_effective`）

| 目标 OS | 目标版本 | `-Dsoftware-renderer-cpu-mvp=true` | `-Dsoftware-renderer-cpu-allow-legacy-os` | 构建期结果 |
| --- | --- | --- | --- | --- |
| macOS | `>= 11.0.0` | 必需 | `false/true` 均可 | `software_renderer_cpu_effective=true` |
| macOS | `< 11.0.0` | 必需 | `false` | `software_renderer_cpu_effective=false` |
| macOS | `< 11.0.0` | 必需 | `true` | `software_renderer_cpu_effective=true`（仅放宽最低版本） |
| Linux | `>= 5.0.0` | 必需 | `false/true` 均可 | `software_renderer_cpu_effective=true` |
| Linux | `< 5.0.0` | 必需 | `false` | `software_renderer_cpu_effective=false` |
| Linux | `< 5.0.0` | 必需 | `true` | `software_renderer_cpu_effective=true`（仅放宽最低版本） |
| Windows / FreeBSD / 其他非 Linux/macOS | 任意 | 必需 | `false` 或 `true` | `software_renderer_cpu_effective=false` |

补充：

- 若 `-Dsoftware-renderer-cpu-mvp=false`，无论平台与版本如何，`software_renderer_cpu_effective` 都为 `false`。
- 当前代码中，legacy override 仅对 `target.os.tag=macos|linux` 生效；对其他 OS tag 会被忽略。

### 2.2 运行时软件路由后端（用于日志/兼容校验）

- Darwin 系列（`macos/ios/tvos/watchos/visionos`）软件路由后端是 `metal`。
- 其他 OS tag 软件路由后端是 `opengl`。
- 这只是“software renderer 的平台路由映射”，不等于 CPU route 已支持该平台。

### 2.3 老设备（旧 macOS/Linux）建议路径

1. 先用显式 target + legacy override 做构建期 bring-up：
   - macOS `10.15`：
     `zig build -Dtarget=aarch64-macos.10.15.0 -Dsoftware-renderer-cpu-mvp=true -Dsoftware-renderer-cpu-allow-legacy-os=true`
   - Linux `4.19`：
     `zig build -Dtarget=x86_64-linux.4.19.0-gnu -Dsoftware-renderer-cpu-mvp=true -Dsoftware-renderer-cpu-allow-legacy-os=true`
2. 运行时先验证基础路径，避免主动触发已知回退门禁：
   - 开启 `software-renderer-experimental=true`
   - 避免 `software-renderer-presenter=legacy-gl`
   - 避免 `-Dsoftware-frame-transport-mode=native`
   - 先不启用 `custom-shader`（确认基础路径后再逐步加回）
3. 预期管理：legacy override 只代表“允许低版本 Linux/macOS 参与实验验证”，不代表稳定性或功能完整性承诺；用于生产时优先使用 macOS `>=11.0.0` / Linux `>=5.0.0` 且关闭 override。
4. 若老设备在 `custom-shader` 场景出现间歇性 capability 不可用，可调重探测节奏：
   - `-Dsoftware-renderer-cpu-shader-reprobe-interval-frames=<u16>` 默认 `120`，`0` 表示禁用周期重探测。
   - 恢复节奏偏慢可下调到 `30~60`；观测噪声偏多可上调到 `180~300`。
   - 该参数只影响观测闭环与恢复节奏，不改变 build/runtime gate 正确性。

## 3. `allow-legacy-os` 的边界

`-Dsoftware-renderer-cpu-allow-legacy-os=true` 只绕过“目标系统最低版本”这一个构建期检查，不会绕过运行时回退门禁。

在当前代码中，它仅在目标 OS 为 `Linux/macOS` 时参与构建 gate；对其他平台（例如 Windows、FreeBSD）不会把 CPU route 构建为 effective。这一点由 `softwareRendererCpuLegacyOverrideSupported` 及对应单测约束。

它不能保证：

- 旧系统上的工具链/依赖一定可用；
- `custom-shader` 场景一定不回退；
- `native` transport 或 `legacy-gl` presenter 场景下仍可强制走 CPU 路由。

在 CI 入口脚本 `.github/scripts/software-renderer-cpu-path-ci.sh` 中，`allow_legacy_os` 默认保守保持为 `false`；即使 target 是 Linux `<5` / macOS `<11` 的旧系统，也只有在显式设置 `SR_CI_FORCE_ALLOW_LEGACY_OS=true` 时才开启 legacy override。

补充：CI 入口的 `SR_CI_OS` 也仅接受 `linux|macos`，与上面的平台边界一致。

## 4. capability `unobserved` 语义

在当前实现中，`unobserved` 的语义是“当前状态尚未执行 capability 观测”，不是“永久不支持”。

可按以下方式理解：

- `observed=false`：
  - 表示当前决策路径没有进行 capability 观测；
  - 诊断字段通常是 `n/a`。
- `observed=true && available=false`：
  - 才表示“已观测且当前不可用”，此时 `reason/hint_*` 具备排障价值。
- `observed=true && available=true`：
  - 表示 capability 已可用。

因此，`capability unobserved` 不应被解释为“后续永远不支持”；只要进入可观测路径（例如相关 shader 路径被触发），状态可能变化。

补充区分两类日志：

- `software renderer cpu shader capability kv ...` 是 capability probe 快照，只会在实际执行过 probe 后输出；当前实现里这条日志固定带 `observed=true`，描述“本次 probe 的可用性、reason 与 hint 来自哪里”。
- `software renderer cpu route is disabled ... shader_capability_reason=...` 是路由决策结果，描述“为什么当前没有走 CPU 路由”。
- `software renderer cpu damage kv ...` 是 damage metadata 退化/采样快照，当前重点看 `rect_count`、`overflow_count` 与 `damage_rect_cap`。
- `software renderer cpu publish retry kv ...` 是发布重试事件快照，重点看 `reason` 与累计 `retry_count`。
- `software renderer cpu publish warning kv ...` 是慢帧告警事件快照，重点看 `last_cpu_frame_ms`、`threshold_ms` 与 `warning_count`。

这两类日志的 `reason` 不完全等价。例如：

- `custom_shaders_capability_unobserved` 在路由日志里会表现为 `capability-unobserved`
- `safe` 模式下只有在 capability 已观测且可用时，`timeout-ms=0` 才会在路由日志里表现为 `timeout-budget-zero`；若 capability 尚未观测或已判定 unavailable，会优先落到对应的 `capability-unobserved` / `unsupported` 原因

## 5. Shader Capability 重探测参数

`-Dsoftware-renderer-cpu-shader-reprobe-interval-frames=<u16>` 用于调节 CPU custom-shader capability 的周期重探测节奏。

重要边界：它只影响 capability 观测闭环与恢复节奏，不参与 CPU route gate 判定，不会改变 `software_renderer_cpu_effective`、运行时回退门禁和渲染正确性。

| 参数 | 默认值 | 边界与语义 | 建议调优方向 |
| --- | --- | --- | --- |
| `-Dsoftware-renderer-cpu-shader-reprobe-interval-frames=<u16>` | `120` | 合法输入 `0..65535`；`0` 禁用周期重探测；仅在 `custom-shader` 激活且 capability `observed=true && available=false`，并且原因属于可重探测策略时按帧计数触发重探测 | 老设备恢复慢时下调到 `30~60`；噪声多或想降低重探测频率时上调到 `180~300`；需要固定观察窗口时可设 `0` |

补充语义：

- 当前可重探测原因包括：`runtime_init_failed`、`pipeline_compile_failed`、`execution_timeout`、`device_lost`。
- `backend_disabled`、`backend_unavailable`、`minimal_runtime_disabled` 不走周期重探测。

CI 对应环境变量：

- `SR_CI_CPU_SHADER_REPROBE_INTERVAL_FRAMES`

## 6. CPU Damage 跟踪参数

当前构建参数还支持 CPU 路径的 damage rect 跟踪策略：

| 参数 | 默认值 | 边界与语义 | 建议 |
| --- | --- | --- | --- |
| `-Dsoftware-renderer-cpu-frame-damage-mode=off|rects` | `rects` | `off` 禁用 damage rect 跟踪；`rects` 跟踪并发布 damage rect metadata | 老设备或排障初期可先保持默认 `rects`，必要时切 `off` 对比 |
| `-Dsoftware-renderer-cpu-damage-rect-cap=<u16>` | `64` | `rects` 模式下 `0` 会自动夹到 `1`；用于限制单帧发布的 damage rect 数量上限 | metadata 噪声高或下游实现较脆弱时可适度下调 |

当前阶段的重要边界：

- 即使启用 `rects`，CPU 路径当前仍以保守的整帧合成为主；
- damage rect 目前主要用于发布 metadata 与下游提示，不等于 CPU 合成已经完全裁剪到 dirty rect；
- `cpu_damage_rect_overflow_count` 非 `0` 表示该帧超出 cap，发布时会退化为更保守的 damage 表达。

CI 对应环境变量：

- `SR_CI_CPU_FRAME_DAMAGE_MODE`
- `SR_CI_CPU_DAMAGE_RECT_CAP`

## 7. CPU 发布告警阈值调优参数

这两个参数用于调节“CPU 路径发布延迟告警”的观测灵敏度，适用于兼容测试和老设备噪声控制。

重要边界：它们只影响告警观测，不参与 CPU route gate 判定，不会改变 `software_renderer_cpu_effective`、运行时回退门禁和渲染正确性。

| 参数 | 默认值 | 边界与语义 | 建议调优方向 |
| --- | --- | --- | --- |
| `-Dsoftware-renderer-cpu-publish-warning-threshold-ms=<u32>` | `40` | 合法输入 `0..4294967295`；仅当 `last_cpu_frame_ms > threshold` 才累计慢帧告警计数（`=` 阈值不计入） | 老设备告警过多时优先上调阈值；建议从 `60` 起步，常见区间 `60~120` |
| `-Dsoftware-renderer-cpu-publish-warning-consecutive-limit=<u8>` | `3` | 合法输入 `0..255`，其中 `0` 会自动夹紧为 `1`；达到连续慢帧上限后才触发一次告警 | 若偶发抖动导致噪声，保持阈值不变，先把连续上限调到 `4~6`；抖动更重可到 `8` |

补充语义（用于理解“为什么不影响路由正确性”）：

- 告警只在 capability ready 时才累计（`observed=true && available=true && minimal-runtime-enabled=true`）。
- 连续慢帧告警是一次性触发；后续需要“出现快帧或 capability 非 ready”才会复位后再次触发。

推荐调优顺序（老设备）：

1. 先调 `threshold-ms`（降低噪声但保留趋势）。
2. 再调 `consecutive-limit`（过滤偶发尖峰）。
3. 每次只改一个参数并保留一轮对照日志，避免把真正退化隐藏掉。

CI 对应环境变量：

- `SR_CI_CPU_PUBLISH_WARNING_THRESHOLD_MS`
- `SR_CI_CPU_PUBLISH_WARNING_CONSECUTIVE_LIMIT`

补充：当前发布侧 diagnostics 主要通过快照暴露，只有少数字段会直接进入 warning 日志。下面按“累计计数”和“最近一次快照值”区分，便于排障时不把两类字段混在一起：

累计计数：
- `publish_retry_count`
- `cpu_publish_retry_invalid_surface_count`
- `cpu_publish_retry_pool_pressure_count`
- `cpu_publish_retry_pool_exhausted_count`
- `cpu_publish_retry_mailbox_backpressure_count`
- `cpu_publish_skipped_no_damage_count`
- `cpu_publish_latency_warning_count`
- `cpu_retired_pool_pressure_warning_count`
- `cpu_frame_pool_exhausted_warning_count`

最近一次快照值：
- `last_cpu_publish_retry_reason`
- `last_cpu_publish_latency_warning_frame_ms`
- `last_cpu_publish_latency_warning_consecutive_count`
- `last_cpu_frame_pool_warning_reason`
- `last_cpu_frame_ms`
- `cpu_damage_rect_count`
- `cpu_damage_rect_overflow_count`

## 8. CI 脚本关键 env 与优先级

### 8.1 入口脚本与必填项

主入口脚本：`.github/scripts/software-renderer-cpu-path-ci.sh`

必填环境变量：

- `SR_CI_OS`：`linux|macos`
- `SR_CI_TRANSPORT_MODE`：`auto|shared|native`

macOS 额外必填：

- `SR_CI_SYSTEM_PATH`（传给 compat-check 的 `--system`）

### 8.1.1 项目仓库专属 `Project CI` 工作流

当前项目仓库的 Windows 验收现在拆成两层：

- `.github/workflows/project-ci.yml`
- `.github/workflows/windows-strict-runtime.yml`

触发方式：

- `Project CI`：默认分支 `push` 自动触发，同时保留 `workflow_dispatch`
- `Windows Strict Runtime Acceptance`：仅 `workflow_dispatch`

其中 `Project CI` 承担 GitHub-hosted 的快速 hosted 验收：

- `Linux Build Windows Native Smoke Artifact`
- `Windows Win32 D3D12 Native Smoke`
- `Windows Win32 D3D12 Core Draw Smoke`
- `Windows Win32 D3D12 Basic Interaction`

`Windows Strict Runtime Acceptance` 承担 self-hosted Windows 严格验收：

- `Build Windows Default Full Runtime`
- `Strict Native Runtime`
- `Strict Core Draw Runtime`
- `Strict Real Interaction`

职责边界：

- `Project CI`：只负责 hosted Windows 的快速 smoke，包括 `native`、`core-draw` 和基础交互；
- `Windows Strict Runtime Acceptance`：只跑在 self-hosted Windows runner 上，验证完整 build graph、默认 runtime 路径以及更严格的真实交互；
- 所有更慢的核心测试、software-renderer 兼容矩阵、macOS 非 UI 验证与完整 UI 验证，继续转移到本地机器或专用 runner 执行。

换句话说：

- hosted 层负责自动快速 smoke；
- self-hosted 层负责手动严格验收；
- 更完整、更慢的跨平台验证默认不再放在线上 hosted runner 自动跑。

### 8.1.2 本地优先的验证边界

当前推荐的验证策略是：

- 线上 hosted：只保留快速 smoke，避免 GitHub-hosted runner 长时间占用与假运行噪音；
- 线上 self-hosted：只保留 Windows 严格验收，在真实桌面会话里执行；
- 本地：承担 `zig build test`、software-renderer 兼容脚本、runtime diagnostics smoke、macOS 非 UI 验证；
- 专用本机 runner：承担完整 macOS UI tests（如果需要）。

因此不应再把项目仓库上的 `Project CI` 结果理解为“完整产品验证”，它只代表：

- Win32/D3D12 hosted smoke 构建与快速交互可跑；
- self-hosted Windows 严格验收是否通过，需要单独看 `Windows Strict Runtime Acceptance`。

### 8.2 常用可选项

- target 与 gate 预期：
  - `SR_CI_TARGET`
  - `SR_CI_EXPECT_CPU_EFFECTIVE`
  - `SR_CI_FORCE_ALLOW_LEGACY_OS`
- shader 相关：
  - `SR_CI_CPU_SHADER_MODE`
  - `SR_CI_CPU_SHADER_BACKEND`
  - `SR_CI_CPU_SHADER_TIMEOUT_MS`
  - `SR_CI_CPU_SHADER_REPROBE_INTERVAL_FRAMES`
  - `SR_CI_CPU_SHADER_ENABLE_MINIMAL_RUNTIME`
  - `SR_CI_INJECT_FAKE_SWIFTSHADER_HINT`
- damage / 发布相关：
  - `SR_CI_CPU_FRAME_DAMAGE_MODE`
  - `SR_CI_CPU_DAMAGE_RECT_CAP`
- CPU 发布告警阈值相关：
  - `SR_CI_CPU_PUBLISH_WARNING_THRESHOLD_MS`
  - `SR_CI_CPU_PUBLISH_WARNING_CONSECUTIVE_LIMIT`
- 运行期 diagnostics 断言：
  - `SR_CI_EXPECT_CPU_DAMAGE_OVERFLOW`
  - `SR_CI_EXPECT_CPU_PUBLISH_RETRY_REASON`
  - `SR_CI_EXPECT_CPU_PUBLISH_WARNING`
  - `SR_CI_EXPECT_CPU_PUBLISH_SUCCESS`
- `primary` 真实 smoke 入口：
  - `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PRIMARY_TEST_FILTER`
  - `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PRIMARY_EXPECT_CPU_DAMAGE_OVERFLOW`
  - `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PRIMARY_EXPECT_CPU_PUBLISH_RETRY_REASON`
  - `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PRIMARY_EXPECT_CPU_PUBLISH_WARNING`
- `secondary` diagnostics smoke 入口：
  - `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_SECONDARY_TEST_FILTER`
  - `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_SECONDARY_EXPECT_CPU_DAMAGE_OVERFLOW`
  - `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_SECONDARY_EXPECT_CPU_PUBLISH_RETRY_REASON`
  - `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_SECONDARY_EXPECT_CPU_PUBLISH_WARNING`
- `published` 真实 smoke 入口：
  - `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PUBLISHED_TEST_FILTER`
  - `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PUBLISHED_EXPECT_CPU_PUBLISH_SUCCESS`
- 兼容保留的 `primary` 旧别名：
  - `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_TEST_FILTER`
  - `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_EXPECT_CPU_DAMAGE_OVERFLOW`
  - `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_EXPECT_CPU_PUBLISH_RETRY_REASON`
  - `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_EXPECT_CPU_PUBLISH_WARNING`
- capability 断言：
  - `SR_CI_EXPECT_CPU_SHADER_CAPABILITY_STATUS`
  - `SR_CI_EXPECT_CPU_SHADER_CAPABILITY_REASON`
  - `SR_CI_EXPECT_CPU_SHADER_CAPABILITY_HINT_SOURCE`
  - `SR_CI_EXPECT_CPU_SHADER_CAPABILITY_HINT_READABLE`
- 其他：
  - `SR_CI_EXPECT_CPU_SHADER_BACKEND`
  - `SR_CI_EXPECT_SOFTWARE_ROUTE_BACKEND`
- `SR_CI_DRY_RUN`

### 8.2.1 本地复现原项目专属 CI 的 macOS 路径

若要本地复现 hosted macOS CI 的非 UI 验证口径，可执行：

```bash
nix --accept-flake-config build -L .#deps
SYSTEM_PATH="$(readlink ./result)"
GHOSTTY_CI_SKIP_UI_TESTS=true zig build test --system "$SYSTEM_PATH"
```

若要在本地继续执行完整 macOS UI tests，则不要设置 `GHOSTTY_CI_SKIP_UI_TESTS`：

```bash
nix --accept-flake-config build -L .#deps
SYSTEM_PATH="$(readlink ./result)"
zig build test --system "$SYSTEM_PATH"
```

### 8.2.2 本地执行项目专属慢测与兼容脚本

当前项目的**默认验收**是：

1. 本地执行 `scripts/local-project-smoke.sh`
2. 线上确认 `Project CI` hosted 层通过
3. 需要切 Windows 默认 runtime 或做发布前收口时，再手动触发一次 `Windows Strict Runtime Acceptance`

若只想走一条默认的本地项目验收，可直接执行：

```bash
scripts/local-project-smoke.sh
```

若只想跑快速项，可执行：

```bash
scripts/local-project-smoke.sh --quick
```

若要把本机可执行的项目 smoke 一次性拉满，可执行：

```bash
scripts/local-project-smoke.sh --full
```

若在 Windows 本机上只想单独跑 Win32 runtime smoke，可执行：

```bash
scripts/local-project-smoke.sh --win32-native
scripts/local-project-smoke.sh --win32-core-draw
scripts/local-project-smoke.sh --win32-basic-interaction
scripts/local-project-smoke.sh --win32-strict
```

**Windows smoke 日志与诊断：**

- 本地执行 `scripts/local-project-smoke.sh` 会把每个 phase 的完整输出记录到 `local-logs/<phase>.log`。
- Win32 smoke/interaction 脚本自身会把关键日志写入仓库根目录的 `ci-logs/`：
  - runtime smoke：`ci-logs/windows-win32-d3d12-smoke-<layer>-native.log`、`ci-logs/windows-win32-d3d12-smoke-<layer>-core-draw.log`
  - 交互 smoke：`ci-logs/windows-win32-d3d12-interaction-basic.log`、`ci-logs/windows-win32-d3d12-interaction-strict.log`
- CI 失败时，优先看 `ci-logs/` 里的原始日志；`local-logs/` 里的包装日志更适合回看“本地脚本到底跑了哪些阶段/参数”。

复现 CI 使用的同一份 `ghostty.exe` 时，可从 GitHub Actions 下载对应 artifact（例如 `windows-win32-d3d12-smoke-exe` 或 `windows-win32-d3d12-strict-exe`），建议解压后放到仓库根目录 `ci-artifacts/` 下（该目录默认不入库），然后用 `GHOSTTY_CI_SMOKE_EXE_PATH` 指向它：

```powershell
$env:GHOSTTY_CI_SMOKE_EXE_PATH = (Resolve-Path .\ci-artifacts\...\ghostty.exe)
$env:GHOSTTY_CI_WIN32_SMOKE_LAYER = "local"
$env:GHOSTTY_CI_WIN32_REQUIRE_WINDOW = "true"
pwsh -NoLogo -NoProfile -File .\.github\scripts\windows-win32-d3d12-smoke.ps1 -Mode native
pwsh -NoLogo -NoProfile -File .\.github\scripts\windows-win32-d3d12-smoke.ps1 -Mode core-draw
pwsh -NoLogo -NoProfile -File .\.github\scripts\windows-win32-d3d12-interaction.ps1 -Mode basic
```

**本地临时产物目录（可安全删除）：**

- `ci-artifacts/`（本地下载的 CI 产物，如 `ghostty.exe`）
- `ci-logs/`（Win32 smoke/interaction 脚本日志；CI 也会上传该目录为 artifact）
- `local-logs/`（`scripts/local-project-smoke.sh` 的分阶段日志）
- `windows-smoke-artifact/`、`windows-strict-artifact/`（CI 工作流的临时 staging 目录）
- `zig/`（可选的本地 Zig 便携安装目录；Windows 脚本会优先尝试 `zig\zig.exe`）

若只想单独跑 software-renderer contracts，可执行：

```bash
scripts/local-project-smoke.sh --software-renderer-contracts
```

脚本跳过语义：

- 无 `nix` 时，会明确跳过 `libghostty` 与 `software-renderer contracts` 的主机运行项；
- 非 Windows 主机上，`--win32-native` / `--win32-core-draw` / `--win32-basic-interaction` / `--win32-strict` 会明确以 `host-not-windows` 跳过；
- `Project CI` 承担 hosted 自动 smoke；`Windows Strict Runtime Acceptance` 承担 self-hosted 手动严格验收；两者都不替代完整本地慢测。

以下验证已从自动 `Project CI` 移出，默认建议在本地执行：

Linux 核心测试：

```bash
nix --accept-flake-config develop -c zig build test -Dskip-macos-ui-tests=true
```

Linux software renderer 兼容/diagnostics：

```bash
SR_CI_OS=linux \
SR_CI_TRANSPORT_MODE=auto \
./.github/scripts/software-renderer-cpu-path-ci.sh
```

macOS software renderer 兼容/diagnostics：

```bash
nix --accept-flake-config build -L .#deps
SYSTEM_PATH="$(readlink ./result)"
SR_CI_OS=macos \
SR_CI_TRANSPORT_MODE=auto \
SR_CI_SYSTEM_PATH="$SYSTEM_PATH" \
./.github/scripts/software-renderer-cpu-path-ci.sh
```

### 8.3 CI 入口脚本 fail-fast 参数校验边界

入口脚本 `.github/scripts/software-renderer-cpu-path-ci.sh` 对以下 `SR_CI_*` 参数做 fail-fast 校验（仅在参数非空时触发）：

| 环境变量 | 合法范围 | 非法输入示例 | 失败行为 |
| --- | --- | --- | --- |
| `SR_CI_FORCE_ALLOW_LEGACY_OS` | `true|false` | `maybe`、`1`、空格字符串 | 立即报错并退出 |
| `SR_CI_CPU_FRAME_DAMAGE_MODE` | `off|rects` | `tiles`、`damage` | 立即报错并退出 |
| `SR_CI_CPU_SHADER_REPROBE_INTERVAL_FRAMES` | `u16`，即 `0..65535` | `-1`、`abc`、`70000` | 立即报错并退出 |
| `SR_CI_CPU_DAMAGE_RECT_CAP` | `u16`，即 `0..65535` | `-1`、`x10`、`70000` | 立即报错并退出 |
| `SR_CI_CPU_PUBLISH_WARNING_THRESHOLD_MS` | `u32`，即 `0..4294967295` | `-1`、`1.5`、`5000000000` | 立即报错并退出 |
| `SR_CI_CPU_PUBLISH_WARNING_CONSECUTIVE_LIMIT` | `u8`，即 `0..255` | `-1`、`abc`、`256` | 立即报错并退出 |
| `SR_CI_EXPECT_CPU_DAMAGE_OVERFLOW` | 十进制非负整数文本（运行期 `u64` 断言，`0` 表示断言“没有 overflow 日志”） | `-1`、`1.5`、`one`、`18446744073709551616` | 立即报错并退出 |
| `SR_CI_EXPECT_CPU_PUBLISH_RETRY_REASON` | `invalid_surface`、`pool_retired_pressure`、`frame_pool_exhausted`、`mailbox_backpressure` | `pressure`、`retry` | 立即报错并退出 |
| `SR_CI_EXPECT_CPU_PUBLISH_WARNING` | `true|false` | `maybe`、`1` | 立即报错并退出 |
| `SR_CI_EXPECT_CPU_PUBLISH_SUCCESS` | `true|false` | `maybe`、`1` | 立即报错并退出 |
| `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PRIMARY_EXPECT_CPU_DAMAGE_OVERFLOW` | 十进制非负整数文本（运行期 `u64` primary smoke 断言） | `-1`、`one`、`18446744073709551616` | 立即报错并退出 |
| `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PRIMARY_EXPECT_CPU_PUBLISH_RETRY_REASON` | `invalid_surface`、`pool_retired_pressure`、`frame_pool_exhausted`、`mailbox_backpressure` | `pressure`、`retry` | 立即报错并退出 |
| `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PRIMARY_EXPECT_CPU_PUBLISH_WARNING` | `true|false` | `maybe`、`1` | 立即报错并退出 |
| `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_SECONDARY_EXPECT_CPU_DAMAGE_OVERFLOW` | 十进制非负整数文本（运行期 `u64` secondary smoke 断言） | `-1`、`one`、`18446744073709551616` | 立即报错并退出 |
| `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_SECONDARY_EXPECT_CPU_PUBLISH_RETRY_REASON` | `invalid_surface`、`pool_retired_pressure`、`frame_pool_exhausted`、`mailbox_backpressure` | `pressure`、`retry` | 立即报错并退出 |
| `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_SECONDARY_EXPECT_CPU_PUBLISH_WARNING` | `true|false` | `maybe`、`1` | 立即报错并退出 |
| `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PUBLISHED_EXPECT_CPU_PUBLISH_SUCCESS` | `true|false` | `maybe`、`1` | 立即报错并退出 |

统一失败语义：

- 布尔/枚举型参数只接受脚本白名单字面值；数值型参数仅接受十进制非负整数文本。出现非法字面值、非数字或越界值时，入口脚本输出 `invalid SR_CI_...` 错误并以 `exit 2` 结束。
- 失败发生在调用 `./.github/scripts/software-renderer-compat-check.sh` 之前，属于“启动前失败”，不会进入 compat-check 执行阶段。
- 当参数合法且被设置时，入口脚本会同时透传 `--cpu-*` 与对应 `--expect-cpu-*` 断言参数到 compat-check，确保 `options.zig` 快照值和期望一致（防止“参数传入但未生效”）。
- 运行期 diagnostics 断言类参数不会参与 `options.zig` 校验，而是直接透传到 compat-check，对 `zig build test` 输出中的结构化日志做运行期匹配。
- `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PRIMARY_*` / `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_SECONDARY_*` / `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PUBLISHED_*` 分别属于 `primary` / `secondary` / `published` 三次 smoke 调用专用参数；若设置任一槽位的 smoke 断言而未设置对应 `*_TEST_FILTER`，入口脚本会直接失败，避免“看起来启用了 smoke 实际没有跑”。
- 旧单槽位 `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_*` 变量仍作为 `primary` 兼容别名保留；若旧别名与新 `PRIMARY_*` 同时设置且值不一致，入口脚本会直接失败。
- 对会被构建侧归一化的值，入口脚本会先对齐“生效值”再组装 `--expect-*`：
  - `SR_CI_CPU_FRAME_DAMAGE_MODE=rects` 且 `SR_CI_CPU_DAMAGE_RECT_CAP=0` 时，期望值归一化为 `1`；
  - `SR_CI_CPU_PUBLISH_WARNING_CONSECUTIVE_LIMIT=0` 时，期望值归一化为 `1`。

### 8.4 优先级（从高到低）

1. Workflow 注入的 `SR_CI_*` 显式值（最高优先级）。
2. `software-renderer-cpu-path-ci.sh` 的推导/兜底：
   - `allow_legacy_os` 默认保守保持 `false`；只有显式设置 `SR_CI_FORCE_ALLOW_LEGACY_OS=true|false` 时才覆盖；
   - route backend 默认 Linux=`opengl`、macOS=`metal`；`SR_CI_EXPECT_SOFTWARE_ROUTE_BACKEND` 仅做一致性断言，不用于覆盖：值非法时 `exit 2`，与当前 `SR_CI_OS` 的期望后端不一致时 `exit 1`；
   - `cpu_shader_reprobe_interval_frames` 在 CI 入口日志默认展示 `120`，显式设置 `SR_CI_CPU_SHADER_REPROBE_INTERVAL_FRAMES` 时透传到 compat-check；
   - `cpu_damage_rect_cap` 与 `cpu_publish_warning_consecutive_limit` 的 `--expect-*` 会按构建侧生效值归一化；
   - `SR_CI_EXPECT_CPU_DAMAGE_OVERFLOW`、`SR_CI_EXPECT_CPU_PUBLISH_RETRY_REASON`、`SR_CI_EXPECT_CPU_PUBLISH_WARNING` 直接透传为运行期日志断言；
   - 当设置 `SR_CI_CPU_SHADER_MODE` 且未设置 backend 时，会推导 `expect_cpu_shader_backend=vulkan_swiftshader`。
3. 入口脚本组装 `software-renderer-compat-check.sh` 的 CLI 参数（仅非空值透传）。
4. `software-renderer-compat-check.sh` 组装 `zig build -D...`（未传值时回落到构建默认值）。
5. 运行时 Vulkan loader hint 环境变量优先级（仅 `vulkan_swiftshader` 路径相关）：
   - `VK_DRIVER_FILES` > `VK_ICD_FILENAMES` > `VK_ADD_DRIVER_FILES`

`software-renderer-compat-check.sh` 额外支持 4 个运行期 diagnostics 断言参数，适合在已知测试场景下校验结构化日志：

- `--expect-cpu-damage-overflow <u64>`
- `--expect-cpu-publish-retry-reason <invalid_surface|pool_retired_pressure|frame_pool_exhausted|mailbox_backpressure>`
- `--expect-cpu-publish-warning <true|false>`
- `--expect-cpu-publish-success <true|false>`

对应的 `cpu-path-ci` 环境变量分别是：

- `SR_CI_EXPECT_CPU_DAMAGE_OVERFLOW`
- `SR_CI_EXPECT_CPU_PUBLISH_RETRY_REASON`
- `SR_CI_EXPECT_CPU_PUBLISH_WARNING`
- `SR_CI_EXPECT_CPU_PUBLISH_SUCCESS`

默认 CI 还会额外跑三条 runtime diagnostics smoke：

- `primary` 通过 `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PRIMARY_TEST_FILTER` 把 compat-check 限定到 `drawFrame software cpu smoke retries exhausted pool and clears platform transient state`；
- `primary` 直接走 `drawFrame -> publishCpuSoftwareFrame -> retry(frame_pool_exhausted)` 的真实链路，并在下一帧切回平台路由时验证瞬态状态被清理；
- `primary` 默认只断言 `frame_pool_exhausted` retry reason，不强制要求 damage overflow / publish warning 日志；
- `secondary` 通过 `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_SECONDARY_TEST_FILTER` 跑 `cpu route diagnostics kv helpers emit structured logs`；
- `secondary` 专门覆盖 `damage overflow`、`publish retry`、`publish warning` 三类结构化 diagnostics 日志断言；
- `published` 通过 `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PUBLISHED_TEST_FILTER` 跑 `drawFrame software cpu smoke published frame clears pending state and finalizes unloading background`；
- `published` 覆盖真实 `drawFrame -> publishCpuSoftwareFrame -> published` 成功链路，默认通过 `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PUBLISHED_EXPECT_CPU_PUBLISH_SUCCESS=true` 断言成功发布 kv 日志存在；
- `published` 的 success kv 断言会额外检查 `publish_pending=false`，且 `last_cpu_frame_ms` 可解析；
- 旧单槽位 `SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_*` 仍映射到 `primary`，只用于兼容已有本地调用；
- 三条 smoke 都直接消费真实 Zig 测试输出，不依赖 fake log 夹具；
- fake selftest 仍然保留，职责是验证脚本 parser/断言契约，而不是替代真实日志链路。

这些断言都基于 `zig build test` 输出中的结构化 `kv` 日志：

- `--expect-cpu-damage-overflow 0` 是一个特殊语义：断言运行期没有出现 overflow 日志；非 `0` 时要求日志存在且 `overflow_count` 命中指定值。
- 缺日志：`failure-class=assertion runtime-log-missing`
- 有日志但值不匹配：`failure-class=assertion runtime-log-mismatch`

fail-fast 一致性说明：`SR_CI_EXPECT_SOFTWARE_ROUTE_BACKEND` 的断言发生在 route backend 最终取值与 compat-check 参数组装之前；断言失败会立即终止，后续优先级链不再继续。

补充：当 `SR_CI_INJECT_FAKE_SWIFTSHADER_HINT=true` 时，compat-check 会临时设置 `VK_DRIVER_FILES` 指向伪造清单，并在退出时恢复原值。

## 9. 排障建议流程

1. 先确认构建 gate：查看 `cpu-route-target-gate` 与 `options-snapshot` 日志。
2. 若运行时未走 CPU 路由：查看 `software renderer cpu route is disabled reason=...`。
3. 若问题与 `custom-shader` 相关：查看 `software renderer cpu shader capability kv ...` 日志中的 `status/reason/hint_*`。
4. 若日志里已走 CPU 路由但结果异常：继续看发布侧 diagnostics，重点区分：
   - `publish_retry_*` 增长：更像发布链路/池压力问题；
   - `cpu_publish_latency_warning_count` 增长：更像性能退化；
   - `cpu_damage_rect_overflow_count` 增长：更像 damage metadata 退化为保守路径；
   - `last_cpu_frame_ms` 持续偏高：优先按老设备性能问题处理。
5. 若 CI 失败：优先按 `failure-class` 定位。常见类别除了 `config-mismatch`、`runtime-log-mismatch`、`options-zig-missing`、`xcode-build-chain` 外，还包括：
   - `runtime-log-missing`
   - `toolchain-linker-pic`
   - `logic-or-runtime`
