# Git 工作流模板（适用于任意项目类型）

> 这是一份**模板**，不是某个仓库的既定规则。整套模板面向**多人 / 多 Agent 协作**设计，本模板与 [collaborative-workflow-template.md](collaborative-workflow-template.md) 配套使用，不单独覆盖单人场景。复制到新项目后，按「0. 使用说明」完成适配。落位方式二选一：用 `scripts/adapt.*` 自动落位到 `docs/development/`（推荐，本模板即在此目录），或作为 `CONTRIBUTING.md` / 团队 Wiki 的基底手动放置；新项目的 `AGENTS.md` 用 [AGENTS.template.md](AGENTS.template.md) 生成。

## 0. 使用说明

适配步骤：

1. 替换所有 `{{...}}` 适配占位符（`<...>` 为命令语法或每次填写的内容，保留不动）；
2. 把第 5 节「提交前检查」换成项目实际的命令（对照表见 5.2）；
3. 删除不适用的章节（例如没有 AI Agent 就删掉第 12 节）；
4. 与项目已有规则冲突时，保留更具体、更严格的一条，并注明冲突时以哪份为准；
5. 模板假设默认分支为 `main`/`master` 且采用 trunk-based；团队使用 GitFlow 时按 3.2 调整。

常用占位符：`{{默认分支}}`、`{{身份}}`、`{{包管理器}}`、`{{CI 名称}}`、`{{维护者}}`、`{{Review 人数}}`。

本模板与同目录其他模板的分工：

| 模板 | 维护内容 |
|------|----------|
| [AGENTS.template.md](AGENTS.template.md) | 项目规则、常用命令、安全红线；作为新项目的 `AGENTS.md` |
| 本模板 | 提交规范、命令级操作、本地检查、回退；PR 模板与基础 Review 清单 |
| [collaborative-workflow-template.md](collaborative-workflow-template.md) | 角色权限、任务认领、多人 / 多 Agent 并行、冲突协调、发布节奏 |
| [docs-communication.md](docs-communication.md) | 文档如何与代码同步（通信设计） |

## 1. 核心原则（语言无关，可直接保留）

1. 默认分支永远可构建、可运行、可部署；
2. 所有变更走分支 + PR / 合并请求；
3. 一次提交只做一件事，提交信息能说明「改了什么、为什么」；
4. 提交前必须通过项目规定的检查（格式化 / 静态检查 / 测试 / 构建）；
5. 密钥与凭据绝不进版本库；
6. 有 AI Agent 参与时，**人类对最终合并负责**。

## 2. 角色与权限

角色职责与权限矩阵（含分支保护建议）由 [collaborative-workflow-template.md](collaborative-workflow-template.md) 第 2 节统一维护，本模板不重复。要点：维护者负责合并决策与发布；有 AI Agent 参与时，Agent 按所扮演角色行事（开发 / 审核 / 测试），审核角色可 approve 但无提交权，**合并与发布必须由维护者执行**。

## 3. 分支模型

### 3.1 默认推荐：Trunk-based

- 长期分支：`{{默认分支}}`；
- 短期功能分支：数天内完成并合并，合并后删除；
- 需要固定版本时：`release/vX.Y.Z`（只收 bugfix）；
- 线上紧急修复：`hotfix/<主题>`，从 `{{默认分支}}` 或最近 tag 创建。

### 3.2 备选：GitFlow

固定周期发布、多版本并行维护时使用：

```text
{{默认分支}}（生产） + develop（集成） + feature/ + release/ + hotfix/
```

选择 GitFlow 意味着流程更重，提交与合并规则按团队约定补充。

### 3.3 分支命名

```text
{{身份}}/<type>/<主题>                  # 例：zcode/feat/login
{{身份}}/<任务编号>-<type>-<主题>       # 例：zcode/42-fix-timeout
```

`type` 与提交规范一致：`feat` / `fix` / `docs` / `refactor` / `test` / `chore`；`hotfix`、`release` 作为特殊前缀单独使用。`{{身份}}` = Agent 工具名或人员名，任选其一。多人 / 多 Agent 场景的任务编号与分支所有权约定见 [collaborative-workflow-template.md](collaborative-workflow-template.md) 第 4.2、5 节。

## 4. 提交规范（语言无关）

建议 Conventional Commits：

```text
<type>: <描述>

正文说明：为什么改、怎么验证、影响范围。
```

示例：

```text
feat: 新增登录接口

支持邮箱 + 密码登录，并补充 token 刷新流程。
验证：npm test 通过、CI 通过。
```

常用 type：

| type | 用途 |
|------|------|
| `feat` | 新功能 |
| `fix` | 缺陷修复 |
| `docs` | 文档改动 |
| `refactor` | 重构，行为不变 |
| `test` | 测试新增/修改 |
| `chore` | 构建、依赖、配置等杂项 |

## 5. 提交前检查

### 5.1 通用条目（任何项目都执行）

1. 格式化（format）通过；
2. 静态检查（lint / type check）通过；
3. 测试（test）通过；
4. 构建（build）通过；
5. `git diff --check` 无空白错误；
6. `git status --short` 中只有本任务改动；
7. 无密钥、凭据、`.env`、构建产物、大文件。

### 5.2 按项目类型替换命令

| 项目类型 | 格式化 | 静态检查 | 测试 | 构建 |
|----------|--------|----------|------|------|
| Rust | `cargo fmt --check` | `cargo clippy -- -D warnings` | `cargo test` | `cargo build` |
| Node.js / TypeScript | `prettier --check .` | `eslint .`（+ `tsc --noEmit`） | `npm test` / `vitest run` | `npm run build` |
| Python | `ruff format --check .` / `black --check .` | `ruff check .`（+ `mypy .`） | `pytest` | 打包/构建（如需要） |
| Go | `gofmt -l .` | `go vet ./...`（+ `golangci-lint run`） | `go test ./...` | `go build ./...` |
| Java / Kotlin | `spotlessCheck` / `ktlintCheck` | `gradle checkstyleMain` / `ktlint` | `gradle test` | `gradle build` |
| 文档站点 | `markdownlint .` | `vale .`（可选） | — | `npm run build`（如需要） |
| 基础设施 / 配置仓库（IaC） | `terraform fmt -check` | `terraform validate` | `pytest`（可选，测 plan 逻辑） | `terraform plan`（合并前审核） |

> 使用 `{{包管理器}}` 的项目把 `npm` 替换为 `pnpm` / `yarn` 等；新项目类型在此表追加。

## 6. 分支与 PR 流程

1. `git fetch`，基于最新 `{{默认分支}}` 创建分支；
2. 小步提交，每个提交独立可验证；
3. 推送前同步最新 `{{默认分支}}`（未共享分支用 rebase）并跑完整检查；
4. `git push -u origin <分支>`；
5. 创建 PR，填写 PR 模板（见第 7 节）；
6. `{{CI 名称}}` 自动检查；
7. Reviewer 审查，作者在分支上新增提交回应反馈（不 force push 已推送分支）；
8. 满足保护规则后由 `{{维护者}}` 合并；
9. 合并后删除分支；
10. 全员 `git fetch --prune` 同步。

## 7. PR 模板

```text
## 关联任务
closes #<任务编号>

## 改动概述
<一到三句话说明改了什么、为什么>

## 验证结果
- [ ] 格式化通过
- [ ] 静态检查通过
- [ ] 测试通过
- [ ] 构建通过
- [ ] `{{CI 名称}}` 通过

## 影响范围
<改动的文件/模块、接口变化、是否需要迁移>

## 文档同步
- [ ] 已更新：<列出文档路径>
- [ ] 无需更新（说明理由）

## 安全声明
<是否涉及密钥、权限、日志脱敏等>

## 请 reviewer 重点看
<你最不确定的部分>
```

## 8. Review 检查清单（语言无关）

- [ ] 逻辑正确，边界与异常路径已处理
- [ ] 关键路径有测试覆盖
- [ ] 无密钥、凭据、`.env`、大文件
- [ ] 命名与风格一致，无调试残留
- [ ] 文档已同步
- [ ] 无夹带无关改动
- [ ] 错误处理与日志合理

> 多人 / 多 Agent 场景的 Review 补充检查与 approve 规则见 [collaborative-workflow-template.md](collaborative-workflow-template.md) 第 8 节。

## 9. 合并策略

- 默认 **Squash and merge**，保持 `{{默认分支}}` 历史线性；
- 需要保留协作分支历史时用普通 merge commit（由 `{{维护者}}` 决定）；
- 禁止直接向 `{{默认分支}}` 提交；禁止对已推送分支 force push；
- 合并后删除远程与本地分支。

## 10. 回退与撤销（git 命令本身语言无关）

| 场景 | 命令 | 说明 |
|------|------|------|
| 撤销暂存 | `git restore --staged <file>` | 不丢文件 |
| 丢弃未提交改动 | `git restore <file>` | 不可恢复，先确认 |
| 修改最近提交（未推送） | `git commit --amend` | 禁止用于已推送提交 |
| 撤销最近提交但保留改动 | `git reset --soft HEAD~1` | 改动回到暂存区 |
| 撤销已推送提交 | `git revert <commit>` | 生成反向提交 |

除非用户明确要求，禁止：`git reset --hard`、`git checkout -- .`、`git clean -fdx`、`git push --force`。

## 11. 安全红线（语言无关）

- `.env`、密钥文件、配置文件中的真实凭据绝不提交；
- 提交前检查 `git status` 与 `.gitignore`，确认没有凭据或构建产物；
- 误提交密钥：立即 `git rm --cached` → **轮换密钥**（视为已泄露）→ 更新 `.gitignore`；已推送时清理历史需维护者决策；
- 大文件使用 LFS 或外部存储，不直接入库；
- 涉及权限、加密、支付等敏感模块时，**至少 1 个人类 approve**（人类 = 人员，不含 Agent），并由 `{{维护者}}` 合并；Review 人数见第 8 节与协作模板第 8.2 节。

## 12. 多 Agent 协作（无 AI 参与时删除本节）

多人 / 多 Agent 协作规则由 [collaborative-workflow-template.md](collaborative-workflow-template.md) 统一维护，本节只留要点：

- 任务必须有 owner（人类或 Agent），分支名带任务编号；
- **角色权限分离**：开发写生产代码（自验测试不提交）、审核只提意见不提交、测试只提交测试文件（详见协作模板第 2 节权限矩阵）；
- 同一分支同一时间只允许一个写入者，冲突时先沟通、不单方面覆盖；
- Agent 之间可互审机械问题，审核 Agent 可 approve，**合并与发布必须由维护者执行**；
- Agent 账号不授予默认分支直接推送权限。

## 13. 提交 / 合并检查清单（最终版）

- [ ] 格式化、静态检查、测试、构建全部通过
- [ ] PR 描述完整（任务、概述、验证、影响、文档同步、安全声明、请 reviewer 重点看）
- [ ] `{{CI 名称}}` 通过
- [ ] Review approve 数达到 `{{Review 人数}}`
- [ ] 无密钥与无关文件
- [ ] 合并策略符合约定（默认 squash）
- [ ] 合并后分支已删除，全员已同步

> 多人 / 多 Agent 场景的协作特有清单（角色合规、人类终审、验证证据来源等）见 [collaborative-workflow-template.md](collaborative-workflow-template.md) 第 13 节。
