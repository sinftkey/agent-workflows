# 任务中心协议

任务中心是在同一份本地克隆中供多个会话共用的任务记录。任务数据只在专用孤儿分支和一个共享 worktree 中保存；代码分支不安装任务中心运行文件。写命令以 Git 提交作为正式状态边界。任务中心对本机克隆可见，不提供跨克隆同步。

外部 issue 或 PR 只保存完整链接，作为关联信息；任务中心不会读取、写入、评论或关闭外部系统。

## 快速上手

维护者从固定版本的模板来源运行独立 setup 引导器。引导器在本地克隆中创建 `task-center` 孤儿分支和共享 worktree；任务中心运行资产不复制到项目代码分支，不修改项目的 `AGENTS.md`、`.gitignore` 或开发文档。setup 不下载、推送或同步远端内容。

```powershell
pwsh -File "<固定版本模板目录>/scripts/setup-task-center.ps1" -RepoPath "<项目仓库根目录>" -SourcePath "<固定版本模板目录>"
```

```bash
bash "<固定版本模板目录>/scripts/setup-task-center.sh" --repo "<项目仓库根目录>" --source "<固定版本模板目录>"
```

保留模板来源的 tag 或提交标识，保证 setup 脚本与 `templates/task-center/` 资产来自同一版本。setup 输出安装位置和一段工具无关的 Agent 引导；由使用者按具体工具实际支持的机制决定放置位置，不假定用户级指令的加载路径或顺序，也不自动改写用户全局指令文件。

每个 Agent 会话都应使用能区分并发会话的 `TASK_IDENTITY`。先找到当前克隆已登记的任务中心，再阅读该 worktree 中的 `TASK-CENTER.md`，然后从项目任意 worktree 调用任务脚本：

```powershell
$env:TASK_IDENTITY = "<工具名>/<会话标识>"
pwsh -File "<任务中心 worktree>/scripts/task.ps1" init
pwsh -File "<任务中心 worktree>/scripts/task.ps1" list
pwsh -File "<任务中心 worktree>/scripts/task.ps1" check
```

```bash
export TASK_IDENTITY="<工具名>/<会话标识>"
bash "<任务中心 worktree>/scripts/task.sh" init
bash "<任务中心 worktree>/scripts/task.sh" list
bash "<任务中心 worktree>/scripts/task.sh" check
```

Agent 可将以下通用引导加入其工具支持的用户级指令位置；先核对目标工具的实际指令机制。若当前克隆未启用任务中心，应告知用户，不得静默创建：

> 识别当前 Git 克隆，并查找已登记的任务中心或 `task-center` worktree；若已启用，先阅读其中的 `TASK-CENTER.md`，再用唯一的 `TASK_IDENTITY` 运行 `init`、`list` 和 `check`。日常任务只通过 `task.sh` 或 `task.ps1` 命令操作；不要手工编辑任务文件或 INDEX。未启用时明确告知用户，不要静默安装。任务中心只在当前克隆内共享。

## 1. 存储与版本

任务中心 worktree 使用以下布局：

```text
TASK-CENTER.md
scripts/task.sh
scripts/task.ps1
.task-center/version
.task-center/next-id
docs/tasks/INDEX.md
docs/tasks/<编号>-<标题>.md
docs/tasks/archive/<编号>-<标题>.md
```

- 任务文件是唯一任务数据源；`INDEX.md` 是脚本从活跃任务生成的总览，禁止手工改表格行。
- `.task-center/version` 记录 `tool-version`、`schema-version` 和 `source-revision`；`.task-center/next-id` 保存下一个可用整数编号。
- 本机绝对路径、锁与事务恢复记录放在共同 Git 目录下，不进入任务中心分支。
- 首版格式为 `schema-version: 2`。不支持的格式版本必须拒绝写入，并提示由安装/迁移入口处理。脚本不自动下载或升级。
- 任务中心分支不得设置 upstream；所有 task 命令均为本地操作，不运行 fetch、pull 或 push。

## 2. 任务文件字段

字段必须各出现一次，位于正文首个 `##` 标题之前，顺序固定，按 UTF-8 编码保存。字段值不得含换行、制表符或表格分隔符 `|`；未知字段、重复字段、缺字段均使 `check` 失败。

| 字段 | 规则 |
|---|---|
| 标题 | `# 任务 #<编号> <标题>`；文件名编号、标题编号与字段中的任务编号语义一致 |
| 状态 | 待办、已认领、进行中、待审核、待测试、待合并、阻塞、已完成、已取消之一 |
| owner | 开发负责人；待办为 `未认领`，认领后保留到结束 |
| 当前负责人 | 当前阶段的执行身份；待办和终态为 `未分配` |
| 优先级 | 高、中、低之一 |
| 依赖 | `无` 或逗号分隔的任务编号 |
| 分支、PR | 没有时为 `无`；PR 可保存完整链接或外部编号 |
| 外部 | `无` 或完整 issue 链接 |
| 备注 | 单行摘要；较长证据写进进度 |
| 阻塞前状态、阻塞原因、等待对象 | 仅阻塞状态填写；其他状态均为 `无` |
| 创建 | `YYYY-MM-DD <登记身份>`；新记录使用 UTC 日期，迁移时保留原始登记人和时间 |

正文包含 `## 验收标准` 与 `## 进度`。验收标准以 Markdown 复选框列出；完成任务前所有条件须勾选。进度只追加，每条记录身份、UTC 日期、迁移前后状态和证据；证据未知写 `无`。不得改写或删除既有进度。

旧格式迁移时保留正文、日志、备注、链接和编号。旧角色字段映射为当前负责人后要与旧状态核对；无法可靠推导的字段作为待补项报告，不能伪造。迁移前检查所有活跃与归档任务的编号是否复用；存在复用时停止自动迁移。

| 旧数据 | 新字段或处理 |
|---|---|
| 标题与文件名中的编号 | 原编号保留；统一接受纯数字、补零数字与 `TC-` 展示写法 |
| 状态 | 按新状态表映射；非法或含糊的状态列为待补项 |
| owner | 保留为开发负责人；未认领任务写 `未认领` |
| 角色 | 根据旧状态映射为当前负责人；与状态规则冲突时列入迁移报告 |
| 优先级、依赖、分支、PR、备注 | 保留原值；旧平台编号不得伪装成完整外部链接 |
| 任务正文、验收条件、进度日志 | 保留内容与顺序；不重写既有历史 |
| INDEX 行 | 从任务文件重建；INDEX 备注先迁回对应任务文件 |
| 活跃与归档任务编号 | 全量检查唯一性；发现重复时停止并请求维护者提供映射 |

## 3. 状态、责任与权限

身份来自 `TASK_IDENTITY`，必须能区分并发会话。权限列表用逗号分隔身份，配置在调用环境或项目的本地任务中心说明中：`TASK_MAINTAINERS`、`TASK_REVIEWERS`、`TASK_TESTERS`、`TASK_MERGE_AUTHORIZED`。未配置某个角色时，该角色操作默认拒绝。此约定用于减少误操作，不是身份认证；代码平台权限与人工 review 仍按项目规则执行。

| 原状态 | 目标状态 / 命令 | 操作者与必需信息 |
|---|---|---|
| 待办 | 已认领 / `claim` | 认领者本人；同时设置 owner 与当前负责人 |
| 已认领 | 进行中 / `status` | owner；验收标准已明确 |
| 进行中 | 待审核 / `status` | owner；指定已授权审核负责人，验收标准已明确 |
| 待审核 | 待测试 / `status` | 当前审核负责人；通过证据齐备，指定已授权测试负责人 |
| 待审核或待测试 | 进行中 / `status` | 当前阶段负责人；打回原因必填，当前负责人移交 owner |
| 待测试 | 待合并 / `status` | 当前测试负责人；验证证据齐备，指定已授权合并负责人 |
| 待合并 | 已完成 / `done` | 当前合并负责人；交付证据齐备，所有验收条件完成；同一事务归档 |
| 活跃阶段 | 阻塞 / `block` | 当前负责人；填写原因与等待对象，保留原阶段和负责人 |
| 阻塞 | 原阻塞前状态 / `unblock` | 当前负责人；追加解除记录，清空当前阻塞字段 |
| 任一非终态 | 已取消 / `cancel` | 维护者；原因必填；同一事务归档 |

普通 `status` 不得进入阻塞、已完成或已取消，避免绕过专用校验。owner 转交由维护者执行 `assign`；阶段执行人调整由当前负责人或维护者执行 `handoff`，填写原因并验证目标身份有对应角色。终态不可重开；需要继续工作时新建关联任务。

依赖必须存在且不能自指；循环依赖为错误。未完成依赖阻止任务进入进行中及之后的执行阶段，并在 `list` 中提示。

## 4. 命令接口

两套脚本参数语义、验证和退出码一致。先设置 `TASK_IDENTITY` 后使用：

| 命令 | 参数与作用 |
|---|---|
| `init` | 只定位并自检本地任务中心；不联网、不创建或升级安装 |
| `list [--all]` | 从已提交任务文件读取活跃任务；`--all` 包含归档 |
| `check` | 只读校验；问题写到标准错误并返回非零，不自动修复 |
| `new <标题> [--slug <短名>] [--priority 高\|中\|低] [--depends <编号列表>] [--acceptance <文本>] [--external <完整链接>]` | 建任务、递增编号、重建 INDEX 并提交 |
| `claim <编号>` | 本人认领待办任务 |
| `progress <编号> <内容> [--evidence <证据>]` | 追加进度 |
| `status <编号> <目标状态> [--assignee <身份>] [--reason <原因>] [--evidence <证据>]` | 按状态表验证并流转 |
| `assign <编号> <新 owner> --reason <原因>` | 维护者转交 owner |
| `handoff <编号> <新负责人> --reason <原因>` | 当前负责人或维护者交接阶段责任 |
| `block <编号> --reason <原因> --waiting-for <对象>` | 记录阻塞上下文 |
| `unblock <编号> [--evidence <证据>]` | 恢复阻塞前状态 |
| `done <编号> --evidence <证据>` | 完成校验并归档 |
| `cancel <编号> --reason <原因>` | 维护者取消并归档 |
| `index --rebuild` | 从有效任务文件生成活跃任务索引并提交 |
| `recover [--show\|--abort\|--commit]` | 检查、回滚或完成被中断的本地事务；不覆盖与事务快照不符的文件 |
| `edit <编号> --export <路径>` / `edit <编号> --import <路径> --base <提交>` | 导出正文草稿；导入前核对基线，正文导入仍经过字段、索引和状态校验 |

编号接受 `42`、`0042`、`TC-0042`，统一为整数后查找；匹配多个文件时报错。slug 只接受 ASCII 小写字母、数字和连字符。未知参数、缺少参数、非法编号、越界路径和无效状态都必须明确报错。

`edit --export` 生成完整任务草稿及 `<路径>.base` 基线文件，草稿必须在任务中心 worktree 外。`edit --import` 要求提供与当前 HEAD 相同的 `--base`；只接受验收标准区变化，字段区和既有进度必须原样保留。进度日志只能用 `progress` 追加。编辑期间若 HEAD 改变，导入拒绝并要求重新导出、合并。

## 5. 写入、并发与恢复

每次写命令执行：获取共同 Git 目录下的短时全局锁 → 重读已提交快照 → 验证工作区干净、暂存区为空、版本与状态合法 → 写事务记录和修改前副本 → 更新任务、编号元数据及 INDEX → 再校验 → 仅暂存本次明确列出的路径 → 提交 → 清理事务记录 → 释放锁。

- 锁目录采用原子创建，记录身份、进程、开始时间和命令。等待超时后报告占用者，不自动清理疑似遗留锁；先确认持有进程已终止，再由维护者移除。
- 任务中心自身有暂存内容、未提交修改、未知文件或未完成事务时，写命令停止；主代码工作区脏不影响任务中心操作。
- 禁止全目录暂存、`reset --hard`、`clean`、远程读写和宽泛回滚。每次提交只包含任务文件、生成的 INDEX 与必要的 `.task-center/next-id`。
- Git 提交是正式状态边界。中断事务保留基线、目标路径与副本，阻止后续写入；`recover` 先比对当前文件与事务快照，再显式回滚或完成。不能确认归属的内容必须交由维护者处理。
- PowerShell 每次调用 Git 原生命令后检查退出码；命令失败不得报告成功。

读命令读取提交快照。`check` 检查版本、任务字段、编号唯一性、状态与负责人/阻塞字段一致性、依赖、INDEX 和 `next-id`；它不自动修复。任务文件丢失、重复字段、重复编号、索引漂移均明确定位到文件。

## 6. 发现任务中心

脚本用 Git 查询当前仓库的共同 Git 目录，并在同一克隆内按以下顺序定位：显式 `TASK_CENTER_PATH`、共同 Git 目录中的安装登记、Git 登记的目标分支 worktree。候选目录必须属于当前克隆，且目标分支和版本标记有效。多候选、登记与 worktree 清单矛盾、版本缺失或格式不支持时停止并报告。`TASK_BRANCH` 默认 `task-center`；保留 `TASK_WORKTREE_NAME` 仅作迁移兼容，不能据它直接拼接当前根目录。

初始化和旧格式接入由模板仓库的独立 setup 引导器负责。日常脚本的 `init` 只定位并检查现有安装，不会 fetch、pull、push、静默创建、修复或升级任务中心。项目至少要有一个 Git 提交；不支持 bare 仓库或网络共享文件系统。引导器不在 `init` 中下载或升级资产；需要升级时维护者应选择固定来源版本并按迁移方案处理。

## 7. 故障恢复、修复与备份

- `check` 是只读检查，不会自动修复。发现索引陈旧或丢失时，先检查任务文件，再显式运行 `task index --rebuild`。
- 写入失败或进程中断后，先运行 `task recover --show` 查看事务基线、路径和副本；仅当确认归属后才使用 `--abort` 或 `--commit`。遗留锁不能自动删除；确认持有进程已终止后，维护者再按锁记录处理。不得用 `reset --hard`、`clean` 或宽泛回滚清理现场。
- setup 的 `--repair` 默认只预览，`--repair --dry-run` 等价；只有 `--repair --apply` 执行修复。任务中心 worktree 有未提交内容、存在数据歧义、备份验证失败或迁移校验失败时停止切换。修复会先在克隆外建立并验证 bundle，保留旧历史、备份引用和 bundle，不自动清理旧数据。
- PowerShell 对应参数为 `-Repair -DryRun`（或只写 `-Repair` 预览）及 `-Repair -Apply`。
- 先在临时克隆完成迁移、恢复和 `check` 验收，再对真实安装执行 repair；执行前另行确认有可恢复的克隆外备份。

建议在发生任务变更时每日备份，并在迁移或修复前强制备份。先在克隆外创建 `<克隆外备份目录>`。以下示例将 bundle 放在那里；bundle 只包含已提交数据：

```bash
git -C "<项目仓库根目录>" bundle create "<克隆外备份目录>/task-center.bundle" refs/heads/task-center
git -C "<项目仓库根目录>" bundle verify "<克隆外备份目录>/task-center.bundle"
```

若设置了非默认 `TASK_BRANCH`，将示例中的 `refs/heads/task-center` 换成实际分支 ref。

在新克隆中恢复并重新登记（使用创建 bundle 时相同的固定模板来源）：

```powershell
pwsh -File "<固定版本模板目录>/scripts/setup-task-center.ps1" -RepoPath "<新克隆目录>" -SourcePath "<固定版本模板目录>" -RestoreBundlePath "<克隆外备份目录>/task-center.bundle"
pwsh -File "<任务中心 worktree>/scripts/task.ps1" init
pwsh -File "<任务中心 worktree>/scripts/task.ps1" list
pwsh -File "<任务中心 worktree>/scripts/task.ps1" check
```

```bash
bash "<固定版本模板目录>/scripts/setup-task-center.sh" --repo "<新克隆目录>" --source "<固定版本模板目录>" --restore-bundle "<克隆外备份目录>/task-center.bundle"
bash "<任务中心 worktree>/scripts/task.sh" init
bash "<任务中心 worktree>/scripts/task.sh" list
bash "<任务中心 worktree>/scripts/task.sh" check
```

reflog 只能作为尽力恢复线索。不要设置任务中心分支的 upstream，不要运行 `push --all` 或 `push --mirror`；本地分支和 hook 不是不可绕过的上传隔离。

## 8. 外部衔接

- 对外引用本地任务时写 `TC-0042`；外部 issue / PR 字段保存完整链接，不用平台编号冒充本地编号。
- 代码 PR 单独提供可审核摘要、验收结果和证据；reviewer 不需要访问本地任务中心分支。
- 不设置 upstream，不依赖 push refspec 作为安全边界。任务中心分支是本地协作约定，不是不可上传的隔离机制。
