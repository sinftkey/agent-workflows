# 结构化本地任务中心

本资产使用 tool-version 2 / schema-version 3。任务 JSON 是事实源，索引和交接为生成视图；共享 policy 是当前动作/读权限来源。身份、运行、责任和真实技术验收分别核对。目录中的程序用于管理流程，不限制项目采用哪种语言。

## 入口

| 用途 | 两端相同的逻辑参数 |
|---|---|
| 写入 | `apply --request-file <请求JSON> --response-file <响应JSON>` |
| 查询 | `query --query-file <查询JSON> --response-file <响应JSON>` |
| 有限诊断 | `doctor` |
| 恢复预览 | `recover --actor-file <当前身份JSON>` |
| 已提交事务补物化 | `recover --actor-file <当前身份JSON> --apply` |
| 未提交事务放弃 | `recover --actor-file <当前身份JSON> --abort` |

Bash 与 PowerShell 入口只传文件和退出码，共享同一核心。配置 TASK_PYTHON 指向受支持的解释器；离线运行时在当前克隆登记，执行动作时不下载或安装依赖。TASK_IDENTITY 或旧进程角色名单不能补充 policy 权限。支持范围以安装来源的验证矩阵为准。

语法使用 `task.sh <命令> <参数>` 或 `task.ps1 <命令> <参数>`。准备好 JSON 文件后，两个入口接受同样的 `--root <任务中心目录>`、`--request-file <请求文件>`、`--query-file <查询文件>`、`--response-file <响应文件>`；文件名和目录可以包含空格或非 ASCII 字符。不要通过 shell 文本管道构造 JSON，也不要把来源报告正文拼接成命令。

响应的 durable 表示本地事实提交，不表示外部业务成功；exit 0 的门槛评估仍须读取 gates.outcome。提交后响应保存失败返回 9，重试原 request_id，不换 ID 重做。核心业务码为 2 格式/引用、3 授权、4 对象修订冲突、5 同 ID 改内容、6 门槛/证据、7 发现/格式版本、8 运行时、9 结果不确定、10 锁/待恢复、11 恢复保护。安装管理命令的成功响应是各自的计划或结果对象。

请求、查询及全部动作字段以随资产打包的 [Schema](protocol.schema.json)为准。四组正常流程的逻辑顺序是创建约定并接手开工、提交候选并登记自验/检查指派、独立检查并评估、记录真实接受并完成；每组可以包含同一实际 actor/run 的多个动作，不能代替另一个人的实际工作。

## 事实、授权和门槛

每次请求最多 32 个动作、一个实际 actor/run；请求 ID 在首次发送前生成。原 ID 同规范化负载返回历史 receipt，不重复动作。写权撤回后只有保留 receipt.read 的 active 身份/运行可读取历史；新 ID 仍按新写准入。不同内容不得覆盖同 ID。受保护查询有七种明确读能力，不自动从 owner 或写动作推导。

约定继承固定 policy 的 commit/blob/profile；实际动作使用锁内最新授权。候选、检查、自验、复用判断、实际接受和交付尝试分别定位。缺检查者不丢弃候选，失败/未知/未处置问题不被后续绿结果覆盖。四组正常路径可合并动作，但接受必须真实发生。评估不满足返回诊断；只有成功推进写入生命周期事实，未推进的评估结果保存在 receipt 中，不伪造推进事件。

首次 start 评估绑定约定和 owner 指派，不要求候选。dependencies 约束开工和完成；completion_children 只约束父完成，不自动阻止父规划/集成。正式消费固定上游成功交付版本。终态不重开；晚到失败追加限制并由补救任务处理。clearance 固定来源任务、类别、实体、来源交付及本交付；绕行路径和其他版本仍受限。

同一候选的每份交付均从事实重建消费集合，包括完成后追加的成功交付；候选形成后、完成前追加的消费也绑定到该候选各份交付。缺必需消费绑定时保持未知，不能当作无上游。历史代录仍核对原接手事实及原 policy 下的角色、候选目标、全部检查覆盖和独立性；当前代录权不扩大旧指派，原来源后来撤权也不会抹去合格的旧检查。

## 事务、恢复与迁移

当前克隆共享短锁；私有 index 构造限定路径的树，Git ref 比较交换是提交点。命令不运行检查脚本、外部 API、消息或部署。业务完成不产生外部合并/发布权限。

有 pending 事务时停写。恢复默认只读；提交未知先核对 ref/receipt/文件 hash。已提交只补物化，不重放动作；未提交可显式放弃。用户改动、未知 ref、索引冲突、仍存活的锁 owner 均停下。强制接管需要当前维护权限、精确锁 token 和隔离依据，不能仅凭超时删锁。

旧 Markdown 数据只能经独立安装器预览、克隆外完整备份和显式授权后迁移。旧已完成/已取消保持终态，缺证据标未知；owner 及旧角色仅为历史线索，不自动授新权。恢复旧格式前核对没有后继事实；有新事实时禁止用备份覆盖，另行设计补偿。不要直接把新请求交给旧工具，也不要仅改版本文件。

恢复旧格式的预览及锁内执行都会拒绝业务 pending（退出 10）；须先用当前格式恢复入口显式放弃未提交事务或补齐已提交事务，再重新预览。若恢复事务已产生后继提交，仍禁止覆盖；不能通过切换格式绕过 pending。

安装器的两端入口同样只转发参数，管理命令与核心入口共用：

| 命令 | 必需材料与效果 |
|---|---|
| install-preview | `--repo <代码仓库根目录> --destination <克隆外空目标目录> --policy-file <初始policy> --runtime-dir <离线运行时>`；生成计划，不改目标 ref/工作区 |
| install-apply | 同上，加 `--approval-file <确认来源JSON>`；独立孤儿分支及共享 worktree，不写代码分支的跟踪文件 |
| install-recover | `--repo <代码仓库> --actor-file <当前维护者> --runtime-dir <离线运行时>`；默认预览，`--apply` 补齐已核对的安装 |
| migrate-preview | `--root <旧任务中心> --backup-dir <克隆外新目录> --policy-file <明确policy> --runtime-dir <离线运行时>`；备份 bundle/原字节/旧登记，返回迁移计划，源 ref/文件不变 |
| migrate-apply | `--root <旧任务中心> --plan-file <固定批准计划> --runtime-dir <离线运行时>`；计划须含 approval、isolation_evidence，不能遗漏旧任务、改变旧终态或降低编号高水位 |
| migrate-recover | 同 root/runtime，加 `--actor-file <维护者>`；默认预览，已提交用 `--apply`，未提交且源未变才可 `--abort` |
| restore-preview | root/runtime/actor；仅迁移完成且无 pending、任何后继提交或未提交改动时，预览恢复旧格式 |
| restore-apply | 上述材料加 `--plan-file <固定恢复计划> --approval-file <新的恢复确认>`；创建恢复提交，保留迁移历史及备份 |
| restore-recover | root/runtime/actor；默认预览，按 ref 核对后显式 apply 或 abort，不回滚未知后继事实 |

初始 policy 必须明确身份、运行、独立上下文、动作/读范围、确认者、默认约定及真实决策来源。approval-file 是 Schema 中的 confirmation，actor-file 是 identity/run，isolation-file 是 source；从其他聊天收到的报告本身不授予写入或确认权。未发布运行时只允许明确隔离试用并增加 `--candidate`；不得将这个参数当作真实项目发布许可。

受控恢复死进程锁时，在恢复 apply/abort 上附 `--lock-token <原token> --isolation-file <隔离来源JSON>`。工具同时核对当前维护权限、当前主机 PID 已退出及 token 未变，将原锁目录保留为隔离记录；仍存活/未知进程、异地主机、缺 owner 或只有超时一律拒绝。安装/迁移/旧格式恢复也使用相同锁接管条件。

clearance.basis 采用实际附件文件：对象仅含 kind=`clearance-evidence`、local（task/delivery）、origin（task/kind/restriction/delivery）、edges、results、report。edges 每项按本任务/本交付/上游任务/上游交付排列，完整列出当前所有传入消费边且不重复；results 与动作一致，report 是实际独立复验报告 source。缺任一路、绕行边或其他来源交付都不解除；新出现的边使旧依据失效，需重新复验。正常任务无需创建此附件。

## 限制

本地工具不防御有磁盘写权限者绕过协议，不从不同字符串证明实际独立。附件 hash 定位对象，不证明实际检查执行。断电持久化、平台支持、依赖审计及总成本收益须以安装来源的实测报告为准。未通过发布条件的候选只用于明确隔离的试用，不安装到真实项目。

文件写入使用临时文件、文件 fsync 与替换；POSIX 另外同步目录。Windows 尚未验证断电时目录项的持久化保证，进程退出测试不等于断电测试。恢复先检查全部受影响文件和索引，再补物化；遇到用户改动保留原状及日志，不通过 reset/clean 强行恢复。
