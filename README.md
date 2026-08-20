# Agent Workflows

多人 / 多 Agent 协作的 **Git 工作流模板仓库**：存放可复用的协作规则与模板，供新项目直接复制使用。

本仓库解决两个问题：

- **持久化**：把散落在各个项目里的协作约定沉淀为单一事实来源，随 GitHub 长期保存、可版本化；
- **快速复用**：新项目立项时直接复制模板，替换占位符即可，不用重新设计流程。

## 目录结构

| 路径 | 内容 |
|------|------|
| [templates/](templates/) | 可直接复制到新项目的通用模板（语言无关） |
| [scripts/](scripts/) | Agent 适配脚本（adapt.ps1 / adapt.sh，下载并落位模板） |
| [AGENT-ADAPT-GUIDE.md](AGENT-ADAPT-GUIDE.md) | 给 AI Agent 的模板下载适配步骤（含单行命令） |
| [examples/keygateway/](examples/keygateway/) | 真实项目的落地示例（Rust AI 网关） |
| [AGENTS.md](AGENTS.md) | 本仓库自己的 Agent 准则 |
| [README.md](README.md) | 本文件 |

### templates/

| 文件 | 作用 |
|------|------|
| [AGENTS.template.md](templates/AGENTS.template.md) | 新项目的 `AGENTS.md` 模板：项目规则、命令、安全红线、Git 流程入口 |
| [git-workflow-template.md](templates/git-workflow-template.md) | Git 工作流模板（与协作模板配套使用）：提交规范、命令级操作、回退 |
| [collaborative-workflow-template.md](templates/collaborative-workflow-template.md) | 多人 / 多 Agent 协作模板：角色 × 权限矩阵（开发 / 审核 / 测试职责分离）、标准流程编排（需求→开发→测试→审核→发布）、分支所有权、PR/Review、冲突协调 |
| [docs-communication.md](templates/docs-communication.md) | 通用设计指南：让 Git 工作流与项目文档结合，改善人 × Agent 通信（含占位符式落地步骤） |

### examples/keygateway/

KeyGateway（Rust AI API 网关）中完整落地的版本，作为「模板在真实项目里长什么样」的参考：`AGENTS.md`、`git-workflow.md`、`collaborative-workflow.md`、`docs-communication-example.md`。

## 快速开始（新项目使用）

### 方式一：Agent 快速适配（推荐，有 AI Agent 时）

把单行命令粘贴给任意 AI Agent（先 `cd` 到新项目根目录），即可自主完成下载、落位、适配、校验与提交；完整步骤见 [AGENT-ADAPT-GUIDE.md](AGENT-ADAPT-GUIDE.md)。

```powershell
irm https://raw.githubusercontent.com/sinftkey/agent-workflows/main/scripts/adapt.ps1 | iex
```

```bash
curl -sL https://raw.githubusercontent.com/sinftkey/agent-workflows/main/scripts/adapt.sh | bash -s
```

脚本机械步骤（下载模板、复制到 `docs/development/`、生成 `AGENTS.md`、输出待替换 `{{...}}` 适配占位符清单）见 [scripts/](scripts/)。

### 方式二：手动复制

1. 复制模板（`AGENTS.template.md` 除外，见第 2 步）：

```powershell
Copy-Item -Recurse templates/git-workflow-template.md,templates/collaborative-workflow-template.md,templates/docs-communication.md <新项目>/docs/development/
```

```bash
cp templates/git-workflow-template.md templates/collaborative-workflow-template.md templates/docs-communication.md <新项目>/docs/development/
```

2. **移动** `AGENTS.template.md` 到新项目根目录并改名为 `AGENTS.md`（仅此一份，不留在 `docs/development/` 中，避免双份漂移）；
3. 按 AGENTS 模板第 0 节替换 `{{...}}` 适配占位符（项目名、技术栈、命令、身份等；`<...>` 为命令语法或每次填写的内容，保留不动）；
4. 把「提交前检查」的命令换成项目实际命令（模板自带 Rust / Node / Python / Go 等对照表）；
5. 同时保留 `collaborative-workflow-template.md` 与 `docs-communication.md`（整套模板面向多人 / 多 Agent 协作设计，不面向单人场景；单人无 Agent 的裁剪见 [AGENT-ADAPT-GUIDE.md](AGENT-ADAPT-GUIDE.md) 第 3.5 节裁剪矩阵）；
6. 在 `AGENTS.md` 中链接这些文档，并让第一个 PR 落实「文档同步」字段。

> 注意：方式一执行前，脚本会跳过已存在的 `AGENTS.md` 并提示手动合并（保留更具体、更严格的一条）。

注意：`docs-communication.md` 第 5、6 节为需适配部分，用 `{{...}}` 表示各类文档路径，新项目请按实际目录结构填写，并建立自己的「变更 ↔ 文档」映射矩阵；其余章节可原样保留。真实示例见 [examples/keygateway/docs-communication-example.md](examples/keygateway/docs-communication-example.md)。

## 维护方式

- 模板保持**语言无关**：项目特有的命令、路径只能进 `examples/`，不能进 `templates/`；
- 修改模板走分支 + PR（遵循本仓库 [AGENTS.md](AGENTS.md)）；
- 规则冲突时，以使用方项目自己的 `AGENTS.md` 与用户指令为准；
- 模板后续更新跟进机制（submodule / subtree / 重跑适配脚本 diff）见 [AGENT-ADAPT-GUIDE.md](AGENT-ADAPT-GUIDE.md) 第 6 节。

## License

暂未选择开源许可证；对外公开或复用前，请先与作者确认。
