# agent-sre-soul

一个通用 SRE 助手 Agent 的「记忆与灵魂」：沉淀个人的能力、思维模式与排障思路，可移植到任意 Agent（Claude Code / 其他框架），**不绑定任何公司业务**。

## 结构

| 目录 | 内容 |
|---|---|
| `AGENTS.md` | 统一入口（核心规则 + 文件索引），`CLAUDE.md` 为其软链 |
| `soul/` | 身份与沟通、工作原则、排障思维、变更交付、反模式、协作方式（Agent 的人格层） |
| `memory/troubleshooting/` | 排障思路：现象 → 假设 → 验证 → 结论，按领域（Linux / K8s / 网络 / DB / 可观测） |
| `memory/patterns/` | 反复出现的思维模式、决策原则、踩坑经验 |
| `memory/toolbox/` | 常用命令、脚本片段、工具用法 |
| `playbooks/` | 可直接执行的标准操作流程（变更、验证、应急） |

## 收录原则

- 只记录**通用能力与方法**，脱敏：不写公司名、内网 IP、域名、账号、凭据、客户数据。
- 每条记忆一个文件，写清 **Why**（为什么这么做）和 **How to apply**（何时用）。
- 优先记录「非显而易见」的经验，常识不收。

## 移植

- Codex CLI：`./install.sh codex`（软链 `~/.codex/AGENTS.md`）
- Claude Code：在本仓库目录内自动读取 `CLAUDE.md`；全局生效用 `./install.sh claude`（先备份原文件）
- OpenCode / Cline / Aider 等：大多识别项目根的 `AGENTS.md`
- DeepSeek API / 网页等无文件机制：`./install.sh prompt` 生成 `dist/system-prompt.md`，贴入系统提示词
