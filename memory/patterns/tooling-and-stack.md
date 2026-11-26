---
name: tooling-and-stack
description: 自建工具清单与技术栈偏好
metadata:
  type: reference
---

# 自建工具与技术栈

## 自建工具

| # | 通用名称 | 一句话目的 | 关键技术选型 | 设计取舍 |
|---|---|---|---|---|
| 1 | **CI/CD 发布机器人** | 研发在 IM 群里 @机器人，用口语描述发布需求，机器人匹配到真实的 Jenkins 流水线、分支和参数，生成确认卡片；有权限的人点确认后才触发构建，结果回到群里 | TypeScript/Node 22、IM 官方 SDK 长连接（不需要公网回调）、Jenkins REST、Prisma + SQLite、Express 小后台、docker-compose；LLM 可选（Anthropic SDK，希望兼容 DeepSeek/GPT 一类） | **不建"项目数据库"**：直接搜 Jenkins 原生的 View/Folder/Job/参数，不要求事先登记项目（第一版要求逐个配置，被用户整个推翻重做）。**LLM 只做增强**：不配置时用纯规则匹配（分词、拼音、模糊匹配、反查参数真实可选值），出错时静默回退。**越用越准**：被确认过的发布和纠正记录自动变成高权重的匹配依据；只有白名单里的人能教别名。**宁可不做也不能做错**：有歧义时先文字追问，再给多选卡片，也可以让对方发 git 地址辅助核对。命中后还会核实分支是否存在、参数里是否有这个选项。**发布链**（先构建再发布、先灰度再生产）在后台配一次，每一阶都要人点确认，失败时可以中断或强制跳到下一阶。卡片不设超时，确认卡片只能用一次，失效的卡片会被撤回。缓存分层：job 和 view 列表缓存 30 分钟，构建参数缓存 3 分钟。权限按时间分：工作时间允许申请人自己确认，非工作时间只有运维能确认。另有 `/report` 周报（与上周对比）、`/plan` 从在线表格读取发版计划、`/debug on` 显示匹配依据、重启后自动接上未回复的需求，失败的卡片可以"再发一次" |
| 2 | **Jenkins 终端 TUI** | 在终端里浏览 View/Job、填写参数、二次确认后触发构建，并实时跟随日志 | Go + Bubble Tea/Lipgloss；静态编译，兼容老 glibc；GitHub Actions 打 tag 后出 5 个平台的二进制 | 写接口只允许 `/build` 和 `/buildWithParameters`；凭证文件权限 0600；先预览草稿，按 `y` 才真正提交。按 git 仓库地址反查 job 的逻辑后来被机器人直接复用 |
| 3 | **SQL 工单审批 TUI** | 对接开源 SQL 审核平台的极简审批终端：待我审批 → 检测 → 通过/驳回 | Go TUI、静态编译（CGO_ENABLED=0），支持 LDAP 登录 | 只做审批这一件事；密码通过交互输入，避免 shell 把 `!` 展开 |
| 4 | **SRE 集成平台 / 告警聚合平台** | 一个平台内完成 IAM、CMDB、网关、审计，加上监控告警的闭环：数据源 → 规则评估 → 告警归一化和去重 → 路由通知 → 处理闭环 | Go 微服务（go.work 多模块，共享 httpx/authx/pg 库）、PostgreSQL、React + Ant Design、docker-compose；数据源适配层支持托管 Prometheus/Grafana；附带 mock-prometheus 用于本地联调 | 规则参考 Grafana 的"多查询 → 表达式 → 条件"流水线，**只在平台内部评估**，不往外部系统下发规则（明确写成"有意简化，不是待办"）。路由参考 Alertmanager：标签匹配、优先级、continue_matching。抑制规则和分级阈值由写规则的人自己定义，高级别抑制低级别。同一个表达式可以按"评估窗口 + 次数 + 阈值"组合出不同等级（如 5 分钟 10 次算 warning，3 分钟 100 次算严重）。告警动作（静默、认领、升级、webhook）**一律生成建议，由人确认后才执行**。权限矩阵可编辑并写进 JWT。另有拓扑和版本历史。没有接真实账号测试过的代码标 `UNVERIFIED` |
| 5 | **技术门户平台（早期形态）** | 面向技术团队的统一门户：导航、IAM、CMDB、审计 | Go 微服务 + BFF、React + TS + Vite + Ant Design、Podman，可部署到 VM 或 K8s | 先搭地基服务（身份、配置、资产、审计），业务能力往后排；后来演进成上一项 |
| 6 | **时序库 exporter（compact 指标）** | 给时序数据库 exporter 增加 compact 任务进度指标，并在现有监控面板下加面板 | 采集 `show compacts` 和 `ins_compacts`；Grafana 面板 | 只在有 compact 任务时才有数据。指标尽量少（"不需要那么多，累赘"），剩余时间交给面板推算（用 mean 不用 last），进度用进度条展示 |
| 7 | **时序库分批删除脚本** | 在不影响线上的前提下，按 fileset 时间块 × vgroup 串行、按子表逐条删除历史数据 | Bash + taos CLI + iostat；控制文件实现暂停、停止和热调参 | **按 vgroup 串行，不并行**；删除区间对齐 fileset 边界，不跨块。**不用查询去确认是否已删**（会造成温盘 IO），靠 done 账本保证幂等，断点后续跑。每批执行前检查磁盘 util、集群健康和是否有 compact 在跑。单条语句超时、出错或被拒绝写入就熔断。结束时打印醒目的汇总框。参数收敛成"位置参数 + 内部常量"，并支持非交互模式。后续讨论过用 systemd + flock 包装成无人值守 |
| 8 | **IO 定位采集脚本** | 在数据库主机上低开销采集 IO 现场，用来定位每天定点出现的温盘读风暴 | iostat、/proc 线程 IO、文件清单，awk 汇总；crontab 定时 | 只保留必要的采集项，实测自身开销约单核 1%；用 crontab 一行定时执行，"不要搞太复杂" |
| 9 | **时序库集群监控面板生成器** | 用脚本重构 Grafana 集群面板：中文标题和描述、热盘和温盘分开展示（用量、吞吐、IOPS、util、await）、统一单位 | Python 读面板导出 JSON 后生成新面板，通过 Grafana HTTP API 带版本号保存（乐观锁） | 必须保留可回滚的版本备份；**不用 provisioning 锁定**，保存后仍能在页面上编辑；改之前先确认线上版本，避免覆盖别人的手工调整；所有查询都在真实数据源上验证过 |
| 10 | **证书更新** | 证书统一从控制机分发到 Nginx 主机和 K8s TLS Secret；离线机房通过对象存储拉取加密后的证书包 | Ansible playbook；Go 写的拉取工具（支持 Linux/Windows，可替换 Nginx 证书或 K8s/K3s Secret）；对象存储 + SAS + 加密 | 在线推、离线拉，两条路径分开；附带 Mermaid 流程图和换密钥的运维手册 |
| 11 | **抓包平台** | 网页上选主机（SSH）或 K8s Pod 远程抓包，可导出 pcap，多个任务打包成一个 zip 下载 | Node/Express + 单页 HTML；kubectl exec | 优先在集群内用 ServiceAccount + RBAC，在集群外则挂载 kubeconfig；服务端**硬限制**允许的命名空间和 Pod 标签，前端和后端各校验一次；按 PID 精确停止抓包 |
| 12 | **配置中心与数据库定时备份** | 按 cron 备份配置中心的配置和对应的 MySQL，上传到对象存储 | Python（uv 管理）、docker-compose，有常驻定时和单次执行两种模式 | MySQL 用 `mysql_config_editor` 生成登录凭据，不写明文；输出按"环境/数据中心/命名空间"分层 |
| 13 | **告警规则库** | 按组件沉淀 Prometheus/Grafana 告警规则（主机、K8s、数据库、缓存、消息队列、探测等） | YAML 规则；托管 Grafana 不能用文件 provisioning，所以写了脚本把 YAML 转成 API 需要的 JSON 再同步 | 规则放 git 做版本管理，托管和自建 Grafana 共用同一份源 |
| 14 | **GitOps 仓库 + 运维记录仓库** | 按环境和区域分目录的 ArgoCD 声明；事故和操作记录按模板入库，并维护索引 | ArgoCD；Markdown + 索引文件；SECURITY.md 规定只能存脱敏后的内容 | 每次事故和关键操作都要写成记录提交，并且提交要一次做完（分支、记录、索引、推送） |

另外，用户会选用现成的开源容器管理 UI，并做成**离线安装包**（镜像 tar + sha256 + compose），而不是自己重写。

---

## 技术栈偏好

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
