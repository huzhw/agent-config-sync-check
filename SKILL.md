---
name: agent-config-sync-check
description: 四端同步守卫：定期检查 Claude Code / DSH / Codex / ZCode 四个工具端与自研 skill 仓库（F:\idea-workspase-skills）之间的 Junction 技能链接、全局规则硬链接组（CLAUDE.md/AGENTS.md）、仓库根 README 技能列表是否完好，防止同步被破坏；机械性问题可自动修复；并承载新 skill 上架七步流程与 git 提交推送规范。触发词：检查同步、同步检查、配置同步、四端同步、跨端同步、检查链接、链接检查、上架技能、新增技能、新加技能、sync-check、agent-config-sync-check。
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

## 检查项（8 条）

1. **技能链接覆盖**：仓库里每个含 `SKILL.md` 的目录（期望集合从 frontmatter `name` 自动推导，新增技能自动纳入）× 四端，`skills\<name>` 必须存在、是 Junction、目标等于仓库规范路径
2. **死链**：四端 `skills\` 下所有指向本仓库的 Junction，目标必须还存在（仓库删了技能但链接没拆 = 死链）
3. **硬链接组**：规则文件 4 个路径都存在、`LinkType=HardLink`、同组（`(Get-Item).Target` 互含对方路径）、非空
4. **frontmatter 健全**：`name`、`description` 必填；`name` 全小写 kebab-case（`^[a-z0-9]+(-[a-z0-9]+)*$`）
5. **README 技能列表**：仓库根 `README.md` 顶部区块（`<!-- sync-check:skills BEGIN/END -->` 标记）与期望技能集合一致
6. **红线**：`coding-rules` 是独立 git 仓库、非技能，四端 `skills\` 下不得出现指向它的链接
7. **JUNCTION说明.md**：每个技能目录（家族子技能除外，其说明在主目录）必须有；文档须覆盖全部启用端的 `\skills\<name>` 路径；路径上下文里的技能名不得是**陈旧名**（改名后没跟上）或**污染串**（重复前缀叠加，如 `deepseek-harness-deepseek-harness-…`，多来自粗暴的字符串替换）
8. **README 相关技能互链**：每个技能 README（git-commit 等"仓库根 ≠ 技能目录"的按 `repoRoots` 映射定位）的「相关技能」列表必须含全部其他技能与 `coding-rules` 的 GitHub 链接，互链不断档

`.zcode` 的中转链接（目标不在本仓库的 Junction）：只验"中转目标还存在"，上游删了就报死链，**只报告不自动修**。

## 修复规则（-Fix 模式）

**自动修**（机械性问题）：
- 漏挂 → `New-Item -ItemType Junction` 补建，链接名 = frontmatter `name`
- 死链 / 多余仓库链接 / 红线链接 → **非递归**拆链接点（`[IO.Directory]::Delete($path, $false)`）
- README 区块与实际不符 → 按 BEGIN/END 标记重新生成区块，标记外内容不动
- JUNCTION说明.md 缺失 → 按 `templates\JUNCTION-template.md` 生成（`{NAME}` 占位替换）
- JUNCTION说明.md 缺端 → 定位表格行 / `findstr` 行 / `rd` 行三处，按端序补齐缺的行（已有行的端不动，特殊说明段保留）
- JUNCTION说明.md 陈旧名 → 幂等替换：`(?:前缀)+旧名` 折叠 + 负向断言锚定（旧名是新名后缀时，**禁止**裸 `String.Replace`——会自匹配叠加成污染串，这坑已踩过）
- JUNCTION说明.md 污染串 → 判定依据 = 路径 token ∉ 已知技能名/仓库子目录集合；修复 = 模板重建（原版从 git HEAD 可查，无需备份）
- README 互链缺 → 「相关技能」段末条后补缺的链接行（名称/仓库/中文说明全部来自 config：`githubRepos` + `relatedSkills`）

**只报告不自动修**：
- 硬链接组断裂（某端可能已分叉，并错丢内容，人工定哪份为准）
- frontmatter 缺失/格式错（改文件是内容决策）
- 中转死链（可能上游临时改名）
- 技能改名导致的"1 缺 1 多"（报告给旧名→新名映射建议；确要自动修时先建新后拆旧）
- README 文件整份缺失（内容是写作决策，按七段模板由 AI 起草）

## 🔴 红线（脚本与人工都必须遵守）

1. 拆 Junction **必须非递归**——递归删除会穿透链接删掉仓库真文件
2. 硬链接组断裂**不自动合并**
3. 同步问题**只改仓库源文件 + 链接层**，禁止直接改消费端目录里的文件内容（Junction 会穿透写回仓库）
4. 期望集合以**仓库 SKILL.md frontmatter** 为唯一真相，不改 frontmatter 之前不许"让现实迁就清单"

## 配置

`sync-config.json`：四端路径与开关（`skillsEnabled`）、硬链接组路径、README 标记、红线目录、计划任务名。以后新增第 5 端：`agents` 数组加一条即可；某端暂时不想管：把它的 `skillsEnabled` 改 `false`。

## 新增 skill 上架流程（用户说"上架技能 / 新增技能"触发）

环境常量：仓库 `F:\idea-workspase-skills`，GitHub 账号 `huzhw`，远端 `https://github.com/huzhw/<skill-name>.git`，运行时 Windows PowerShell 5.1（无 pwsh 7）。

1. **建目录 + SKILL.md**：frontmatter 必含 `name`（全小写 kebab-case，**= 四端链接名**）和 `description`（含触发词，这是技能被召回的依据）；目录名 = `name`
2. **补齐标配四件**（对齐现有 skill 结构）：
   - `README.md` 七段模板：`# 名称 — 一句话`、定位、`## 相关技能`（列表见下节）、`## 解决了什么问题`、`## 使用`、`## 文件结构`、`## 安装`（`git clone https://github.com/huzhw/<name>.git ~/.claude/skills/<name>`）、`## 许可`（MIT）
   - `JUNCTION说明.md`：四端指向关系表、双向同步说明、检查命令、`rd 不加 /s` 回滚警告
   - `.gitignore`：`logs/`、`*.log` 等运行产物
   - `scripts\`（如需脚本）：PS 5.1 兼容、源码纯 ASCII（中文文案放 config 运行时读或用 Unicode 码点，无 BOM 下 5.1 按 ANSI 解析中文必炸）
3. **四端建 Junction**（5.1 无 `New-Item -ItemType Junction`，必须用 mklink）：
   ```bat
   cmd /c "mklink /J C:\Users\Administrator\.claude\skills\<name> F:\idea-workspase-skills\<name>"
   cmd /c "mklink /J C:\Users\Administrator\.dsh\skills\<name>    F:\idea-workspase-skills\<name>"
   cmd /c "mklink /J C:\Users\Administrator\.codex\skills\<name>  F:\idea-workspase-skills\<name>"
   cmd /c "mklink /J C:\Users\Administrator\.zcode\skills\<name>  F:\idea-workspase-skills\<name>"
   ```
4. **跑上架验证**：`scripts\sync-check.ps1 -Fix` → 仓库根 README 区块自动补齐新技能 + 四端覆盖全绿
5. **旧 README 回填**：所有其他 skill 的 README「相关技能」列表补上新技能条目（保持互链完整）
6. **git 提交**（规范见下节）：`git init -b master` → 逐文件 add（SKILL.md、README.md、JUNCTION说明.md、.gitignore、配置、scripts）→ commit
7. **建远端并推送**：`gh repo create huzhw/<name> --public --description "<一句话>"` → `git remote add origin https://github.com/huzhw/<name>.git` → `git push -u origin master`

## 提交推送规范（本仓库体系专用）

- **仓库形态**：根目录不是 git 仓库，**每个 skill 目录各自独立 git 仓库**（多数 master，deepseek-harness-settings-curator 是 main）；改了哪个目录就在哪个仓库提交，不碰别的仓库
- **遵循 git-commit skill 全部规范**：先看再动（status/diff）、逐文件 add（禁止 `git add .`）、中文标题一行说原因 ≤50 字、原子提交（原因不同就拆）、提交前过目 diff 确认无敏感信息
- **每条 commit 末尾必须带签名段**：
  ```
  🐧 Linus 创造了 Git，但没教你怎么用。这份 skill 补上。
  ```
- **推送核对**：push 后 `git status --short --branch` 确认与远端一致；`gh` 已登录 `huzhw`（账号显示别名 13146248578，`gh api user --jq .login` 验真）；远端可见性用 PUBLIC
- **不入库**：`*.bak-*` 备份、`logs/`、`.idea/`、`.code-check.db` 运行数据
- git.exe / gh 在沙箱下可能被拒，拒绝时按平台规则提权重试同一条命令

## README 维护规范

- **仓库根** `README.md`：顶部技能列表区块（`<!-- sync-check:skills BEGIN/END -->`）由 `sync-check.ps1` 自动生成，**人手不改标记内内容**；区块外内容（架构红线、目录地图）人工维护
- **各 skill 自身** `README.md`：固定七段模板（见上架流程第 2 步），面向 GitHub 读者
- **互链**：每个 README 的「相关技能」列表是全量技能的 GitHub 链接（不含自己）；新增技能时回填所有旧 README（上架流程第 5 步）

  当前标准列表：
  ```markdown
  - [git-commit](https://github.com/huzhw/git-commit-skill)：Git 提交规范
  - [daily-record-gitlab-md](https://github.com/huzhw/daily-record-gitlab-md-skill)：日报记录
  - [daily-merge-gitlab-excel](https://github.com/huzhw/daily-merge-gitlab-excel-skill)：日报合并
  - [claude-code-token-3000](https://github.com/huzhw/claude-code-token-3000-skill)：Claude Code API Token 切换
  - [code-check](https://github.com/huzhw/code-check-skill)：增量代码隐患检查
  - [deepseek-harness-settings-curator](https://github.com/huzhw/deepseek-harness-settings-curator)：DSH 模型配置梳理
  - [reread-rules](https://github.com/huzhw/reread-rules-skill)：重载 CLAUDE.md / AGENTS.md 规则
  - [coding-rules](https://github.com/huzhw/coding-rules)：编码规则库（独立仓库，非 skill）
  ```
