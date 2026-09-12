# agent-config-sync-check — 四端同步守卫

定期检查 Claude Code / DSH / Codex / ZCode 四个工具端与自研 skill 仓库（`F:\idea-workspase-skills`）之间的同步完整性：Junction 技能链接、全局规则硬链接组、README 技能列表、ssh-mcp 配置同步——防止同步被破坏了没人知道。

## 相关技能

- [git-commit](https://github.com/huzhw/git-commit-skill)：Git 提交规范
- [daily-record-gitlab-md](https://github.com/huzhw/daily-record-gitlab-md-skill)：日报记录
- [daily-merge-gitlab-excel](https://github.com/huzhw/daily-merge-gitlab-excel-skill)：日报合并
- [code-check](https://github.com/huzhw/code-check-skill)：增量代码隐患检查
- [deepseek-harness-settings-curator](https://github.com/huzhw/deepseek-harness-settings-curator)：DSH 模型配置梳理
- [deepseek-harness-plugin-doctor](https://github.com/huzhw/deepseek-harness-plugin-doctor)：DSH 插件与升级体检医生
- [reread-rules](https://github.com/huzhw/reread-rules-skill)：重载 CLAUDE.md / AGENTS.md 规则
- [coding-rules](https://github.com/huzhw/coding-rules)：编码规则库（独立仓库，非 skill）
- [service-manager](https://github.com/huzhw/service-manager)：服务管理器（关联仓库，非 skill）
- [daily-report-panel](https://github.com/huzhw/daily-report-panel)：日报管家（关联仓库，非 skill，自动合并/导出/发件）

---

## 解决了什么问题

**四端 Junction 架构下，同步坏了没有任何报警。** 技能目录删了链接悬空、新增 skill 忘挂某端、规则文件被编辑器"另存"成独立副本（硬链接组断裂，改一端其他三端不跟）、README 技能列表过期——这些全是静默故障，等到用的时候才发现技能不见了。这个技能把四端状态一遍扫完，机械性问题自动修，分叉问题报给人。

## 检查项（14 条）

| # | 检查项 | 内容 |
|---|--------|------|
| 1 | 链接覆盖 | 仓库每个含 `SKILL.md` 的目录（frontmatter `name` 自动推导）× 四端，`skills\<name>` 必须是 Junction 且目标正确 |
| 2 | 死链 | 四端指向本仓库的 Junction，目标必须还存在（删技能没拆链 = 死链） |
| 3 | 硬链接组 | `~\.claude\CLAUDE.md` ⇄ `~\.dsh\AGENTS.md` ⇄ `~\.codex\AGENTS.md` ⇄ `~\.zcode\AGENTS.md` 同组且非空 |
| 4 | frontmatter | `name`/`description` 必填，`name` 全小写 kebab-case |
| 5 | README 区块 | 仓库根 README 顶部技能列表（`BEGIN/END` 标记内）与实际技能集合一致 |
| 6 | 红线 | `coding-rules` 是独立 git 仓库，任何端不得挂它 |
| 7 | JUNCTION说明.md | 每技能必有（家族子技能除外），四端路径齐全，无陈旧名/污染串；缺失或污染自动重建，缺端自动补行 |
| 8 | 相关技能互链 | 每技能 README「相关技能」列表含全部其他技能的 GitHub 链接，缺的自动补行 |
| 9 | ssh-mcp 配置 Junction | `~\{claude,dsh,codex,zcode}\ssh-mcp` 四端 Junction → 仓库 `assets\ssh-mcp`（数据源 toml 唯一真相，内网档案丢失只报告）；junction 自身 ACL 须收紧（继承的 Everyone 会令 ssh-mcp 拒启动） |
| 10 | ssh-mcp 各端注册 | 四端统一 launcher 形态：`node <home>\ssh-mcp\launcher.js --config=<本端toml>`（Claude `.claude.json` / DSH web patch / Codex `config.toml` / ZCode `.zcode\cli\config.json`），注册块零密码；密码只存 `assets\ssh-mcp\ssh-passwords.env` 一份并做对账（键须覆盖 toml 全部 profile，防新增服务器忘配密码）；旧形态/缺失 -Fix 自动迁移（备份→校验→失败回滚） |
| 11 | 通用 MCP 同步 | `sync-config.json` 的 `mcpSync.servers` 登记的 MCP（codegraph/dbx/chrome-devtools…）各端 command+args 解析级比对（node YAML / python tomllib / JSON，共享 insert 块也能识别）；支持 `perEndCommand`/`perEndArgsPrepend`/`perEndArgs` 按端覆盖（比对与修复都按生效值）；Claude 端 `.claude.json` 只读检查不自动写；缺失/漂移 -Fix 自动补齐重写；env 不跨端，带敏感值的学 ssh 用 launcher；http 型（idea）暂不支持 |
| 12 | 防护 hooks 同步 | 源 = `~\.claude\settings.json` hooks 段；ZCode 落点 `~\.zcode\cli\config.json` 的 `hooks.events`（runner 须 `enabled: true`），经 `hooks-convert.js` 转换（丢 SessionEnd、去 MultiEdit、`--source=zcode` 改写、shell 串拆 process 型）；缺失/漂移 -Fix 幂等合并；Codex 端只报告（trusted_hash 机制不可自动改写） |
| 13 | 规则手工副本 | 跨卷副本（`coding-rules\CLAUDE.md`，F 盘进不了硬链接组）登记在 `rulesHardlink.manualCopies`：剥掉副本自身开头 `<!-- -->` 头注释后正文须与组正文一致；漂移 -Fix 自动重写（保留其头注释），副本整份丢失不自动修（要先写身份头注释） |
| 14 | chrome-devtools 目录唯一 | Chromium 同一 profile 目录只容一个活动实例，两端 `--userDataDir` 相同 = 谁后启动浏览器谁秒死（Target closed）。按登记端（CC/Codex/ZCode；**DSH 端已弃用浏览器 MCP 改用 dsh-builtin-browser 插件**）解析各端 chrome-devtools 的 userDataDir，重复报 `McpUserDataDirDuplicate`（只报告，目录分配看 `sync-config.json` 的 `perEndArgs`：各端 `User Data MCP-<端名>`）；无 userDataDir 报 WARN |

`.zcode` 里的中转链接（→ `.claude` 官方技能、→ `.codex\.system` 系统技能）只验"上游还在"，上游删了报死链，**只报告不自动修**。

## 使用

**对话触发（推荐）**：说「检查同步 / 四端同步 / 检查链接」，AI 跑检查并把报告转成中文。

**手动跑：**

```bash
# 只读检查
powershell -NoProfile -File "F:\idea-workspase-skills\agent-config-sync-check\scripts\sync-check.ps1"

# 自动修复机械性问题（补挂链接、非递归拆死链、重生成 README 区块）
powershell -NoProfile -File "F:\idea-workspase-skills\agent-config-sync-check\scripts\sync-check.ps1" -Fix

# 硬链接组重建（哈希守卫：四端 SHA256 全部一致才重建，分叉即拒绝）
powershell -NoProfile -File "F:\idea-workspase-skills\agent-config-sync-check\scripts\sync-check.ps1" -FixHardlink
```

退出码：`0` 全绿，`1` 有问题。日志追加在 `logs\sync-check.log`。

**修复边界**：硬链接组断裂（除非 `-FixHardlink` 且哈希全等）、frontmatter 问题、中转死链、规则副本整份丢失**只报告不自动修**——内容可能已分叉，并错了丢东西，人工定哪份为准。

## 文件结构

```
agent-config-sync-check/
├── SKILL.md              ← 技能指令（触发词、检查流程、修复规则、红线）
├── README.md             ← 本文档
├── JUNCTION说明.md        ← 四端 junction 指向关系与回滚方法
├── HOOKS说明.md           ← 四端防护能力对照（hooks/规则/插件，能力对齐实现各异）
├── .gitignore            ← 排除 logs/、assets/ssh-mcp/ 下 toml+密码文件（内网档案不入公开仓）
├── sync-config.json      ← 四端路径与开关、硬链接组路径、README 标记、sshMcpConfig
├── assets/
│   └── ssh-mcp/          ← ssh-mcp 数据源（四端 Junction 指向这里；目录与各端 junction ACL 均已收紧）
│       ├── ssh-mcp-config.toml   ← 服务器档案（内网拓扑，gitignore）
│       ├── ssh-passwords.env     ← 密码单文件（全体系唯一密码副本，gitignore）
│       └── launcher.js           ← 注入器：读密码文件→注入 env→拉起 ssh-mcp（入 git，零密码）
├── logs/                 ← 检查日志（不入 git）
└── scripts/
    ├── sync-check.ps1    ← 检查/修复核心脚本（PS 5.1 兼容，源码纯 ASCII 零密码）
    ├── ssh-claude-register.js← -Fix 专用：Claude 端 ssh 注册重写为 launcher 形态
    └── register-zcode.js     ← -Fix 专用：ZCode 端 mcp.servers 注册写入（JSON 保序，只动目标子树）
```

## 每日定时（可选）

```bat
schtasks /Create /TN "agent-config-sync-check" /TR "powershell -NoProfile -File F:\idea-workspase-skills\agent-config-sync-check\scripts\sync-check.ps1 -Quiet" /SC DAILY /ST 09:00 /F
```

每天 09:00 自动只读检查，结果写日志，问题留给人工决定。

## 新增 skill 时

仓库建目录 + `SKILL.md`（`name` = 四端链接名），四端各建一条 Junction，然后跑一次本技能——README 区块自动补齐、四端覆盖自动验证。配置里加第 5 端只需在 `sync-config.json` 的 `agents` 数组加一行。

## 安装

```bash
git clone https://github.com/huzhw/agent-config-sync-check.git ~/.claude/skills/agent-config-sync-check
```

## 许可

MIT
