# 四端防护能力对照（HOOKS 说明）

> 四端工具（Claude Code / DSH / Codex / Zcode）的防护钩子**能力对齐、实现方式各异**：
> Claude 走 settings.json 挂 shell 脚本；DSH 走声明式规则 + 插件（无用户 hooks 机制）；Codex 走 config.toml 的 hooks 特性；Zcode 走 `~\.zcode\cli\config.json` 的 hooks 段（process 型，注册从 Claude settings.json 自动同步）。
> 脚本分发细节（事实源、复制关系）见 `coding-rules\SYNC说明.md` 第三节。
>
> **Qoder 预留（阶段一未接）**：Qoder 已作为第五端纳入技能 Junction 同步，但其 hooks 机制（`~\.qoder\security-resources\...\.qoder-plugin\qoder-hooks.json`，与 Claude Code hooks 几乎同构、matcher 支持 `MultiEdit`）**暂不纳入 hooksSync**，转换规则与"hooks 是否真执行"待实测后再评估；当前 hooksSync 仍只覆盖 Claude（源）/ Zcode / Codex / DSH。

## 能力对照表

| 防护能力 | Claude Code | DSH | Codex | Zcode |
|---|---|---|---|---|
| 危险 git 拦截（push --force、reset --hard、add . 等） | `block-dangerous-git.sh`（deny，正则） | 内置基线 ask（push --force / reset --hard）+ `rules.yaml` 6 条 deny（clean / branch -D / checkout . / restore . / add 全量） | `block-dangerous-git.sh`（同脚本） | 同 Claude |
| 危险 bash 拦截（rd /s、format、diskpart、rm -rf /、curl\|sh 等） | `guard-dangerous-bash.sh` | `rules.yaml` Windows 段 8 条 deny + 内置基线（mkfs/dd/chmod 777/fork bomb/curl\|sh/敏感路径 ask） | 同脚本（Codex 格式适配） | 同 Claude |
| 记忆守卫（memory/ 分层 + 命名校验 + 台账） | `guard-memory-write.sh` + `guard-memory-approved.sh` | 无 memory 机制（文件沙箱 + AGENTS.md 约定兜底） | `guard-memory-write-codex.sh` + `guard-memory-approved-codex.sh`（apply_patch 适配版） | 同 Claude |
| 下载位置提醒 | `warn-download-location.sh` | 无（AGENTS.md 文字约定） | 无 | 同 Claude |
| 任务完成通知 | tokentracker（Stop/SessionEnd） | `dsh-notification` 插件（桌面通知） | tokentracker（`notify` 配置） | tokentracker（Stop，`--source=zcode`） |
| 提示注入/密钥泄露检测 | 无 | `dsh-defend` 插件（消息/工具参数/工具结果三道闸） | 无 | 无 |
| 审批 AI 预审 | 无（人工审批） | `dsh-auto-review` 插件（第二模型裁决，fail-closed） | 无 | 无 |
| 文件沙箱 | 无内置 | workspace-write 预设（工作区外写入走审批） | 内置 sandbox/approval | 内置 |
| 网络白名单 | 无内置 | `rules.yaml` network 规则 + 本地策略代理 | 无内置 | 无内置 |

## 各端配置位置

| 端 | 机制 | 配置文件 | 脚本/规则位置 |
|---|---|---|---|
| Claude Code | settings.json hooks 段 | `~\.claude\settings.json` | `~\.claude\hooks\*.sh`（事实源副本） |
| Zcode | config.json hooks 段（`hooks.events` + 必须 `hooks.enabled: true`；**只认这一处**——`~\.zcode\settings.json` 不被读取，`~\.claude\settings.json` 被其 legacy 加载器列出但恒不执行） | `~\.zcode\cli\config.json` | process 型直接引用 `~\.claude\hooks\*.sh` 同一路径；注册由 agent-config-sync-check 的 hooksSync 从 Claude settings.json 自动同步（SessionEnd 丢弃、matcher 去 MultiEdit、`--source=zcode` 改写） |
| Codex | config.toml `[[hooks.*]]` + `[features] hooks = true` | `~\.codex\config.toml`（每条 hook 有 trusted_hash，命令变更需重新信任；hooksSync 只报告不自动写） | Bash 拦截引 `~\.claude\hooks\`；记忆守卫用 `~\.codex\hooks\*codex.sh` 适配版 |
| DSH | 声明式规则（无 hooks） | `~\.dsh\rules.yaml`（用户级，热重载）+ `~\.dsh\settings.yaml` `permission.defaultPreset` | 内置基线：`~\.dsh\profiles\web\node_modules\dsh-permission-rules\rules\builtin-high-risk.yaml` |

## DSH 插件清单（防护相关 4 个）

| 插件 | 职责 |
|---|---|
| `dsh-permission-rules` | 声明式 allow/deny/ask 规则（工具名/参数/路径/网络维度，argv 分解精确匹配）、内置高风险基线、进程级网络策略代理、HMR 热重载、`/rules list` `/rules test` 命令 |
| `dsh-auto-review` | ask 类的第二模型 AI 自动审查（只读审查 subagent 决定 allow/deny，fail-closed，审计留痕） |
| `dsh-defend` | 提示注入/越狱/密钥泄露检测（Aho-Corasick 引擎），消息、工具参数、工具结果三道闸，`defend_report` 工具 + `/defend` 命令 |
| `dsh-notification` | 回合结束桌面通知（按结果开关 + 关键词过滤） |

其余为 UI/适配类插件（better-sidebar、tauri 三件、win-terminal-inspector、dshmarket），与防护无关。

## 设计原则（改防护能力时遵守）

1. **改通用脚本** → 只改事实源 `coding-rules\hooks\`，然后复制分发到 `~\.claude\hooks\`（Claude/Zcode/Codex 即全生效），改动走 coding-rules git
2. **改 hook 注册（挂哪些脚本/什么事件）** → 只改 `~\.claude\settings.json`（注册唯一手工维护点）；跑 agent-config-sync-check 的 `-Fix` 自动同步到 ZCode `~\.zcode\cli\config.json`；Codex 端按报告手动同步（trusted_hash 需重新信任）；DSH 无 hooks 走 rules.yaml
3. **改 Codex 记忆守卫** → 只改 `~\.codex\hooks\*codex.sh`（不入 git）
4. **改 DSH 规则** → 只改 `~\.dsh\rules.yaml`（热重载即生效；跑 `/rules list` 验证），不碰内置基线文件（插件升级会被覆盖，差量一律写用户级 rules.yaml）
5. **新增防护能力** → 四端各走各路：脚本类进 coding-rules\hooks 分发，DSH 类进 rules.yaml，Codex 专属适配进 ~/.codex\hooks\

## 验证命令

```powershell
# DSH：规则加载与命中测试（DSH 会话内）
#   /rules list
#   /rules test bash {"command":"git add ."}
# Codex：hook 变更后按提示重新信任（trusted_hash）
# Claude/Zcode：触发一次被拦命令（如 git add .）看拦截输出
```
