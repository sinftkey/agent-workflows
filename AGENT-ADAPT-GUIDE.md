# Agent 适配步骤（agent-workflows 模板 → 新项目）

> 给谁用：任意 AI Agent（Codex / opencode / Claude 等）
> 怎么用：把下方**单行命令**粘贴给 Agent，即可自主完成下载与落位；判断性适配工作（替换占位符、换命令、校验、提交）由 Agent 按本文第 3~5 节执行。
>
> 前提：目标新项目已初始化 git 仓库；本仓库已发布到 GitHub（`sinftkey/agent-workflows`）。
>
> 安全提示：单行命令通过管道从远程执行脚本（`irm | iex` / `curl | bash`）。执行前请确认命令来自本仓库（`https://github.com/sinftkey/agent-workflows`），或先下载脚本到本地审阅后再执行。

## 0. 单行命令

**先 `cd` 到新项目根目录**，再执行（二选一，按本机 shell）：

```powershell
irm https://raw.githubusercontent.com/sinftkey/agent-workflows/main/scripts/adapt.ps1 | iex
```

```bash
curl -sL https://raw.githubusercontent.com/sinftkey/agent-workflows/main/scripts/adapt.sh | bash -s
```

需要指定本地模板目录、落位目标或换仓库源时，可用环境变量 `ADAPT_SOURCE` / `ADAPT_TARGET` / `ADAPT_REPO`，或用参数 `-Source` / `-Target` / `-Repo`；优先级：环境变量 > 参数 > 默认值。两个脚本接口一致。

脚本自动完成：

1. 克隆模板仓库（`--depth 1`）到临时目录，用完即删；
2. 通用 `templates/` 内容复制到 `{{新项目}}/docs/development/`，跳过 `AGENTS.md` 和可选的 `task-center/`（见第 2 节）；
3. `templates/AGENTS.md` 复制到项目根目录，文件名不变（已存在则跳过并警告，需手动合并）；
4. `.gitattributes`、`.gitignore` 复制到项目根目录（已存在则跳过并警告，需手动合并）；
5. 输出复制后所有残留 `{{...}}` 适配占位符清单（`<...>` 是命令语法或每次填写的内容，不在清单内）。

## 1. 手动获取模板（备用，脚本失败时用）

```bash
git clone --depth 1 https://github.com/sinftkey/agent-workflows.git {{临时目录}}
```

或逐文件下载：

```
https://raw.githubusercontent.com/sinftkey/agent-workflows/main/templates/AGENTS.md
https://raw.githubusercontent.com/sinftkey/agent-workflows/main/templates/git-workflow.md
https://raw.githubusercontent.com/sinftkey/agent-workflows/main/templates/collaborative-workflow.md
https://raw.githubusercontent.com/sinftkey/agent-workflows/main/templates/docs-communication.md
```

## 2. 落位（脚本已完成，手动方式参考）

| 来源 | 目标 |
|------|------|
| 通用模板内容（排除 `AGENTS.md` 与可选的 `task-center/`） | `{{新项目}}/docs/development/` |
| `templates/AGENTS.md` | `{{新项目}}/AGENTS.md`（仅此一份，不落入 `docs/development/`） |
| `.gitattributes`、`.gitignore` | `{{新项目}}/`（已存在则跳过并手动合并） |

## 3. 适配（Agent 判断性工作，必须完成）

1. **确认角色**：本次任务是「开发」角色（把模板适配进新项目），按角色权限行事——本次允许修改/新建项目内文件并提交，但不得越权（如 approve、合并）。
2. **替换全部 `{{...}}` 适配占位符**，完整清单按文件分组如下（以第 0 节脚本输出的清单为准，若脚本输出与下表不一致以脚本为准）：

   **AGENTS.md（来自 templates/AGENTS.md）**

   | 占位符 | 替换为 |
   |--------|--------|
   | `{{项目名}}` | 新项目名 |
   | `{{语言 / 框架 / 版本}}` | 项目实际技术栈 |
   | `{{命令}}` | 项目实际命令（安装/构建/测试/格式化/静态检查/启动） |
   | `{{身份}}` | 本项目约定的身份（Agent 工具名或人员名，任选其一） |
   | `{{Git 工作流文档}}` / `{{协作工作流文档}}` / `{{文档通信设计文档}}` | 复制后的实际文档路径 |
   | `{{源码目录}}` / `{{文档目录}}` / `{{配置目录}}` | 项目实际目录 |
   | `{{说明}}` | 目录说明 |
   | `{{一句话描述项目}}`、`{{当前阶段 / 目标；如有路线图文档则附链接}}`、`{{关键依赖或外部服务}}`、`{{运行、部署或性能约束}}`、`{{命名 / 风格约定}}`、`{{错误处理约定}}`、`{{日志约定}}`、`{{敏感目录 / 文件清单，如 .env、密钥库}}`、`{{其他必须遵守的安全约束}}`、`{{业务关键流程，按项目实际填写，例如请求处理顺序、数据流、权限模型}}` | 按名称语义填写项目实际内容 |

   **docs/development/git-workflow.md**

   | 占位符 | 替换为 |
   |--------|--------|
   | `{{默认分支}}` | `main` 或 `master` |
   | `{{身份}}` | 同上 |
   | `{{包管理器}}` | 实际包管理器（`npm` / `pnpm` / `yarn` / `cargo` 等） |
   | `{{CI 名称}}` | 实际 CI 名（GitHub Actions / GitLab CI 等） |
   | `{{维护者}}` | 维护者身份 |
   | `{{Review 人数}}` | 如 `1` |

   **docs/development/collaborative-workflow.md**

   | 占位符 | 替换为 |
   |--------|--------|
   | `{{默认分支}}`、`{{身份}}`、`{{CI 名称}}`、`{{维护者}}`、`{{Review 人数}}` | 同上 |
| `{{Agent 账号}}` | Agent 使用的平台账号 |
| `{{任务系统}}` | 任务系统名（如 GitHub Issues）；若使用本地任务中心，填写「任务中心」，并按本节第 8 步单独启用 |

   **docs/development/docs-communication.md**（第 5、6 节为需适配部分，其余可原样保留）

   | 占位符 | 替换为 |
   |--------|--------|
   | `{{配置规范文档}}`、`{{接口文档}}`、`{{错误处理文档}}`、`{{对应模块的实现文档}}`、`{{认证与密钥文档}}`、`{{架构文档}}`、`{{项目根 AGENTS.md / CONTRIBUTING.md}}`、`{{README}}`、`{{AGENTS.md}}`、`{{文档目录}}` | 项目实际文档路径 |

   保留不动：`<...>`（命令语法或每次填写的内容，如 `<file>`、`<commit>`、`<type>`、`<主题>`、`<任务编号>`、`closes #<外部 issue 编号>`、PR 模板字段），不是适配项。本地任务中心编号写 `TC-0042`，不能用 `#42` 冒充平台 issue 编号。

3. **换实际命令**：按 `docs/development/git-workflow.md` 第 5.2 节把 `AGENTS.md` 第 3 节与模板中的命令换成项目真实命令（Rust / Node / Python / Go 等对照表）。
4. **修正相对链接**：各模板之间、`AGENTS.md` 指向 `docs/development/` 的链接，按实际位置修正。
5. **删除不适用章节**：与项目已有规则冲突时保留更具体、更严格的一条；场景裁剪按下表（一处维护，README 引用本表）：

   | 场景 | AGENTS.md | git-workflow 模板 | 协作模板 | docs-communication |
   |------|-----------|-------------------|----------|--------------------|
   | 单人无 Agent | 保留全部 | 保留；删第 12 节「多 Agent 协作」 | 删第 11、12 节（Agent 行为规范、多 Agent 并行） | 保留（第 5、6 节适配） |
   | 多人无 Agent | 保留全部 | 保留 | 保留；删第 11、12 节 | 保留 |
   | 多人多 Agent | 保留全部 | 保留全部 | 保留全部 | 保留 |
| 角色不足（如 2 人团队、无专职测试） | 保留全部 | 保留 | 保留；由维护者授权开发兼任测试并在任务登记中声明，或显式降级为「开发自验 + 审核对账」并写明证据等级下降 | 保留 |

6. 角色权限矩阵（协作模板第 2 节）与标准流程编排（第 3 节）按项目实际角色调整，但保持「开发 / 审核 / 测试」职责分离的默认结构。
7. **抽取 PR 模板**：把 git-workflow 模板第 7 节内容抽取为 `.github/PULL_REQUEST_TEMPLATE.md`（GitHub；其他平台放对应位置，如 GitLab 的 `.gitlab/merge_request_templates/`），让 PR 模板在真实 PR 中生效。
8. **任务中心（可选）**：若不用外部任务系统，或希望 Agent 使用本地任务操作面，取得与其余模板相同 tag / 提交的完整模板仓库 checkout，再运行其中独立的 `scripts/setup-task-center.ps1` 或 `scripts/setup-task-center.sh`，显式指定项目仓库与该固定来源。不要把 `templates/task-center/` 复制到项目代码分支的 `docs/tasks/` 或 `docs/development/`，也不要把本地安装路径写入项目 `AGENTS.md`。setup 会把运行资产放到本地 `task-center` 孤儿分支和共享 worktree，并登记在 Git 元数据中；它不会改写使用方代码分支中的文件。安装后按协议运行 `init`、`list`、`check`。setup 会输出工具无关的 Agent 引导语；安装到用户级指令的位置前，先按目标工具自己的文档核对实际机制，不假设路径或加载顺序，也不自动改写全局指令文件。未启用时应明确告知 Agent，不得静默安装。

## 4. 校验（未通过不得提交）

- [ ] 全文无残留 `{{...}}` 适配占位符（校验命令见下；`<...>` 语法占位符不在校验范围）
  - bash：`grep -rnoE '{{[^{}]+}}' AGENTS.md docs/`（应无输出）
  - PowerShell：`Get-ChildItem AGENTS.md, docs -Recurse -Filter *.md | Select-String -Pattern '\{\{[^{}]+\}\}' -Encoding UTF8`（应无输出）
- [ ] 所有 Markdown 链接有效（本地文件路径存在）
- [ ] PR 模板已抽取落位（`.github/PULL_REQUEST_TEMPLATE.md` 或对应平台位置，见第 3 节步骤 7）
- [ ] 任务中心已按 `TASK-CENTER.md` 初始化（如启用）：同一克隆内登记唯一、worktree 与版本有效；运行 `init` / `list` / `check`；任务中心资产未复制到项目代码分支，且代码分支没有因启用任务中心而新增文件
- [ ] 无密钥、凭据、`.env`、构建产物进入工作区
- [ ] 权限矩阵、流程编排与模板原文结构一致，未擅自弱化约束
- [ ] 文档内命令与项目实际命令一致

## 5. 提交

- 分支前缀 `{{身份}}/`：如 `zcode/feat/init-collab-templates`
- 提交信息用 Conventional Commits：`docs: 引入多人/多 Agent 协作模板并适配`（或 `chore:`）
- 只提交本次适配相关文件；若项目已有未提交改动，先确认归属
- 提交完成后向用户汇报：落位路径、占位符替换情况、校验结果、遗留事项（如未处理的占位符、AGENTS.md 合并冲突），并等待用户 review，**不得自行合并或推送默认分支**

## 6. 模板后续更新跟进（可选）

- **git submodule**：`git submodule add https://github.com/sinftkey/agent-workflows.git docs/development/agent-workflows`
- **git subtree**：`git subtree add --prefix docs/development/agent-workflows https://github.com/sinftkey/agent-workflows.git main --squash`
- 或重跑第 0 节脚本到临时目录，用 `git diff` 对比本地上次落位的副本，手动吸收更新（文档与代码同步规则见 `docs/development/docs-communication.md`）
- 跟进时建议 pin 到版本 tag 而不是跟随默认分支漂移（本仓库版本记录见 [CHANGELOG.md](CHANGELOG.md)）
