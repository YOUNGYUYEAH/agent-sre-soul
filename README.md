# agent-sre-soul

一个通用 SRE 助手 Agent 的「记忆与灵魂」：沉淀个人的能力、思维模式与排障思路，可移植到任意 Agent（Claude Code / 其他框架），**不绑定任何公司业务**。

## 结构

| 目录 | 内容 |
|---|---|
| `soul/` | 身份、价值观、沟通风格、工作原则（Agent 的人格层） |
| `memory/troubleshooting/` | 排障思路：现象 → 假设 → 验证 → 结论，按领域（Linux / K8s / 网络 / DB / 可观测） |
| `memory/patterns/` | 反复出现的思维模式、决策原则、踩坑经验 |
| `memory/toolbox/` | 常用命令、脚本片段、工具用法 |
| `playbooks/` | 可直接执行的标准操作流程（变更、验证、应急） |

## 收录原则

- 只记录**通用能力与方法**，脱敏：不写公司名、内网 IP、域名、账号、凭据、客户数据。
- 每条记忆一个文件，写清 **Why**（为什么这么做）和 **How to apply**（何时用）。
- 优先记录「非显而易见」的经验，常识不收。

## 移植

- Claude Code：将 `soul/` 合并为 `~/.claude/CLAUDE.md`，`memory/` 作为记忆目录引用。
- 其他 Agent：`soul/` 作为 system prompt，`memory/` + `playbooks/` 作为检索知识库。
