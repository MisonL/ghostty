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

在 CI 入口脚本 `.github/scripts/software-renderer-cpu-path-ci.sh` 中，`allow_legacy_os` 会按 target 主版本自动推导（Linux `<5`、macOS `<11`），并可被 `SR_CI_FORCE_ALLOW_LEGACY_OS` 强制覆盖。

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

## 6. CPU 发布告警阈值调优参数

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

## 7. CI 脚本关键 env 与优先级

### 7.1 入口脚本与必填项

主入口脚本：`.github/scripts/software-renderer-cpu-path-ci.sh`

必填环境变量：

- `SR_CI_OS`：`linux|macos`
- `SR_CI_TRANSPORT_MODE`：`auto|shared|native`

macOS 额外必填：

- `SR_CI_SYSTEM_PATH`（传给 compat-check 的 `--system`）

### 7.2 常用可选项

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
- CPU 发布告警阈值相关：
  - `SR_CI_CPU_PUBLISH_WARNING_THRESHOLD_MS`
  - `SR_CI_CPU_PUBLISH_WARNING_CONSECUTIVE_LIMIT`
- capability 断言：
  - `SR_CI_EXPECT_CPU_SHADER_CAPABILITY_STATUS`
  - `SR_CI_EXPECT_CPU_SHADER_CAPABILITY_REASON`
  - `SR_CI_EXPECT_CPU_SHADER_CAPABILITY_HINT_SOURCE`
  - `SR_CI_EXPECT_CPU_SHADER_CAPABILITY_HINT_READABLE`

### 7.3 CI 入口脚本 fail-fast 参数校验边界

入口脚本 `.github/scripts/software-renderer-cpu-path-ci.sh` 对以下 `SR_CI_*` 参数做 fail-fast 校验（仅在参数非空时触发）：

| 环境变量 | 合法范围 | 非法输入示例 | 失败行为 |
| --- | --- | --- | --- |
| `SR_CI_CPU_SHADER_REPROBE_INTERVAL_FRAMES` | `u16`，即 `0..65535` | `-1`、`abc`、`70000` | 立即报错并退出 |
| `SR_CI_CPU_DAMAGE_RECT_CAP` | `u16`，即 `0..65535` | `-1`、`x10`、`70000` | 立即报错并退出 |
| `SR_CI_CPU_PUBLISH_WARNING_THRESHOLD_MS` | `u32`，即 `0..4294967295` | `-1`、`1.5`、`5000000000` | 立即报错并退出 |
| `SR_CI_CPU_PUBLISH_WARNING_CONSECUTIVE_LIMIT` | `u8`，即 `0..255` | `-1`、`abc`、`256` | 立即报错并退出 |

统一失败语义：

- 仅接受十进制非负整数文本；出现非数字或越界值时，入口脚本输出 `invalid SR_CI_...` 错误并以 `exit 2` 结束。
- 失败发生在调用 `./.github/scripts/software-renderer-compat-check.sh` 之前，属于“启动前失败”，不会进入 compat-check 执行阶段。
- 当参数合法且被设置时，入口脚本会同时透传 `--cpu-*` 与对应 `--expect-cpu-*` 断言参数到 compat-check，确保 `options.zig` 快照值和期望一致（防止“参数传入但未生效”）。

### 7.4 优先级（从高到低）

1. Workflow 注入的 `SR_CI_*` 显式值（最高优先级）。
2. `software-renderer-cpu-path-ci.sh` 的推导/兜底：
   - `allow_legacy_os` 自动推导后可被 `SR_CI_FORCE_ALLOW_LEGACY_OS` 覆盖；
   - route backend 默认 Linux=`opengl`、macOS=`metal`，可被 `SR_CI_EXPECT_SOFTWARE_ROUTE_BACKEND` 覆盖；
   - `cpu_shader_reprobe_interval_frames` 在 CI 入口日志默认展示 `120`，显式设置 `SR_CI_CPU_SHADER_REPROBE_INTERVAL_FRAMES` 时透传到 compat-check；
   - 当设置 `SR_CI_CPU_SHADER_MODE` 且未设置 backend 时，会推导 `expect_cpu_shader_backend=vulkan_swiftshader`。
3. 入口脚本组装 `software-renderer-compat-check.sh` 的 CLI 参数（仅非空值透传）。
4. `software-renderer-compat-check.sh` 组装 `zig build -D...`（未传值时回落到构建默认值）。
5. 运行时 Vulkan loader hint 环境变量优先级（仅 `vulkan_swiftshader` 路径相关）：
   - `VK_DRIVER_FILES` > `VK_ICD_FILENAMES` > `VK_ADD_DRIVER_FILES`

补充：当 `SR_CI_INJECT_FAKE_SWIFTSHADER_HINT=true` 时，compat-check 会临时设置 `VK_DRIVER_FILES` 指向伪造清单，并在退出时恢复原值。

## 8. 排障建议流程

1. 先确认构建 gate：查看 `cpu-route-target-gate` 与 `options-snapshot` 日志。
2. 若运行时未走 CPU 路由：查看 `software renderer cpu route is disabled reason=...`。
3. 若问题与 `custom-shader` 相关：查看 `software renderer cpu shader capability kv ...` 日志中的 `status/reason/hint_*`。
4. 若 CI 失败：优先按 `failure-class` 定位（常见如 `config-mismatch`、`runtime-log-mismatch`、`options-zig-missing`、`xcode-build-chain`）。
