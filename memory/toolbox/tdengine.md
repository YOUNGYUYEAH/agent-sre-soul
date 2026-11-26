---
name: tdengine-toolbox
description: TDengine 3.x 运维排障速查（慢 SQL 与 KILL、节点/vgroup 检查、Leader 重平衡、副本变更、COMPACT、多级/S3 存储与磁盘用量、taosAdapter SQL 录制、taosdump、taosX 任务、fatrace 定位热点 vnode、用户权限）
metadata:
  type: reference
---

# TDengine 3.x 速查

> 全部针对 **TDengine 3.x**（`information_schema.ins_*` / `performance_schema.perf_*` 均为 3.0 引入；2.x 是 `SHOW ...` + `log` 库，语法不通用）。标 `[3.3.x]` 的是较新版本才有。多级存储、S3、BALANCE、taosX 等多为**企业版**功能。
> 显示被截断时先执行：`SET MAX_BINARY_DISPLAY_WIDTH 4096;`

## 1. 客户端用法

```bash
taos -h <HOST> -u <USER> -p                 # 交互输入密码
taos -s "<SQL>;"                            # 执行单条；可 \G 竖排
taos -f <FILE.sql>                          # 执行文件
```

```sql
<SELECT ...> >> /tmp/out.csv;    -- taos 命令行内：结果导出为 CSV（只适用于 SELECT）
source <FILE.sql>;               -- taos 命令行内执行文件
```

- `taos -s "..." >> x.csv` 是 shell 重定向表格文本，**不是** CSV；要 CSV 用 SQL 内的 `>> file`。

## 2. 查询慢 / 卡住：找到并 KILL

```sql
SHOW QUERIES;                                  -- = SELECT * FROM performance_schema.perf_queries;
SELECT kill_id, user, create_time, exec_usec, `sql`
FROM performance_schema.perf_queries ORDER BY exec_usec DESC LIMIT 10\G
-- 执行超 30s 的（exec_usec 单位微秒）
SELECT kill_id, create_time, exec_usec, `sql`
FROM performance_schema.perf_queries WHERE exec_usec > 30000000 ORDER BY exec_usec DESC LIMIT 10\G
-- 慢且命中子任务/文件块多的（sub_num 大通常 = 扫的时间范围/子表太多）
SELECT kill_id, create_time, ROUND(exec_usec/1000000.0, 3) AS exec_sec,
       stable_query, sub_num, sub_status, `sql`
FROM performance_schema.perf_queries WHERE sub_num > 10 ORDER BY exec_usec DESC\G

KILL QUERY '<KILL_ID>';          -- 3.x kill_id 形如 '0x...:0x...'，必须加引号

SHOW CONNECTIONS;                -- = performance_schema.perf_connections
KILL CONNECTION <CONN_ID>;
```

```bash
# 批量取出超时查询的 kill_id（审查后再逐个 KILL）
taos -s 'SELECT kill_id FROM performance_schema.perf_queries WHERE exec_usec > 30000000\G' \
  | awk '/kill_id:/{print $NF}'
```

### 历史慢 SQL（taosKeeper 写入 log 库）[3.3.x]

```sql
SELECT * FROM log.taos_slow_sql_detail WHERE _c0 > NOW - 4h ORDER BY query_time DESC LIMIT 10;
SELECT _c0, query_time, `sql` FROM log.taos_slow_sql_detail
WHERE _c0 >= '<START_TS>' AND _c0 < '<END_TS>' AND `sql` NOT LIKE 'select 1'
ORDER BY query_time DESC LIMIT 100;

-- 慢 SQL 文本被截断时调大（同时确认客户端/taosAdapter 侧同名参数）
ALTER ALL DNODES 'slowLogMaxLen' '16384';
SELECT * FROM information_schema.ins_dnode_variables WHERE name = 'slowLogMaxLen';
```

- 慢 SQL 由**客户端**（含 taosAdapter）判定并上报，阈值看 `slowLogThreshold`、范围看 `slowLogScope`；没数据先查 taosKeeper 是否在跑、`monitor` 是否开启。

## 3. 集群健康检查

```sql
SHOW DNODES;    SHOW MNODES;    SHOW VGROUPS;    SHOW VNODES;
SELECT * FROM information_schema.ins_dnodes;     -- status、vnodes 数、启动时间
SELECT * FROM information_schema.ins_vnodes;     -- 每个 vnode 角色/状态/是否 restored
SHOW TRANSACTIONS;                               -- mnode 事务卡住（如 DDL/重平衡未完成）在这里看
SHOW VARIABLES;                                  -- 集群级参数
SHOW DNODE <ID> VARIABLES;                       -- = ins_dnode_variables
SELECT * FROM information_schema.ins_dnode_variables WHERE name LIKE '%<KEYWORD>%';
RESET QUERY CACHE;                               -- 清客户端元数据缓存（建删表后报表不存在时用）
```

### 临时打开 debug 日志

```sql
ALTER DNODE <ID> 'debugFlag' '135';   -- 135=debug，143=trace；查完务必改回 131（默认），否则日志迅速占满磁盘
ALTER LOCAL 'debugFlag' '135';        -- 当前客户端
```

### 常用 information_schema 表（3.x）

`ins_dnodes / ins_mnodes / ins_qnodes / ins_snodes / ins_cluster / ins_databases / ins_stables / ins_tables / ins_tags / ins_columns / ins_users / ins_user_privileges / ins_grants / ins_vgroups / ins_vnodes / ins_configs / ins_dnode_variables / ins_topics / ins_subscriptions / ins_streams / ins_stream_tasks / ins_views / ins_compacts / ins_compact_details / ins_tsmas / ins_arbgroups / ins_anodes`；较新的 3.3.x 新增 `ins_disk_usage / ins_filesets / ins_transaction_details`（具体起始版本以 `SHOW information_schema.TABLES` 实测为准）。

## 4. 库/表信息

```sql
SHOW CREATE DATABASE <DB>\G
SELECT * FROM information_schema.ins_databases;          -- 所有库的参数（keep、duration、replica、vgroups…）
DESC <DB>.<TABLE>;
SELECT COUNT(*) FROM information_schema.ins_tables WHERE db_name = '<DB>' AND stable_name = '<STABLE>';  -- 子表数
SHOW TABLE DISTRIBUTED <DB>.<STABLE>\G                  -- 存储分布、Total_Size、块行数分布（判断是否需 compact）
```

## 5. Leader 分布不均 → 重平衡

```sql
-- 1) 每个 dnode 上的 leader 数
SELECT dnode_id, COUNT(*) FROM information_schema.ins_vnodes WHERE status = 'leader'
GROUP BY dnode_id ORDER BY dnode_id;
-- 2) 细到库
SELECT db_name, dnode_id, COUNT(*) FROM information_schema.ins_vnodes WHERE status = 'leader'
GROUP BY db_name, dnode_id ORDER BY db_name, dnode_id;
-- 3) 按库逐个平衡（一个库完成再做下一个）
BALANCE VGROUP LEADER DATABASE <DB>;
-- 全集群一次性（影响面大，慎用）
BALANCE VGROUP LEADER;
-- 4) 回到第 1 步复核
```

- 前提：所有 vnode `restored = true`（ins_vnodes 中查看），否则可能失败或选主异常。
- `BALANCE VGROUP LEADER` 只切换 leader 角色、不搬数据，但切换瞬间该 vgroup 写入会短暂失败/重试，避开业务高峰。
- 与之区分：`BALANCE VGROUP`（不带 LEADER）会**迁移 vnode 数据**，IO 很重。

## 6. 副本数变更

```sql
-- !! 高风险：1→3 会全量复制数据，持续高 IO/网络；仅支持 1 ↔ 3
ALTER DATABASE <DB> REPLICA 3;
-- 观察进度/落点
SELECT * FROM information_schema.ins_vnodes WHERE db_name = '<DB>';
SELECT vgroup_id, v1_dnode, v1_status, v2_dnode, v2_status, v3_dnode, v3_status
FROM information_schema.ins_vgroups WHERE db_name = '<DB>' ORDER BY vgroup_id;
```

## 7. 数据重整（COMPACT）

```sql
-- !! 消耗大量 IO，可能引起集群卡顿，生产避开高峰，优先按 vgroup + 时间段分批
COMPACT DATABASE <DB>;
COMPACT DATABASE <DB> START WITH '<TS_START>' END WITH '<TS_END>';               -- 如 '2024-01-01T00:00:00+0800'
COMPACT <DB>.VGROUPS IN (<VGROUP_ID>[, ...]);                                    -- [3.3.x]
COMPACT <DB>.VGROUPS IN (<VGROUP_ID>) START WITH '<TS_START>' END WITH '<TS_END>';  -- 避开仍在写入的最新 fileset

SHOW COMPACTS;               -- 任务列表
SHOW COMPACT <COMPACT_ID>;   -- 各 vnode 进度
SELECT * FROM information_schema.ins_compact_details WHERE `progress(%)` < 100;   -- 未完成的
KILL COMPACT <COMPACT_ID>;   -- 必要时终止
```

## 8. 存储：多级存储 / S3 / 磁盘用量

```sql
SELECT name, `keep`, s3_keeplocal FROM information_schema.ins_databases;
ALTER DATABASE <DB> KEEP 30d,180d,3650d;     -- 企业版多级存储：keep0<=keep1<=keep2 分别对应 level0/1/2 的保留期
ALTER DATABASE <DB> S3_KEEPLOCAL 180d;       -- 超过该时长的数据迁到 S3
S3MIGRATE DATABASE <DB>;                     -- 手动触发 S3 迁移
ALTER DATABASE <DB> KEEP_TIME_OFFSET <HOURS>;  -- [3.2+] 迁移/过期删除任务的执行时刻偏移（基于 UTC 0 点，单位小时）
ALTER ALL DNODES 'retentionSpeedLimitMB' '50'; -- 迁移限速 MB/s
SELECT * FROM information_schema.ins_dnode_variables WHERE name LIKE '%speed%';
```

- 较新版本（约 3.3.7 起）S3 相关更名为共享存储：`ss_keeplocal`、`SSMIGRATE` 等；执行前用 `SHOW CREATE DATABASE` 确认当前版本字段名。

```sql
USE <DB>;
SHOW DISK_INFO;                                         -- 当前库在各节点的磁盘用量

-- 按库汇总（ins_disk_usage 数值单位为 KB，/1024/1024 得 GB）
SELECT db_name,
       ROUND(SUM(data1)/1024/1024, 2)      AS hot_gb,
       ROUND(SUM(data2)/1024/1024, 2)      AS warm_gb,
       ROUND(SUM(data3)/1024/1024, 2)      AS cold_gb,
       ROUND(SUM(wal_size)/1024/1024, 2)   AS wal_gb,
       ROUND(SUM(cache_rdb)/1024/1024, 2)  AS cache_gb,
       ROUND(SUM(table_meta)/1024/1024, 2) AS meta_gb,
       ROUND(SUM(s3)/1024/1024, 2)         AS s3_gb,
       ROUND(SUM(wal_size+data1+data2+data3+cache_rdb+table_meta+s3)/1024/1024, 2) AS total_gb
FROM information_schema.ins_disk_usage
GROUP BY db_name ORDER BY total_gb DESC;
-- 需要 TOTAL 行时再 UNION ALL 一个不分组的同结构查询

-- 按 fileset 看某库数据增长趋势（total_size 为字节）
SELECT db_name, fileset_id, start_time, end_time, COUNT(*) AS vg_cnt,
       ROUND(SUM(total_size)/1024.0/1024/1024, 2) AS total_gb
FROM information_schema.ins_filesets
WHERE db_name = '<DB>' AND start_time >= '<TS_START>' AND end_time < '<TS_END>'
GROUP BY db_name, fileset_id, start_time, end_time ORDER BY fileset_id;

SHOW <DB>.VGROUPS;   -- vgroup_id 与磁盘目录 vnode/vnode<ID> 对应
-- 数据文件命名：v<VGROUP_ID>f<FILESET_ID>ver<COMMIT_ID>.data
SELECT * FROM information_schema.ins_filesets WHERE vgroup_id = <VGROUP_ID> AND fileset_id = <FILESET_ID>;
```

- ins_disk_usage 的列单位以实际版本文档为准，结果与 `du` 对比一次即可校准。
- `s3` 列是远端对象存储，不占本地盘；本地盘告警只看 data1/2/3 + wal + cache + meta。

## 9. 磁盘 IO 高：定位被频繁读的 vnode

```bash
# fatrace 需 root；-s 采样秒数；输出形如 "taosd(<PID>): R /path/vnode/vnode<N>/..."
fatrace -s 30 -o /tmp/trace.txt
# 事件类型：O 打开 R 读 W 写 C 关闭 D 删除（可能组合如 RC）
grep "(<PID>):" /tmp/trace.txt | awk '$2 ~ /R/ {print $NF}' | sort | uniq -c | sort -n | tail -20     # 热点文件
grep "(<PID>):" /tmp/trace.txt | awk '$2 ~ /R/ {print $NF}' \
  | sed -nE 's|.*/vnode/vnode([0-9]+)/.*|\1|p' | sort | uniq -c | sort -n | tail -20                   # 热点 vnode
```

```sql
SELECT * FROM information_schema.ins_vgroups WHERE vgroup_id IN (<VGROUP_ID>, ...);   -- vnode 目录号 = vgroup_id → 所属库
```

- 用 `awk '$2 ~ /R/'` 按事件列匹配，不要直接 `grep R`（路径里的大写 R 也会命中）。

## 10. taosAdapter：录制某时间段的 SQL / 临时调高日志 [3.3.x]

```bash
# 录制指定时间窗口内经 adapter 执行的 SQL 到 CSV（文件落在 adapter 日志目录）
curl -s -u <USER>:<PASSWORD> -X POST 'http://<HOST>:6041/record_sql' \
  --data '{"start_time":"<YYYY-MM-DD HH:MM:SS>","end_time":"<YYYY-MM-DD HH:MM:SS>","location":"Asia/Shanghai"}'
curl -s -u <USER>:<PASSWORD> -X GET    'http://<HOST>:6041/record_sql' | jq   # 查看录制任务
curl -s -u <USER>:<PASSWORD> -X DELETE 'http://<HOST>:6041/record_sql'        # 停止

# 临时开 trace 日志，10 分钟后恢复（务必恢复）
curl -s -u <USER>:<PASSWORD> -X PUT 'http://<HOST>:6041/config' --data '{"log.level":"trace"}'
sleep 600
curl -s -u <USER>:<PASSWORD> -X PUT 'http://<HOST>:6041/config' --data '{"log.level":"info"}'
```

- 用 `-u` 时注意 shell history；可用 `curl --netrc-file` 或读取环境变量。

## 11. taosdump 导出导入

```bash
# 输出目录需提前创建且为空；-p 后不带值则交互输入密码
taosdump -h <HOST> -u <USER> -p -o /backup/td_dump -T 8 <DB> <STABLE>        # 指定库的指定超级表（含数据）
taosdump -h <HOST> -u <USER> -p -D <DB1>,<DB2> -s -o /backup/td_schema        # 多个库，仅结构
taosdump -h <HOST> -u <USER> -p <DB> <STABLE> -s -o /backup/td_schema         # 指定表，仅结构

taosdump -h <HOST> -u <USER> -p -i /backup/td_dump -T 8                       # 原样导入
taosdump -h <HOST> -u <USER> -p -i /backup/td_dump -T 8 -W "<DB>=<NEW_DB>"    # 导入到新库名（多个用 | 分隔）
```

- `-W` 改库名导入时，若导出时未包含建库/超级表结构，需先在目标库手工建好同结构超级表。

## 12. taosX 数据同步任务（默认端口 6050）

```bash
curl -s http://<HOST>:6050/tasks | jq -r '.[] | [.id, .name, .status] | @tsv' | column -t   # 任务列表
curl -s http://<HOST>:6050/tasks/<ID> | jq
curl -s http://<HOST>:6050/tasks/<ID> | jq -r '"Status: \(.status)", "Reason: \(.reason)"'  # 异常原因
curl -s -X POST http://<HOST>:6050/tasks/<ID>/stop
curl -s -X POST http://<HOST>:6050/tasks/<ID>/start
```

## 13. 用户与权限

```sql
CREATE USER <USER> PASS '<PASSWORD>';      -- 3.3.x 对密码长度/复杂度有要求
SHOW USERS;                                -- = information_schema.ins_users
ALTER USER <USER> PASS '<PASSWORD>';
ALTER USER <USER> ENABLE 0;                -- 禁用（不影响已建立的连接，需要时再 KILL CONNECTION）
DROP USER <USER>;

GRANT READ  ON <DB>.* TO <USER>;           -- read / write 两种权限相互独立，读写都要就分别授予
GRANT WRITE ON <DB>.* TO <USER>;
REVOKE READ  ON <DB>.* FROM <USER>;
REVOKE WRITE ON <DB>.* FROM <USER>;
SHOW USER PRIVILEGES;                      -- = information_schema.ins_user_privileges
```

- 部署后第一件事改掉 root 默认密码；taosAdapter / taosKeeper / taosX / 监控等组件配置里的密码要同步更新。
