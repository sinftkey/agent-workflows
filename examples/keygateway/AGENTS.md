# KeyGateway — Agent 准则

本文件是给在本仓库内工作的 AI Agent（如 Codex）及协作者遵循的项目约定。用户明确指令优先于本文档。

## 1. 项目概览

KeyGateway 是一个本地运行的 AI API 网关（Rust），负责：

- **认证**：校验客户端携带的代理 Key（`kg_` 前缀）
- **路由**：根据请求中的 `model` 映射到上游 provider 与真实模型名
- **协议匹配**：校验请求端点协议与 provider 协议一致
- **转发**：构造上游请求并透明透传响应
- **审计**：记录请求元数据（不含任何密钥）
- **KeyVault**：SQLite 中保存加密后的真实 API Key

当前处于 **Phase 0**：OpenAI `chat/completions` 透明代理 + KeyVault CRUD + TOML 配置 + Axum 服务。进度与任务清单见 [docs/implementation/phase-0-plan.md](docs/implementation/phase-0-plan.md)。

## 2. 技术栈与约束

- Rust 2024 edition，异步栈：Tokio + Axum 0.8 + reqwest
- SQLite（rusqlite）：**单连接**，访问需加锁；避免在 async 上下文中长时间同步阻塞
- 配置：`config.toml`（TOML），只含 provider 元数据，**不含任何真实密钥**
- 日志：`tracing`，JSON 输出到 stdout；审计记录落 SQLite
- 代码注释与文档使用**中文**，与现有代码保持一致

## 3. 常用命令

```powershell
cargo build                  # 构建
cargo test                   # 运行单元测试（各模块均有 #[cfg(test)]）
cargo fmt --check            # 格式检查
cargo clippy -- -D warnings  # 静态检查
cargo run -- --port 18999    # 启动网关
```

CLI（代理 Key 管理）：

```powershell
cargo run -- key add --provider deepseek --key <real-key> [--label text]
cargo run -- key list
cargo run -- key disable|enable <proxy-key>
```

启动网关做冒烟测试时，使用**临时 HOME 隔离数据目录**（例如 `$env:HOME` 指向 `$env:TEMP` 下的临时目录），不要污染真实 `$HOME/.keygateway`。

## 4. 目录结构

| 路径 | 说明 |
|------|------|
| `src/main.rs` | 入口、CLI 解析、Axum handler |
| `src/config.rs` | TOML 配置解析与校验 |
| `src/crypto.rs` | 主密钥加载/生成、AES-256-GCM 加解密 |
| `src/key_vault.rs` | SQLite 代理 Key CRUD、真实 Key 加解密 |
| `src/auth.rs` | Authorization 头提取与代理 Key 校验 |
| `src/routing.rs` | model → provider 解析、协议匹配 |
| `src/forwarder.rs` | 上游请求构造与转发 |
| `src/audit.rs` | 审计记录写入 |
| `src/error.rs` | 统一错误类型，OpenAI 兼容 JSON 响应 |
| `src/state.rs` | Axum 共享状态 |
| `docs/` | 需求、设计、实现文档（中文） |
| `config.toml` | 运行配置样例 |

需要设计背景时按需查阅：[需求文档](docs/requirement/program.md)、[架构设计](docs/design/architecture.md)、[接口说明](docs/api/endpoints.md)、[配置规范](docs/design/config-spec.md)。

## 5. 编码规范

- 错误处理统一走 `AppError` → HTTP 状态码 + OpenAI 兼容 JSON；新错误优先挂到现有枚举，必要时再扩展
- 日志使用结构化字段（`tracing::info!(field = value, ...)`），不要用裸字符串拼接
- 模块保持单一职责，按 [架构设计](docs/design/architecture.md) 的模块边界开发，不跨模块绕路
- 新增/修改公共函数必须补单元测试；行为变更时同步更新 `docs/` 中对应文档
- 审计写入是**非关键路径**：失败只 `warn`，绝不影响请求响应
- 提交前不得遗留 `dbg!` / `println!` 调试代码（CLI 用户输出除外）

## 6. 安全红线（必须遵守）

- 任何真实 API Key、代理 Key 全文、master key 都**不得**写入日志、文档、提交内容或 HTTP 响应
- 日志中只允许出现代理 Key 前缀（现有约定：前 4 个字符）
- 真实 Key 只在转发瞬间存在于内存，不持久化明文
- `$HOME/.keygateway/`（`keygateway.db`、`master.key`）是本地敏感数据目录，不得纳入版本库
- 不得提交 `target/`、`__pycache__`、`config.json`
- `src/config/config.json` 是遗留的密钥样例文件（已被 `.gitignore` 忽略）：不要读取其中密钥、不要将其作为配置来源、不要提交
- 修改加密/密钥相关代码后，必须先跑 `cargo test` 验证加解密往返与密钥校验逻辑

## 7. 请求处理流程

handler 顺序固定：提取代理 Key → 校验 → 解析 model → 路由解析 → 协议匹配 → 解密真实 Key 并转发 → 写审计。不要改变顺序，例如不要在校验前转发，也不要在任何环节输出密钥。

## 8. Git 工作流

文档集（docs/development/）：

- 个人操作步骤：[git-workflow.md](docs/development/git-workflow.md)
- 多人 / 多 Agent 协作规则：[collaborative-workflow.md](docs/development/collaborative-workflow.md)
- 通用 Git 模板（任意项目类型）：[git-workflow-template.md](docs/development/git-workflow-template.md)
- 多人 / 多 Agent 协作模板：[collaborative-workflow-template.md](docs/development/collaborative-workflow-template.md)
- Git 工作流与项目文档的集成设计：[docs-communication.md](docs/development/docs-communication.md)

- 新分支使用 `codex/` 前缀（除非用户另有要求）
- commit 前必须通过：`cargo fmt --check`、`cargo clippy -- -D warnings`、`cargo test`、`cargo build`
- 保持 commit 聚焦：一次提交对应一个可描述的功能或修复
- 不提交与任务无关的本地改动；工作区已有未提交改动时，先确认归属再动手
