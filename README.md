# Agent Workflows

多人 / 多 Agent 协作的 **Git 工作流模板仓库**：存放可复用的协作规则与模板，供新项目直接复制使用。

本仓库解决两个问题：

- **持久化**：把散落在各个项目里的协作约定沉淀为单一事实来源，随 GitHub 长期保存、可版本化；
- **快速复用**：新项目立项时直接复制模板，替换占位符即可，不用重新设计流程。

## 目录结构

| 路径 | 内容 |
|------|------|
| [templates/](templates/) | 可直接复制到新项目的通用模板（语言无关） |
| [examples/keygateway/](examples/keygateway/) | 真实项目的落地示例（Rust AI 网关） |
| [AGENTS.md](AGENTS.md) | 本仓库自己的 Agent 准则 |
| [README.md](README.md) | 本文件 |

### templates/

| 文件 | 作用 |
|------|------|
| [AGENTS.template.md](templates/AGENTS.template.md) | 新项目的 `AGENTS.md` 模板：项目规则、命令、安全红线、Git 流程入口 |
| [git-workflow-template.md](templates/git-workflow-template.md) | Git 工作流模板（与协作模板配套使用）：提交规范、命令级操作、回退 |
| [collaborative-workflow-template.md](templates/collaborative-workflow-template.md) | 多人 / 多 Agent 协作模板：角色权限、分支所有权、PR/Review、冲突协调 |
| [docs-communication.md](templates/docs-communication.md) | 通用设计指南：让 Git 工作流与项目文档结合，改善人 × Agent 通信（含占位符式落地步骤） |

### examples/keygateway/

KeyGateway（Rust AI API 网关）中完整落地的版本，作为「模板在真实项目里长什么样」的参考：`AGENTS.md`、`git-workflow.md`、`collaborative-workflow.md`、`docs-communication-example.md`。

## 快速开始（新项目使用）

1. 复制模板：

```powershell
Copy-Item -Recurse templates/* <新项目>/docs/development/
```

```bash
cp -r templates/* <新项目>/docs/development/
```

2. 把 `AGENTS.template.md` 放到新项目根目录并改名为 `AGENTS.md`；
3. 按 AGENTS 模板第 0 节替换 `<占位符>`（项目名、技术栈、命令、Agent 工具名/角色/身份）；
4. 把「提交前检查」的命令换成项目实际命令（模板自带 Rust / Node / Python / Go 等对照表）；
5. 同时保留 `collaborative-workflow-template.md` 与 `docs-communication.md`（整套模板按多人 / 多 Agent 协作设计，不覆盖单人场景）；
6. 在 `AGENTS.md` 中链接这些文档，并让第一个 PR 落实「文档同步」字段。

注意：`docs-communication.md` 第 5 节用 `<占位符>` 表示各类文档路径，新项目请按实际目录结构填写，并建立自己的「变更 ↔ 文档」映射矩阵；真实示例见 [examples/keygateway/docs-communication-example.md](examples/keygateway/docs-communication-example.md)。

## 维护方式

- 模板保持**语言无关**：项目特有的命令、路径只能进 `examples/`，不能进 `templates/`；
- 修改模板走分支 + PR（遵循本仓库 [AGENTS.md](AGENTS.md)）；
- 规则冲突时，以使用方项目自己的 `AGENTS.md` 与用户指令为准。

## License

暂未选择开源许可证；对外公开或复用前，请先与作者确认。
