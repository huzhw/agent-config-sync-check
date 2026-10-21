# JUNCTION 说明 — agent-config-sync-check

> 本目录已与五个全局 skill 目录建立 junction，**实时双向同步，改哪边都一样**。

## 指向关系

| 项 | 路径 |
|----|------|
| 全局路径（junction，Claude Code） | `C:\Users\Administrator\.claude\skills\agent-config-sync-check` |
| 全局路径（junction，DeepSeek Harness） | `C:\Users\Administrator\.dsh\skills\agent-config-sync-check` |
| 全局路径（junction，Codex） | `C:\Users\Administrator\.codex\skills\agent-config-sync-check` |
| 全局路径（junction，ZCode） | `C:\Users\Administrator\.zcode\skills\agent-config-sync-check` |
| 全局路径（junction，Qoder CN） | `C:\Users\Administrator\.qoder-cn\skills\agent-config-sync-check` |
| 实际目录（F 仓库） | `F:\idea-workspase-skills\agent-config-sync-check` |

## 说明

- 五个全局目录都是指向 F 仓库的 junction，五处是**同一个目录**，不是副本。
- 修改 F 仓库，五端立刻生效；在全局路径下改文件，F 仓库同步变化。
- 日常维护只改 F 仓库（git 提交推送后全局自动一致），**不需要手动复制同步**。
- 本 skill 于 2026-08-31 新增（首发四端，2026-09-18 接入 Qoder 升五端，2026-10-10 接入 CodeBuddy 升六端——其 skills 复用 `.claude`，规则走 `~\.codebuddy\rules\core-discipline.md` 手工副本（同日硬链接 `CLAUDE.md`/`CODEBUDDY.md` 摘除），无更名历史；同日接入 MiniMax Code 升七端——仅规则硬链接组 `~\.minimax\AGENTS.md`，不挂技能；2026-10-11 接入 WorkBuddy 升八端——仅规则手工副本 `~\.workbuddy\user-<id>-personal\MEMORY.md`，不挂技能；2026-10-21 CodeBuddy CN 卸载，CodeBuddy 端随退出本守卫（skills 原复用 `.claude`，规则手工副本 `~\.codebuddy\rules\core-discipline.md` 同日摘除），端数回落七端；2026-10-21 同日接入 OpenCode 补回八端——仅规则硬链接组 `~\.config\opencode\AGENTS.md`，不挂技能（opencode 自身已发现 `~/.claude/skills`，再挂属重复））。

## 检查是否正常

```bash
cmd /c dir "C:\Users\Administrator\.claude\skills" | findstr agent-config-sync-check
cmd /c dir "C:\Users\Administrator\.dsh\skills"    | findstr agent-config-sync-check
cmd /c dir "C:\Users\Administrator\.codex\skills"  | findstr agent-config-sync-check
cmd /c dir "C:\Users\Administrator\.zcode\skills"  | findstr agent-config-sync-check
cmd /c dir "C:\Users\Administrator\.qoder-cn\skills" | findstr agent-config-sync-check
```

正常应显示 `<JUNCTION>` 字样。也可以直接跑本 skill 的检查脚本，覆盖验证更全：

```bash
powershell -NoProfile -File "F:\idea-workspase-skills\agent-config-sync-check\scripts\sync-check.ps1"
```

## 回滚方法（恢复成独立副本）

```bat
rd "C:\Users\Administrator\.claude\skills\agent-config-sync-check"
rd "C:\Users\Administrator\.dsh\skills\agent-config-sync-check"
rd "C:\Users\Administrator\.codex\skills\agent-config-sync-check"
rd "C:\Users\Administrator\.zcode\skills\agent-config-sync-check"
rd "C:\Users\Administrator\.qoder-cn\skills\agent-config-sync-check"
```

> 注意：`rd` 不要加 `/s`，否则可能递归进 F 源目录。删除 junction 只删链接，不删 F 源目录。

## 本 skill 特殊差异

- 本身就是八端同步的守卫：链接断了它自己会查出来，`JUNCTION说明.md` 的指向关系与 `sync-config.json` 保持一致。
- 检查日志 `logs\` 不入 git，删了不影响功能。
