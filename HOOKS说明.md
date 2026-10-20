# 六端防护能力对照（HOOKS 说明）

> 六端工具（Claude Code / DeepSeek Harness / Codex / Zcode / Qoder CN / CodeBuddy）的防护钩子**能力对齐、实现方式各异**：
> Claude 走 settings.json 挂 shell 脚本；DeepSeek Harness 走声明式规则 + 插件（无用户 hooks 机制）；Codex 走 config.toml 的 hooks 特性；Zcode 走 `~\.zcode\cli\config.json` 的 hooks 段（process 型，注册从 Claude settings.json 自动同步）；Qoder 走 `~\.qoder-cn\settings.json` 的 hooks 组（与 Claude Code 同构，注册从 Claude settings.json 自动同步；2026-10-11 国际版卸载，落点由 `~\.qoder` 换 `~\.qoder-cn`）；CodeBuddy 走 `~\.codebuddy\settings.json` 的 hooks 组（Claude Code 同构生态，注册同样自动同步）。
> 脚本分发细节（事实源、复制关系）见 `coding-rules\SYNC说明.md` 第三节。
>
> **Qoder 已接入 hooksSync**：落点 `~\.qoder-cn\settings.json` 的 `hooks` 组（SessionEnd/Stop/MultiEdit 全支持、timeout 秒制；2026-10-11 起，旧 `~\.qoder` 为国际版遗留不再注册），复用 `hooks-convert.js` 转换（`--source=qoder` 改写、排除 tokentracker/notify.cjs），-Fix 经 `register-qoder-hooks.js` 幂等 upsert（按脚本路径原位替换、清理同脚本历史重复条目，自动备份+写后复验；用户自加 hooks 不动）。
>
> **CodeBuddy 已接入 hooksSync**（2026-10-10）：落点 `~\.codebuddy\settings.json` 的 `hooks` 组（Claude Code 同构），复用 Qoder 的转换管线（process 型、去 MultiEdit、`--source=codebuddy` 改写、排除 tokentracker/notify.cjs——它有自带的 `--source=codebuddy` 采集注册），-Fix 经 `register-codebuddy-hooks.js` 幂等 upsert（按脚本路径原位替换、清理同脚本历史重复条目，自动备份+写后复验；用户自加 hooks 不动）。

## 能力对照表

| 防护能力 | Claude Code | DeepSeek Harness | Codex | Zcode | Qoder | CodeBuddy |
|---|---|---|---|---|---|---|
| 危险 git 拦截（push --force、reset --hard、add . 等） | `block-dangerous-git.sh`（deny，正则） | 内置基线 ask（push --force / reset --hard）+ `rules.yaml` 6 条 deny（clean / branch -D / checkout . / restore . / add 全量） | `block-dangerous-git.sh`（同脚本） | 同 Claude | 同脚本（hooksSync 自动同步） | 同 Claude（hooksSync 自动同步） |
| 危险 bash 拦截（rd /s、format、diskpart、rm -rf /、curl\|sh 等） | `guard-dangerous-bash.sh` | `rules.yaml` Windows 段 8 条 deny + 内置基线（mkfs/dd/chmod 777/fork bomb/curl\|sh/敏感路径 ask） | 同脚本（Codex 格式适配） | 同 Claude | 同脚本 | 同 Claude（hooksSync 自动同步） |
| 记忆守卫（memory/ 分层 + 命名校验 + 台账） | `guard-memory-write.sh` + `guard-memory-approved.sh` | 无 memory 机制（文件沙箱 + AGENTS.md 约定兜底） | `guard-memory-write-codex.sh` + `guard-memory-approved-codex.sh`（apply_patch 适配版） | 同 Claude | 同 Claude（直引 `~\.claude\hooks\` 脚本） | 同 Claude（hooksSync 自动同步，直引 `~\.claude\hooks\` 脚本） |
| 下载位置提醒 | `warn-download-location.sh` | 无（AGENTS.md 文字约定） | 无 | 同 Claude | 同 Claude | 同 Claude |
| 任务完成通知 | tokentracker（Stop/SessionEnd） | `dsh-notification` 插件（桌面通知） | tokentracker（`notify` 配置） | tokentracker（Stop，`--source=zcode`） | 无（hooksSync 排除 tokentracker，停止无效采集） | tokentracker（SessionEnd，`--source=codebuddy`，自带注册） |
| 提示注入/密钥泄露检测 | 无 | `dsh-defend` 插件（消息/工具参数/工具结果三道闸） | 无 | 无 | 无 | 无 |
| 审批 AI 预审 | 无（人工审批） | `dsh-auto-review` 插件（第二模型裁决，fail-closed） | 无 | 无 | 无 | 无 |
| 文件沙箱 | 无内置 | workspace-write 预设（工作区外写入走审批） | 内置 sandbox/approval | 内置 | 内置（终端沙箱 + 权限升级询问；另有 Full Access 模式可绕过） | 内置（工具权限审批询问） |
| 网络白名单 | 无内置 | `rules.yaml` network 规则 + 本地策略代理 | 无内置 | 无内置 | 无（官方"白名单"指企业放行 Qoder 域名，非 Agent 侧管控） | 无内置 |

## 各端配置位置

| 端 | 机制 | 配置文件 | 脚本/规则位置 |
|---|---|---|---|
| Claude Code | settings.json hooks 段 | `~\.claude\settings.json` | `~\.claude\hooks\*.sh`（事实源副本） |
| Zcode | config.json hooks 段（`hooks.events` + 必须 `hooks.enabled: true`；**只认这一处**——`~\.zcode\settings.json` 不被读取，`~\.claude\settings.json` 被其 legacy 加载器列出但恒不执行） | `~\.zcode\cli\config.json` | process 型直接引用 `~\.claude\hooks\*.sh` 同一路径；注册由 agent-config-sync-check 的 hooksSync 从 Claude settings.json 自动同步（SessionEnd 丢弃、matcher 去 MultiEdit、`--source=zcode` 改写） |
| Codex | config.toml `[[hooks.*]]` + `[features] hooks = true` | `~\.codex\config.toml`（每条 hook 有 trusted_hash，命令变更需重新信任；hooksSync 只报告不自动写） | Bash 拦截引 `~\.claude\hooks\`；记忆守卫用 `~\.codex\hooks\*codex.sh` 适配版 |
| DeepSeek Harness | 声明式规则（无 hooks） | `~\.dsh\rules.yaml`（用户级，热重载）+ `~\.dsh\profiles\web\cordis.patch.yml` 的 `- id: permission` → `defaultPreset`（2026-09-23 起；旧的 `~\.dsh\settings.yaml` 已退役改名 `.imported`） | 内置基线：`~\.dsh\profiles\web\node_modules\dsh-permission-rules\rules\builtin-high-risk.yaml` |
| Qoder | settings.json hooks 段（与 Claude 同构：SessionEnd/Stop/MultiEdit 全支持、timeout 秒制） | `~\.qoder-cn\settings.json`（2026-10-11 换端；`~\.qoder` 为国际版遗留） | 直引 `~\.claude\hooks\*.sh` 同一路径；注册由 agent-config-sync-check 的 hooksSync 从 Claude settings.json 自动同步（排除 tokentracker/notify.cjs、`--source=qoder` 改写；解释器为带引号的 Git Bash 绝对路径） |
| CodeBuddy | settings.json hooks 段（Claude Code 同构生态、timeout 秒制） | `~\.codebuddy\settings.json` | 直引 `~\.claude\hooks\*.sh` 同一路径（命令串端，解释器为带引号的 Git Bash 绝对路径）；注册由 agent-config-sync-check 的 hooksSync 从 Claude settings.json 自动同步（排除 tokentracker/notify.cjs——它有自带 `--source=codebuddy` 注册、`--source=codebuddy` 改写） |

## DeepSeek Harness 插件清单（防护相关 4 个）

| 插件 | 职责 |
|---|---|
| `dsh-permission-rules` | 声明式 allow/deny/ask 规则（工具名/参数/路径/网络维度，argv 分解精确匹配）、内置高风险基线、进程级网络策略代理、HMR 热重载、`/rules list` `/rules test` 命令 |
| `dsh-auto-review` | ask 类的第二模型 AI 自动审查（只读审查 subagent 决定 allow/deny，fail-closed，审计留痕） |
| `dsh-defend` | 提示注入/越狱/密钥泄露检测（Aho-Corasick 引擎），消息、工具参数、工具结果三道闸，`defend_report` 工具 + `/defend` 命令 |
| `dsh-notification` | 回合结束桌面通知（按结果开关 + 关键词过滤） |

其余为 UI/适配类插件（better-sidebar、tauri 三件、win-terminal-inspector、dshmarket），与防护无关。

## Git 换安装路径事故与解释器红线（2026-10-20）

**事故**：2026-10-15 22:55 Git 升到 2.56，安装位置从默认 `C:\Program Files\Git` 换到 `F:\Program Files (x86)\Git`。新安装只把 `...\Git\cmd` 加进 PATH（`cmd` 目录里没有 `bash.exe`），裸 `bash` 于是命中 `C:\Windows\System32\bash.exe`（WSL 存根）——没装发行版时直接报错。表现：

- Claude Code：`PreToolUse:Write hook error: ["$HOME"/.claude/hooks/guard-memory-write.sh]: failed; blocking because Git Bash wasn't found ... Install Git for Windows ...`（写文件被拦死）
- Qoder CN：CLI 日志在 2026-10-20T08:46 仍报 `Git Bash not found yet, background download scheduled`；5 条 `bash "..."` 钩子全部失效
- CodeBuddy：同样 5 条裸 `bash` 钩子失效
- ZCode（`F:/.../Git/usr/bin/bash.exe`）与 Codex（绝对 bash）**不受影响**；**git 仓库自身的 hooks 也不受影响**——Git 执行 hook 时会把 `usr/bin` 前置进 PATH
- 附带发现：agent-config-sync-check 仓库 2 条 Qoder AI tracker 钩子写死已卸载的 `D:\tools\Qoder\.qoder-versions\0.3.3`，已备份删除（`~\.claude\backups\20261020-qoder-tracker-hooks\`）

**修复（2026-10-20 已落地）**：

1. 用户环境变量 `CLAUDE_CODE_GIT_BASH_PATH=F:\Program Files (x86)\Git\bin\bash.exe`（Claude Code 新会话生效；`claude.exe` 内置认这个变量名）
2. `sync-config.json` → `hooksSync.ends.qoder` / `ends.codebuddy` 补 `bashCommand: "F:/Program Files (x86)/Git/usr/bin/bash.exe"`；`scripts\sync-check.ps1` 的 `Get-QoderHookEntries` 对**含空格的解释器路径自动加双引号**（命令串端会经 shell 解析，不引号就被空格劈开）
3. `scripts\register-qoder-hooks.js` / `register-codebuddy-hooks.js` 改为按**脚本路径**（命令末尾 `"...xxx.sh"`）原位替换：旧的 `bash "..."` 被替换成固定解释器，并清理同脚本的历史重复条目，不再追加第二份
4. 2026-10-20 环境层兜底：用户 PATH 最前插 `F:\Program Files (x86)\Git\bin`（`WM_SETTINGCHANGE` 已广播，新开进程裸 `bash` 即命中 Git Bash；原 PATH 备份 `~\.claude\backups\20261020-git-path\user-path.bak.txt`）。同时把 4 个用 codegraph 的仓库共 16 条 git hook 里 `NODE="/f/nodejs/node.exe"`（nvm 符号链接）钉成绝对版本路径 `"/f/nvm/v22.20.0/node.exe"`（备份 `~\.claude\backups\20261020-codegraph-hooks\`）；codegraph 重装重新生成 hooks 后要再钉一次
5. 顺带清理死配置（2026-10-20）：备份后删除 `~\.qoder\settings.json`（国际版 Qoder 已卸载，内含插件/MCP 配置）与 `~\.zcode\settings.json`（ZCode 不读它，真源是 `~\.zcode\cli\config.json`），备份在 `~\.claude\backups\20261020-dead-configs\`

**红线（新增端 / 换环境必查）**：

- 命令串型端（Claude Code、Qoder、CodeBuddy）：解释器一律**绝对路径 + 双引号**；拼命令时别丢引号
- process 型端（ZCode）：用数组参数，**不要**在 `command`/`args` 里加引号
- 裸 `bash` 虽已由用户 PATH 的 `...\Git\bin` 兜底（2026-10-20 起，仅对新开进程有效），但客户端 / 脚本仍**默认不依赖**裸 bash，按绝对路径钉死
- Git 仓库 hooks 不用跟着改（Git 自带 PATH 前置）；客户端 hooks 才需要解释器钉死

## 设计原则（改防护能力时遵守）

1. **改通用脚本** → 只改事实源 `coding-rules\hooks\`，然后复制分发到 `~\.claude\hooks\`（Claude/Zcode/Codex/Qoder/CodeBuddy 即全生效），改动走 coding-rules git
2. **改 hook 注册（挂哪些脚本/什么事件）** → 只改 `~\.claude\settings.json`（注册唯一手工维护点）；跑 agent-config-sync-check 的 `-Fix` 自动同步到 ZCode `~\.zcode\cli\config.json`、Qoder `~\.qoder-cn\settings.json` 与 CodeBuddy `~\.codebuddy\settings.json`；Codex 端按报告手动同步（trusted_hash 需重新信任）；DeepSeek Harness 无 hooks 走 rules.yaml
3. **改 Codex 记忆守卫** → 只改 `~\.codex\hooks\*codex.sh`（不入 git）
4. **改 DeepSeek Harness 规则** → 只改 `~\.dsh\rules.yaml`（热重载即生效；跑 `/rules list` 验证），不碰内置基线文件（插件升级会被覆盖，差量一律写用户级 rules.yaml）
5. **新增防护能力** → 六端各走各路：脚本类进 coding-rules\hooks 分发，DeepSeek Harness 类进 rules.yaml，Codex 专属适配进 ~/.codex\hooks\

## 验证命令

```powershell
# DeepSeek Harness：规则加载与命中测试（DeepSeek Harness 会话内）
#   /rules list
#   /rules test bash {"command":"git add ."}
# Codex：hook 变更后按提示重新信任（trusted_hash）
# Claude/Zcode/Qoder/CodeBuddy：触发一次被拦命令（如 git add .）看拦截输出
# 注册漂移：pwsh -NoProfile -File "F:\idea-workspase-skills\agent-config-sync-check\scripts\sync-check.ps1"
# 解释器钉死自检：Qoder/CodeBuddy settings.json 里每条 .sh 钩子应为
#   "F:/Program Files (x86)/Git/usr/bin/bash.exe" "C:/Users/Administrator/.claude/hooks/xxx.sh"
```
