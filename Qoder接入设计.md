# Qoder 第五端接入设计

> 状态：**阶段一已实施（2026-09-18），阶段二未实施**
> 取证日期：2026-09-18 ~ 2026-09-19（实机探查 + 官方文档）
> 关联文档：`SKILL.md`（四端同步守卫）、`sync-config.json`、`scripts\sync-check.ps1`
> **落地勘误**：本设计原判断"脚本零逻辑改动"在**检查项 7（JUNCTION说明.md 补行）上不成立**——补行走 `Fix-JunctionDoc`/`Ensure-Block`，遍历的是脚本顶部硬编码清单 `$script:Domains`，不读 `agents`，导致新端"检查报缺、修复静默不写"。实施时已改为配置驱动（`$script:Domains`/`$script:EndLabels` 在配置加载后按 `$cfg.agents` 构建，`agents` 每条新增 `label` 字段）。另：本机为 Windows PowerShell 5.1，无 `pwsh 7`，验收命令用 `powershell` 而非 `pwsh`。详见文末「实施记录」。

---

## 1. 背景与目标

本仓库当前维护 Claude Code / DSH / Codex / ZCode **四端**同步：技能 Junction、全局规则硬链接组、README、ssh-mcp、MCP 注册、hooks 注册。新装软件 **Qoder**（阿里 AI IDE，2026-09-18 安装）后出现第五个 agent 消费端，若不纳入守卫：

- Qoder 侧技能与规则长期裸奔，与四端渐行渐远；
- 将来手工补挂链接时无检查兜底，链接坏了自己不知道。

**目标**：把 Qoder 纳入 agent-config-sync-check 的守卫范围，方式为**分阶段接入**——先接零风险部分（技能 Junction），观察后再决定是否接规则硬链接组，守卫先于接入。

---

## 2. 调研结论

### 2.1 实机现状（`C:\Users\Administrator\.qoder`）

| 探查项 | 结果 | 守卫含义 |
|---|---|---|
| 顶层 `AGENTS.md` / `CLAUDE.md` | **不存在** | 阶段二的挂点尚空闲，无分叉风险 |
| 顶层 `skills\` 目录 | **不存在** | 阶段一挂点尚空闲，`mklink /J` 前需先 `mkdir` |
| `settings.json` | 仅 `enabledPlugins`（qoder-context），无 `mcpServers`、无 `hooks` | MCP/hooks 同步暂无落点，天然支持"暂不做" |
| CLI 形态 | `entry\qoder.cmd` + `qoder-dispatcher.ps1`，`bin\`、`.bin\`、`app\` | Qoder 有与四端同类的 CLI agent，不是纯 IDE |
| 内置 skill 样本 | `security-resources\security-scan\skills\security-scan\SKILL.md` | frontmatter `name`+`description` 格式与四端**完全一致** |
| 内置 hooks 样本 | `security-resources\security-scan\.qoder-plugin\qoder-hooks.json` | 结构与 Claude Code hooks **几乎同构**（type/matcher/timeout/async），且 matcher 支持 `MultiEdit`（ZCode 不支持） |
| `projects\` | 已有 `F--idea-workspase-skills-agent-config-sync-check` 会话目录 | 用户已在 Qoder 中打开过本仓库 |
| `memory\` | 空 | 自动记忆未启用，与 AGENTS.md 是两个东西 |
| `qoder-knowledge\legacy-migration\state.v1.json` | 存在 | **Qoder 会做家目录迁移**，升级有拆链风险（见第 6 节） |
| `mcp-router.json` | 含运行时 `apiKey`、`baseUrl`、`pid` | 敏感文件，任何同步逻辑不得读取/入库/入档 |

### 2.2 官方文档确认的对接点

1. **用户级技能** `~/.qoder/skills/{skill-name}/SKILL.md`，同名时用户级覆盖项目级
   来源：<https://docs.qoder.com/zh/cli/Skills>
   → 与四端 Junction 模式**完全对口**，是阶段一的落点。
2. **用户级规则** `~/.qoder/AGENTS.md`。`context.fileName` 默认 `AGENTS.md`；官方明确列出常用位置：用户级 `~/.qoder/AGENTS.md`、项目级 `<project>/AGENTS.md`、本地级 `AGENTS.local.md`
   来源：<https://docs.qoder.com/zh/cli/how-memory-works>、<https://docs.qoder.com/zh/cli/settings-reference>
   → 可作硬链接组第五成员，是阶段二的落点。
3. **Qoder CLI 的定位差异（关键）**：官方明确"项目说明是提供给模型的上下文，而不是强制策略"，且 `/init`、`/memory` 面板会把 `~/.qoder/AGENTS.md` 当**可写记忆文件**管理——它不是纯只读消费端（四端中 ZCode/Codex 也不严格只读，但 Qoder 自带编辑入口，写概率更高，见第 6 节风险①）。

### 2.3 明确出界的部分（守卫不管）

- **Qoder IDE 侧规则**：走项目内 `.qoder/rules\` 目录 + IDE 设置存储（用户图标 → 设置 → 规则），AGENTS.md 兼容也仅项目级。不落家目录文件，守卫无法也无需覆盖。
   来源：<https://docs.qoder.com/zh/user-guide/rules>
- **Qoder 云端 / Cloud Agents / 移动端**：云端形态，无本地配置文件。
- **自动记忆**（`memory\` 目录）：Qoder 私有运行数据，非同步对象。

---

## 3. 设计原则

1. **只读消费优先**：先接对 Qoder 而言纯只读的部分（技能 Junction，内容真身在 F 盘仓库）；Qoder 有写权限的部分（AGENTS.md）后接、有判据地接。
2. **分阶段、可退**：每一阶段都有独立的回滚路径和降级形态（阶段二退组 → 手工副本跟随模式）。
3. **守卫先于接入**：先让 sync-check 能看见 qoder 端（配置登记），再让链接存在；接入动作尽量复用 `-Fix` 自动修，不引入新脚本逻辑。
4. **零脚本结构改动**：已核实 sync-check.ps1 的硬链接组检查按 `rulesHardlink.paths` 数组 pairwise 互查（L204-230，天然支持 N 端）、技能检查按 `agents` 数组 `skillsEnabled: true` 过滤（L1421）——两处都是数据驱动，第五端只是配置数据变化。
5. **敏感边界**：`mcp-router.json`（含 apiKey）永不读取、不同步、不入库。

---

## 4. 分阶段设计

> **状态标记**：阶段一 ☐ 未实施 ｜ 阶段二 ☐ 未实施（每阶段完成时勾选并更新本行）

### 4.1 阶段一：五端技能 Junction（对应上轮方案 B）

**范围**：只挂技能链接；`rulesHardlink.paths` 不动，`~/.qoder/AGENTS.md` 不创建。

**`sync-config.json` 唯一变更点**（`agents` 数组追加一条）：

```json
{ "name": "qoder", "home": "C:\\Users\\Administrator\\.qoder", "rulesFile": "AGENTS.md", "skillsEnabled": true }
```

字段说明：
- `home`：Junction 的父目录基点，脚本拼 `home\skills\<name>`（sync-check.ps1 L139）；
- `skillsEnabled: true`：纳入检查项 1/2/6/7 与 README 区块端清单（L1421 过滤依据）；
- `rulesFile: "AGENTS.md"`：**仅文档性记录**。经 grep 核实，脚本规则检查完全由 `rulesHardlink.paths` 驱动，不读取 `agents[].rulesFile`；阶段二才让该字段对应真实文件。

**实施序**（顺序有依赖，不能颠倒）：
1. 先 `mkdir C:\Users\Administrator\.qoder\skills`——`mklink /J` 要求父目录存在，且未核实 `-Fix` 是否自动建父目录（实施时验证一次即可）；
2. 跑 `sync-check.ps1` → 检查项 1 应报 qoder 端全量缺链接（预期 ERROR）；
3. 跑 `sync-check.ps1 -Fix` → 自动补建全部技能 Junction（复用现有"漏挂自动修"逻辑）+ 自动补各 skill 仓库 `JUNCTION说明.md` 的 qoder 行（复用现有"缺端补行"逻辑，行格式由 `junctionDoc.tableRowFormat` 生成）。

**人工内容改动清单**（内容决策，`-Fix` 不碰）：
- `SKILL.md`：描述与表格"四端"→"五端"、加 qoder 行、检查项表述核对；
- `scripts\sync-check.ps1` 顶部注释（L10 "AGENTS.md x4"、L1420 "ensure four-end rows"，纯注释文案，无逻辑）；
- `scripts\sync-check.ps1` **L215 错误消息字面量**（`... 4-end rules sync is broken`）：阶段二触发 `HardlinkBroken` 时会弹出此文案，五端断链却报"4-end"，属误导性活文案，非注释，须一并改为端数无关表述（如 "N-end rules sync"）；
  - 注：L906 是历史事故记录（"四端共用目录互顶"），陈述事实非计数，保留不动。
- 本 skill 的 `README.md` 四端表述；
- `HOOKS说明.md` 加一条"Qoder 预留（hooks 同构，暂不接）"注记。

### 4.2 阶段二：AGENTS.md 进硬链接组（升级为方案 A，观察期后）

**前置核实项**（实施第一步，未验证不得继续）：
- `-FixHardlink` 重建逻辑对第五条路径的行为（读一遍该函数体确认它是纯 `paths` 数组驱动）；
- PS 5.1 下建链命令：`fsutil hardlink create "C:\Users\Administrator\.qoder\AGENTS.md" "C:\Users\Administrator\.claude\CLAUDE.md"`（向组内任一现有成员建链即同组）。

**变更点**：
- `rulesHardlink.paths` 追加 `"C:\\Users\\Administrator\\.qoder\\AGENTS.md"`；
- 建链后跑 `sync-check.ps1`，检查项 3 五端 pairwise 同组全绿。

**观察期判据**（决定"入组 / 留组 / 退组"，这是本设计的核心判据）：

| 观察窗口 | 信号 | 判定 | 动作 |
|---|---|---|---|
| 入组前 | Qoder CLI 无实际使用（`projects\` 无新会话） | 中性 | 不入组，继续等 |
| 入组后 2 周 | 日检零 `HardlinkBroken`（qoder 路径） | 好 | 转正，阶段二完成 |
| 入组后 2 周 | `HardlinkBroken` ≥2 次，且非编辑器已知行为 | 坏 | **退组**，转降级形态 |
| 任意时刻 | Qoder 升级后 `skills\` 目录被迁移 | 坏 | 阶段一回滚重评估 |

**退组后的降级形态**（不回到裸奔）：把 `~/.qoder/AGENTS.md` 登记进现有 `rulesHardlink.manualCopies`（`stripHeaderComment: true`，副本开头加身份头注释）——复用 coding-rules 副本跟随机制，检查项 13 自动盯正文漂移。已知残余风险：若 Qoder 与 `-Fix` 双向写会互相覆盖，届时以"组为准、Qoder 手改走 F 盘源"为使用纪律，或彻底不接。

### 4.3 暂不做清单（预留扩展点）

| 项 | 现状 | 预留接口 | 触发条件 |
|---|---|---|---|
| mcpSync qoder 端 | `settings.json` 无 `mcpServers`；`mcp-router.json` 是运行时进程路由（含 apiKey，禁碰） | 需新增端类型 `qoder-json`（只碰 `settings.json` 顶层 `mcpServers`，禁碰 router） | Qoder 里真配了需跨端同步的 MCP |
| hooksSync qoder 端 | `qoder-hooks.json` 与 CC 同构，matcher 支持 `MultiEdit`（转换成本低于 ZCode） | 参照 zcode 端做转换规则 + 实测 hooks 是否真执行 | Qoder 侧有硬性拦截需求（规则文件只是软约束） |
| ssh-mcp qoder 端 | `sshMcpConfig.junctionEnds` / `registration.ends` 是显式登记制，qoder 未登记即不检查 | `junctionEnds` 加 `"qoder"` + ends 加条 + ACL 收紧（ssh-mcp v2.4 会拒宽松 ACL） | 需要在 Qoder 里用 ssh-mcp 时 |
| chrome-devtools 唯一目录（检查项 14） | 只检查登记端；qoder 未登记 | `perEndArgs` 加 `--userDataDir=...MCP-qoder` | Qoder 配 chrome-devtools 时，**必须**先分独立目录 |
| IDE 侧规则 | 项目内 `.qoder/rules\`，不落家目录 | 无 | 永久出界（见 2.3） |

---

## 5. 脚本影响面（逐检查项核对）

| # | 检查项 | 第五端接入后 | 是否需改脚本 |
|---|---|---|---|
| 1 | 技能链接覆盖 | agents 加条后自动覆盖 qoder 端（`home\skills\<name>` 逐一比对） | 否 |
| 2 | 死链 | 自动覆盖（扫描四端→五端 `skills\` 下指向本仓库的 Junction） | 否 |
| 3 | 硬链接组 | 阶段二 paths 加条后自动纳入 pairwise 互查（L204-230 已核实数组驱动） | 否 |
| 4 | frontmatter 健全 | 与端无关 | 否 |
| 5 | README 技能列表 | 与端无关 | 否 |
| 6 | 红线（coding-rules 不得被链接） | qoder 端自动纳入红线扫描 | 否 |
| 7 | JUNCTION说明.md | "须覆盖全部启用端"→ qoder 缺行会报错，`-Fix` 按端序自动补行 | 否 |
| 8 | README 相关技能互链 | 与端无关 | 否 |
| 9 | ssh-mcp Junction | 显式登记制，qoder 不登记不检查 | 否（暂不做） |
| 10 | ssh-mcp 注册 | 同上 | 否（暂不做） |
| 11 | 通用 MCP 同步 | ends 结构显式登记制 | 否（暂不做） |
| 12 | hooks 注册同步 | ends 结构显式登记制 | 否（暂不做） |
| 13 | 规则手工副本 | 与端无关；阶段二降级形态复用它 | 否 |
| 14 | chrome-devtools 目录唯一 | 只查登记端 | 否（暂不做） |

**结论：脚本零逻辑改动**。全部变化 = 配置数据（agents / paths）+ 文档文案 + 链接层操作。

---

## 6. 风险与防线

1. **Qoder 写文件拆硬链接**（阶段二主要风险，具体失败模式）：Qoder CLI 的 `/init`、`/memory` 面板把 `~/.qoder/AGENTS.md` 当可写记忆文件，"替换写"保存即拆链（同款实踩：2026-09-05 编辑器拆链）。
   防线：检查项 3 每日报 `HardlinkBroken` → 修复走 `-FixHardlink`（N 端 SHA256 全等才重建，分叉拒绝）→ 反复拆则按 4.2 判据退组转手工副本跟随。**接受"可能天天拆"的成本上限就是退组判据本身。**
2. **Qoder 升级迁移家目录**：已存在 `legacy-migration` 迹象，`skills\` 或整个目录可能被改名/迁移，Junction 变死链。
   防线：检查项 1/2 报错可发现；死链只报告不自动修（现有语义刚好匹配"上游可能临时改名"）。
3. **Junction 写穿**（四端同样存在的共性风险，第五端放大暴露面）：Junction 无只读语义，Qoder 理论上能穿透写回 F 盘仓库真文件。
   防线：红线 3（只改仓库源 + 链接层）继续适用；每个 skill 目录都是独立 git 仓库，写穿必然弄脏工作区，`git status` 立即可见——这层探测对 qoder 端同样成立，无需新机制。
4. **`-Fix` 连带面扩大**：阶段一会让 `-Fix` 同时改几十个 skill 仓库的 `JUNCTION说明.md`。
   防线：内容全部由模板机械生成（可从 git HEAD 复原）；提交按仓库拆分、逐文件 add（git-commit 规范），不打包一锅提交。

---

## 7. 实施步骤、验收与回滚

### 7.1 阶段一操作序

1. 改 `sync-config.json`（agents 加 qoder 条，见 4.1）；
2. `mkdir C:\Users\Administrator\.qoder\skills`；
3. `sync-check.ps1`（只读，确认报缺链接）→ `sync-check.ps1 -Fix`（补链接 + 补 JUNCTION说明.md 行）；
4. 人工改内容文案（SKILL.md / ps1 注释 / README / HOOKS说明.md，见 4.1 清单）；
5. git 提交：agent-config-sync-check 仓库（config + 文档 + ps1 注释）一笔；其他 skill 仓库各自 JUNCTION说明.md 一笔（逐仓库、逐文件 add、中文标题、🐧 签名段）；
6. push 后 `git status --short --branch` 核对远端一致。

### 7.2 验收清单

- [ ] `pwsh -NoProfile -File sync-check.ps1` 退出码 0，汇总行 Agents 含 `qoder`；
- [ ] `cmd /c dir C:\Users\Administrator\.qoder\skills | findstr <某技能名>` 能看到 Junction 且目标为仓库规范路径；
- [ ] Qoder CLI 新会话输入 `/skills`，列表含全量自研技能；任选一技能（建议 agent-config-sync-check）实际触发验证可用；
- [ ] 各改动仓库 push 后与远端一致。

### 7.3 阶段二操作序（观察期通过后）

1. 前置核实 `-FixHardlink` 第五路径行为（见 4.2）；
2. `fsutil hardlink create` 建第五链 → `rulesHardlink.paths` 加条 → sync-check 五端全绿；
3. 文案跟改 + git 提交。

### 7.4 回滚

- **阶段一回滚**：`sync-config.json` 移除 qoder 条 → 逐个 `rd "C:\Users\Administrator\.qoder\skills\<name>"`（**不加 `/s`**，红线 1）→ 各 JUNCTION说明.md 删 qoder 行（手工，`-Fix` 对"多余端行"未定义行为）→ 文案还原 → git 提交。
- **阶段二回滚**：`rulesHardlink.paths` 移除条目 → `del C:\Users\Administrator\.qoder\AGENTS.md`（删硬链接组的一条名字，其余四端不受影响，语义安全）→ git 提交。
- **降级路径**：阶段二退组 → 4.2 降级形态（manualCopies 跟随），不是裸奔。

---

## 附：本设计的关键事实来源

- 实机探查：`C:\Users\Administrator\.qoder`（2026-09-18/19，目录清单、settings.json、qoder-hooks.json、SKILL.md 样本）
- 官方文档：[CLI 技能](https://docs.qoder.com/zh/cli/Skills)、[记忆工作原理](https://docs.qoder.com/zh/cli/how-memory-works)、[配置项/环境变量/文件路径](https://docs.qoder.com/zh/cli/settings-reference)、[IDE 规则](https://docs.qoder.com/zh/user-guide/rules)
- 脚本事实：`scripts\sync-check.ps1` L139/L204-230/L1421（grep 核实，`agents[].rulesFile` 未被脚本读取）

---

## 8. 实施记录（2026-09-18，阶段一）

- ✅ **检查项 7 原判断有误并已修正**：第 5 节"检查项 7 是否需改脚本 = 否"不成立。`Test-JunctionDocs`（检查）读 `$Cfg.agents` 数据驱动，但 `Fix-JunctionDoc`/`Ensure-Block`（修复 L1375/L1379/L1427/L1431）读脚本顶部硬编码 `$script:Domains = @('claude','dsh','codex','zcode')`，二者脱节 → qoder 端"检查报缺行、`-Fix` 打印 added 却 git diff 为空、复检恒红"。
  - **改法（治本）**：`$script:Domains`/`$script:EndLabels` 移到主流程 `$cfg` 加载后，按 `$cfg.agents`（`skillsEnabled` 过滤）构建；`sync-config.json` 每条 `agents` 增加 `label` 字段（claude=Claude Code / dsh=DSH / codex=Codex / zcode=Zcode / qoder=Qoder）。此后加端只动配置，检查与修复同源，第 6 端不再复现此坑。
  - **第 5 节结论订正**：脚本"零逻辑改动"应改为"检查项 1/2/3/6 零改动、检查项 7 需一次性治本改动（端清单配置驱动）"。
- ✅ 阶段一动作全部完成：`agents` 加 qoder 条（含 label）→ `mkdir .qoder\skills` → 只读 sync-check 报 23 项（15 MissingLink + 8 doc 缺端）→ `-Fix` 建 15 个 Junction（PowerShell 复核 LinkType=Junction、目标正确）+ 补 8 份 `JUNCTION说明.md` qoder 行 → 复检 `errors 0 / Status PASS`。
- ✅ 文案：`SKILL.md`（架构表加 Qoder 行、checks 1/2/6/7 改"各启用端"、上架流程、配置"新增端"说明含 label）、`README.md`（同类改动）、`sync-check.ps1` 顶部注释（5 agent ends；规则 x4/4-end 因阶段一硬链接组仍 4 端**保持准确不动**）、`HOOKS说明.md` 加 Qoder 预留注记。
- ⚠️ **验收命令更正**：本机无 `pwsh 7`（脚本头 `Runtime: ...no pwsh 7`），第 7.2 节 `pwsh -File` 应为 `powershell -NoProfile -File`。
- ☐ **未决（留人工拍板）**：技能品牌仍叫"四端同步守卫"、SKILL.md `description` 与标题、触发词"四端同步"未改（现在技能链接已 5 端、规则硬链接仍 4 端，"四端/五端"口径取决于品牌是否随端数改名）。
- ☐ 阶段二（`~\.qoder\AGENTS.md` 进硬链接组）未实施，按第 4.2 判据待观察。
