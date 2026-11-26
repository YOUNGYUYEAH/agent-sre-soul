---
name: tech-stack
description: 技术栈偏好（语言、部署、存储、集成、安全底线）
metadata:
  type: reference
---

# 技术栈偏好


- **语言**：
  - Go：CLI/TUI、微服务、跨平台小工具，要求静态编译以兼容老 glibc。
  - TypeScript/Node：IM 机器人和要快速迭代的服务。
  - Python：数据处理、面板生成、备份、Webhook 脚本，用 uv 管理依赖。
  - Bash：一线现场脚本，要兼容 mawk，开销要低。
- **前端**：React + Ant Design（管理后台类）；终端类用 Bubble Tea。
- **部署**：
  - 默认 `docker-compose up --build` 一条命令起服务；数据库这类依赖放在 compose 内部网络，**不对外暴露端口**。
  - 生产侧用 Ansible、ArgoCD，以及 systemd/crontab。
  - Windows 本地用 Podman。
- **存储**：
  - 轻量工具优先用 SQLite，不愿为一个机器人多起一个 Postgres 容器。
  - 平台级多服务用 PostgreSQL。
  - 备份和证书分发用对象存储。
  - 时序数据用 TDengine/Prometheus。
- **集成方式**：
  - IM 用长连接，避免申请公网回调地址。
  - 尽量复用既有系统的原生结构（Jenkins、Grafana、Alertmanager 的语义），不另造一套数据模型。
- **AI/LLM**：
  - 只做可插拔的增强层，必须有规则回退。
  - 希望能兼容多家模型。
- **安全底线**：
  - token 只在命令行内联获取，不落盘。
  - 凭据文件权限设为 0600，或用 login-path。
  - 不在生产库上用 strace 跟踪数据库进程。

---
