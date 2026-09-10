---
name: agent-config-sync-check
description: 四端同步守卫：定期检查 Claude Code / DSH / Codex / ZCode 四个工具端与自研 skill 仓库（F:\idea-workspase-skills）之间的 Junction 技能链接、全局规则硬链接组（CLAUDE.md/AGENTS.md）、仓库根 README 技能列表、ssh-mcp 配置同步是否完好，防止同步被破坏；机械性问题可自动修复；并承载新 skill 上架七步流程与 git 提交推送规范。触发词：检查同步、同步检查、配置同步、四端同步、跨端同步、检查链接、链接检查、上架技能、新增技能、新加技能、sync-check、agent-config-sync-check、ssh-mcp、ssh配置同步、ssh配置。
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

- **硬链接组重建模式**（`-FixHardlink`，哈希守卫）：四端规则文件 SHA256 **全部一致**才重建硬链接组（编辑器"替换写"拆链后一键修复）；任何一个哈希不等 = 可能分叉，**拒绝执行**维持只报告，人工定哪份为准

  ```powershell
  pwsh -NoProfile -File "F:\idea-workspase-skills\agent-config-sync-check\scripts\sync-check.ps1" -FixHardlink
  ```

- **看最近一次检查**：读 `agent-config-sync-check\logs\sync-check.log` 最新记录（手动运行 skill 时写入；默认不装定时任务，需要时按 README「每日定时（可选）」建）
- 退出码：`0` = 全绿；`1` = 仍存在问题

## 检查项（13 条）

1. **技能链接覆盖**：仓库里每个含 `SKILL.md` 的目录（期望集合从 frontmatter `name` 自动推导，新增技能自动纳入）× 四端，`skills\<name>` 必须存在、是 Junction、目标等于仓库规范路径
2. **死链**：四端 `skills\` 下所有指向本仓库的 Junction，目标必须还存在（仓库删了技能但链接没拆 = 死链）
3. **硬链接组**：规则文件 4 个路径都存在、`LinkType=HardLink`、同组（`(Get-Item).Target` 互含对方路径）、非空
4. **frontmatter 健全**：`name`、`description` 必填；`name` 全小写 kebab-case（`^[a-z0-9]+(-[a-z0-9]+)*$`）
5. **README 技能列表**：仓库根 `README.md` 顶部区块（`<!-- sync-check:skills BEGIN/END -->` 标记）与期望技能集合一致
6. **红线**：`coding-rules` 是独立 git 仓库、非技能，四端 `skills\` 下不得出现指向它的链接
7. **JUNCTION说明.md**：每个技能目录（家族子技能除外，其说明在主目录）必须有；文档须覆盖全部启用端的 `\skills\<name>` 路径；路径上下文里的技能名不得是**陈旧名**（改名后没跟上）或**污染串**（重复前缀叠加，如 `deepseek-harness-deepseek-harness-…`，多来自粗暴的字符串替换）
8. **README 相关技能互链**：每个技能 README（git-commit 等"仓库根 ≠ 技能目录"的按 `repoRoots` 映射定位）的「相关技能」列表必须含全部其他技能与 `coding-rules` 的 GitHub 链接，互链不断档
9. **ssh-mcp 配置 Junction**：`~\{claude,dsh,codex,zcode}\ssh-mcp` 四端必须是 Junction 且指向仓库 `agent-config-sync-check\assets\ssh-mcp`（数据源 toml = 唯一真相，内网档案丢失只报告不生成）；**junction 自身 ACL 也要收紧**（继承自各端 home 的 Everyone/杂 SID 会让 ssh-mcp 拒启动，dsh 端曾中招）
10. **ssh-mcp 各端注册（launcher 形态）**：四端注册统一为 `node <home>\ssh-mcp\launcher.js --config=<home>\ssh-mcp\ssh-mcp-config.toml`（Claude=`.claude.json` 的 `mcpServers.ssh`、DSH=web patch 的 `mcp-ssh` insert 块、Codex=`config.toml` 的 `[mcp_servers.ssh]`、ZCode=`.zcode\cli\config.json` 的 `mcp.servers.ssh`），**注册块内零密码**；ssh 密码只存 `assets\ssh-mcp\ssh-passwords.env` 一份（launcher 运行时注入，gitignore 排除）；检查含**密码对账**（passwords.env 键必须覆盖 toml 全部 profile，缺键报错，防"新增服务器忘配密码"静默故障）；旧形态（直接 ssh-mcp + env 内联密码）报 `SshMcpLegacyRegistration`，-Fix 自动迁移
11. **通用 MCP 注册同步（mcpSync）**：`sync-config.json` 的 `mcpSync.servers` 登记要同步的 MCP（期望 command+args + DSH/Codex/ZCode 端注册位置；Claude 端 `.claude.json` 为源，新增 MCP 照样先在 Claude 配好再抄进来）；比对是**解析级**的（node YAML / python tomllib / JSON 解析后比 command+args，不挑物理块结构——共享 insert 块里的条目也能识别）；缺失报 `McpMissing`、漂移报 `McpDrift`，-Fix 自动补齐/重写；**env 不跨端**（带敏感值的 MCP 学 ssh 用 launcher 单文件模式）；http 型 MCP（如 idea）暂不支持，不登记即不同步
12. **防护 hooks 注册同步（hooksSync）**：源 = `~\.claude\settings.json` hooks 段（hooks 只手工维护这一处）；ZCode 端落点 = `~\.zcode\cli\config.json` 的 `hooks.events`（**实测 ZCode 只执行这里的 hooks，且必须 `hooks.enabled: true`**；`~\.zcode\settings.json` 不被读取，`~\.claude\settings.json` 被其 legacy 加载器列出但 `enabled` 恒 false 不执行）；转换规则在 `scripts\hooks-convert.js`：`SessionEnd` 事件丢弃（ZCode 不支持）、matcher 去掉 `MultiEdit`（ZCode 无此工具，`ApplyPatch` 走 `Write|Edit` 别名）、`rtk hook claude` 排除（Claude 生态专属）、`--source=claude` 改写 `--source=zcode`、shell 命令串拆成 `process` 型（`.sh` → `bash <绝对路径>`、`.cjs/.js` → `node <路径> <参数>`，timeout 秒→毫秒）；缺失报 `HookMissing`、漂移报 `HookDrift`、runner 没开报 `HooksRunnerDisabled`，-Fix 经 `scripts\register-zcode-hooks.js` 幂等合并（按 event+matcher 分组、args 含脚本路径=同源条目原位替换）；Codex 端只**报告**（`CodexHookMissing`，config.toml 每条 hook 带 trusted_hash，自动改写会破坏信任需手动重新接受），且排除 Codex 适配版脚本与走 notify 配置的 tokentracker
13. **规则手工副本（rulesHardlink.manualCopies）**：跨卷副本（如 `coding-rules\CLAUDE.md` 在 F 盘）无法进硬链接组，靠复制跟随组——登记进 config 后纳入检查：副本**剥掉自身开头 `<!-- ... -->` 头注释**（副本身份说明，按设计就不同）后正文须与组正文逐字一致；不一致报 `RulesCopyDrift`（-Fix 用组正文重写副本、保留其头注释），副本文件丢失报 `RulesCopyMissing`（重建需先写身份头注释，属内容决策，**不自动修**）。2026-09-05 实战：组内更新 rustup 后此副本漏同步，全靠人眼发现，故立此检查

`.zcode` 的中转链接（目标不在本仓库的 Junction）：只验"中转目标还存在"，上游删了就报死链，**只报告不自动修**。

## 修复规则（-Fix 模式）

**自动修**（机械性问题）：
- 漏挂 → `cmd /c "mklink /J <端skills路径>\<name> <仓库skill目录>"` 补建（PS 5.1 无 `New-Item -ItemType Junction`），链接名 = frontmatter `name`
- 死链 / 多余仓库链接 / 红线链接 → **非递归**拆链接点（`[IO.Directory]::Delete($path, $false)`）
- README 区块与实际不符 → 按 BEGIN/END 标记重新生成区块，标记外内容不动
- JUNCTION说明.md 缺失 → 按 `templates\JUNCTION-template.md` 生成（`{NAME}` 占位替换）
- JUNCTION说明.md 缺端 → 定位表格行 / `findstr` 行 / `rd` 行三处，按端序补齐缺的行（已有行的端不动，特殊说明段保留）
- JUNCTION说明.md 陈旧名 → 幂等替换：`(?:前缀)+旧名` 折叠 + 负向断言锚定（旧名是新名后缀时，**禁止**裸 `String.Replace`——会自匹配叠加成污染串，这坑已踩过）
- JUNCTION说明.md 污染串 → 判定依据 = 路径 token ∉ 已知技能名/仓库子目录集合；修复 = 模板重建（原版从 git HEAD 可查，无需备份）
- README 互链缺 → 「相关技能」段末条后补缺的链接行（名称/仓库/中文说明全部来自 config：`githubRepos` + `relatedSkills`）
- ssh-mcp Junction 缺失/目标错/断链 → mklink /J 重建（指向 `assets\ssh-mcp`）
- ssh-mcp 注册缺失/旧形态（DSH patch / Codex toml / ZCode json 直接挂密码或非 launcher 形态）→ 备份 → 删旧块 → 追加 launcher 形态块 → node YAML / python tomllib / JSON 解析校验 → 失败自动回滚备份
- Claude 端 ssh 注册非 launcher 形态 → `scripts\ssh-claude-register.js` 整体重写（自动备份）
- 通用 MCP（mcpSync.servers）缺失/漂移 → 备份 → 删旧块（DSH 子项级手术，共享块/独立块通吃）→ 追加规范块 → 解析复验 → 失败回滚
- ZCode hooks（hooksSync）缺失/漂移/runner 未开 → `scripts\register-zcode-hooks.js` 幂等合并写入 `~\.zcode\cli\config.json`（强制 `hooks.enabled: true`，按 event+matcher 分组、args 含脚本路径视为同源原位替换，自动备份 + 写后 JSON 复验）；spec 用 hooks-convert.js 的原始 JSON 输出直传，**禁止经 PS 对象 ConvertTo-Json 往返**（PS 5.1 会把反斜杠二次转义毁掉 Windows 路径）
- 规则手工副本漂移（`RulesCopyDrift`）→ 用组正文重写副本文件，**保留副本自身开头 `<!-- ... -->` 头注释**（副本身份说明不动，只同步正文）

**只报告不自动修**：
- 硬链接组断裂（某端可能已分叉，并错丢内容，人工定哪份为准；唯一安全出口 = `-FixHardlink`：四端哈希全等即证明未分叉，机械重建）
- 规则手工副本文件整份丢失（`RulesCopyMissing`，重建要先写副本自身的身份头注释，内容决策）
- frontmatter 缺失/格式错（改文件是内容决策）
- 中转死链（可能上游临时改名）
- 技能改名导致的"1 缺 1 多"（报告给旧名→新名映射建议；确要自动修时先建新后拆旧）
- README 文件整份缺失（内容是写作决策，按七段模板由 AI 起草）
- ssh-mcp 数据源 toml 丢失（内网机器档案，无法自动生成）
- DSH/Codex 注册存在但 `--config` 路径漂移（改写已有块有风险，人工核）
- 各端注册目标文件本身缺失（`.claude.json` 等不属于本技能管辖）
- Codex hooks 缺失（`CodexHookMissing`，trusted_hash 机制，自动改写会破坏信任）

## 🔴 红线（脚本与人工都必须遵守）

1. 拆 Junction **必须非递归**——递归删除会穿透链接删掉仓库真文件
2. 硬链接组断裂**不自动合并**——唯一例外 `-FixHardlink`：先四端 SHA256 对账，**全部一致**（可证未分叉）才删副本重建；任何哈希不等立即拒绝
3. 同步问题**只改仓库源文件 + 链接层**，禁止直接改消费端目录里的文件内容（Junction 会穿透写回仓库）
4. 期望集合以**仓库 SKILL.md frontmatter** 为唯一真相，不改 frontmatter 之前不许"让现实迁就清单"
5. ssh-mcp v2.4 有 **ACL 自检**：`assets\ssh-mcp` 目录及 toml 必须只剩 owner/SYSTEM/Administrators 可写，否则拒绝启动；三个坑：icacls 多账户合写一条命令会静默 `0 files` 必须逐条；`S-1-4-*` 虚拟 SID icacls 删不动要用 .NET `PurgeAccessRules`；先 `/inheritance:d` 断继承才能删继承 ACE

## 配置

`sync-config.json`：四端路径与开关（`skillsEnabled`）、硬链接组路径与手工副本清单（`rulesHardlink.paths` / `rulesHardlink.manualCopies`）、README 标记、红线目录、计划任务名、`sshMcpConfig`（ssh-mcp 配置同步：数据源目录、Junction 端清单、各端注册方式与密码源）、`mcpSync`（通用 MCP 注册同步：servers 数组登记期望形态与端位置）、`hooksSync`（防护 hooks 注册同步：源 settings.json、ZCode 端落点与转换/排除/改写规则、Codex 端只报告）。以后新增第 5 端：`agents` 数组加一条即可；某端暂时不想管：把它的 `skillsEnabled` 改 `false`；新增跨卷规则副本：`manualCopies` 加一条（`stripHeaderComment: true` = 副本开头头注释不参与比对）。

四端防护钩子（hooks/规则/插件）的能力对照与配置位置见本目录 `HOOKS说明.md`；脚本事实源与分发关系见 `coding-rules\SYNC说明.md` 第三节。

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
  - [agent-config-sync-check](https://github.com/huzhw/agent-config-sync-check)：四端同步守卫：链接/硬链接/README 同步检查与修复
  - [git-commit](https://github.com/huzhw/git-commit-skill)：Git 提交规范
  - [daily-record-gitlab-md](https://github.com/huzhw/daily-record-gitlab-md-skill)：日报记录
  - [daily-merge-gitlab-excel](https://github.com/huzhw/daily-merge-gitlab-excel-skill)：日报合并
  - [code-check](https://github.com/huzhw/code-check-skill)：增量代码隐患检查
  - [deepseek-harness-settings-curator](https://github.com/huzhw/deepseek-harness-settings-curator)：DSH 模型配置梳理
  - [reread-rules](https://github.com/huzhw/reread-rules-skill)：重载 CLAUDE.md / AGENTS.md 规则
  - [coding-rules](https://github.com/huzhw/coding-rules)：编码规则库（独立仓库，非 skill）
  - [service-manager](https://github.com/huzhw/service-manager)：服务管理器（关联仓库，非 skill）
  ```
