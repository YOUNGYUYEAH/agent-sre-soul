---
name: kafka
description: Kafka 运维速查（topic/配置管理、分区与 ISR 巡检、消费组积压与 offset 重置、生产消费调试、KRaft 与 ZooKeeper 元数据查看、磁盘占用统计），已修正常见错误并标注版本差异
metadata:
  type: reference
---

# Kafka 运维速查

约定：在 Kafka 的 `bin/` 目录下执行；`export BS=<BOOTSTRAP_SERVERS>`（如 `<BROKER_1>:9092,<BROKER_2>:9092`）。
- **2.2+ 管理脚本统一用 `--bootstrap-server`**；`kafka-topics.sh --zookeeper` 在 3.0 移除，`kafka-configs.sh --zookeeper` 仅 ZK 模式下的 SCRAM 引导场景保留；**4.0 彻底移除 ZooKeeper**（`zookeeper-shell.sh` 也随之移除）。
- 开了 SASL/TLS 的集群，所有命令加 `--command-config <CLIENT_PROPERTIES>`（console 工具用 `--producer.config` / `--consumer.config`）。

## 1. Topic 管理

```bash
# 创建（分区只能增不能减；副本数 ≤ broker 数）
./kafka-topics.sh --bootstrap-server $BS --create --if-not-exists \
  --topic <TOPIC> --partitions <P> --replication-factor <R> \
  --config retention.ms=172800000            # 2 天

./kafka-topics.sh --bootstrap-server $BS --list
./kafka-topics.sh --bootstrap-server $BS --describe --topic <TOPIC>        # 分区/Leader/Replicas/Isr
./kafka-topics.sh --bootstrap-server $BS --describe --topics-with-overrides  # 只列有非默认配置的 topic

# 扩分区
./kafka-topics.sh --bootstrap-server $BS --alter --topic <TOPIC> --partitions <P_NEW>
# !! 删除（需 broker 端 delete.topic.enable=true，1.0+ 默认 true）
./kafka-topics.sh --bootstrap-server $BS --delete --topic <TOPIC> --if-exists
```
- 扩分区会改变 key→分区的映射，依赖 key 有序的业务要评估；扩分区不会自动迁移已有数据。
- `--topic` 支持正则，名字含 `.`/`*` 时加引号，删除时尤其小心误匹配。

### cleanup.policy 与保留
- `cleanup.policy=delete`（默认）：按 `retention.ms` / `retention.bytes` 删除旧段。
- `cleanup.policy=compact`：按 key 只保留最新值，**`retention.ms` 对纯 compact 不生效**；想「压缩 + 超期删除」要设 `compact,delete`。
- `retention.bytes` 是**每个分区**的上限，不是整个 topic。
- 删除/压缩以 segment 为单位，活跃段不会被删；小流量 topic 可能看起来「超期没删」，看 `segment.ms`。

## 2. Topic 配置（kafka-configs）

```bash
./kafka-configs.sh --bootstrap-server $BS --describe --entity-type topics                         # 所有 topic 的覆盖配置
./kafka-configs.sh --bootstrap-server $BS --describe --entity-type topics --entity-name <TOPIC> --all  # 含默认值
./kafka-configs.sh --bootstrap-server $BS --alter --entity-type topics --entity-name <TOPIC> \
  --add-config retention.ms=86400000,retention.bytes=1073741824
# 列表型值用方括号
./kafka-configs.sh --bootstrap-server $BS --alter --entity-type topics --entity-name <TOPIC> \
  --add-config 'cleanup.policy=[compact,delete]'
./kafka-configs.sh --bootstrap-server $BS --alter --entity-type topics --entity-name <TOPIC> --delete-config <KEY>

# broker 动态配置
./kafka-configs.sh --bootstrap-server $BS --describe --entity-type brokers                  # 各 broker
./kafka-configs.sh --bootstrap-server $BS --describe --entity-type brokers --entity-default  # 集群级默认
```

## 3. 分区健康巡检

```bash
./kafka-topics.sh --bootstrap-server $BS --describe --under-replicated-partitions   # ISR < 副本数
./kafka-topics.sh --bootstrap-server $BS --describe --under-min-isr-partitions      # ISR < min.insync.replicas，acks=all 的生产会失败
./kafka-topics.sh --bootstrap-server $BS --describe --unavailable-partitions        # 无 leader，最严重
```
- 用内置参数，不要 grep 文本：describe 输出列顺序是 `Leader ... Replicas ... Isr`，`grep -v "Isr: .*Replicas"` 永远不匹配；无 leader 时不同版本显示 `-1` 或 `none`，grep 不可靠。
- 排查思路：under-replicated 集中在某个 broker → 看该 broker 磁盘/网络/GC；全局出现 → 看 controller 与网络。

## 4. 消费组与积压

```bash
./kafka-consumer-groups.sh --bootstrap-server $BS --list
./kafka-consumer-groups.sh --bootstrap-server $BS --describe --group <GROUP>              # LAG 列即积压
./kafka-consumer-groups.sh --bootstrap-server $BS --describe --group <GROUP> --members --verbose  # 成员与分配的分区
./kafka-consumer-groups.sh --bootstrap-server $BS --describe --all-groups --state | column -t  # 状态/协调者/分配策略

# 只看某个 topic 的所有消费组积压（--all-groups 每组都会重复输出表头，只保留第一行）
./kafka-consumer-groups.sh --bootstrap-server $BS --describe --all-groups \
  | awk '$1=="GROUP" && !h {print; h=1; next} $2=="<TOPIC>"' | column -t

# 删除消费组（组内必须没有活跃成员）
./kafka-consumer-groups.sh --bootstrap-server $BS --delete --group <GROUP>
```
- 状态 `Empty`=无成员但有已提交 offset；`PreparingRebalance` 频繁出现 → 看 `max.poll.interval.ms` 超时、消费者重启。
- LAG 某几个分区特别大 → 数据倾斜（key 不均）或该分区消费者卡住；全部分区都大 → 消费能力不足。

### 查看 topic 端 offset
```bash
./kafka-get-offsets.sh --bootstrap-server $BS --topic <TOPIC> --time -1   # -1 最新，-2 最早；该脚本 3.0+ 才有
# 3.0 之前：./kafka-run-class.sh kafka.tools.GetOffsetShell --broker-list $BS --topic <TOPIC> --time -1
```

### 重置 offset（会跳过或重复消费数据）
```bash
# 必须先停掉该组所有消费者（组状态为 Empty），否则报错
./kafka-consumer-groups.sh --bootstrap-server $BS --group <GROUP> --topic <TOPIC> \
  --reset-offsets --to-latest --dry-run       # 先预览
./kafka-consumer-groups.sh --bootstrap-server $BS --group <GROUP> --topic <TOPIC> \
  --reset-offsets --to-latest --execute
```
- 其他目标：`--to-earliest`、`--to-offset <N>`、`--shift-by <±N>`、`--to-datetime 2026-04-13T10:00:00.000`（无时区后缀按本机时区，可加 `+08:00`）、`--by-duration PT1H`。
- 只重置部分分区：`--topic <TOPIC>:0,1,2`。
- `--to-latest` 等于丢弃积压，执行前确认业务可接受；可先 `--export` 导出当前 offset 留底。

## 5. 生产 / 消费调试

```bash
./kafka-console-producer.sh --bootstrap-server $BS --topic <TOPIC>                 # 交互式，每行一条
./kafka-console-producer.sh --bootstrap-server $BS --topic <TOPIC> < messages.txt  # 文件批量
./kafka-console-producer.sh --bootstrap-server $BS --topic <TOPIC> \
  --property parse.key=true --property key.separator=:                              # 带 key：key:value

./kafka-console-consumer.sh --bootstrap-server $BS --topic <TOPIC>                     # 只收新消息
./kafka-console-consumer.sh --bootstrap-server $BS --topic <TOPIC> --from-beginning --max-messages 100
./kafka-console-consumer.sh --bootstrap-server $BS --topic <TOPIC> --partition 0 --offset earliest  # --offset 需配合 --partition
./kafka-console-consumer.sh --bootstrap-server $BS --topic <TOPIC> \
  --property print.key=true --property print.timestamp=true --property print.partition=true
```
- 不指定 `--group` 时会生成随机组 `console-consumer-xxxxx`，不影响业务组。
- **指定 `--group <GROUP>` 时 `--from-beginning` 只在该组没有已提交 offset 时生效**；而且会参与业务组的 rebalance、提交 offset，切勿用业务组名调试。

## 6. 集群元数据

### KRaft 模式（3.3+ 生产可用）
```bash
./kafka-metadata-quorum.sh --bootstrap-server $BS describe --status        # leader、epoch、voters/observers
./kafka-metadata-quorum.sh --bootstrap-server $BS describe --replication   # 各节点 LogEndOffset、Lag
#   --human-readable 新版本才有（较老 3.x 无此参数）
./kafka-cluster.sh cluster-id --bootstrap-server $BS
./kafka-cluster.sh list-endpoints --bootstrap-server $BS         # 3.7+ 支持
./kafka-cluster.sh list-endpoints --bootstrap-controller <CONTROLLER>:9093
./kafka-broker-api-versions.sh --bootstrap-server $BS | grep 'id:'   # 列出在线 broker 及 ID
```
- quorum replication 中某 voter Lag 持续增长 → 该 controller 落后，检查其磁盘与网络。

### ZooKeeper 模式（≤3.x）
```bash
echo "ls /brokers/ids"      | ./zookeeper-shell.sh <ZK_HOST>:2181 2>/dev/null | grep -o '\[.*\]'   # 在线 broker ID
echo "get /controller"      | ./zookeeper-shell.sh <ZK_HOST>:2181 2>/dev/null | grep -o '"brokerid":[0-9]*'  # 当前 controller
echo "get /brokers/ids/<ID>" | ./zookeeper-shell.sh <ZK_HOST>:2181 2>/dev/null | grep '^{' | python3 -m json.tool
```
- broker 在 `/brokers/ids` 中消失 = ZK 会话超时（常见于长 GC、网络抖动），先查该 broker GC 日志。

## 7. Topic 磁盘占用统计

```bash
./kafka-log-dirs.sh --bootstrap-server $BS --describe \
  | sed -n '/^{/,$p' \
  | jq -r '
      [ .brokers[]?.logDirs[]? | select(.error == null) | .partitions[]?
        | select((.size // -1) >= 0)
        | { topic: (.partition | sub("-[0-9]+$"; "")), partition: .partition, size: (.size // 0) } ]
      | group_by(.topic)
      | map({ topic: .[0].topic,
              partitions: (map(.partition) | unique | length),
              replicas: length,
              size_gb: ((map(.size) | add) / 1073741824) })
      | sort_by(.size_gb) | reverse | .[]
      | "\(.topic)\t\(.partitions)\t\(.replicas)\t\((.size_gb*100|round)/100) GB"' \
  | (echo -e "TOPIC\tPARTITIONS\tREPLICAS\tSIZE"; cat) | column -t
```
- SIZE 是**所有副本合计**的磁盘占用（≈ 单份 × 副本数）。
- 可加 `--topic-list <TOPIC_A>,<TOPIC_B>` 或 `--broker-list <ID>` 缩小范围。

## 8. CMAK（原 Kafka Manager）

```yaml
# docker compose -p cmak -f cmak.yaml up -d
services:
  cmak:
    image: vimagick/cmak:<PINNED_TAG>      # 避免 latest
    container_name: cmak
    restart: unless-stopped
    ports:
      - "9000:9000"
    environment:
      ZK_HOSTS: "<ZK_1>:2181,<ZK_2>:2181,<ZK_3>:2181"
```
- CMAK 依赖 ZooKeeper，**只适用 ZK 模式集群**，项目已停止维护；KRaft 集群改用 Kafka UI 类工具（如 kafbat/kafka-ui、AKHQ）。
- Compose v2 中顶层 `version:` 字段已废弃，可省略。
- CMAK 自身无默认认证，不要直接暴露到公网。
