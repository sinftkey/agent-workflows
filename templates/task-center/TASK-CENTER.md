# 任务中心协议（Task Center）

> 本文是仓库内任务中心（`docs/tasks/`）的使用协议。任务中心用 markdown 文档作为任务中枢：任务的登记、认领、状态、进度、验收标准、验证证据都在其中流转，Agent 与人通过读写它协调工作。
>
> 与外部任务系统（GitHub Issues 等）的关系二选一：
> - **替代模式**：不使用外部任务系统，任务中心是唯一任务源；
> - **并存模式**：外部系统保持人类视图与长期规划，任务中心作为 Agent 的日常操作面；任务完成后由维护者回链关闭外部 issue。
> 两种模式都不要做双向自动同步（单向引用即可）。

## 1. 结构与发号

```text
docs/tasks/
├── INDEX.md            # 任务注册表（发号、总览），只列活跃任务
├── 0042-<标题>.md      # 一任务一文件，文件名 = 四位编号-标题
├── 0043-<标题>.md
└── archive/            # 已完成任务（INDEX 中删除对应行）
```

- 编号在 INDEX 递增发号：取当前最大编号 + 1；
- 撞号处理：先 push 先得，后到者重取号并改名（`git mv`）；
- 任务文件字段为极简 key-value 行（`状态：进行中`），进度区 append-only（只追加、不改写历史）。

## 2. 分支模型：task-center 分支

任务中心内容**不随任务分支、不进默认分支**，统一放在专用分支 `task-center` 上：

- 分支为**孤儿分支**（不含代码历史，按 §2.1 初始化）：worktree 检出只含 `docs/tasks/`，不产生代码副本，也无需跟随代码分支演进；
- 代码 squash 合并不会压乱进度日志，任务中心历史独立可审计；
- 平台侧建议：对 `task-center` 分支开启保护（至少禁止 force push）；
- 推送权限：参与者（人 + Agent）均可 push，按本协议与角色权限矩阵自我约束。

### 2.1 初始化（维护者执行一次）

```bash
mkdir -p docs/tasks/archive
cp <模板>/INDEX.md docs/tasks/INDEX.md   # 趁模板文件还在工作区先复制好（未跟踪文件在下一步切换后保留）
git switch --orphan task-center                   # 孤儿分支：已跟踪文件暂时移出工作区，不含代码历史
git add docs/tasks && git commit -m "docs(tasks): 初始化任务中心"
git push -u origin task-center
git switch -                                      # 切回原分支，代码文件恢复
```

> 须在干净工作区执行（有未提交改动时 `git switch --orphan` 会拒绝）。`--orphan` 创建的分支不含代码历史，因此 worktree 检出只有 `docs/tasks/`，不产生代码副本；切回后主工作区如残留空的 `docs/tasks/archive/` 目录，删除即可。

### 2.2 参与者接入（每人执行一次）

```bash
git fetch origin task-center
git worktree add .worktrees/task-center task-center   # .worktrees/ 需加入 .gitignore
```

任务中心的读写都在 worktree 目录（`.worktrees/task-center/`）中完成，与代码工作区互不干扰；也可用 `task.sh` / `task.ps1` 脚本封装上述操作（见第 5 节）。

## 3. 状态机与写权限

```text
待办 → 已认领 → 进行中 → 待审核 → 待测试 → 待合并 → 已完成
              ↖__________↙ 打回        阻塞 → 进行中（原因写入进度）
```

| 操作 | 允许角色 |
|------|----------|
| 登记新任务（INDEX + 任务文件） | 维护者（或受指派者） |
| 认领（填 owner、状态「已认领」） | 认领者本人 |
| 状态「已认领→进行中→待审核」、追加进度 | owner |
| 状态「待审核↔进行中」（打回须写原因） | 审核角色 |
| 状态「待测试→待合并」（验证证据齐备） | 测试角色 |
| 任意状态、归档、改 INDEX 结构 | 维护者 |
| 越权改状态 | 任何人都不允许，按协作模板权限矩阵处理 |

任务文件「角色」字段记**当前责任角色**，历史角色看进度日志。

## 4. 读写协议

1. **开工**：读 INDEX（`task.sh list` 或看 worktree 里的 INDEX.md）→ 认领 → `task.sh claim <编号>`（或手工改 owner / 状态）；
2. **执行**：每完成一个可验证步骤追加一条进度——`<日期> <身份>：<做了什么>（证据）→ 下一步`；证据写 commit / 命令输出 / PR 编号，不粘贴长日志；
3. **交接**：状态改下一环节，进度末条写清移交对象与待办；
4. **收尾**：代码 PR 合并后，维护者执行 `task.sh done <编号>`（状态「已完成」+ 文件移 `archive/` + INDEX 删行）；
5. 每次写操作前 pull --rebase、写完 push，只提交与本人任务相关的文件。

## 5. task 脚本

`scripts/task.sh`（bash）与 `task.ps1`（PowerShell）接口一致，封装 worktree 与提交流程：

```bash
export TASK_IDENTITY=<身份>          # 必填，Agent 工具名或人员名

task.sh init                          # 初始化 / 更新 worktree
task.sh list                          # 查看活跃任务
task.sh new "<标题>" [slug]           # 登记新任务（取号 + 建文件 + INDEX 登记）
task.sh claim <编号>                  # 认领
task.sh progress <编号> "<内容>" [--status <状态>]   # 追加进度，可同时改状态
task.sh status <编号> <状态>          # 仅改状态
task.sh done <编号>                   # 完成归档（维护者）
```

环境变量：`TASK_IDENTITY`（身份，必填）、`TASK_BRANCH`（默认 `task-center`）、`TASK_WORKTREE_NAME`（默认 `task-center`）。

脚本只做机械操作（取号、追加、提交、push），状态合法性、角色权限由协议约束 + review 把关。

## 6. 与代码 PR 的关联

- 代码 PR 的「关联任务」字段填 `#<编号>（进度见任务中心）`；reviewer 需要进度上下文时到 `task-center` 分支查阅对应任务文件；
- 提交信息建议带编号（见 Git 工作流文档提交规范）；
- 代码 PR 中**不复制**任务中心进度内容（单一事实来源，防止双写漂移）。

## 7. 常见问题

- **任务卡住怎么办**：维护者巡检 INDEX 的状态与最近进度日期；阻塞任务须在进度里写明原因（依赖、等待角色、外部条件）。
- **并发冲突**：任务按文件分流（一任务一文件），冲突通常只在 INDEX；解法是 rebase 后重 push，不 force push。
- **手工改还是脚本改**：都可以。脚本保证格式一致，手工改更灵活；无论哪种都要遵守第 3 节的角色权限。
- **会话中断恢复**：新会话先 `task.sh list` + 读自己 owner 的任务文件，从「下一步」继续。
