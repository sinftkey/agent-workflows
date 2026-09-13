# Changelog

本仓库所有 notable 变更记录于此。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Fixed

- 适配指南第 4 节 bash 校验命令改为 `grep -rnoE`，修复 BRE 下 `+` 按字面量匹配导致校验形同虚设的问题（P0）
- `adapt.sh` 补齐 `ADAPT_REPO` / `ADAPT_SOURCE` / `ADAPT_TARGET` 环境变量与 `-Repo` / `-Source` / `-Target` 参数解析，与 `adapt.ps1` 及 README 声明对齐（P0）
- `adapt.sh` / `adapt.ps1` 在「目标文件已存在跳过」时打印模板原文地址（raw URL 或本地路径），保留手动比对的合并源
- 修正 `git-workflow.md` 第 11 节 Review 人数的错误交叉引用（原指向第 8 节，实为第 13 节与协作模板第 2、13 节）
- `adapt.ps1` 模板路径拼接改用 `Join-Path`，兼容 Linux / macOS 下的 pwsh；克隆显式指定 `-b main`
- 协作模板 §3.1 备选方案消除自相矛盾（带 skip 标记的用例不再被描述为红灯）
- 协作模板 §4.2 分支命名规则统一（任务编号、owner 登记、推荐口径三处一致）

### Added

- 裁剪矩阵新增「角色不足」维度（如 2 人团队无专职测试时的兼任授权 / 显式降级路径）
- 协作模板新增「维护者必须由人类担任」硬约束（核心原则第 5 条）
- 协作模板 §4.2 定义多写入者分支（TDD 同一分支）的命名与所有权规则
- PR 模板新增「角色」字段；适配指南第 3 节新增「抽取 PR 模板落位」步骤并列入第 4 节校验清单
- git-workflow 提交规范补充任务编号写法（`(#<任务编号>)`，与 docs-communication §4.4 闭环）
- 任务中心（可选模板）：`templates/task-center/` 三件套（INDEX 模板、任务文件模板、`TASK-CENTER.md` 协议）+ `task.sh` / `task.ps1` 脚本，以仓库内 markdown 作为多 Agent 协作的任务中枢，任务与进度在专用 `task-center` 分支上流转

### Changed

- 模板文件名统一去掉 `template` 字段：`AGENTS.template.md` → `AGENTS.md`、`git-workflow-template.md` → `git-workflow.md`、`collaborative-workflow-template.md` → `collaborative-workflow.md`、task-center 下 `INDEX.template.md` → `INDEX.md`、`task-file.template.md` → `task-file.md`；落位到新项目后即为最终文件名，无需再改名（引用与适配脚本已同步更新）
- 任务中心初始化改为孤儿分支（`git switch --orphan`）：`task-center` 分支不再携带代码历史，worktree 检出只含 `docs/tasks/`，消除代码副本及其误读、误提交风险
- 协作模板 §5 增加「任务中心模式」、§2 平台侧建议补充任务中心分支保护；git-workflow PR 模板「关联任务」补充任务中心引用格式；适配指南第 3 节新增任务中心可选步骤
- `examples/` 幽灵引用消除：项目特有内容规则改为「不入本仓库；如需示例先建 `examples/` 并在 README 登记」
- 裁剪矩阵声明改为「一处维护，README 引用本表」；协作模板 §0 步骤 3 改为引用矩阵，去掉第二维护点
- git-workflow §12 去重（角色要点保留在第 2 节），§13 改为纯引用聚合清单
- README 目录结构表补充 `.gitattributes` / `.gitignore`；方式二手动复制命令先创建 `docs/development/`
- 两个脚本头注释记录「ps1 英文 / sh 中文」输出语言差异的原因，防止后人顺手统一造成回归

### Removed

- `.github/`（GitHub Actions CI：Markdown 相对链接检查、占位符校验命令防回归）停止跟踪，机器检查回归人工执行；忽略规则写在本仓库 `.git/info/exclude`，不动共享 `.gitignore`（下游项目需用 `.github/` 放 PR 模板）

## 版本基线

仓库尚无 tag；首个 tag（`v1.0.0`）将在本批整改合并后创建，届时 `[Unreleased]` 条目归入该版本。
