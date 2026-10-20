# Agent Workflows

多人 / 多 Agent 协作的 **Git 工作流模板仓库**：存放可复用的协作规则与模板，供新项目直接复制使用。

本仓库解决两个问题：

- **持久化**：把散落在各个项目里的协作约定沉淀为单一事实来源，随 GitHub 长期保存、可版本化；
- **快速复用**：新项目立项时直接复制模板，替换占位符即可，不用重新设计流程。

## 目录结构

| 路径 | 内容 |
|------|------|
| [templates/](templates/) | 可直接复制到新项目的通用模板（语言无关） |
| [examples/workflow-small-fix.md](examples/workflow-small-fix.md) | 优化方案的最小正常路径与操作账单示例，尚未真实运行，不是现行模板操作指令 |
| [docs/workflow-optimization-summary.md](docs/workflow-optimization-summary.md) | A–D 阶段改动、实际验证范围与保留项汇总；历史讨论及逐轮记录见归档索引 |
| [scripts/](scripts/) | Agent 适配脚本（adapt.ps1 / adapt.sh）与任务中心安装、修复引导器（setup-task-center.ps1 / setup-task-center.sh） |
| [.gitattributes](.gitattributes) | 文本属性 / 行尾规则，随模板一起复制到新项目 |
| [.gitignore](.gitignore) | 通用忽略规则，随模板一起复制到新项目 |
| [AGENT-ADAPT-GUIDE.md](AGENT-ADAPT-GUIDE.md) | 给 AI Agent 的模板下载适配步骤（含单行命令） |
| [AGENTS.md](AGENTS.md) | 本仓库自己的 Agent 准则 |
| [CHANGELOG.md](CHANGELOG.md) | 版本变更记录（模板发版打 tag 的基线） |
| [LICENSE](LICENSE) | MIT 许可证 |
| [README.md](README.md) | 本文件 |

### templates/

| 文件 | 作用 |
|------|------|
| [AGENTS.md](templates/AGENTS.md) | 新项目的 `AGENTS.md` 模板：项目规则、命令、安全红线、Git 流程入口 |
| [git-workflow.md](templates/git-workflow.md) | Git 工作流模板（与协作模板配套使用）：提交规范、命令级操作、回退 |
| [collaborative-workflow.md](templates/collaborative-workflow.md) | 多人 / 多 Agent 协作模板：角色 × 权限矩阵（开发 / 审核 / 测试职责分离）、标准流程编排（需求→开发→测试→审核→发布）、分支所有权、PR/Review、冲突协调 |
| [docs-communication.md](templates/docs-communication.md) | 通用设计指南：让 Git 工作流与项目文档结合，改善人 × Agent 通信（含占位符式落地步骤） |
| [task-center/](templates/task-center/) | 可选的同一克隆本地任务中枢：任务文件是唯一数据源，INDEX 自动生成；Bash / PowerShell 命令提供状态校验、全局写锁、隔离暂存和可恢复事务；由独立 setup 安装在孤儿分支和共享 worktree，不落入项目代码分支 |
| [task-center-v2/](templates/task-center-v2/) | 阶段 D 的结构化候选实现（tool 2 / schema 3）：共享核心、文件请求、明确读写授权、依赖纠正、离线运行时与显式迁移；D1-c2 已在限定范围内复核接受，完整发布条件仍未证明 |

## 快速开始（新项目使用）

### 方式一：Agent 快速适配（推荐，有 AI Agent 时）

把单行命令粘贴给任意 AI Agent（先 `cd` 到新项目根目录），即可自主完成下载、落位、适配、校验与提交；完整步骤见 [AGENT-ADAPT-GUIDE.md](AGENT-ADAPT-GUIDE.md)。

```powershell
irm https://raw.githubusercontent.com/sinftkey/agent-workflows/main/scripts/adapt.ps1 | iex
```

```bash
curl -sL https://raw.githubusercontent.com/sinftkey/agent-workflows/main/scripts/adapt.sh | bash -s
```

脚本机械步骤（下载通用模板、复制到 `docs/development/`、生成 `AGENTS.md`、复制 `.gitattributes` / `.gitignore`、输出待替换 `{{...}}` 适配占位符清单）见 [scripts/](scripts/)。适配脚本会跳过可选的 `templates/task-center/` 和 `templates/task-center-v2/`；如需启用，请按下方说明使用独立 setup。参数接口两个脚本一致：环境变量 `ADAPT_REPO`（模板仓库地址）、`ADAPT_SOURCE`（本地模板目录，跳过克隆）、`ADAPT_TARGET`（落位目标目录，默认当前目录），优先级环境变量 > 命令行参数；直接执行脚本时也可用 `-Repo` / `-Source` / `-Target` 参数。

### 方式二：手动复制

1. 复制模板（`templates/AGENTS.md` 除外，见第 2 步）：

```powershell
New-Item -ItemType Directory -Force <新项目>/docs/development/
Copy-Item templates/git-workflow.md,templates/collaborative-workflow.md,templates/docs-communication.md <新项目>/docs/development/
```

```bash
mkdir -p <新项目>/docs/development
cp templates/git-workflow.md templates/collaborative-workflow.md templates/docs-communication.md <新项目>/docs/development/
```

2. 保留来源仓库的 `templates/AGENTS.md`，将其**复制**为新项目根目录的 `AGENTS.md`；若目标文件已存在，则跳过覆盖并手动比对合并。新项目仅在根目录维护这一份，不在 `docs/development/` 中另存副本，避免双份漂移；
3. 复制 `.gitattributes`、`.gitignore` 到新项目根目录（已存在则跳过，手动合并）；
4. 按 AGENTS 模板第 0 节替换 `{{...}}` 适配占位符（项目名、技术栈、命令、身份等；`<...>` 为命令语法或每次填写的内容，保留不动）；
5. 把「提交前检查」的命令换成项目实际命令（模板自带 Rust / Node / Python / Go 等对照表）；
6. 同时保留 `collaborative-workflow.md` 与 `docs-communication.md`（整套模板面向多人 / 多 Agent 协作设计，不面向单人场景；单人无 Agent 的裁剪见 [AGENT-ADAPT-GUIDE.md](AGENT-ADAPT-GUIDE.md) 第 3 节步骤 5 的裁剪矩阵）；
7. 在 `AGENTS.md` 中链接这些文档，并让第一个 PR 落实「文档同步」字段。

> 注意：方式一只对目标根目录已存在的 `AGENTS.md`、`.gitattributes`、`.gitignore` 跳过覆盖并提示手动合并；`docs/development/` 中的同名通用模板文档会被覆盖。已有适配文档或准备重跑时，先将 `ADAPT_TARGET` 指向独立临时落位目录，再比对并手动合并到项目；已有任务中心副本的处理与具体步骤见 [适配指南第 0 节](AGENT-ADAPT-GUIDE.md#0-单行命令)。

注意：`docs-communication.md` 第 5、6 节为需适配部分，用 `{{...}}` 表示各类文档路径，新项目请按实际目录结构填写，并建立自己的「变更 ↔ 文档」映射矩阵；其余章节可原样保留。

### 任务中心（可选）

任务中心供同一份本地克隆内的多个会话使用。它的协议、脚本和任务数据保存在本地 `task-center` 孤儿分支及一个共享 worktree 中；setup 登记路径并维护本地忽略规则，不修改使用方代码分支里的 `AGENTS.md`、`.gitignore`、开发文档或其他已跟踪文件。它不推送任务分支、不设置 upstream，也不提供跨克隆同步。

从固定版本的模板仓库 checkout 运行 setup；脚本和 `templates/task-center/` 资产必须来自同一 tag 或提交：

```powershell
pwsh -File "<固定版本模板目录>/scripts/setup-task-center.ps1" -RepoPath "<项目仓库根目录>" -SourcePath "<固定版本模板目录>"
pwsh -File "<任务中心 worktree>/scripts/task.ps1" init
pwsh -File "<任务中心 worktree>/scripts/task.ps1" list
pwsh -File "<任务中心 worktree>/scripts/task.ps1" check
```

```bash
bash "<固定版本模板目录>/scripts/setup-task-center.sh" --repo "<项目仓库根目录>" --source "<固定版本模板目录>"
bash "<任务中心 worktree>/scripts/task.sh" init
bash "<任务中心 worktree>/scripts/task.sh" list
bash "<任务中心 worktree>/scripts/task.sh" check
```

写命令前设置能区分并发会话的 `TASK_IDENTITY`，并阅读任务中心 worktree 中的 `TASK-CENTER.md`。用户级 Agent 指令示例由 setup 输出；安装位置和加载规则须按目标工具实际文档核对，setup 不自动修改用户全局指令。未启用任务中心时，Agent 应告知用户，不得静默创建。

安装要求项目已有至少一个 Git 提交；不支持 bare 仓库或网络共享文件系统。脚本当前会拒绝低于 Git 2.23 的版本，但最低版本和各平台兼容性仍需发布前验证，不能据此视为已保证支持。

迁移与修复流程为：先运行 `setup-task-center` 的 repair 预览；确认克隆外备份和迁移计划后，才显式执行。PowerShell 使用 `-Repair -DryRun` / `-Repair -Apply`，Bash 使用 `--repair --dry-run` / `--repair --apply`。恢复、bundle 备份、版本与字段规则见 [任务中心协议](templates/task-center/TASK-CENTER.md)。

### 结构化任务中心候选（阶段 D）

这是独立的 tool 2 / schema 3 实现，入口为 [setup-task-center-v2.ps1](scripts/setup-task-center-v2.ps1) / [setup-task-center-v2.sh](scripts/setup-task-center-v2.sh)，不会自动升级上述旧安装。两端使用同一 Python 核心，JSON 文件承载请求和响应；24 个写动作、7 种读能力、恢复与管理入口见[候选使用说明](templates/task-center-v2/TASK-CENTER.md)。业务模板保持语言无关，工具运行本身需要受支持的 Python 和固定离线依赖。

先在联网准备机按 [Windows 运行时锁](runtime/task-center/windows-cp312.lock.json)或 [Linux 运行时锁](runtime/task-center/linux-cp312.lock.json)获取并核对 wheel；[准备脚本](scripts/prepare-task-center-runtime.py)只从明确提供的本地 wheel 目录安装至新的隔离目录，并生成逐文件 hash 锁，不改全局环境。任务命令不会自动联网或安装。当前仅有候选运行时，安装与迁移必须显式指定 `--candidate` 并限于隔离仓库；不能据此安装到真实项目。平台实测、首次失败和修订、发布限制、操作成本及固定复核入口统一见[阶段 D 报告](optimization-stage-d-report.md)，复现方法见[隔离验证说明](tests/STRUCTURED-README.md)。

D1-c1 独立复核发现的三项 P2 已在 D1-c2 修订并经独立复核关闭，用户已接受：每份交付保留消费关系，历史代录核对原指派资格，恢复旧格式前在预览与锁内拦截业务 pending。实际验证范围和接受依据见[A–D 汇总](docs/workflow-optimization-summary.md)，完整发布条件不据此补判通过。

新安装先 `install-preview`，再以显式 policy 和确认来源执行 `install-apply`；已有旧任务数据先 `migrate-preview`，核对克隆外 bundle、逐文件备份和固定计划后，才允许 `migrate-apply`。迁移保留旧终态及证据未知，不把旧角色转成新授权；有后继事实时拒绝恢复旧格式。旧客户端普通命令及 recover 都拒绝新格式，所有写入共用克隆级锁。此处说明实现能力，未授权实际业务数据迁移或阶段 E。

## 维护方式

### 工作流优化方案与阶段实施

先读[A–D 阶段改动汇总](docs/workflow-optimization-summary.md)了解实际成果，再从[执行交接](execution-handoff.md)进入[当前安排](optimization-trial-arrangement.md)。阶段决定只维护当前安排，E 按用户要求暂停推进；本轮不从旧提示词自动续做任务。

[统一方案](optimization-plan.md)、[正常路径与操作账单](examples/workflow-small-fix.md)、[异常推演](optimization-exception-cases.md)和[成本标准](optimization-trial-criteria.md)保留语义与试用依据。三类发现性任务已交付，但匹配基线、H/A 和总成本收益仍未知，不补判完整 A/B 达标。

设计资料为 [C1 信息模型](optimization-stage-c-design.md)及其[概念示意](examples/workflow-stage-c-small-fix.json)、[C2 契约](optimization-stage-c-spec.md)、[Schema](design/stage-c/protocol.schema.json)、[完整数据示例](examples/workflow-stage-c-complete.json)和[向量](design/stage-c/vectors.json)。四份 C2 技术源保持冻结；D 的实现与复现入口见[技术报告](optimization-stage-d-report.md)和[隔离验证说明](tests/STRUCTURED-README.md)。设计或候选接受不等于发布或真实数据迁移许可。

早期讨论、原 A/B 工作单及逐轮回传集中到[历史归档](docs/archive/workflow-optimization/README.md)。历史“下一步”和未完成状态仅描述当时情况，后续模板变更仍须同步说明并经过 review 后合并。

### 仓库维护规则

- 模板保持**语言无关**：项目特有的命令、路径不能进 `templates/`；如需示例先建 `examples/` 并在本文登记；
- 修改模板走分支 + PR（遵循本仓库 [AGENTS.md](AGENTS.md)）；
- 规则冲突时，以使用方项目自己的 `AGENTS.md` 与用户指令为准；
- 模板后续更新跟进机制（submodule / subtree / 重跑适配脚本 diff）见 [AGENT-ADAPT-GUIDE.md](AGENT-ADAPT-GUIDE.md) 第 6 节；
- 版本化：模板仓库发版打 tag，变更记录见 [CHANGELOG.md](CHANGELOG.md)，跟进方建议 pin 到 tag。

## License

[MIT](LICENSE)（Copyright © 2026 sinftkey），复制、修改、商用均免费，保留版权声明即可。
