# Agent 适配步骤（agent-workflows 模板 → 新项目）

> 给谁用：任意 AI Agent（Codex / opencode / Claude 等）
> 怎么用：把下方**单行命令**粘贴给 Agent，即可自主完成下载与落位；判断性适配工作（替换占位符、换命令、校验、提交）由 Agent 按本文第 3~5 节执行。
>
> 前提：目标新项目已初始化 git 仓库；本仓库已发布到 GitHub（`<owner>/agent-workflows`）。

## 0. 单行命令

**先 `cd` 到新项目根目录**，再执行（二选一，按本机 shell）：

```powershell
irm https://raw.githubusercontent.com/<owner>/agent-workflows/main/scripts/adapt.ps1 | iex
```

```bash
curl -sL https://raw.githubusercontent.com/<owner>/agent-workflows/main/scripts/adapt.sh | bash -s
```

脚本自动完成：

1. 克隆模板仓库（`--depth 1`）到临时目录，用完即删；
2. `templates/*` 复制到 `<新项目>/docs/development/`；
3. `AGENTS.template.md` 复制到项目根目录并改名 `AGENTS.md`（已存在则跳过并警告，需手动合并）；
4. 输出复制后所有残留 `<占位符>` 清单。

## 1. 手动获取模板（备用，脚本失败时用）

```bash
git clone --depth 1 https://github.com/<owner>/agent-workflows.git <临时目录>
```

或逐文件下载：

```
https://raw.githubusercontent.com/<owner>/agent-workflows/main/templates/AGENTS.template.md
https://raw.githubusercontent.com/<owner>/agent-workflows/main/templates/git-workflow-template.md
https://raw.githubusercontent.com/<owner>/agent-workflows/main/templates/collaborative-workflow-template.md
https://raw.githubusercontent.com/<owner>/agent-workflows/main/templates/docs-communication.md
```

## 2. 落位（脚本已完成，手动方式参考）

| 来源 | 目标 |
|------|------|
| `templates/*`（4 个文件） | `<新项目>/docs/development/` |
| `templates/AGENTS.template.md` | `<新项目>/AGENTS.md`（改名） |

## 3. 适配（Agent 判断性工作，必须完成）

1. **确认角色**：本次任务是「开发」角色（把模板适配进新项目），按角色权限行事——本次允许修改/新建项目内文件并提交，但不得越权（如 approve、合并）。
2. **替换全部占位符**，至少包括：

   | 占位符 | 替换为 |
   |--------|--------|
   | `<项目名>` | 新项目名 |
   | `<语言 / 框架 / 版本>` | 项目实际技术栈 |
   | `<命令>` | 项目实际命令（安装/构建/测试/格式化/静态检查/启动） |
   | `<Agent 工具名/角色/身份>` | 本项目约定的 Agent 身份，如 `<工具名>/<角色>` |
   | `<默认分支>` | `main` 或 `master` |
   | `<CI 名称>` | 实际 CI 名（GitHub Actions / GitLab CI 等） |
   | `<维护者>` | 维护者身份 |
   | `<Review 人数>` | 如 `1` |
   | `<Agent 账号>` | Agent 使用的平台账号 |
   | `<任务系统>` | 任务系统名（GitHub Issues 等） |
   | `<Git 工作流文档>` / `<协作工作流文档>` / `<文档通信设计文档>` | 复制后的实际文档路径 |

3. **换实际命令**：按 `docs/development/git-workflow-template.md` 第 5.2 节把 `AGENTS.md` 第 3 节与模板中的命令换成项目真实命令（Rust / Node / Python / Go 等对照表）。
4. **修正相对链接**：各模板之间、`AGENTS.md` 指向 `docs/development/` 的链接，按实际位置修正。
5. **删除不适用章节**：与项目已有规则冲突时保留更具体、更严格的一条；无 Agent 的团队删除协作模板第 11、12 节。
6. 角色权限矩阵（协作模板第 2 节）与标准流程编排（第 3 节）按项目实际角色调整，但保持「开发 / 审核 / 测试」职责分离的默认结构。

## 4. 校验（未通过不得提交）

- [ ] 全文无残留 `<占位符>`（`grep -rno '<[^<>]\+>' AGENTS.md docs/` 结果为空）
- [ ] 所有 Markdown 链接有效（本地文件路径存在）
- [ ] 无密钥、凭据、`.env`、构建产物进入工作区
- [ ] 权限矩阵、流程编排与模板原文结构一致，未擅自弱化约束
- [ ] 文档内命令与项目实际命令一致

## 5. 提交

- 分支前缀 `<角色>/`：如 `dev/feat/init-collab-templates`
- 提交信息用 Conventional Commits：`docs: 引入多人/多 Agent 协作模板并适配`（或 `chore:`）
- 只提交本次适配相关文件；若项目已有未提交改动，先确认归属
- 提交完成后向用户汇报：落位路径、占位符替换情况、校验结果、遗留事项（如未处理的占位符、AGENTS.md 合并冲突），并等待用户 review，**不得自行合并或推送默认分支**

## 6. 模板后续更新跟进（可选）

- **git submodule**：`git submodule add <模板仓库 URL> docs/development/agent-workflows`
- **git subtree**：`git subtree add --prefix docs/development/agent-workflows <模板仓库 URL> main --squash`
- 或重跑第 0 节脚本到临时目录，用 `git diff` 对比本地上次落位的副本，手动吸收更新（文档与代码同步规则见 `docs/development/docs-communication.md`）