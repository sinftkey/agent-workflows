# Changelog

本仓库所有 notable 变更记录于此。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Fixed

- Bash repair now writes the current padded-ID INDEX format, normalizes legacy filenames and default fields for both clients, and keeps Git Bash paths compatible with the shared PowerShell registration.
- `adapt.sh` / `adapt.ps1` 不再把可选 `templates/task-center/` 复制进项目代码分支；既有同名目录或旧式 `docs/tasks/TASK-CENTER.md` 会提示维护者检查且不会被脚本覆盖或删除
- 适配指南第 4 节 bash 校验命令改为 `grep -rnoE`，修复 BRE 下 `+` 按字面量匹配导致校验形同虚设的问题（P0）
- `adapt.sh` 补齐 `ADAPT_REPO` / `ADAPT_SOURCE` / `ADAPT_TARGET` 环境变量与 `-Repo` / `-Source` / `-Target` 参数解析，与 `adapt.ps1` 及 README 声明对齐（P0）
- `adapt.sh` / `adapt.ps1` 在「目标文件已存在跳过」时打印模板原文地址（raw URL 或本地路径），保留手动比对的合并源
- 修正 `git-workflow.md` 第 11 节 Review 人数的错误交叉引用（原指向第 8 节，实为第 13 节与协作模板第 2、13 节）
- `adapt.ps1` 模板路径拼接改用 `Join-Path`，兼容 Linux / macOS 下的 pwsh；克隆显式指定 `-b main`
- 协作模板 §3.1 备选方案消除自相矛盾（带 skip 标记的用例不再被描述为红灯）
- 协作模板 §4.2 分支命名规则统一（任务编号、owner 登记、推荐口径三处一致）

### Added

- 新增独立 `setup-task-center.sh` / `setup-task-center.ps1` 安装与修复入口：在同一克隆登记本地孤儿分支和共享 worktree，设置本地忽略规则；旧格式修复默认预览，显式执行前创建并验证克隆外 bundle，支持恢复并重新登记
- 任务中心协议补充 Agent 快速上手、工具无关用户级引导、事务恢复、repair、克隆外 bundle 备份与恢复示例；setup 输出引导语，但不修改用户全局指令
- 任务中心阶段一：定稿 v2 任务字段、状态权限、迁移映射、版本元数据与命令参数；Bash / PowerShell 脚本改为共同 Git 目录发现、本地读写、全局事务锁、显式路径提交、任务源校验与 INDEX 生成
- 修复任务中心恢复提交夹带事务外暂存项、PowerShell 替换目标文件时的中断窗口、补零标题编号查找及 Bash 恢复遗留 PowerShell 备份文件；增加对应恢复与一致性回归用例
- 裁剪矩阵新增「角色不足」维度（如 2 人团队无专职测试时的兼任授权 / 显式降级路径）
- 协作模板新增「维护者必须由人类担任」硬约束（核心原则第 5 条）
- 协作模板 §4.2 定义多写入者分支（TDD 同一分支）的命名与所有权规则
- PR 模板新增「角色」字段；适配指南第 3 节新增「抽取 PR 模板落位」步骤并列入第 4 节校验清单
- git-workflow 提交规范补充任务编号写法（当时使用外部 issue 的 `#<编号>`；当前本地任务中心使用 `TC-0042`，与 docs-communication §4.4 闭环）
- 任务中心早期版本提供 `templates/task-center/`、`task.sh` / `task.ps1`，以 markdown 和专用分支承接多 Agent 任务；现行本地安装、数据和路径约定以本 changelog 的 v2 条目及任务中心协议为准

### Changed

- 任务中心运行资产只进入本地孤儿分支和共享 worktree；从本仓库适配模板时跳过 `templates/task-center/`，适配指南不再建议复制至使用方代码分支的 `docs/tasks/` 或写入项目级 Agent 规则
- 协作模板保留通用任务跟踪和 PR 衔接规则，移除本地任务中心专属的分支推送、路径和安装说明；本地任务编号统一使用 `TC-0042`，不伪装成平台 `#42`
- 任务中心安装、迁移、版本与兼容性说明集中在 README 和协议；Git 2.23 仅为当前检查下限，最低版本及平台兼容性尚待发布前验证
- 模板文件名统一去掉 `template` 字段：`AGENTS.template.md` → `AGENTS.md`、`git-workflow-template.md` → `git-workflow.md`、`collaborative-workflow-template.md` → `collaborative-workflow.md`、task-center 下 `INDEX.template.md` → `INDEX.md`、`task-file.template.md` → `task-file.md`；落位到新项目后即为最终文件名，无需再改名（引用与适配脚本已同步更新）
- 任务中心早期初始化改为孤儿分支（`git switch --orphan`）以隔离代码历史；当前分支同时保存协议、脚本、版本元数据和任务数据，安装方式见独立 setup 引导器
- 早期协作模板曾含本地任务中心专属模式；本版已移除该模式的项目级安装、路径和推送条款，并保留通用任务跟踪规则
- `examples/` 幽灵引用消除：项目特有内容规则改为「不入本仓库；如需示例先建 `examples/` 并在 README 登记」
- 裁剪矩阵声明改为「一处维护，README 引用本表」；协作模板 §0 步骤 3 改为引用矩阵，去掉第二维护点
- git-workflow §12 去重（角色要点保留在第 2 节），§13 改为纯引用聚合清单
- README 目录结构表补充 `.gitattributes` / `.gitignore`；方式二手动复制命令先创建 `docs/development/`
- 两个脚本头注释记录「ps1 英文 / sh 中文」输出语言差异的原因，防止后人顺手统一造成回归

### Removed

- `.github/`（GitHub Actions CI：Markdown 相对链接检查、占位符校验命令防回归）停止跟踪，机器检查回归人工执行；忽略规则写在本仓库 `.git/info/exclude`，不动共享 `.gitignore`（下游项目需用 `.github/` 放 PR 模板）

## 版本基线

仓库尚无 tag；首个 tag（`v1.0.0`）将在本批整改合并后创建，届时 `[Unreleased]` 条目归入该版本。
