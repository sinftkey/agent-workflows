# Git 工作流指南

> 本文是 [AGENTS.md](../../AGENTS.md) 第 8 节「Git 工作流」的展开说明，给出在本项目中按规范使用 git 的具体步骤、命令与检查清单。
>
> 多人 / 多 Agent 协作规则见 [collaborative-workflow.md](collaborative-workflow.md)；可复用到其他项目的通用模板见 [git-workflow-template.md](git-workflow-template.md)。

## 1. 核心原则

1. **一个任务一个分支**：新分支统一使用 `<身份>/` 前缀（`<身份>` = Agent 工具名或人员名，任选其一，如 `zcode`）。
2. **提交前必须验证**：`cargo fmt --check`、`cargo clippy -- -D warnings`、`cargo test`、`cargo build` 全部通过。
3. **提交保持聚焦**：一次提交只包含一个可独立描述的功能或修复，不夹带无关改动。
4. **密钥绝不进版本库**：真实 API Key、代理 Key 全文、master key、`config.json`、`.keygateway/` 均不得提交。
5. **先确认再动手**：工作区已有未提交改动时，先确认这些改动属于谁、与当前任务是否相关。

## 2. 环境准备

### 2.1 检查 git 身份

提交前确认用户名与邮箱已设置（当前仓库已配置）：

```powershell
git config user.name
git config user.email
```

如果为空，全局设置一次：

```powershell
git config --global user.name "你的名字"
git config --global user.email "你的邮箱"
```

### 2.2 处理 safe.directory（所有权校验）

本项目曾出现 `detected dubious ownership` 报错（仓库属主与当前用户不同）。若遇到，需要把仓库加入信任列表：

```powershell
git config --global --add safe.directory D:/coding/Code/KeyGateway
```

临时绕过（不写入全局配置）可用：

```powershell
git -c safe.directory=D:/coding/Code/KeyGateway status
```

### 2.3 确认 remote

当前仓库**尚未配置 remote**。需要推送或提 PR 前，先添加远端：

```powershell
git remote add origin <仓库地址>
git remote -v
```

## 3. 任务开始前的检查

每次开始新任务前，先看清工作区状态：

```powershell
git status
git branch --show-current
git log --oneline -5
```

如果工作区是干净的，直接创建分支；如果已有未提交改动：

- 改动属于**当前任务**：先在当前分支上继续，或随分支一起带过去；
- 改动属于**其他任务或他人**：不要动它，先与用户确认归属再继续；
- 不确定：停下来问，不要猜测。

## 4. 创建分支

分支命名建议 `<身份>/<类型>/<简短主题>`（`<身份>` = Agent 工具名或人员名，任选其一，如 `zcode`），类型可选 `feat`、`fix`、`docs`、`refactor`、`test`、`chore`：

```powershell
git switch -c zcode/docs/git-workflow
git switch -c zcode/feat/sse-streaming
```

分支应基于最新的 `master` 创建。分支生命周期：任务完成、合并后即删除，不长期保留。

## 5. 日常工作循环

推荐的循环顺序（不要跳过验证步骤）：

```text
编辑代码 → 格式化 → 静态检查 → 测试 → 审查 diff → 暂存 → 提交
```

### 5.1 编辑与验证

```powershell
# 格式化（用 rustfmt 统一风格）
cargo fmt

# 静态检查
cargo clippy -- -D warnings

# 单元测试
cargo test

# 构建
cargo build
```

### 5.2 审查改动

提交前用 `git diff` 自查，确认没有调试代码、密钥或无关改动：

```powershell
# 查看未暂存改动
git diff

# 检查空白错误（行尾空格、空文件尾等）
git diff --check

# 确认没有意外文件进入待提交列表
git status --short
```

### 5.3 暂存与提交

只暂存与本次提交相关的文件，**不要使用 `git add .` 无差别提交**：

```powershell
git add src/forwarder.rs docs/implementation/sse-streaming.md
git status --short   # 再次确认暂存内容
git commit
```

提交信息规范见第 6 节。

### 5.4 提交前检查清单

对照 AGENTS.md 第 8 节，提交前逐项确认：

- [ ] `cargo fmt --check` 通过
- [ ] `cargo clippy -- -D warnings` 通过
- [ ] `cargo test` 全部通过
- [ ] `cargo build` 成功
- [ ] 无 `dbg!` / `println!` 调试代码（CLI 用户输出除外）
- [ ] `git status --short` 中只有本任务的改动
- [ ] 没有密钥、`config.json`、`.keygateway/`、`target/` 等敏感或忽略文件
- [ ] 提交信息能清晰说明「改了什么、为什么」

## 6. 提交信息规范

建议使用 Conventional Commits 风格：`<type>: <描述>`，描述用中文，正文说明动机与影响。

常用 type：

| type | 用途 |
|------|------|
| `feat` | 新功能 |
| `fix` | 缺陷修复 |
| `docs` | 文档改动 |
| `refactor` | 重构，行为不变 |
| `test` | 测试新增/修改 |
| `chore` | 构建、依赖等杂项 |

示例：

```text
docs: 新增 Git 工作流指南

补充 AGENTS.md 第 8 节的实操细节：分支命名、提交前验证、
提交信息规范、冲突处理与安全回退命令。
```

```text
feat: 实现 SSE 流式转发

在 forwarder 中逐帧透传上游响应，并补充流式传输的单元测试。
```

一次提交只做一件事：如果改动包含多个主题，拆成多个提交。

## 7. 推送与合并

### 7.1 推送分支

```powershell
git push -u origin zcode/feat/sse-streaming
```

### 7.2 创建 PR

```powershell
gh pr create --title "feat: 实现 SSE 流式转发" --body "说明改动内容与验证结果"
```

没有 `gh` 时，用推送成功后终端输出的链接在网页创建。

### 7.3 合并策略

仓库处于早期阶段，建议默认 **Squash and merge**，保持 `master` 历史线性、每条提交都可读。合并前在 PR 描述中附上验证结果（fmt / clippy / test / build 均通过）。

合并完成后：

```powershell
git switch master
git pull
git branch -d zcode/feat/sse-streaming
```

## 8. 冲突处理

分支落后于 `master` 或有冲突时：

```powershell
# 先同步最新 master
git fetch origin

# 方式一：rebase（推荐，保持线性历史，仅用于未推送/可安全改写分支）
git rebase origin/master

# 方式二：merge（已共享的分支用 merge 更稳妥）
git merge origin/master
```

冲突时 git 会标出冲突文件：

```powershell
git status                 # 查看冲突文件列表
git diff                   # 查看冲突标记 <<<<<<< ======= >>>>>>>
```

手动解决冲突的原则：**保留双方意图**，而不是简单选择一边；不确定的代码向用户确认。解决后：

```powershell
git add <已解决的文件>
git rebase --continue      # 如果使用的是 rebase
# 或
git commit                 # 如果使用的是 merge
```

禁止用 `git reset --hard` 或 `git checkout --` 丢弃冲突中他人的工作。

## 9. 撤销与回退（安全操作）

只使用可恢复的操作，避免破坏工作区或历史：

### 9.1 撤销暂存（不丢失文件）

```powershell
git restore --staged <file>
```

### 9.2 丢弃未提交改动（有风险，先确认）

```powershell
git restore <file>         # 丢弃工作区未提交改动，不可恢复
```

使用前先确认该文件确实不需要保留；有疑问就先备份或询问用户。

### 9.3 修改最近一次提交（未推送时）

```powershell
git add <补充的文件>
git commit --amend
```

只允许在**未推送**的提交上使用 `--amend`。

### 9.4 撤销最近一次提交但保留改动

```powershell
git reset --soft HEAD~1
```

改动会回到暂存区，方便重新整理后再次提交。

### 9.5 撤销已推送的提交

```powershell
git revert <commit-hash>
```

用 `revert` 生成反向提交，**不要**对已推送的分支使用 `git reset --hard` 或 `git push --force`。

### 9.6 明确禁止的操作

除非用户明确要求，禁止执行：

```text
git reset --hard
git checkout -- .
git clean -fdx
git push --force
```

这些命令会永久丢失工作区改动或改写共享历史。

## 10. 常见问题

### 10.1 dubious ownership 报错

见第 2.2 节，添加 safe.directory 后即可正常使用 git。

### 10.2 Windows 换行符

当前 `core.autocrlf=true`，仓库没有 `.gitattributes`。多人/多平台协作前，建议后续在项目根目录添加：

```gitattributes
* text=auto
```

并提交一次规范化换行符。新增该文件属于一次独立提交。

### 10.3 误提交了密钥怎么办

立即处理，不要只靠「删掉文件再提交」：

1. `git rm --cached <密钥文件>` 从版本库移除；
2. 把相关密钥**全部轮换**（视为已泄露）；
3. 更新 `.gitignore` 防止再次提交；
4. 若密钥已推送到远端，历史清理（`filter-repo` 等）需用户明确同意后再执行。

### 10.4 提示无法读取全局 gitignore

```
warning: unable to access 'C:\Users\wsssj/.config/git/ignore': Permission denied
```

这是环境权限问题，不影响本仓库 git 操作；如需要，可在仓库内补充 `.gitignore` 规则，不要依赖全局配置。

### 10.5 敏感模块合并要求

涉及认证、加密、密钥、支付等敏感模块的改动，合并前**至少 1 个人类 approve**（人类 = 人员，不含 Agent），并由维护者执行合并（见 [collaborative-workflow.md](collaborative-workflow.md) 第 8、13 节）。

## 11. 与 AGENTS.md 的关系

本指南是 AGENTS.md 第 8 节的实操展开。规则冲突时，以 AGENTS.md 和用户明确指令为准；本指南中的命令如果与用户指示不一致，按用户指示执行。
