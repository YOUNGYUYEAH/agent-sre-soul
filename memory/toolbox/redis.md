---
name: redis-toolbox
description: Redis 排障速查（info 分段、客户端连接管理/暂停、慢日志、动态配置、集群检查、RDB 离线分析大 key/前缀/过期/热点）
metadata:
  type: reference
---

# Redis 排障速查

> 连接：`redis-cli -h <HOST> -p <PORT> --user <USER> --askpass`（避免 `-a <PASSWORD>` 留在 shell history 和 ps 里）。集群模式加 `-c` 跟随重定向。

## 1. 先看概况：info 分段

```text
info server        版本、运行时长、配置文件路径
info clients       connected_clients、blocked_clients
info memory        used_memory / used_memory_rss / mem_fragmentation_ratio / maxmemory_policy
info stats         ops、keyspace_hits/misses、evicted_keys、expired_keys、rejected_connections
info persistence   rdb/aof 状态，rdb_last_bgsave_status，aof_rewrite_in_progress
info keyspace      每个 db 的 key 数 / 带过期 key 数
info replication   role、从库 offset 与 lag
info cluster       cluster_enabled:1 即集群模式
info commandstats  每个命令调用次数与耗时（找打满 CPU 的命令）
info modules
```

- `mem_fragmentation_ratio` > 1.5 碎片高（可 `config set activedefrag yes`，4.0+ 且需 jemalloc）；< 1 说明发生了 swap。
- `evicted_keys` 持续增长 = 内存打满正在淘汰；`rejected_connections` > 0 = 达到 maxclients。

## 2. 连接数异常 / 某客户端拖垮实例

```text
client list                        # 每行一个连接：addr、age、idle、flags、cmd、qbuf、omem、tot-mem
client id                          # 当前连接 ID
client kill id <ID>                # 按 ID 杀（新语法返回被杀数量）
client kill addr <CLIENT_IP:PORT>
client kill maxage <SECONDS>       # 7.4+ 杀连接时长超过 N 秒的
client kill type pubsub|replica|normal
```

```bash
# 按来源 IP 统计连接数
redis-cli ... client list | awk '{split($2,a,"[=:]"); print a[2]}' | sort | uniq -c | sort -rn | head
```

- 关注 `omem`（输出缓冲）大的连接：通常是慢消费的 pubsub 或拉大 key 的客户端，可能把内存撑爆。
- 杀 `type replica` 会触发从库重连甚至全量同步，慎用。

## 3. 暂停客户端（切换/迁移时止写）

```text
client pause <TIMEOUT_MS> WRITE    # 6.2+ 只阻止写（读继续），常用于主从切换前追平
client pause <TIMEOUT_MS>          # 默认 ALL：阻止所有客户端命令
client unpause                     # 6.2+ 提前恢复
```

- **timeout 是必填且在前**：`CLIENT PAUSE timeout [WRITE|ALL]`。

## 4. 慢查询

```text
config get slowlog*                       # slowlog-log-slower-than / slowlog-max-len
config set slowlog-log-slower-than 10000  # 单位微秒；0 记录所有，负数关闭
slowlog get 10                            # 最近 10 条：id、时间戳、耗时(μs)、命令参数、客户端
slowlog len
slowlog reset
```

- 慢日志只计命令**执行**时间，不含网络与排队；客户端侧慢但 slowlog 为空 → 查网络、大 value 传输、或其他命令阻塞（单线程排队）。
- 其他手段：`redis-cli --latency` / `--latency-history`、`latency doctor`（需 `latency-monitor-threshold` > 0）。

## 5. 动态配置

```text
config get <KEY>          # 支持通配，如 config get *max*
config set <KEY> <VALUE>
config rewrite            # 把运行时配置写回 redis.conf，否则重启丢失
```

- 集群/主从下 `config set` 只改当前节点；集群可用 `redis-cli --cluster call <HOST>:<PORT> config set <KEY> <VALUE>` 批量下发。
- 容器/K8s 下配置文件常为只读挂载，`config rewrite` 会失败，要改 ConfigMap。

## 6. 集群

```text
cluster info              # cluster_state、slots_assigned/ok/pfail/fail
cluster nodes             # 节点、角色、主从关系、slot 分配
cluster shards            # 7.0+，按分片结构化输出
```

```bash
redis-cli --cluster check <HOST>:<PORT>          # slot 覆盖、open slot、节点一致性
redis-cli --cluster info  <HOST>:<PORT>          # 每个 master 的 key 数/slot 数
redis-cli --cluster fix   <HOST>:<PORT>          # 修复 open slot / 未覆盖 slot —— 会改集群拓扑，先 check 再用
redis-cli --cluster rebalance <HOST>:<PORT> --cluster-simulate   # 先模拟再真正迁移
redis-cli --cluster call  <HOST>:<PORT> <CMD> ... [--cluster-only-masters]
```

## 7. 大 key / 内存分析

### 7.1 在线采样（有负载影响，低峰执行）

```bash
redis-cli ... --bigkeys        # 按元素数（4.0+ 用 SCAN，不阻塞，但会持续扫描）
redis-cli ... --memkeys        # 6.0+ 按内存
redis-cli ... --hotkeys        # 需 maxmemory-policy 为 *-lfu
redis-cli ... --scan --pattern '<PREFIX>:*' | head
MEMORY USAGE <KEY>             # 单 key 内存
```

### 7.2 离线分析 RDB（推荐，零线上压力）

工具：HDT3213/rdb（Go 单文件，从 GitHub Releases 下载对应平台二进制）。

```bash
rdb -c memory -o memory.csv dump.rdb                       # 每个 key 的内存报告
rdb -c bigkey -n 20 [-o bigkeys.csv] dump.rdb              # Top N 大 key
rdb -c prefix -prefix-sep : -n 20 [-o prefix.csv] dump.rdb # 按前缀层级统计数量/内存，定位是哪类业务占内存
rdb -c json -o all.json dump.rdb                           # 全量转 JSON
rdb -c json -regex '^<KEY_PREFIX>:' -o subset.json dump.rdb
rdb -c json -show-global-meta -o all.json dump.rdb         # 带 redis 版本、ctime 等元信息
rdb -c json -expire noexpire  -o no_ttl.json dump.rdb      # 永不过期的 key
rdb -c json -expire anyexpire -o has_ttl.json dump.rdb     # 设了过期的 key
rdb -c json -expire 'now~inf' -o future.json dump.rdb      # 尚未过期（过期时间在当前之后）
rdb -c json -expire '0~now'   -o expired.json dump.rdb     # 相对当前已过期但仍在 RDB 中
rdb -c json -expire '<TS_START>~<TS_END>' -o range.json dump.rdb   # Unix 秒
rdb -c json -size '1MB~inf' -o huge.json dump.rdb          # 按大小过滤
rdb -c flamegraph -port 16379 -sep : dump.rdb              # 浏览器打开 http://localhost:16379（远程需端口转发）
rdb -c hotkey -n 50 -o hotkey.csv dump.rdb                 # 依赖 RDB 中的 LFU 计数，仅 maxmemory-policy=*-lfu 时有意义
rdb -c aof -o dump.aof dump.rdb                            # 转 AOF，可回灌 redis 做二次分析
```

```bash
# JSON 二次筛选示例：value 为 JSON 字符串时按字段过滤 key
jq -r '.[] | select(.value | fromjson | .<FIELD> | test("<PATTERN>")) | .key' subset.json
```

- 集群：每个 master 分别 `BGSAVE` 取 RDB，各自分析后合并结果（或转 AOF 灌入同一个临时实例再分析）。
- 取 RDB 时 `BGSAVE` 会 fork，大内存实例注意 fork 耗时与 COW 内存翻倍；优先从从库取。
