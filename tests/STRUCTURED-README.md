# 结构化候选的隔离验证

测试仅在新建的临时仓库/worktree 中运行，包括安装、迁移及恢复。不要将 TASK_TEST_ROOT 指向真实项目。失败目录保留以便核对 pending、Git ref 和原字节；测试不会运行外部业务检查、发布或部署。

先使用固定运行时锁和六份本地 wheel，运行 `scripts/prepare-task-center-runtime.py prepare --wheelhouse <wheel目录> --lock <制品锁JSON> --destination <新的隔离运行时目录>`。准备本身需要当前解释器已有 pip；不安装全局依赖。Windows 与 Linux 使用各自的制品锁，不能跨平台复用 native wheel。准备程序输出 runtime-lock.json 的 SHA-256。

在仓库根目录运行，测试前重新生成安装资产清单；这一步应得到与固定候选相同的清单。不要在套件运行时修改模板来源。

```powershell
$env:TASK_TEST_RUNTIME = '<已准备的Windows运行时目录>'
$env:TASK_TEST_ROOT = '<隔离测试父目录>'
$env:TASK_TEST_BASH = '<Git Bash可执行文件>'
$env:TASK_TEST_PWSH = '<PowerShell 7可执行文件>'
python -B scripts/build-task-center-v2-assets.py
python -B -X utf8 -m unittest discover -s tests -p 'test_structured*.py' -v
```

```bash
export TASK_TEST_RUNTIME='<已准备的Linux运行时目录>'
export TASK_TEST_ROOT='<本地文件系统隔离测试父目录>'
export TASK_TEST_BASH=/usr/bin/bash
python3 -B scripts/build-task-center-v2-assets.py
python3 -B -X utf8 -m unittest discover -s tests -p 'test_structured*.py' -v
```

Windows 入口测试实际调用 Bash、Windows PowerShell 5.1、PowerShell 7 和 Python；Linux 入口测试调用 Bash 和 Python，不把缺少 PowerShell 算作通过。测试使用每个平台原生 Git/路径和独立临时 Git 配置，打印保留的 fixture 根目录。并发测试启动两个真实写入进程；硬退出测试仅在测试子进程中注入 os._exit，不给生产 CLI 增加环境变量后门。

`test_structured_task_center_vectors.py` 实际执行冻结的 67 组结构、11 组词法、6 组 K 向量。设计文件中的 decision/restriction/semantic 文字用例不是现成请求；业务证明来自具名集成测试，不把静态文字遍历冒充程序执行。

`test_structured_task_center_review.py` 针对 D1-c1 独立复核的三处缺口补 6 项回归：第二份终态交付与后补消费的上游传播；历史代录的原候选、角色、完整覆盖、独立性及合法撤权来源；prepared/objects-ready pending 和预览至锁内执行的交错。恢复拒绝须保持 ref、版本、登记和原 pending；放弃未提交事务后可恢复旧格式，补齐已提交事务后则受后继事实保护。

旧工具另跑既有五组 setup 回归和 `task-center-conformance.ps1`。平台版本、原始失败、最终日志、未覆盖范围及固定候选摘要统一见[阶段 D 报告](../optimization-stage-d-report.md)。
