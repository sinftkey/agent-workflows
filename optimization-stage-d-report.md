# 阶段 D 实现与统一验证

2026-10-16，D1-c2 作者修订及验证完成，固定送检。D1-c1 已经 re1 独立复核，发现三项 P2，AC1/AC2/AC3 不通过，未登记接受；本稿补充修订与回归，原 c1 固定包保持原字节。当前授权和阶段状态以[试用安排](optimization-trial-arrangement.md)为准；c2 独立复核、用户接受及发布仍待实际发生。

## 约定与边界

基线为 C 接受提交 `c61a5df8ab5f213edc31c510f5d09b2e0b3f4466`，实现分支 `codex/feat/structured-task-center`。依据[冻结设计](optimization-stage-c-spec.md)及 C2-c2 固定归档，保持 C 技术稿/Schema/向量/示例原字节，D 增量另行定位。README 的实施说明可以按 D 同步，原送检 README 由 C2-c2 归档保留。

实现包括共享核心、Bash/PowerShell 入口、24 写动作、7 读能力、对象修订/幂等/授权/门槛、依赖纠正、Git 私有索引事务、故障恢复、两端新安装器、离线运行时、预览/备份/迁移及安全恢复、文档及回归。旧工具保留独立入口，但补齐 recover 新格式拒写和适配器两类任务中心隔离。候选实现不安装到真实项目、不操作真实业务数据、不执行外部消息/API/部署；E 仍未授权。用户本轮没有要求本地提交、推送或合并。

D 验收：AC1 实现与冻结语义对应，正常四组、批量原子性、历史结果和读写/确认者边界一致；AC2 临时真实 Git 仓库中验证双端、权限、并发、幂等、纠正、故障/恢复；AC3 迁移只读源预览、完整备份、终态未知保留、隔离、拒绝冲突/后继事实覆盖，失败可恢复；AC4 文档/适配/依赖资产同步及部署成本明确；AC5 re1 整体独立复核后用户接受。原 D 的跨平台发布、运行保障及“没有增加总负担”退出条件须如实核对，不能用功能自检或合成样例补成量化收益。

## 实现中的明确选择

- 新资产在 `templates/task-center-v2/`，旧 `templates/task-center/` 保留 tool1/schema2；新安装器显式选择新资产，不静默改变旧安装器和现有数据。
- 新安装使用克隆外空目录及独立孤儿分支，路径登记在共同 Git 目录。安装资产包含原 MIT 许可。C 四份技术源保持原字节；包内 Schema 仅将 `$id` 改为通用协议命名空间、将设计注释改为运行注释，所有验证约束与冻结源逐项相同。
- gate.evaluate 未推进时只保留 receipt 诊断，不写生命周期推进事件；通过且 advance 的前门才产生任务事件，历史可从任务事实重建。
- clearance 的 basis 指向带实际报告引用的结构化核对依据，列出完整来源键、本版本、全部已知消费边和结果 ID；只覆盖一路的依据被拒绝，防止把自然语言附件当任意解除选择器。正常路径不额外填此异常资料。
- 运行时从本地固定 hash 的六份 wheel 离线准备，不在任务命令中联网/安装；许可证文本和安装文件逐项 hash。候选尚未获得跨平台发布批准，安装必须显式用于隔离候选，真实项目安装继续保留给后续决定。

## 实现与验收定位

| 范围 | 实现与验证入口 |
|---|---|
| 严格 JSON / Schema / K | [codec.py](templates/task-center-v2/scripts/taskcore/codec.py)、[validation.py](templates/task-center-v2/scripts/taskcore/validation.py)；实际执行 67 个结构、11 个词法、6 个 K 向量；另验证 URI 只解码一次、完整 SHA-256 OID 及 Schema 约束等价 |
| 24 个写动作 | [engine.py](templates/task-center-v2/scripts/taskcore/engine.py)、[model.py](templates/task-center-v2/scripts/taskcore/model.py)；约定、指派/接手、开工/进展、候选、结果/历史代录、复用/处置、问题/阻塞、消费/解除、交付/对账、门槛、完成/取消/归档、policy 更新均有处理分支及具名集成断言 |
| 7 种读能力 | [auth.py](templates/task-center-v2/scripts/taskcore/auth.py)与 engine.query；无隐含写权，关联任务及多任务 receipt 先核对完整范围，无部分泄露；历史重放仍要求当前读权和 active 身份/运行 |
| 事务、并发和故障 | [store.py](templates/task-center-v2/scripts/taskcore/store.py)、[cli.py](templates/task-center-v2/scripts/taskcore/cli.py)；独立 R/T 进程追加、五个故障窗口、真实进程硬退出、原 ID 恢复、活锁/错误 token/用户改动保护 |
| 接管竞争 | 固定 inode 上的 OS 文件锁串行化隔离过程，随后核对 token/PID 并保留原锁目录；防止两个恢复者在“核对旧 token → rename”窗口隔离新 owner；Windows 与 POSIX 均验证此交错 |
| 安装、迁移、恢复旧格式 | [install.py](templates/task-center-v2/scripts/taskcore/install.py)；当前格式拒写、预览/克隆外 bundle 与原字节备份、固定计划、旧终态及未知保留、编号高水位、隔离、两侧 ref 故障、后继事实保护、管理事务类型及脏状态保护 |
| 部署资产与说明 | [双端入口说明](templates/task-center-v2/TASK-CENTER.md)、[复现方法](tests/STRUCTURED-README.md)、[Windows 锁](runtime/task-center/windows-cp312.lock.json)、[Linux 锁](runtime/task-center/linux-cp312.lock.json)；README/适配指南/变更记录同步 |

24 动作分组：task.open / contract.revise；assignment.set / accept；work.begin / progress.append；candidate.submit；result.append / record-historical；applicability.confirm / requirement.disposition；issue.report / resolve；block.set / resolve；dependency.consume / clearance；delivery.record / reconcile；gate.evaluate；task.complete / cancel / archive；policy.update。七种读能力为 task.read / list / check / handoff、gate.read、receipt.read、policy.read。

依赖测试使用实际提交的 A 两次交付、X/Y 汇合、B/C 和绕行消费者；精确解除 a1 后 a2 仍阻断，解除两者只放行经过 B 的路径，直接消费 A 的版本仍阻断。部分边证明被拒绝，父的 start 不等待 completion_children，父子反向完成循环被拒绝。合格 issue.resolve 不以新的绿结果自动抹去旧失败；交付完成重新核对实际附件与映射。以上均为隔离协议夹具，不是生产任务成功或真实技术检查的证明。

## D1-c1 独立复核与 D1-c2 修订

[re1 原复核报告](C:/Users/wsssj/.codex/visualizations/2026/10/13/01a13608-e293-7bc1-a84c-42b6d97fce3f/re1-D1-c1-review.md)实测确认三项 P2。原 Ubuntu 全套 32/0 未覆盖这些反例；不能以该绿结果认定 AC1–AC3 已通过。R 的 Windows 全量范围未完成，另有两项双端补验通过；其范围不改写成全量通过。

| 原 P2 | c2 实现与对应回归 |
|---|---|
| 第二份成功交付丢失上游消费关系 | model 从不可变候选及消费事实重建每份交付的输入，终态追加同候选交付沿用该候选输入；候选仍属当前约定时，后补消费同步其各份交付，其他候选/约定不追随变动。dependency_paths/edge_signature 对缺必需输入或不一致绑定保持未知；新增第二份终态交付受晚到上游问题限制、两消费者均拒绝开工、先记录后消费及缺绑定拒绝用例 |
| 历史代录未核对原指派对象与范围 | 仍从原 binding 修订和实际接手事件定位原 policy，核对原来源身份/运行/动作权，并补角色、精确候选、全部 coverage 和独立性校验；直接独立结果同样核对全部覆盖。合法旧来源即使已改派或撤权也能由当前有权者代录；新增错候选、自验借 checker、覆盖越界、候选作者冒充独立来源及合法旧修订/撤权正例 |
| 旧格式恢复绕过业务 pending | restore-preview 检查业务 pending/管理 marker；restore-apply 取得共用写锁后再次检查，pending 返回 10。不改 ref、版本、登记、pending 或创建 restore journal。新增 prepared/objects-ready、预览后锁前插入 pending、显式 abort 后可恢复旧格式、提交后补物化仍受后继保护用例 |

新增 [6 项回归](tests/test_structured_task_center_review.py)已经在旧实现上重现缺口；修复前日志保留。首次 Windows 启动误导入整个 ExtendedTests，主动终止该额外套件；修正为模块导入。修复前 Ubuntu 一次运行还出现子场景复用 legacy 目录的测试错误，已把每个子场景的夹具初始化放在开始处；不把此测试错误计为额外产品缺陷。两份原始记录均随 c2 保存。

c2 作者验证如下；三项 P2 须 re1 复核才能关闭。固定交付为 D1-c2，复核入口 review.md 内的证据均用包内相对链接；manifest 同时列出完整源码及相对 c1 的字节变化，保留原 c1 证据和两份相同摘要的离线包。

| c2 检查 | 实际结果与原始记录 |
|---|---|
| 修复前反例 | [Ubuntu 6 项失败及夹具错误](C:/Users/wsssj/.codex/visualizations/2026/10/13/01a135f7-eb45-7de0-9909-0a2f200e1871/trial/D1-c2-work/suite-linux-before-native.txt)；[Windows 主动中断的误导入套件](C:/Users/wsssj/.codex/visualizations/2026/10/13/01a135f7-eb45-7de0-9909-0a2f200e1871/trial/D1-c2-work/aborted-unintended-imported-suite.txt)，不计完整验证 |
| 首轮修复后定向 | [Ubuntu 新增回归 6/0](C:/Users/wsssj/.codex/visualizations/2026/10/13/01a135f7-eb45-7de0-9909-0a2f200e1871/trial/D1-c2-work/suite-linux-focused-native.txt)，56.664 秒 |
| 最终 Ubuntu 全套 | [38/0](C:/Users/wsssj/.codex/visualizations/2026/10/13/01a135f7-eb45-7de0-9909-0a2f200e1871/trial/D1-c2-work/suite-linux-full-native.txt)，244.005 秒；[环境及资产摘要](C:/Users/wsssj/.codex/visualizations/2026/10/13/01a135f7-eb45-7de0-9909-0a2f200e1871/trial/D1-c2-work/linux-full-context.json)、[完整临时 Git 夹具](C:/Users/wsssj/.codex/visualizations/2026/10/13/01a135f7-eb45-7de0-9909-0a2f200e1871/trial/D1-c2-work/linux-full-fixtures.tar.gz) |
| Windows 受影响范围 | [10/0](C:/Users/wsssj/.codex/visualizations/2026/10/13/01a135f7-eb45-7de0-9909-0a2f200e1871/trial/D1-c2-work/suite-windows-affected.txt)，792.257 秒；[环境及资产摘要](C:/Users/wsssj/.codex/visualizations/2026/10/13/01a135f7-eb45-7de0-9909-0a2f200e1871/trial/D1-c2-work/windows-affected-context.json)。新增 6 项、原历史代录/终态、完整来源解除、迁移恢复，以及 Bash/PowerShell 5.1/7/Python 四入口；本轮没有运行 Windows 全套 38 项 |
| 静态及语法 | [核对结果](C:/Users/wsssj/.codex/visualizations/2026/10/13/01a135f7-eb45-7de0-9909-0a2f200e1871/trial/D1-c2-work/static-check.json)、[四个 Bash 与四个 PowerShell 文件逐个语法检查及差异检查](C:/Users/wsssj/.codex/visualizations/2026/10/13/01a135f7-eb45-7de0-9909-0a2f200e1871/trial/D1-c2-work/syntax-check.json)；C 四份源、15 份安装资产、占位符、通用性、链接、许可锁及密钥模式均通过 |

最终两端资产清单 SHA-256 同为 `71294c65c463232e916b7844fbf12ec7c9192f249adba40b2497fee4374721a0`。测试仅证明表列平台及临时夹具中的程序行为；不替代完整平台矩阵、真实运行验收或量化收益。

## D1-c1 历史作者验证结果与证据

完整运行和失败日志位于本地产物 D1 目录，固定包会收集原始日志、运行时锁及其摘要。测试源码在 tests/test_structured_task_center*.py；不在生产 CLI 设置故障注入环境后门。

| 检查 | 实际结果与日志 |
|---|---|
| 收敛前 Windows 全套 | 28/0，1208.815 秒；[原始日志](C:/Users/wsssj/.codex/visualizations/2026/10/13/01a135f7-eb45-7de0-9909-0a2f200e1871/trial/D1/suite-windows-final.txt) |
| 收敛前 Ubuntu 全套 | 28/0，1324.135 秒；[原始日志](C:/Users/wsssj/.codex/visualizations/2026/10/13/01a135f7-eb45-7de0-9909-0a2f200e1871/trial/D1/suite-linux-final.txt)；该轮运行时位于 Windows 挂载目录 |
| 安装保护/通用 Schema/读范围/OID 补验 | Windows 10/0，231.275 秒；[日志](C:/Users/wsssj/.codex/visualizations/2026/10/13/01a135f7-eb45-7de0-9909-0a2f200e1871/trial/D1/suite-windows-package.txt) |
| policy 计划语义补验 | Windows 4/0，130.999 秒；[日志](C:/Users/wsssj/.codex/visualizations/2026/10/13/01a135f7-eb45-7de0-9909-0a2f200e1871/trial/D1/suite-windows-bootstrap-final.txt)；迁移计划复用初装相同检查，无效身份引用在更新 ref 前退出 2 |
| 最终锁接管与管理回归 | Windows 6/0，181.879 秒；[日志](C:/Users/wsssj/.codex/visualizations/2026/10/13/01a135f7-eb45-7de0-9909-0a2f200e1871/trial/D1/suite-windows-lock-final.txt) |
| 最终源码 POSIX 全套 | Ubuntu 32/0，186.121 秒；[日志](C:/Users/wsssj/.codex/visualizations/2026/10/13/01a135f7-eb45-7de0-9909-0a2f200e1871/trial/D1/suite-linux-fixed-native.txt)、[环境与资产摘要](C:/Users/wsssj/.codex/visualizations/2026/10/13/01a135f7-eb45-7de0-9909-0a2f200e1871/trial/D1/linux-fixed-context.json)、[Git 夹具归档](C:/Users/wsssj/.codex/visualizations/2026/10/13/01a135f7-eb45-7de0-9909-0a2f200e1871/trial/D1/linux-fixed-fixtures.tar.gz)；运行时和 Git 事实均放在同次 WSL 调用的原生临时文件系统 |
| 外层新 setup 双端入口 | [四次实际调用](C:/Users/wsssj/.codex/visualizations/2026/10/13/01a135f7-eb45-7de0-9909-0a2f200e1871/trial/D1/setup-entrypoints-check.json)通过；Windows PowerShell 5.1 与 Git Bash 各执行预览和新安装，预览不创建目标、安装后任务树干净，代码分支 HEAD/工作区保持 |
| 旧工具回归 | 五组 setup 回归均通过；next-id 中断兼容修订后，[双端 conformance](C:/Users/wsssj/.codex/visualizations/2026/10/13/01a135f7-eb45-7de0-9909-0a2f200e1871/trial/D1/task-center-conformance-second.txt)通过；新格式下普通命令及 recover 两端均拒绝 |
| 适配器 | [双端实际复制核对](C:/Users/wsssj/.codex/visualizations/2026/10/13/01a135f7-eb45-7de0-9909-0a2f200e1871/trial/D1/adapter-check.json)通过；两类任务中心均跳过，六份既有文件原字节保留 |
| 静态检查 | [核对结果](C:/Users/wsssj/.codex/visualizations/2026/10/13/01a135f7-eb45-7de0-9909-0a2f200e1871/trial/D1/static-check.json)；Python AST、Markdown 本地链接/锚点、占位符、常见密钥模式、通用模板、资产 hash、C 冻结字节、许可/离线锁；另作双端语法及 Git 差异检查 |

Windows 实测：CPython 3.12.14、Git 2.40.0.windows.1、Windows PowerShell 5.1.26100.9444、PowerShell 7.6.5、Git Bash。Ubuntu 实测：CPython 3.12.3、Git 2.43.0、Bash 5.2.21、WSL2 Linux 6.18.54.1；原生临时文件系统由 stat 报告 ext2/ext3。两端使用独立临时克隆；未验证 Windows/WSL 跨 OS 同克隆混写。

冻结文件中的 75 条 semantic 文字场景保留为需求索引，不把它们全部改称程序运行通过；本轮运行证明来自具名测试、实际临时 Git 对象和上述反例。程序不能验证报告叙述真实、确认者确实说过某句话或两个声明代表实际独立上下文，这些仍须人和 R 核对。

## 已发生的验证与返工

首轮八项核心集成测试：一项通过、七项触发保护错误。定位到 Windows 长路径中 Git 读取完整 commit:path 的 receipt 路径失败；改为每次 Git 调用明确启用 core.longpaths，不改用户配置。首次临时仓库及 pending 日志保留；修订后正常四组/幂等/同 ID 改内容的聚焦测试通过。后续全套结果待完成再统一填写，不把聚焦通过当全套通过。

离线运行时首装因沙箱临时目录权限失败；在授权产物目录用同样本地 wheel 完成隔离重试，无全局安装。六份依赖的制品 hash/许可证已入锁；2026-10-16 OSV API 查询这六个固定版本返回零已知条目，仅表示当次数据库查询，没有安全保证或发布批准。离线制品及原始查询保存在 D1 本地产物目录，未纳入通用模板代码。

补充回归中还发生：测试输入漏字段/误带 expected、错误的数组下标、Windows 路径大小写断言，以及把读写同时清空成非法空 grant；修正测试输入后重跑，原失败日志保留。旧 recover 首次被新增版本守卫误挡，因 next-id 可在合法中断时尚未物化，现将恢复的格式守卫与普通完整性条件分开，双端 conformance 重跑通过。静态检查发现包内 Schema 的仓库命名空间和设计注释，已只更正这两项注解并验证约束相等。

Ubuntu 初次打包补验跨调用引用 /tmp 中的运行时失败，5 个模块在导入前失败，未执行业务动作；现将原生运行时复制、整套测试及夹具归档置于同一 WSL 调用，原失败日志保留。迁移 policy 预检、管理恢复脏状态/事务类型和接管竞争窗口在送检前收紧，均列入最终补验。没有删改失败日志来制作全绿记录。

## 运行时、成本与发布保留项

Windows 与 Linux 各锁定同一组六个版本及各自制品 hash/许可证；原 wheel 组成两个离线包。准备命令要求本地已有 pip；Ubuntu 缺 pip 时只在候选构建目录复用了已有纯 Python pip，不安装系统软件。运行时逐文件校验；两个 release_approved 均为 false，默认安装被发布门槛拒绝。`--candidate` 只用于明确授权的隔离试用，该参数不构成真实项目安装许可。安全查询原始结果及运行时准备记录随固定包保存。

一次任务正常夹具实际产生四个业务请求、四份 receipt、四个 Git 提交和 12 条事件；安装另有初始提交、policy 审阅和运行时准备，事务还会写私有索引/日志/备份/物化文件。七类只读查询不生成业务 receipt。这里没有把“四组”写成完整磁盘保存或行政操作次数，也不将测试耗时当作 H/A。

本轮用户只作一次 D 阶段决定，实施中无新增权限询问、无自动跨聊天派发。技术修订及重复验证均属于实际建设成本，完整人工 H、Agent A、配置摊销及总保存次数未知；B 的量化缺口保留，没有“工具化减负已达标”结论。

| 保留项 | 交付后的边界 |
|---|---|
| 独立 review 与用户接受 | AC5 待 re1 对固定候选复核，再由用户接受；作者自验不替代 |
| 原 D 总负担退出条件 | 尚未证明，沿用 B 的未知状态；不以测试通过补判收益 |
| 完整平台发布矩阵 | CPython 3.11/3.13、其他架构、macOS、最低 Git/Bash/PowerShell 等尚未实测/制品锁齐；当前两平台 CPython 3.12 是候选验证范围 |
| 断电/磁盘故障 | 文件 fsync 与进程退出已覆盖相应路径，Windows 目录项断电持久化未证实；不是断电保证 |
| 真实项目与外部事务 | 无真实安装、迁移、部署、消息发送或 API/平台操作；所有移植/恢复验证使用临时夹具 |
| 后续阶段 | E 未授权；不自动开始真实使用、数据迁移、发布或下一阶段 |

本修订完成作者验证后重新进入统一复核；整体 D 发布退出条件保持未通过。D1-c2 另存固定候选，D1-c1 保留；包含完整源码/逐份摘要、两端离线包、原始日志及相对 c1 的差异。R 另存独立报告，结果只在状态页登记，无需新增接收回执。
