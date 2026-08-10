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
| [git-workflow-template.md](templates/git-workflow-template.md) | 个人级 Git 工作流模板：提交规范、命令级操作、回退 |
| [collaborative-workflow-template.md](templates/collaborative-workflow-template.md) | 多人 / 多 Agent 协作模板：角色权限、分支所有权、PR/Review、冲突协调 |
| [docs-communication.md](templates/docs-communication.md) | 设计指南：如何让 Git 工作流与项目文档结合，改善人 × Agent 通信 |

### examples/keygateway/

KeyGateway（Rust AI API 网关）中完整落地的版本，作为「模板在真实项目里长什么样」的参考：`AGENTS.md`、`git-workflow.md`、`collaborative-workflow.md`。

## 快速开始（新项目使用）

1. 复制模板：

```powershell
Copy-Item -Recurse templates/* <新项目>/docs/development/
```

2. 把 `AGENTS.template.md` 放到新项目根目录并改名为 `AGENTS.md`；
3. 按模板第 0 节替换 `<占位符>`（项目名、技术栈、命令、分支前缀、维护者）；
4. 把「提交前检查」的命令换成项目实际命令（模板自带 Rust / Node / Python / Go 等对照表）；
5. 有多个协作者或 AI Agent 时，同时保留 `collaborative-workflow-template.md` 与 `docs-communication.md`；
6. 在 `AGENTS.md` 中链接这些文档，并让第一个 PR 落实「文档同步」字段。

注意：`docs-communication.md` 第 5 节的示例假设目标项目使用 `docs/design`、`docs/implementation`、`docs/api` 目录结构；新项目目录不同时，修正其中的相对链接即可。

## 维护方式

- 模板保持**语言无关**：项目特有的命令、路径只能进 `examples/`，不能进 `templates/`；
- 修改模板走分支 + PR（遵循本仓库 [AGENTS.md](AGENTS.md)）；
- 规则冲突时，以使用方项目自己的 `AGENTS.md` 与用户指令为准。

## License

暂未选择开源许可证；对外公开或复用前，请先与作者确认。
