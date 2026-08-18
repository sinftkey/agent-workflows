# Git 工作流 × 项目文档：落地示例（KeyGateway）

> 本文是通用模板 `templates/docs-communication.md` 第 5、6 节在 KeyGateway 项目中的真实落地版本：用真实文档路径替换模板中的 `<占位符>`，并记录实际推进状态，作为「模板在真实项目里长什么样」的参考。
>
> 注意：文中的相对链接（`../design/...` 等）按原仓库 `docs/development/` 位置编写，独立复制后需要修正；新项目请以模板为准，不要直接套用本文路径。
>
> 规则冲突时，以本仓库 [AGENTS.md](../../AGENTS.md) 与用户明确指令为准。

## 1. 变更 ↔ 文档映射矩阵

| 变更类型 | 必须同步的文档 |
|----------|----------------|
| 配置字段 / 格式 | [config-spec.md](../design/config-spec.md) |
| HTTP 端点 / 协议 / 错误码 | [endpoints.md](../api/endpoints.md)、[error-handling.md](../implementation/error-handling.md) |
| 路由 / 协议匹配 | [routing.md](../implementation/routing.md) |
| 认证 / KeyVault / 加密 | [authentication.md](../implementation/authentication.md)、[key-vault.md](../implementation/key-vault.md) |
| 审计字段 | [audit-logging.md](../implementation/audit-logging.md) |
| SSE / 流式转发 | [sse-streaming.md](../implementation/sse-streaming.md) |
| 新模块 / 架构变化 | [architecture.md](../design/architecture.md) + 对应实现文档 |
| 构建 / 命令 / 协作规则 | [AGENTS.md](../../AGENTS.md)、README |

## 2. 已落地

- [AGENTS.md](../../AGENTS.md) 第 8 节已链接整套文档集；
- 协作工作流的 PR 模板已加入「文档同步」字段（见 [collaborative-workflow.md](collaborative-workflow.md) 第 7 节）；
- Review 清单已加入文档一致性检查（见 [collaborative-workflow.md](collaborative-workflow.md) 第 8 节）。

## 3. 建议后续（可选）

- 在 docs/ 根目录加一份总索引 README；
- 每个文档头部标注「状态：生效 / 草稿 / 已废弃」与维护者；
- CI 增加 markdown 链接检查；
- 正式发布后启用 changelog 自动生成。

## 4. 推行状态（渐进，不一步到位）

1. 规则写进 AGENTS.md（已完成）；
2. PR 模板加入「文档同步」字段（已完成）；
3. Review 清单加入文档一致性检查（已完成）；
4. 行为变更强制要求同步文档（从下一个 PR 开始执行）；
5. CI 增加链接检查（文档规模变大后）；
6. changelog 自动化（有正式发布后）；
7. 每次发布前做一次文档审计。