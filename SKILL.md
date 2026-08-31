---
name: agent-config-sync-check
description: 四端同步守卫：定期检查 Claude Code / DSH / Codex / ZCode 四个工具端与自研 skill 仓库（F:\idea-workspase-skills）之间的 Junction 技能链接、全局规则硬链接组（CLAUDE.md/AGENTS.md）、仓库根 README 技能列表是否完好，防止同步被破坏；机械性问题可自动修复。触发词：检查同步、同步检查、配置同步、四端同步、跨端同步、检查链接、链接检查、sync-check、agent-config-sync-check。
author: 胡志伟
motto: "同步不怕断，怕断了没人知道——定期查，机械修，分叉留给人工。"
---

# agent-config-sync-check —— 四端同步守卫

## 这是什么

本仓库（`F:\idea-workspase-skills`）是自研技能的唯一数据源，四个工具端通过 Windows Junction 链接消费它：

| 端 | 家目录 | 技能目录 | 规则文件 |
|---|---|---|---|
| Claude Code | `~\.claude` | `skills\`（Junction→仓库） | `CLAUDE.md`（硬链接组） |
| DSH | `~\.dsh` | `skills\`（Junction→仓库） | `AGENTS.md`（硬链接组） |
| Codex | `~\.codex` | `skills\`（Junction→仓库） | `AGENTS.md`（硬链接组） |
| ZCode | `~\.zcode` | `skills\`（Junction→仓库 + 中转链接） | `AGENTS.md`（硬链接组） |

全局规则是**一个硬链接组**（同一份文件 4 个名字）。`.zcode` 里还有指向 `.claude`、`.codex\.system` 的**中转链接**。

## 使用方法

用户说"检查同步 / 四端同步 / 检查链接"等触发词时，执行检查：

```powershell
pwsh -NoProfile -File "F:\idea-workspase-skills\agent-config-sync-check\scripts\sync-check.ps1"
```

- **只读检查**：上面命令原样跑，输出问题清单，不动任何东西
- **修复模式**（问题确认为机械性、用户同意修时加 `-Fix`）：

  ```powershell
  pwsh -NoProfile -File "F:\idea-workspase-skills\agent-config-sync-check\scripts\sync-check.ps1" -Fix
  ```

- **看最近一次定时检查**：读 `agent-config-sync-check\logs\` 下最新日志（每日 09:00 计划任务自动跑）
- 退出码：`0` = 全绿；`1` = 仍存在问题

## 检查项（6 条）

1. **技能链接覆盖**：仓库里每个含 `SKILL.md` 的目录（期望集合从 frontmatter `name` 自动推导，新增技能自动纳入）× 四端，`skills\<name>` 必须存在、是 Junction、目标等于仓库规范路径
2. **死链**：四端 `skills\` 下所有指向本仓库的 Junction，目标必须还存在（仓库删了技能但链接没拆 = 死链）
3. **硬链接组**：规则文件 4 个路径都存在、`LinkType=HardLink`、同组（fsutil hardlink list 互相包含）、非空
4. **frontmatter 健全**：`name`、`description` 必填；`name` 全小写 kebab-case（`^[a-z0-9]+(-[a-z0-9]+)*$`）
5. **README 技能列表**：仓库根 `README.md` 顶部区块（`<!-- sync-check:skills BEGIN/END -->` 标记）与期望技能集合一致
6. **红线**：`coding-rules` 是独立 git 仓库、非技能，四端 `skills\` 下不得出现指向它的链接

`.zcode` 的中转链接（目标不在本仓库的 Junction）：只验"中转目标还存在"，上游删了就报死链，**只报告不自动修**。

## 修复规则（-Fix 模式）

**自动修**（机械性问题）：
- 漏挂 → `New-Item -ItemType Junction` 补建，链接名 = frontmatter `name`
- 死链 / 多余仓库链接 / 红线链接 → **非递归**拆链接点（`[IO.Directory]::Delete($path, $false)`）
- README 区块与实际不符 → 按 BEGIN/END 标记重新生成区块，标记外内容不动

**只报告不自动修**：
- 硬链接组断裂（某端可能已分叉，并错丢内容，人工定哪份为准）
- frontmatter 缺失/格式错（改文件是内容决策）
- 中转死链（可能上游临时改名）
- 技能改名导致的"1 缺 1 多"（报告给旧名→新名映射建议；确要自动修时先建新后拆旧）

## 🔴 红线（脚本与人工都必须遵守）

1. 拆 Junction **必须非递归**——递归删除会穿透链接删掉仓库真文件
2. 硬链接组断裂**不自动合并**
3. 同步问题**只改仓库源文件 + 链接层**，禁止直接改消费端目录里的文件内容（Junction 会穿透写回仓库）
4. 期望集合以**仓库 SKILL.md frontmatter** 为唯一真相，不改 frontmatter 之前不许"让现实迁就清单"

## 配置

`sync-config.json`：四端路径与开关（`skillsEnabled`）、硬链接组路径、README 标记、红线目录、计划任务名。以后新增第 5 端：`agents` 数组加一条即可；某端暂时不想管：把它的 `skillsEnabled` 改 `false`。
