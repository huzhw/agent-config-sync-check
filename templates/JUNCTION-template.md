# JUNCTION 说明 — {NAME}

> 本目录已与四个全局 skill 目录建立 junction，**实时双向同步，改哪边都一样**。

## 指向关系

| 项 | 路径 |
|----|------|
| 全局路径（junction，Claude Code） | `C:\Users\Administrator\.claude\skills\{NAME}` |
| 全局路径（junction，DSH） | `C:\Users\Administrator\.dsh\skills\{NAME}` |
| 全局路径（junction，Codex） | `C:\Users\Administrator\.codex\skills\{NAME}` |
| 全局路径（junction，ZCode） | `C:\Users\Administrator\.zcode\skills\{NAME}` |
| 实际目录（F 仓库） | `F:\idea-workspase-skills\{NAME}` |

## 说明

- 全局四个目录都是指向 F 仓库的 junction，四处是**同一个目录**，不是副本。
- 修改 F 仓库，全局立刻生效；在全局路径下改文件，F 仓库同步变化。
- 日常维护只改 F 仓库（git 提交推送后全局自动一致），**不需要手动复制同步**。

## 检查是否正常

```bash
cmd /c dir "C:\Users\Administrator\.claude\skills" | findstr {NAME}
cmd /c dir "C:\Users\Administrator\.dsh\skills"    | findstr {NAME}
cmd /c dir "C:\Users\Administrator\.codex\skills"  | findstr {NAME}
cmd /c dir "C:\Users\Administrator\.zcode\skills"  | findstr {NAME}
```

正常应显示 `<JUNCTION>  ...  {NAME}`。

## 回滚方法（恢复成独立副本）

```bat
rd "C:\Users\Administrator\.claude\skills\{NAME}"
rd "C:\Users\Administrator\.dsh\skills\{NAME}"
rd "C:\Users\Administrator\.codex\skills\{NAME}"
rd "C:\Users\Administrator\.zcode\skills\{NAME}"
```

> 注意：`rd` 不要加 `/s`，否则可能递归进 F 源目录。删除 junction 只删链接，不删 F 源目录。
