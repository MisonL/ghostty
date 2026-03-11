#!/usr/bin/env bun
/**
 * 生成“最终成品待办清单”（自动扫描 TODO/FIXME/HACK/XXX + not implemented 等）。
 *
 * 约束：
 * - 只扫描本仓库一方代码（排除 vendor/pkg 等第三方目录）。
 * - 仅把注释语义的 XXX 计入（避免把 mktemp 的 XXXXXX 之类误识别为待办）。
 * - 文档分为“手工里程碑”与“自动扫描结果”两段，脚本只会覆盖自动段落。
 */

import { spawnSync } from "bun";
import { existsSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";

type Match = {
  category: string;
  file: string;
  line: number;
  col: number;
  text: string;
};

function runOrThrow(cmd: string[], cwd: string): string {
  const res = spawnSync({
    cmd,
    cwd,
    stdout: "pipe",
    stderr: "pipe",
  });

  const stdout = new TextDecoder().decode(res.stdout);
  const stderr = new TextDecoder().decode(res.stderr);
  if (res.exitCode !== 0) {
    const msg = [
      `命令执行失败：${cmd.join(" ")}`,
      `exitCode=${res.exitCode}`,
      stderr.trim() ? `stderr:\n${stderr.trim()}` : "",
      stdout.trim() ? `stdout:\n${stdout.trim()}` : "",
    ]
      .filter(Boolean)
      .join("\n\n");
    throw new Error(msg);
  }

  return stdout;
}

function parseRgLines(raw: string, category: string): Match[] {
  const out: Match[] = [];
  for (const line of raw.split("\n")) {
    if (!line) continue;
    // rg --line-number --column --no-heading => file:line:col:text
    const i1 = line.indexOf(":");
    if (i1 < 0) continue;
    const i2 = line.indexOf(":", i1 + 1);
    if (i2 < 0) continue;
    const i3 = line.indexOf(":", i2 + 1);
    if (i3 < 0) continue;

    const file = line.slice(0, i1);
    const lineStr = line.slice(i1 + 1, i2);
    const colStr = line.slice(i2 + 1, i3);
    const text = line.slice(i3 + 1).trimEnd();

    const ln = Number.parseInt(lineStr, 10);
    const col = Number.parseInt(colStr, 10);
    if (!Number.isFinite(ln) || !Number.isFinite(col)) continue;

    out.push({
      category,
      file,
      line: ln,
      col,
      text: text.trim(),
    });
  }
  return out;
}

function filePrefix2(path: string): string {
  const parts = path.split("/");
  if (parts.length <= 1) return parts[0] ?? path;
  return `${parts[0]}/${parts[1]}`;
}

function formatTable(matches: Match[]): string {
  const lines: string[] = [];
  lines.push("| ID | 类别 | 位置 | 摘要 |");
  lines.push("| --- | --- | --- | --- |");
  for (let i = 0; i < matches.length; i++) {
    const m = matches[i]!;
    const id = `FP-AUTO-${String(i + 1).padStart(4, "0")}`;
    const loc = `${m.file}:${m.line}:${m.col}`;
    const summary = m.text.replaceAll("|", "\\|");
    lines.push(`| ${id} | ${m.category} | ${loc} | ${summary} |`);
  }
  return lines.join("\n");
}

function replaceAutoSection(existing: string, generated: string): string {
  const start = "<!-- AUTO-GENERATED:START -->";
  const end = "<!-- AUTO-GENERATED:END -->";
  const iStart = existing.indexOf(start);
  const iEnd = existing.indexOf(end);
  if (iStart >= 0 && iEnd >= 0 && iEnd > iStart) {
    return (
      existing.slice(0, iStart + start.length) +
      "\n\n" +
      generated.trim() +
      "\n\n" +
      existing.slice(iEnd)
    );
  }

  // 没有 marker 就整体覆盖为新模板，避免把旧格式继续传播。
  return templateDoc(generated);
}

function templateDoc(generated: string): string {
  return `# 最终成品待办清单

本文件用于收口“最终成品”所有待开发/待修复事项。分为两部分：
- **手工里程碑**：稳定维护，方便老板直接看进度与优先级。
- **自动扫描结果**：由脚本生成，覆盖本仓库一方代码中的 TODO/FIXME/HACK/XXX（注释语义）与 not implemented 等残留。

## 手工里程碑（请勿自动覆盖）

### P0（必须先变成稳定可用）
- Windows：ConPTY 读线程退出/断管错误码处理必须不崩溃（涉及 \`src/termio/Exec.zig\`）。
- Windows：D3D12 present 帧 pacing 不能每帧 \`waitForGpuIdle\` 强同步（涉及 \`src/renderer/D3D12.zig\`）。
- libghostty：\`include/ghostty.h\` 与 \`include/ghostty/vt.h\` 必须可同时 include（\`GHOSTTY_SUCCESS\` 冲突）。
- 终端协议：OSC 动态颜色 13-19/113-119 与 special colors（OSC 4/5/104/105）必须可用且有行为级测试。
- GTK：最小 Preferences/Settings 窗口与入口（配置概览 + 诊断 + 打开/重载 + 常用项写回）。
- macOS：Preferences 从“配置查看器”推进到“可搜索/更多可写项”，并修复菜单快捷键一致性问题。

### P1（用户可见功能补齐）
- Kitty 图像动画 action、tmux control mode 的 windows action、XTWINOPS 标题栈、charset slot \`-./\` 等（详见自动扫描结果与协议盘点）。

<!-- AUTO-GENERATED:START -->

${generated.trim()}

<!-- AUTO-GENERATED:END -->
`;
}

function main() {
  const root = runOrThrow(["git", "rev-parse", "--show-toplevel"], process.cwd()).trim();
  const commit = runOrThrow(["git", "rev-parse", "--short", "HEAD"], root).trim();
  const now = new Date();
  const nowIso = now.toISOString();

  const roots = [
    "src",
    "macos",
    "include",
    "docs",
    "scripts",
    ".github",
    "example",
    "dist",
    "flatpak",
    "snap",
  ];

  const excludeGlobs = [
    "!vendor/**",
    "!pkg/**",
    "!.zig-cache/**",
    "!zig-out/**",
    "!.build/**",
    "!_ci_artifacts/**",
    "!ci-artifacts/**",
    "!local-logs/**",
    "!.tmp/**",
    "!.github/workflows.disabled/**",
  ];

  const rgBase = [
    "rg",
    "--no-heading",
    "--line-number",
    "--column",
    "--color",
    "never",
    "-P",
    ...excludeGlobs.flatMap((g) => ["--glob", g]),
  ];

  const matches: Match[] = [];

  // 1) 注释语义的 TODO/FIXME/HACK/XXX
  // 只匹配注释（//, #, /*, *）里的关键字，避免把普通字符串里的 XXX 计入。
  {
    const pattern =
      String.raw`(?:^|\s)(?:(?://+)|#|/\*+|\*)\s*(TODO|FIXME|HACK|XXX)\b`;
    const raw = runOrThrow([...rgBase, pattern, ...roots], root);
    matches.push(...parseRgLines(raw, "comment-marker"));
  }

  // 2) 运行期/编译期未实现（panic/compileError）
  {
    const pattern = String.raw`@panic\(".*?not implemented.*?"\)`;
    const raw = runOrThrow([...rgBase, pattern, "src"], root);
    matches.push(...parseRgLines(raw, "panic-not-implemented"));
  }
  {
    const pattern = String.raw`@compileError\("unimplemented"\)`;
    const raw = runOrThrow([...rgBase, pattern, "src"], root);
    matches.push(...parseRgLines(raw, "compileError-unimplemented"));
  }

  // 3) 文本级 not implemented（日志/分支说明等）
  {
    const pattern = String.raw`\bnot implemented\b`;
    const raw = runOrThrow([...rgBase, pattern, "src"], root);
    matches.push(...parseRgLines(raw, "text-not-implemented"));
  }

  // 排序：先文件，再行列，最后类别
  matches.sort((a, b) => {
    if (a.file !== b.file) return a.file.localeCompare(b.file);
    if (a.line !== b.line) return a.line - b.line;
    if (a.col !== b.col) return a.col - b.col;
    return a.category.localeCompare(b.category);
  });

  const byCategory = new Map<string, number>();
  const byPrefix = new Map<string, number>();
  for (const m of matches) {
    byCategory.set(m.category, (byCategory.get(m.category) ?? 0) + 1);
    const p = filePrefix2(m.file);
    byPrefix.set(p, (byPrefix.get(p) ?? 0) + 1);
  }

  const topPrefixes = [...byPrefix.entries()].sort((a, b) => b[1] - a[1]).slice(0, 20);

  const generated = [
    `## 自动扫描结果（由脚本生成）`,
    ``,
    `生成时间：\`${nowIso}\``,
    `基于提交：\`${commit}\``,
    ``,
    `### 统计`,
    ``,
    `- 总条目：\`${matches.length}\``,
    ...[...byCategory.entries()]
      .sort((a, b) => b[1] - a[1])
      .map(([k, v]) => `- ${k}：\`${v}\``),
    ``,
    `### Top 路径前缀（前 20）`,
    ``,
    ...topPrefixes.map(([p, v]) => `- \`${p}\`：\`${v}\``),
    ``,
    `### 明细`,
    ``,
    formatTable(matches),
  ].join("\n");

  const outPath = join(root, "docs", "final-product-backlog.md");
  const existing = existsSync(outPath) ? readFileSync(outPath, "utf8") : "";
  const next = existing ? replaceAutoSection(existing, generated) : templateDoc(generated);
  writeFileSync(outPath, next, "utf8");

  // 方便终端直接看到结果
  // eslint-disable-next-line no-console
  console.log(`已生成 ${outPath}（共 ${matches.length} 条）`);
}

main();

