# 阶段 C：完整格式与接口设计候选

2026-10-16，C2-draft，候选 C2-c2。本文补齐[已接受的 C1 信息模型](optimization-stage-c-design.md)第 9 节全部精确设计项，并修订首轮独立复核发现的四项 P2；C1 和 C2-c1 固定送检快照保持不变。当前状态、用户决定和例外只在[试用安排](optimization-trial-arrangement.md)维护。本文、Schema 及设计向量是设计资料，不是现行工具的输入或安装包。

本版设计标识为 `stage-c/2-draft`。拟发布工具版本 2、数据格式 3；这是兼容性方案中的目标数字，**没有修改或发布现行 tool-version 1 / schema-version 2**。草案经独立 review、修订闭环及用户接受后才可登记冻结；设计完成不授权 D 实现、安装、迁移或 E 自动交互。B 的量化收益仍未知。

## 1. 交付清单与设计依据

| C1 剩余项 | 本次交付 | 设计验收 |
|---|---|---|
| 精确键、类型、版本、引用与字节约束 | [协议 Schema](design/stage-c/protocol.schema.json)、§2–3 | Schema 结构及正反例验证；引用、权限和状态约束另作语义核对 |
| 双端依赖、解析及序列化 | §4 | 选择共享核心，明确支持范围、缺依赖拒写和新增部署成本 |
| 请求、响应、退出码及对象修订 | §5–7 | 24 个动作、批量失败、历史接收、重试与门槛明确 |
| 恢复、预览和迁移计划 | §8–9；Schema 中 journal/migration | 版本隔离、路径、备份、未知提交及人工恢复分支都有约定 |
| 正常及四类异常设计向量 | [完整正常数据](examples/workflow-stage-c-complete.json)、[设计向量](design/stage-c/vectors.json)、§10 | 结构向量可执行校验；业务向量逐项静态推演，运行证明留 D |

依据为[统一方案](optimization-plan.md) §3–7、§9–10、[异常表](optimization-exception-cases.md)、[成本标准](optimization-trial-criteria.md)。真实试用支持稳定候选、失败保留、独立检查、接受、实际版本映射及减少重复入口；撤权竞争、事务故障和传递纠正仍主要是必要保障及静态推演，不能宣称已由现场证明。新字段只服务于这些定位、权限或异常需求，不引入后台调度、外部调用器或自动影响分析。

Schema 使用 [JSON Schema 2020-12 Core](https://json-schema.org/draft/2020-12/json-schema-core) 和[结构验证词汇](https://json-schema.org/draft/2020-12/json-schema-validation)。这些词汇验证数据结构；跨文件引用、授权、事实真实性、事务和门槛由本文另行约束，不能把 Schema 通过等同业务通过。全部 `$ref` 指向同一文件的 `$defs`，验证时不访问网络。

## 2. 文件、编号和事实源

拟发布布局：

```text
.task-center/version                    tool-version 2 / schema-version 3，仍为固定文本
.task-center/policy.json                当前授权与默认配置，已提交快照
.task-center/next-id                    十进制下一编号，单行 LF
.task-center/receipts/<请求UUID>.json    已提交请求摘要及历史接收结果
docs/tasks/<编号>.json                  活跃任务事实源
docs/tasks/archive/<编号>.json          终态归档，ID 不变
docs/tasks/INDEX.md                     可重建视图
```

相较 C1，增加 receipts 是为了任务归档、跨任务批量和配置变更后的持久重试定位；每成功写事务自动生成一份，不由用户填写，不复制原报告。它记录接收结果和历史门槛，不是独立批准源。事实仍在任务 `records` 和 policy；若 receipt 与事实不符则停写，不能选其中一个继续。

共同 Git 目录内 `task-center-v2/` 放锁、事务日志、私有 index、临时树、工作树修复资料和本克隆发现信息，均不进入业务分支。运行锁是 Git common-dir 作用域；跨 clone、远端平台和绕过工具的写入不在原子性保证内。只支持本地普通 Git 工作树，拒绝裸库、共享网络文件系统和未受控的额外写入者；这些限制须在 D 探针中验证。

编号规范：task ID 为无前导零的十进制字符串，范围 1 至 999999999999999；文件名只含编号，不含可变标题。旧 `001` 和 `1` 归一化冲突时停止迁移。任务内部实体 ID 为小写 ASCII `[a-z][a-z0-9-]{0,63}`，按任务及实体类别定位；同类 ID 不重用。跨任务引用必须含 task ID，不能仅凭相同 result ID 查找。实体修订为 1..2147483647；请求 expected 中的 0 只表示实体尚不存在。记录 seq 从 1 连续增加，只表示本任务历史顺序，不作为所有动作的 CAS。

请求及事件 ID 为小写 UUID v4；首次发送前生成，超时重试不换请求 ID。动作 ID 在请求内唯一，引用及输出关联用它，不表示授权。一个 batch 最多 32 个动作，最多创建一个 `new` 任务；`task.open` 必须是其首次动作，后续 `new` 解析到事务内分配编号，失败不消耗编号。新任务不能在同批中作为另一个任务的上游交付。

`task` 顶层精确为 kind、protocol、id、title、legacy、records、current。记录精确为 seq、event_id、request_id、action_id、actor、policy、recorded_at、action。action 保存实际接受的请求动作，连同其预期修订和差异输入；继承项由约定固定 policy 的 commit/blob/revision/profile 重建，不能随当前配置漂移。Git 历史及其固定引用不可 squash/重写或清理为不可达；缺少旧配置对象时 check 为未知并拒绝相关门槛。

`current` 只缓存 contract、candidate_revision、candidate、owner_assignment、state、seq。由 records 加 legacy 导入事实重建；写请求不能直接提供 current。清单、owner、问题和环境视图均按需生成，避免多份手填派生状态。归档保留相同记录，终态下新失败仍可追加到归档文件；归档不是忽略限制或撤销编号。

父子关系按需在 task.open.payload.parent 提供已存在 task ID，省略表示无父任务；它只用于组织视图，不生成 dependencies 或消费边。第一版创建后不改 parent，拒绝自指/环，不支持同批引用尚未分配的父任务；规划父任务无需先完成子任务。父任务若在约定中显式要求子完成，才建立对应完成门槛，不能默认为父的开工依赖。

该完成门槛用按需 contract.overrides.completion_children 明列子 ID，省略表示空；必须核对它们实际 parent 为本任务。这里只表达父任务的必需子交付，不增加任意阶段依赖。父可先集成稳定子候选，集成接收事实使子按各自边界完成，再记录子实际 delivery 消费，父的 complete 才放行；父的 start 不等待这些子完成。子若需父完成才完成将形成逻辑循环，约定预检拒绝，不能以父子标签忽略循环。

## 3. JSON、引用、时间与摘要规范

### 3.1 输入和序列化

- UTF-8 无 BOM；无效 UTF-8、孤立代理项、NUL 字符、重复对象键、NaN/Infinity、非整数数值、注释、尾逗号全部拒绝。键及 ID 区分大小写；任意层级的未知键拒绝，不提供可影响控制逻辑的任意 extensions。
- 接受合法 JSON 空白及 CRLF，写出 UTF-8/LF、两空格缩进、文件末一个 LF；不改变业务字符串的 Unicode 归一化形式，不把 CRLF 字符串内容改成 LF。控制字符仅允许正文中的 TAB/LF/CR，ID、路径及 URI 禁止控制字符。
- 数值 token 只能为 JSON 十进制整数，不接受 `1.0`、`1e0` 或 `-0`；范围按 Schema。布尔值不作为整数。单文件/单请求上限 8 MiB、嵌套深度 64；记录和普通数组最多 10000 项，到限额必须报告容量限制，不能截断历史。扩容需要新兼容性设计。
- 所有对象关闭 additionalProperties；所有必需字段见 Schema，nullable 才允许 null。未知不以空串、0 或缺少关键字段替代。空数组仅在 Schema 允许且确实无项时使用。

Schema 不能检查 JSON 解析前的重复键、数字 token 和 UTF-8；必须先严格词法解析，再 Schema，再关联/语义校验。Schema 的 time pattern 之后还要检查真实日历日期，拒绝闰秒、无效日期和偏移时间。不能依赖验证器的可选 format 注解自动完成这些检查。

### 3.2 时间、来源和稳定对象

time 是带 kind 的三选一：known 使用精确 `YYYY-MM-DDTHH:MM:SSZ`；unknown 带原因；legacy 保留原字符串和不能转成确定 UTC 的原因。新记录的 recorded_at 必须为工具获得的 known 时间；performed_at 允许 unknown，是否阻断取决于该要求是否依赖时效，不能因此宣称满足过期检查。legacy 只用于迁移的原始时间。排序使用提交顺序/seq，不以墙钟先后替代事务顺序。

source 是 URI、原字节 SHA-256 和说明。URI 定位附件，不从报告正文抽取“通过”作为授权或执行命令。使用 URI 前验证实际可读对象及摘要；网络 URI 不在锁内自动抓取，未准备成本地稳定对象时相关动作拒绝/未知。摘要全部小写十六进制；Git OID 必须是仓库实际算法的完整 40 或 64 位，且对象类型和存在性正确，不接受短 hash、分支名或单独 HEAD。policyRef 同时校验 commit 中 policy 路径的 blob 和内含 revision。

artifact 的 snapshot 必须有稳定 URI、原字节 sha256，git_object 为 null；git 必须同时有完整对象 OID 及其所指交付包/清单的原字节摘要。非空 materialization 保存源对象、精确转换规则及核对报告，不能把 CRLF/LF 转换后摘要说成原字节相同。检查和交付各有对象清单，交付映射报告核对二者的差异与实际检查适用性。

### 3.3 规范化摘要 K

请求幂等摘要定义为 SHA-256(K(整个 request))，不是输入文件原字节 hash。K 是本协议的有限 JSON 编码，不声称实现通用 JCS：

1. 先完成词法和结构校验；只含对象、数组、Unicode 标量字符串、整数、true/false/null。
2. 对象键按 ASCII 升序排列（本协议所有键为 ASCII）；数组次序保留，禁止自动对动作或覆盖数组排序。
3. 无空白；整数为最短十进制；布尔/null 用小写。字符串不做 NFC；引号和反斜线分别为 `\"`、`\\`；U+0000..001F 统一编码为小写 `\u00xx`，不用 `\n` 等短转义；其他标量直接 UTF-8，`/` 不转义。
4. K 不带 BOM 或尾 LF。相同 ID/相同 K 才幂等；改变 expected、数组顺序、来源、actor/run 或任一业务值都是不同负载。

同一 task/result ID 跨请求重送时比较 K(result)；相同则无新增结果事件，不同则退出 5。新事实纠正用新 result ID，并显式引用 corrects；不会覆盖旧事实，也不自动解除失败。artifact/source SHA-256 始终针对原字节，和 K 的用途分开。全部请求成功后才生成 receipt；拒绝请求没有业务 receipt，不被缓存为成功。

## 4. 双端解析和部署取舍

选用**一个共享 Python 核心**负责严格解析、Schema、K、业务校验、Git 事务和视图。Bash、PowerShell 仅做显式定位、文件参数传递和退出码转发，不各写一套 JSON 解析器。D 才实现该核心；本轮只有格式文件和评审用核对脚本。

| 方案 | 代价与结论 |
|---|---|
| jq + ConvertFrom-Json | jq 新依赖，PowerShell 不同版本的键比较/重复键及编码差异仍需补层；两套业务与序列化长期维护。此版不选 |
| Node 共享核心 | 仍需 JSON 严格解析补层及 Schema 依赖，且目标用户是否已有 Node 未知。没有试用证据支持额外优势，此版不选 |
| Python 共享核心 | 增加 Python 与验证器安装、锁版本、多平台制品和审计成本；只维护一套业务契约，选用但不假定免费或已经安装 |

拟支持 Python CPython 3.11–3.13，Bash ≥4.0，PowerShell 5.1 或 7.2+。Shell 不参与 JSON 反序列化：`apply --request-file <路径> --response-file <路径>` 的文件必须无 BOM UTF-8；调用参数不以 eval/拼接命令执行，PS 5.1 不走默认文本管道生成 JSON；退出码取核心进程值。非 ASCII 路径、Windows 本机与 Git Bash 路径转换、POSIX 权限/锁，在 D 覆盖。C 不宣称已兼容这些平台。

Schema 验证依赖选 jsonschema 4.23.0，不宣称是最新版本。本次隔离核对环境解析到 attrs 26.1.0、jsonschema-specifications 2025.9.1、referencing 0.37.0、rpds-py 2026.9.1、typing-extensions 4.16.0；这是当前 Windows/CPython 3.12 的验证环境清单，**不是已审核的跨平台发布锁**。D 安装前必须为支持矩阵锁定完整版本/制品 hash、许可证、离线安装包及安全检查；失败则不发布，不能由运行命令临时联网安装或换版本。JSON Schema 资源打包本地，禁用远程 `$ref` 检索。

缺 Python/验证器、版本不受支持、Schema 摘要与安装 manifest 不符：退出 8，零业务写入；允许独立的 shell `doctor` 只读报告缺依赖/现行版本位置，不假装完成 JSON 一致性检查。核心可用时 show/list/check/handoff 也先检查格式；高版本仅报告拒绝原因，不忽略字段。迁移先安装隔离新运行时，再显式调用新迁移入口，不能覆盖旧脚本后才发现无法读旧数据。

一次性配置成本包括运行时和 wheel 获取、平台包验证、默认授权、备份及培训；每次行政成本包括请求生成、引用核对、receipt 和 Git 提交，全部进入 D 的账单。不以“四组”代替实际写入/保存/验证次数，不以共享核心推算收益。

## 5. 请求、响应和动作修订表

### 5.1 请求入口

拟入口 `apply --request-file <路径> --response-file <路径>`；受保护只读入口统一为 `query --query-file <路径> --response-file <路径>`，doctor 仅做下述有限诊断。动作以 Schema 中的 request 表达：kind/protocol/request_id/actor/actions，单一实际 actor/run，一个有界原子 batch。不同人的真实行为不能伪装成同一运行；当前有权代录者可依据固定来源记录人类决定，保留 confirmation.identity/source/at。配置中的 confirmers 约束可代录确认者；本地工具不能证明聊天内容真实性。

`expected` 只允许表中列出的键，**列出的键必须恰好存在，其他键拒绝**，Schema 已逐动作限定键集合。数值是在当前克隆锁内比较的对象修订，不是请求读到的整个 task seq。未创建的对象必须传 0；追加结果不带当前候选 CAS，避免错拒并行真实结果。配置更新独占 batch，不能和任务动作混批；其他动作不得把 task 设为 policy。

| 动作 | expected 键 | 前置、写入及生命周期结果 |
|---|---|---|
| task.open | contract=0 | task=new；有创建/约定权限，固定默认+本次差异+决策来源；生成约定修订 1，todo |
| contract.revise | contract | 有约定变更权；替换完整差异输入，增加约定修订；旧候选保留，未终态回 active，新约定所有门槛重新判断 |
| assignment.set | assignment | 按 payload.id 比较；有分配权，owner 的 target=null/requirements=[]，checker 固定候选/要求；增加指派修订并清除旧接手；owner 变更前核对隔离，协调者负责待接手跟进 |
| assignment.accept | assignment | payload.binding 修订一致且 actor 为被指派身份；绑定当前 active run。旧 run 转新 run 须改派增加修订，不能仅再次 accept |
| work.begin | contract, assignment | 两者与 payload 一致；本人已接手 owner；锁内重算 start 依赖、隔离及阻塞，进入 active |
| progress.append | 无 | 核对 payload.binding 的历史/当前责任；仅当前已接手者追加本责任进展，不改约定/候选/门槛 |
| candidate.submit | contract, candidate, assignment | 当前已接手 owner，重算 start 依赖/隔离；候选 ID 新建、对象固定、AC 完整映射；candidate 指针修订 +1，进入 verifying，即使 checker 尚未分配 |
| result.append | 无 | source_actor=当前 actor；本人指派授权及实际运行成立；检查用 payload.binding 的**该次指派历史版本**校验，不用最新 task seq 拒收；撤权/指派已撤销则不允许直接追加 |
| result.record-historical | 无 | 当前有代录权者读取原证据，保留实际来源、原指派证据和未核实项；不恢复旧来源权限，不当作新的当前检查授权 |
| applicability.confirm | 无 | 当前合格检查者已接手目标检查；读原结果及实际差异，reuse 且无 gaps 才可能填目标要求；supplement/rerun 本身不通过 |
| requirement.disposition | contract, candidate | 有该要求处置权、真实确认来源及适用条件；not-applicable 有事实，waived 仅允许 waivable=true/项目允许；有期限时 known 且未过期，不能免外部强制要求 |
| issue.report | 无 | 有报告权限；绑定已存在对象/结果/交付及真实来源，可在终态追加限制；不要求发现者有解除权 |
| issue.resolve | issue | 对该 id 当前修订 CAS；合格处置者读对应结果、原因与剩余影响，修订 +1；不因新绿结果自动关闭矛盾 |
| block.set | block | 0 创建或对同 id 变更；影响门槛/等待条件/跟进人齐备，修订 +1 |
| block.resolve | block | 相同 id 当前修订、解除依据及权限；只解除该阻塞 |
| dependency.consume | contract, assignment | 本人已接手 owner，upstream.task 在本约定 dependencies 或 completion_children 名单，实际完成且版本可依赖，记录明确 delivery ID；不把父子关系当依赖 |
| dependency.clearance | delivery | 本任务交付修订 CAS；合格独立检查者对 restriction_task/restriction_kind/restriction/restriction_delivery 完整来源键及本 delivery 给排除/重验依据；只截断这一来源经过本版本的传播 |
| delivery.record | 无 | 有交付事实记录权且确认者在边界/代录 grant 内；稳定实际对象、映射和真实来源齐备；保存每次尝试含失败/未知，不自动做外部动作、不自动完成 |
| delivery.reconcile | delivery | 对 payload.delivery 当前修订 CAS；责任人依据确认记录外部实际版本/残留效果/retry_safe，修订 +1；unknown 不解除 retry 门槛 |
| gate.evaluate | start 为 contract, assignment；其他为 contract, candidate | start.target 仅含 contract_revision/binding，无 candidate；其他 target 为 candidateRef。锁内重算；advance=true 只允许 before-delivery，通过则 verifying→delivering；其他 advance=false；缺口不回滚同批已接收的事实 |
| task.complete | contract, candidate, delivery | 绑定目标和实际交付，重算 before-delivery、complete、依赖、问题及残留影响；全通过才 done |
| task.cancel | contract | 有取消权、原因/外部遗留处置/后续责任；保留记录为 canceled，不满足成功依赖 |
| task.archive | 无 | 仅终态且有归档权；受限交付仍保留可见，原子移动到 archive，同号冲突拒绝 |
| policy.update | policy | task=policy；旧 policy 维护权限+真实授权依据，替换 body，revision+1；不能用新授予自己的权限批准此次变更 |

`check.assign` 从 C1 逻辑别名收敛为 assignment.set(role=checker)；不保留含义重叠的额外写命令。历史来源代录与 requirement.disposition 为按需动作；正常任务不填空异常对象。所有动作还需 policy 当前 action/task 范围授权；owner 或维护者身份本身不隐含其他动作权。

同一 task/约定的 AC、要求、实体 ID、身份、运行、grant/profile ID、请求 action ID 不得重复；requirement.after 引用有效且无环。独立要求必须由不同实际上下文、非任何候选作者的合格检查者承担；比较字符串只是必要检查，实际独立性必须有来源。候选跨约定、自验借 checker、冒充 confirmation 或无法读差异都不通过。已撤回的指派不能靠提供旧 revision 写当前控制；已有检查者针对旧候选回报，只有其指派尚有效且当前授权仍允许历史事实时可直接收录，否则走代录。

修订算法固定如下：task.open/contract.revise 增加 contract；candidate.submit 增加 candidate 指针修订；assignment.set 增加其 id 的修订，accept 不增加修订但绑定唯一 run；issue.report 创建 1、resolve 增加其修订；block.set/resolve 增加其修订；delivery.record 创建 1、reconcile 和 dependency.clearance 增加其修订；policy.update 增加 policy。其他追加不修改这些修订。除 result 的同负载重送外，新请求重复创建已有实体 ID 退出 5；已接手 assignment 的新 accept 请求退出 4，原请求重试走 receipt。

### 5.2 门槛、结果及状态

每份 result 的 coverage 可覆盖多个要求，逐项为 pass/fail/unknown；必须与约定 AC、方法、对象、必要环境相符。任何 fail/unknown、矛盾结果或 issue 限制在相关对象仍有效时均阻止门槛；新的 pass 不自动覆盖旧 fail。后续结果 corrects 只声明关联，解除仍需合格 issue.resolve 或具体来源 clearance。故障修复需要修改产物时以新候选进入 active→verifying；仅证据不足则 verifying；交付后验证未齐保留 delivering。结果接收后由重建计算缺口和必要回退，终态不回退。

condition 是需有事实依据判断的条件说明，不执行文本表达式；默认要求适用，仅明确的合格 not-applicable 处置可排除。result.prerequisites 列出实际使用的前置结果 ID，与 requirement.after 逐项对应并核对对象/适用性；报告能证实真实先后关系才满足要求，不能仅比较时间字符串。缺前置证据可以保存检查事实，但该要求不满足。accepted-risk 处置不能绕过 waivable=false、独立要求或外部强制审批；需有匹配且合法的 requirement.disposition，缺失时仍阻断。

旧候选的未处置失败/未知不会因切换当前指针而消失：作为 result ID 来源限制继续影响本任务相关要求及交付，直至创建引用该 result 的 issue 并由合格 issue.resolve 给出 corrects 关联及复验/排除依据。无需先补 issue 才能阻止放行；需要关闭时才建立处置链。约定变更若排除原范围，也须有明确决策和合格排除依据，不自动洗掉旧失败。复用第一版仅支持同 ID 且语义/方法/条件保持一致的 AC/要求；要求改名或语义变化不能仅靠 applicability.requirements 任意映射为通过，须重验或另行精确设计。

状态控制固定：非 legacy 任务 task.open→todo；work.begin 只从 todo/verifying/delivering 转 active（用于开工或明确开始返工）；candidate.submit 从 active/verifying/delivering 转 verifying；前门 advance 只从 verifying 转 delivering；task.complete 只从 delivering 转 done；task.cancel 从任一非终态转 canceled。before-delivery 证据失效令 delivering 回 verifying；仅 complete 要求失败/未知保留 delivering，需改产物时由 owner work.begin 明确转 active。work.begin 的 start 不因当前候选自身待修问题阻断，仍检查上游、隔离及 start 阻塞，避免无法进入修复。无需产物的其他追加不擅改主状态。

start：约定/owner 接手/隔离/依赖消费齐备且无相关阻塞；若有已批准 dependencies，每个须完成一次明确 dependency.consume，开工前再重算该版本当前可依赖性。planning/协调可在 todo，不冒充依赖已满足。before-delivery：当前候选匹配当前约定、所有交付前要求有适用通过或合法处置、无相关失败/未知/阻塞/依赖限制。complete：重算前门及完成检查，存在达成该约定边界的真实交付和被允许的确认者，实际版本映射及要求适用，全部遗留责任已处置或明确合法接受。retry：所有相关前次尝试 actual 已确认，retry_safe=yes，残留影响及新外部审批齐备；账本只报告准备结果，不执行外部重试。

start 的目标是 `{contract_revision,binding}`，其中 binding 是 owner 指派 ID/修订，尚未指派时允许 null；**不接收 candidate 字段**，首次开工也不需伪造候选。gate.evaluate(start) 的 expected 必须恰为 contract/assignment；前者匹配当前约定及 target.contract_revision，后者匹配当前 owner 指派及 binding.revision，binding=null 时必须为 0 且当前无 owner 指派。结构错误退出 2，修订不符退出 4；修订一致但缺接手、上游消费或 start 阻塞则评估成功、退出 0、gates=blocked。它只记录准备评估，不开工；实际 work.begin 仍重新校验并在不满足时退出 6。响应 start gate 的 candidate 恒为 null。其他门槛必须使用真实存在的 candidateRef，不能传 null。

completion_children 只在 complete 要求逐子成功交付、明确消费及版本仍可依赖；它不阻止父 before-delivery 的组合版本检查/集成准备。已经消费的任何子版本若出现纠正，仍按 §7 阻止受影响交付，不因名单类型不同而忽略限制。

gate.evaluate 的 blocked/unknown 是**成功完成的评估**，不是写入异常。若同批 result.append 成功而 gate 不通过，batch 仍提交事实及评估，响应退出 0，并在 gates 给缺口；调用者不能反复写结果寻求绿灯。task.complete/work.begin/candidate.submit 等真正修改受门槛约束状态的动作，前提不满足则整个 batch 退出 6、无事实提交；需要先保留检查事实时，应使用第三组 result batch，第四组再完成。

终态 done/canceled 不允许约定、候选、责任或生命周期控制重开。允许真实历史结果、问题、外部补充观察、处置、clearance 及归档；当前可依赖性按具体交付动态计算。需求继续修改时创建关联补救任务，不抹掉原接受/取消事实。未知配置、版本、循环、缺引用或源证据不可信均不放行。

### 5.3 共享 policy

policy 包含 revision、body(identities/runs/grants/defaults)、decision；快照历史由 Git 保留，不增加每次全量复制。grant 精确列 id/identity/actions/read_actions/tasks/confirmers/basis；actions 仅 24 个写动作，read_actions 单列下节的七种读能力，均可为空数组，但同一 grant 至少有一种能力。tasks 仅具体编号、`new` 或 `*`，不以模糊前缀扩大范围；`new` 只匹配创建，不匹配任何已分配编号的读取。defaults 的 requirements/boundary/coordinator/dependencies 固定版本读取。写入代码等工作范围由 contract 表达，账本不能阻止绕过工具的磁盘编辑。

启动 bootstrap 没有可自授予的 API：由用户或明确委任维护者在 D 安装流程中离线审阅并签认首份 policy；固定该来源并提交，再启用写入口。维护 grants 变化由旧快照授权，policy.update 独占 batch；失败不产生部分授权。未知/撤销 identity/run 无受限动作权，调用者环境名单没有补权作用。代录只赋予记录动作权，不能伪造源授权、独立性或外部平台权限。

### 5.4 只读查询及读取范围

query 是第八类结构文档，精确含 kind/protocol/actor/op 及下表对应字段；无 request_id、actions 或 expected，不生成事实/receipt，不改 INDEX。读取以一次固定已提交快照为准，先核对当前 identity、run 均 active 且对应关系正确，再合并该 identity 当前有效 grants。没有默认公开的任务或“本人历史自动可读”规则；写能力、owner 身份、检查指派均不自动产生读能力。原共享授权的本地信任边界保持，不声称可阻止绕过工具直接读磁盘。

| op / read_actions 能力 | query 额外字段 | 读取范围和返回 data |
|---|---|---|
| task.read（show） | task | 对该 task 有此读能力；data 为 op/task 完整任务 |
| task.list（list） | 无 | 仅枚举有 task.list 的编号范围；data 为 op/tasks 摘要数组，其他任务的标题、数量、编号均不返回 |
| task.check（check） | task | 根任务须有 task.check；data 为 op/task/consistent/gaps/readiness，三层诊断不等于实际技术验收 |
| task.handoff（handoff） | task | 根任务须有 task.handoff；data 为 op/task/text，只生成交接正文，不发消息 |
| gate.read（gate） | task、payload | payload 为 start 的 contract/binding 目标，或其他门槛的 candidateRef；无 advance。data 只有 op，实际结果在 response.gates |
| receipt.read | receipt_id | 对 receipt 实际涉及的**全部** task ID 有 receipt.read；data 为 op/receipt，保留原 actor、事实接收和历史 gates |
| policy.read | 无 | 须有 read_actions 含 policy.read 且 tasks 含 `*` 的 grant；data 为 op/policy 当前快照 |

除 task.list 按合法范围过滤外，查询均不部分成功：根对象读能力不足或 query 的关联闭包中某任务不可读，退出 3，data=null/gates=[]/action_results=[]，仅给不泄露被拒绝任务 ID 的 READ_SCOPE_DENIED。check/handoff/gate 若需读取其他任务的消费边、限制或清除依据，调用者必须对每个被读取任务另有 task.read；不是只检查根任务后偷偷跨范围读。task.read 返回本任务中已有的固定引用，不自动展开附件或其他任务。查询引用的历史 policy 可由内部验证读取，但只有 policy.read 可输出完整配置。scope 检查早于向调用者返回对象存在性、缺口及关联内容；已获根任务范围但根对象确实缺失时退出 2 NOT_FOUND、data=null；根存在而可读关联对象缺失时，check/gate 只读报告一致性/unknown，不假装通过。

task.list 对不存在的显式编号不增加“有权但不存在”条目；既无该能力也无任何允许范围时退出 3，合法范围当前为空则退出 0 返回空数组。receipt 的范围从原 action_results 的已分配 task ID 推导，不从重试者传来的 `new` 或当前指派推导；若含 task=null 的 policy 事务，则还必须有 `*` 范围的 receipt.read 及 policy.read。多任务 receipt 缺任一范围时整体拒绝，不只展示本人部分。

receipt_id 不存在时无法从原记录推导任务范围：只有持 `*` receipt.read 的当前调用者可得退出 2 NOT_FOUND；仅有局部范围者退出 3 READ_SCOPE_DENIED，不用差异化错误泄露其他范围的 receipt 存在性。已有 receipt 则无论是否本人创建均按实际全部目标检查，policy 事务仍须附加 policy.read。

写 grant 被撤回而 identity/run 仍 active、读 grant 保留时，可读历史/查询门槛；identity 或 run 已 revoked 时所有受保护查询及 apply 重放都退出 3。恢复后的新 run 必须先在当前 policy 登记授权；可用 query(receipt.read) 读取有权历史，不能换 actor/run 后沿用旧请求的 K 假装同一次重放。doctor 不要求这些权限，但仅报告依赖可用性、安装版本及定位，不读取/输出任务、receipt、配置正文或门槛；它不能充当查询降级通道。

gate.read(start) 与写评估使用同一 startRef，但不做 CAS。目标 revision 已非当前时，退出 0，gates=unknown、缺口 TARGET_NOT_CURRENT；合法目标缺依赖时退出 0 blocked，不退出 6。查询从不推进状态，不能携 advance。新的写动作必须在锁内重读当前权限和事实；只读返回 pass 不构成未来放行令牌。

## 6. 响应、重试和诊断

response 精确字段见 Schema。响应文件先写同目录临时文件、flush 后原子替换；标准输出只在未给 response-file 时输出一个 JSON，诊断到 stderr。response 文件失败发生在提交之后时退出 9，不撤销已提交事实；以原 request ID 查询/重试，不能改 ID 重做。响应不包含密钥/环境全量；错误只给对象 ID、稳定 code 与可行动消息。

| exit | status / 持久性 | 含义 |
|---|---|---|
| 0 | committed / durable=true | 已确认 Git ref 更新且物化核对完成；门槛是否通过另看 gates |
| 0 | replayed / durable=true | 同 ID 同 K；不新写。original_commit 为原提交，gate_context=historical，旧绿灯不能当新批准 |
| 0 | read / durable=false | 只读结果，commit 是此次读取快照（无可读快照可为 null）；gate.read 用 current-read，receipt.read 用 historical，其余 none |
| 2 | rejected / false | 编码/JSON/Schema/未知动作或字段/非法路径/引用自洽错误 |
| 3 | rejected / false | 当前身份、运行、动作授权、确认者、指派或独立性不符 |
| 4 | rejected / false | 对象 expected 修订冲突；重读，不自动改负载重试 |
| 5 | rejected / false | 请求/实体 ID 重用而 K 不同 |
| 6 | rejected / false | 受限状态动作的业务前提、门槛、依赖、隔离或时效不满足 |
| 7 | rejected / false | 版本不支持或必须显式迁移 |
| 8 | rejected / false | 缺运行时/依赖/Schema；doctor 也可能只能给文本诊断 |
| 9 | indeterminate / false | I/O/Git/提交结果或工作树物化未确认；停写，走恢复；false 表示**未能保证**，不证明没提交 |
| 10 | rejected / false | 获取锁超时、现有待恢复事务或旧进程隔离未完成 |
| 11 | rejected / false | 当前业务树/暂存脏状态、越界路径、摘要变化或恢复资料矛盾；先人工处理 |

response 增加必需 data：committed/replayed/rejected/indeterminate 均为 null；read 按 §5.4 的闭合 readData 返回，不复用任意字典。rejected 的 commit/original_commit 为 null、action_results/gates 为空、errors 非空；batch 预检失败无部分结果。committed 的 commit 非空、original_commit=null、errors=[]、gate_context=at-commit；replayed 的 original_commit 非空、commit=null、errors=[]。receipt.read 的 original_commit 为原 receipt 所在提交，data.receipt.gates 是历史，不复制到当前 response.gates；其他 read 的 original_commit=null。只读数据一致性诊断在 data.gaps，不把诊断结果当受限状态推进。indeterminate 不返回可执行的通过门槛。读取响应不承诺下一次写入仍合法，推进必须锁内再算。

apply 的处理顺序：依赖/版本及严格解析 → 获取锁和恢复守卫 → 读取已提交当前 policy，核对 identity/run active 及其对应关系 → 内部查找 request_id 的 receipt，按下面两条分支处理。内部查找不意味着向未授权调用者暴露 receipt 是否存在。

- 已有 receipt：先按 §5.4 检查全部目标的 receipt.read（policy 事务还需 policy.read），不足退出 3；读取许可后比较整个 K(request)，不同退出 5，相同退出 0 replayed。此分支**不重新要求原写 grant、指派或 CAS**，不重新计算/推进 gate，只返回历史接收结果；原请求 actor 必须仍是同一 active identity/run。查询其他人的 receipt 走 query，不用伪造其 actor。
- 没有 receipt：才逐动作检查当前写动作授权、指派、expected、关联及业务门槛，成功后构造事实/缓存/receipt 并按 §8 提交；无写权退出 3。内部校验读取在所授写动作的对象范围内，不因此授予任意查询/重放权；跨任务源对象仍需 task.read，拒绝时不得泄露范围外正文。新写请求无需另具 receipt.read 才能首次提交，但没有该能力时将无法通过原 ID 获取历史，预检应报告此准备缺口，不能静默授予读权。

成功 receipt 不恢复任何写权；新请求不能借历史绿灯推进。失败请求不预留新 ID；撤权之后的新 ID 不存在可重放 receipt，则按新请求拒绝写入。query 仅依赖读能力，使用一致的已提交快照和恢复守卫；有待恢复事务时可读取已确认 Git 快照并标注物化未确认，不把工作树半成品当事实源，不能确认快照时退出 9。

同 result ID 同 K(result) 的重送可以被新请求幂等接收，仍校验当前记录权，action_result.events=[]；相同请求重放不得重新 gate.advance 或 task.complete。想重新计算使用新的**只读 gate 查询**；想实际推进使用新请求并带当前对象修订。

## 7. 纠正传播与外部实际状态

已记录的依赖边固定 upstream task/delivery；本任务完成时，该消费集合绑定其 delivery。可依赖性为 usable/needs-review/unusable，由实际交付事实、未解问题和可达上游限制重建，非人工 current 开关。关键失败/unknown 的结果自动成为对应版本的限制来源，即使尚未补写 issue，也不得放行。已知聊天问题但尚未代录时，人必须暂停相关动作；工具不能感知未登记消息。

对所有已知消费边做带版本的图遍历；完整限制键为 `(restriction_task, restriction_kind, restriction, restriction_delivery)`，分别是来源任务、result/issue 类别、来源实体 ID、来源实际交付 ID。dependency.clearance 还必须指定本任务 delivery、真实合格检查结果及依据，键中各项不得省略、null、使用当前候选替代或写通配符。先验证来源实体确实限制该来源 delivery、本 delivery 存在且该来源可沿实际消费边到达本版本；错误关联退出 2，缺合格排除/重验依据退出 6。对尚无实际交付的候选问题仍保留本任务门槛限制，不构造假 delivery，不用 clearance 清除，走 issue.resolve。

同一来源 issue r 若关联 A@a1/A@a2，则为两个不同键；B@b 只排除 a1 时，a2 不变。a1 经 X/Y 多条路径都到 B@b 时，clearance 是对“这一完整来源键在 B@b 的全部已知消费影响”的确认，需证据覆盖这些输入；只核对其中一条路径的报告不足，退出 6，不能用一次局部核对解除整节点。合格确认只切断经过该 B@b 的匹配路径；另有 A@a1→Z→C 绕开 B 的路径时仍阻止 C。clearance 的适用范围由本任务/本 delivery/完整来源键定位，记录 ID 独立；同 request_id 同 K 重试走 receipt，新评估须新记录 ID 及 delivery CAS，不覆盖旧记录。按该记录所在提交树重建当时全部已知消费关系；新发现未覆盖消费关系使旧排除不再充分，保留未知，不自动扩大范围。

传播时相同完整键可在显示中合并，但必须保留可达路径/节点依据，不能先全局去重再错误忽略绕行路径；不同源 delivery 永不合并。终态、通知或某个清除事件不抹掉其他来源。循环、任务缺失、归档重复、不可解析版本、排除依据失效或出现未覆盖路径均返回 unknown/blocked；不得以 visited 防无限循环后直接视为通过。

issue.resolve 解除自身问题来源，不能解除其引用的其他原始失败；如失败被证明无效，处置事实必须同时明确关联该 result 的纠正与合格复验，派生算法才关闭对应失败来源，独立要求不能作者自批。清除某来源后重新遍历剩余来源；通知、超时、取消下游、owner 换人均不解除限制。

delivery.record 每次独立尝试 ID，accepted/succeeded/failed/unknown 只是确认来源中的观察。失败和未知仍应及时保留，即使当前门槛已不满足；这不等于批准此前越权动作。delivery.reconcile 追加实际版本、effects、retry_safe 与依据，不覆盖原尝试。非外部小任务可直接以 accepted 交付记录及用户来源完成；外部任务的 succeeded 不代替部署后检查、迁移效果确认或外部审批。工作回退不撤销外部事实；终态出现新失败产生限制并建立补救任务。

## 8. 事务日志和恢复设计

以下是 D 必须实现并验证的算法契约，本次没有执行它。Git 提交作为当前克隆的业务持久化点：生成对象、私有 index、新 tree/commit，然后 `update-ref <目标分支> <新commit> <base>` 比较并交换；不用用户 index，不把整个工作目录 git add。写前拒绝任务中心受管文件的未提交更改、可疑符号链接/重解析点、未知资产；实现工作区的普通代码修改不归此事务暂存。

事务白名单：version、policy.json、next-id、receipts 中本请求路径、受影响任务/归档路径及生成 INDEX；迁移另需已批准计划逐项列出的工具/模板文件。任何最终解析路径必须留在核准工作树内；路径按 `/` 分段，拒绝绝对路径、盘符、`.`/`..`、空分段、大小写等价冲突、符号链接/重解析越界和额外文件。backup URI 是克隆外位置，不按业务相对路径处理。迁移前后目录范围分别核对。

| 日志 state | 必须已持久保存的事实 | 故障后选择 |
|---|---|---|
| prepared | 基线 commit、请求 hash、路径及 before/after 字节 hash、外部临时资料位置 | 确认 ref 仍 base 且没有新 commit 后，可弃隔离资料；不改业务事实 |
| objects-ready | 上述事实及 new_commit、私有对象树和可重建 receipt | ref=base 可明确中止；ref=new 视为已提交；第三个 ref/缺对象停写 |
| ref-updated | ref 已指向 new_commit，日志随后写入 | 不重新执行动作；从新提交按白名单物化工作树 |
| materialized | 受管文件字节与提交 tree 完全一致、索引已同步核对 | 标记完成并释放锁，返回成功；日志可归档清理，不删除业务 receipt |

日志使用 Schema 的 journal；所有 before/after 为文件原字节 hash，新增/删除对应 null。prepared 的 new_commit=null，其余必须非空；changes 路径唯一，receipt_path 在本请求白名单。日志先写临时文件、flush/fsync、原子 rename；父目录持久化/Windows flush 的具体平台能力在 D 探针验证，不能证明则不承诺断电原子性，拒绝宣称发布就绪。

`update-ref` 成功但日志仍 objects-ready 的崩溃窗口：以真实分支 ref、commit 内容及 receipt 的 request/hash 为准认定提交；不能只按日志 state 回滚。若 ref 已前进到可验证后继且包含相同 receipt/路径历史，可先只读展示，但不自动恢复未知中间状态，停写等待人工选择。new_commit 不存在、ref 既非 base/new、工作树含用户不同改动、日志 hash 不符或多个冲突事务均退出 11，保留所有资料。

恢复入口默认只读预览，需列出 ref/base/new、receipt、每个文件当前/期望 hash、可用选择及风险。显式 apply 仅在已授权恢复范围内：未提交的隔离事务可放弃；已提交事务只补物化与索引，不重做检查或外部动作；恢复旧业务版本须另获授权并创建可追溯反向提交，不能隐式 reset/覆盖用户文件。拿不到旧锁不删除它；核查锁 owner/run、进程和副本后由有权者提供隔离证据再接管。

业务改动、policy 变更、依赖检查使用同一 common-dir 锁。锁内重读最新 policy、所有被读取任务和限制；任何额外分支写者会触发 update-ref CAS 冲突并停写重读，不自动复用旧门槛。锁不包测试、网络、人工等待或外部 API。Git hook/签名不得产生未审外部效果，D 使用明确受控的提交环境并公开限制。成功后仍不保证远端同步或强身份认证。

## 9. 兼容、迁移预览和恢复范围

version 保持独立工具/格式数字及 source-revision；新目标标记 tool-version:2、schema-version:3。旧普通写入口应拒绝新标记；现行 recover 路径有绕过普通 version_check 的特例，因此不能仅靠改标记证明所有旧操作隔离，迁移还必须清理/处置旧待恢复事务并停用旧入口。新入口遇 tool1/schema2 只读识别并给迁移指引；未知更高组合拒写。此双端动态兼容与旧 recover 隔离留 D 验证。

迁移绝不由普通 apply 自动执行。独立的 preview 输出 Schema migration-plan：固定 source_commit/source_tool/source_schema、目标版本、固定工具 source_revision、逐条旧/新路径和摘要、ID 映射、next_id、待补/冲突、policy_proposal、克隆外备份清单、隔离和批准来源。mode=preview 的 approval/isolation_evidence 为 null；mode=approved 必须均非空、issues 不含阻断项，源树和备份摘要再次核对。不填 new_hash 表示还未获得确定输出，不能 apply。

预览不改源库数据、版本或安装资产；只写用户指定的克隆外产物目录。完整备份保存受管工作树资产和原字节、活跃及归档任务、编号/版本、Git refs/bundle、发现/旧事务资料及其摘要；不把新的备份放进旧库后误算为业务文件。含凭据的环境/无关用户数据不收集。备份可读与对象可恢复性必须验证，不能仅记录路径存在。用户未授权 D 和此次迁移时，即使 approved 示例可解析也不能 apply。

| 旧状态/信息 | 目标与待补约束 |
|---|---|
| 待办 / 已认领 | todo；owner 仅 legacy 提示，不授予权限/接手 |
| 进行中 | active 历史映射，但缺现代约定/责任的受限动作停在待补 |
| 待审核 / 待测试 | verifying；缺候选、来源或检查标 missing，不造通过 |
| 待合并 | 预览优先 verifying；只有独立复核新前门后才能 delivering，不信旧标签 |
| 阻塞 | 按可证明原阶段映射并补 block；无法推导则此项阻断，new_state=null |
| 已完成 / 已取消 | 保留终态、legacy 原文/摘要/协议；证据缺失未知，不伪造 delivery 或重新接受 |
| 旧 ID、角色、身份 | 归一化先查等价冲突；身份只作为登记提案，由授权维护者另行确认新权 |

导入结果的 legacy 字段固定原 source、协议、原状态、映射、missing、owner_hint；未补现代记录时 records 可为空，current 从 legacy 取原阶段，其 contract/candidate_revision/seq=0。此为保留历史的例外，不能把无约定任务当作可推进。首次合法 contract/assignment 需真实新来源；旧终态缺交付的可依赖性保持 unknown，可在关联补救任务中核验历史版本，不借迁移补造原验收。

表中旧状态是现行 Markdown 的实际中文值，不把命令名 done 或推测的英文标签当作原状态。旧依赖、备注、负责人、字段和原始进度全部留在固定原文件/备份；有效依赖必须经真实约定变更映射到新 dependencies，再核实实际消费版本。无法可靠转换的字段逐项进 missing，不因只保留现代核心字段而删除原文；旧环境角色只供提案，不构成 bootstrap 授权。

apply 前在源基线重做只读预览；固定新增 policy 批准来源；核实所有旧进程/副本停止或隔离，旧 pending journal 先合法处置，common-dir 守卫阻断新旧工具。生成完整隔离目标树并 check，获得具体迁移确认后，以 §8 提交目标资产/数据/版本；版本与数据须同一提交，不逐文件暴露混合格式。工作树物化未完成仍停写。新工具 rollback 不等于外部业务数据回滚。

失败恢复：ref 未更新则源安装/数据保持，清理仅限可证明的本事务临时资料；ref 已更新则先完成物化或停写，不静默换回旧脚本。若明确选择回到备份，需核对无后续业务写入、单独批准恢复计划，恢复资产/数据/ref/发现信息的一致集合，保存失败候选和后继事实；存在迁移后新事实则只能设计补偿/反向迁移，不能覆盖丢失。备份不完整或隔离不能确认时不继续 apply。

## 10. 正常数据、异常向量与统一验收

[完整正常数据](examples/workflow-stage-c-complete.json)全部是虚构来源，包含初始 policy、四个 request、预期累计任务、响应及恢复/迁移形状示例；外层有 example_only，**不是可直接 apply 的单个请求**。每组内只含一个实际 actor。第一组继承默认并经已有授权建立约定、owner 接手和开工；第二组提交固定候选、自验和 checker 指派；第三组由另一实际运行接手并追加一份多要求独立报告；第四组在真实接受来源已经存在后记录交付、评估前门和完成。没有提前把接受写进第二组，没有额外人工同步索引。附加 prestart_task 是第一组前三项之后、work.begin 之前的快照；start_evaluation 与七个 queries 演示新入口形状，不追加进原四组。clearance_request 则是独立 a1/a2 汇合反例的结构探针，引用背景见向量的 restriction_cases，不表示正常任务已存在 delivery-b/verification-one 或已允许清除。

[设计向量](design/stage-c/vectors.json)包括字节/结构正反例、正常关联、业务静态场景，以及本次补充的 decision_cases/restriction_cases。后两者只对“读取/重放/新写分支的判定表”和“完整来源键及路径集合选择”做纯数据断言，专门防止正文与向量再次出现分支冲突；没有读写真实 policy、Git 事务或执行任务动作。其余业务场景的前提、动作、预期码/事实/门槛及不得发生项逐项静态推演。业务表不是新工具的运行结果，不能以验证器支持某种输入结构证明权限、事务、崩溃或并发已实现。

C2 统一 AC：

1. **AC1 格式**：八类文档（task/policy/request/query/response/receipt/journal/migration）结构闭合，字节/K/时间/引用/legacy 例外明确；正反例和本地引用完整。
2. **AC2 操作**：24 动作的负载、权限、CAS、批量/幂等/响应区分可确定；四组路径不代填未来接受，不重复手填派生状态。
3. **AC3 异常**：失联与恢复、并行结果、交付后失败、终态纠正及主方案 §10.1 场景均有设计向量；原事实/限制不被新绿结果吞掉。
4. **AC4 兼容与恢复**：解析依赖/部署成本、两端范围、新旧拒写、旧 recover 特例、只读预览/完整备份/隔离/恢复选择明确，不执行 D。
5. **AC5 阶段闭环**：re1 对完整固定候选独立复核并关闭阻断项，用户接受；之后才可登记 C 格式冻结。本轮作者自检不能代替该项，进入 D/E 仍须后续明确授权。

本轮按用户“一次性完成 C 阶段所有任务后再做总结和检查”的要求，将五项精确设计连续完成后统一自检并固定一个候选，不逐项索要决定。新增依赖、格式、receipt 和设计验证本身都是建设成本；人工 H、Agent A、完整保存次数和收益未知。未更改现行模板/生产脚本/安装器/任务数据，未提交、部署或迁移；C1 接受和 C2 送检位置只在唯一状态页登记。
