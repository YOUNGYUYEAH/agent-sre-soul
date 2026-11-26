---
name: mysql-toolbox
description: MySQL 排障命令/SQL 速查（CPU、慢 SQL、锁与事务、MDL、内存、连接、磁盘、索引、复制/MGR、客户端技巧），已标注 5.7 / 8.0 差异
metadata:
  type: reference
---

# MySQL 排障速查

> 版本约定：未标注即 5.7 / 8.0 通用；`[8.0]` 表示仅 8.0（含小版本号时为最低版本）。
> performance_schema 的 `*_TIMER_*` 单位是皮秒，`/1e12` 得秒。所有 `summary` 表是**自启动或上次 TRUNCATE 以来的累计值**，看趋势要做两次快照求差。

## 0. 先看全局：我连的是谁、什么配置

```sql
\s                                   -- 客户端内：当前连接、版本、字符集、uptime
SELECT @@hostname, @@port, @@server_id, @@server_uuid, @@version, @@read_only, @@super_read_only;
SELECT @@global.sql_mode, @@session.sql_mode;
SELECT @@character_set_server, @@character_set_database, @@character_set_connection,
       @@character_set_client, @@character_set_results,
       @@collation_server, @@collation_database, @@collation_connection;
SELECT @@datadir, @@log_error, @@pid_file, @@socket, @@tmpdir, @@secure_file_priv;
```

## 1. 连接数打满 / 线程堆积

```sql
SHOW GLOBAL STATUS LIKE 'Threads_connected';   -- 当前连接
SHOW GLOBAL STATUS LIKE 'Threads_running';     -- 真正在跑的（经验：持续 > CPU 核数 即拥塞）
SHOW GLOBAL STATUS LIKE 'Max_used_connections';
SHOW VARIABLES LIKE 'max_connections';

SELECT state, COUNT(*) FROM information_schema.processlist GROUP BY state ORDER BY 2 DESC;  -- 先看状态分布
SELECT user, SUBSTRING_INDEX(host, ':', 1) AS src, COUNT(*) FROM information_schema.processlist
GROUP BY 1, 2 ORDER BY 3 DESC;                                                              -- 谁在占连接

SHOW FULL PROCESSLIST;   -- 不带 FULL 时 Info 只显示前 100 字符
SELECT id, user, host, db, command, time, state, info
FROM information_schema.processlist
WHERE command <> 'Sleep' AND time > 10
ORDER BY time DESC;
```

- `[8.0.22+]` `information_schema.processlist` 已标记废弃，可用 `performance_schema.processlist`（不持有全局 mutex，对繁忙实例更友好）。
- 状态分布里大量 `Waiting for table metadata lock` → 去看第 4 节 MDL；大量 `Sending data`/`executing` → 看第 2 节。

### 会话 + 事务合并视图（找"长事务挂着不提交"的 Sleep 连接）

```sql
SELECT p.id, p.user, p.host, p.db, p.command, p.time, p.state,
       LEFT(p.info, 50) AS sql_50,
       t.trx_started,
       TIMESTAMPDIFF(SECOND, t.trx_started, NOW()) AS trx_sec,
       t.trx_rows_modified, t.trx_isolation_level
FROM information_schema.processlist p
LEFT JOIN information_schema.innodb_trx t ON p.id = t.trx_mysql_thread_id
ORDER BY trx_sec DESC;
```

- 关键经验：`command = Sleep` 但 `trx_started` 很早的连接 = 应用开了事务没提交，它持有的行锁/MDL 会阻塞别人，processlist 里却看不到 SQL。

## 2. CPU 高 / 慢 SQL

### 2.1 当前正在跑的最久语句

```sql
SELECT id, user, host, db, command, time,
       DATE_SUB(NOW(), INTERVAL time SECOND) AS started_at, state, info
FROM information_schema.processlist
WHERE command <> 'Sleep' AND info IS NOT NULL
ORDER BY time DESC LIMIT 10;

-- sys 视图版本，信息更全（临时表、全表扫描、锁等待）
SELECT conn_id, user, db, command, state, time,
       LEFT(current_statement, 200) AS stmt, statement_latency,
       rows_examined, rows_sent, tmp_tables, tmp_disk_tables, full_scan,
       lock_latency, trx_latency, trx_state
       -- , cpu_latency            -- [8.0.28+] 才有该列
FROM sys.session
WHERE command <> 'Sleep'
  AND user NOT IN ('mysql.session', 'mysql.sys')
  AND user NOT LIKE 'sql/%' AND user NOT LIKE 'group_rpl/%'   -- 排除复制/MGR 后台线程
ORDER BY time DESC;
```

- 后台线程名随版本变：8.0.26 前是 `sql/slave_worker`，之后是 `sql/replica_worker`，用 `LIKE 'sql/%'` 兼容。

### 2.2 历史累计 Top SQL（按总耗时）

```sql
SELECT digest_text,
       count_star,
       ROUND(sum_timer_wait/1e12, 3) AS total_s,
       ROUND(avg_timer_wait/1e12, 3) AS avg_s,
       ROUND(max_timer_wait/1e12, 3) AS max_s,
       ROUND(sum_lock_time/1e12, 3)  AS lock_s,
       sum_rows_examined, sum_rows_sent, sum_rows_affected,
       sum_created_tmp_tables, sum_created_tmp_disk_tables,
       sum_select_scan, sum_no_index_used, sum_no_good_index_used
       -- , ROUND(sum_cpu_time/1e12, 3) AS cpu_s   -- [8.0.28+] 真正的 CPU 时间
FROM performance_schema.events_statements_summary_by_digest
ORDER BY sum_timer_wait DESC LIMIT 10;

SELECT * FROM sys.statement_analysis ORDER BY total_latency DESC LIMIT 10;  -- 同上的格式化版本
```

- **注意**：`sum_timer_wait` / `avg_latency` 是**墙钟耗时**（含锁等待、IO），不等于 CPU。真要按 CPU 排需 8.0.28+ 的 `SUM_CPU_TIME`；老版本用 `sum_rows_examined` 大 + `sum_no_index_used` 高作为"吃 CPU"的近似信号。
- `rows_examined / rows_sent` 比值很大 → 缺索引或索引选择性差。

### 2.3 按语句类型看整体负载

```sql
SELECT REPLACE(event_name, 'statement/sql/', '') AS stmt_type,
       count_star,
       ROUND(sum_timer_wait/1e12, 2) AS total_s,
       ROUND(avg_timer_wait/1e12, 4) AS avg_s,
       sum_rows_examined, sum_created_tmp_tables, sum_created_tmp_disk_tables,
       IF(sum_created_tmp_tables = 0, 0,
          ROUND(sum_created_tmp_disk_tables / sum_created_tmp_tables * 100)) AS disk_tmp_pct,
       sum_select_scan, sum_no_index_used
FROM performance_schema.events_statements_summary_global_by_event_name
WHERE event_name LIKE 'statement/sql/%' AND count_star > 0
ORDER BY sum_timer_wait DESC;
```

### 2.4 慢日志表

```sql
SHOW VARIABLES WHERE variable_name IN ('slow_query_log','long_query_time','log_output','slow_query_log_file');
SELECT start_time, query_time, lock_time, rows_examined, db, sql_text
FROM mysql.slow_log ORDER BY start_time DESC LIMIT 10;
```

- 只有 `log_output` 包含 `TABLE` 时 `mysql.slow_log` 才有数据；默认是 `FILE`，那就去 `slow_query_log_file` 用 `mysqldumpslow` / `pt-query-digest` 分析。

### 2.5 执行计划

```sql
EXPLAIN <SQL>;  SHOW WARNINGS;      -- SHOW WARNINGS 给出优化器改写后的 SQL
EXPLAIN FORMAT=JSON <SQL>;          -- 看 cost、used_columns、是否用到覆盖索引
EXPLAIN FORMAT=TREE <SQL>;          -- [8.0.16+]
EXPLAIN ANALYZE <SQL>;              -- [8.0.18+] 会真实执行！
EXPLAIN FOR CONNECTION <ID>;        -- 对正在跑的连接取执行计划（ID 来自 processlist）
```

- `EXPLAIN ANALYZE` **真实执行语句**；8.0.19+ 支持多表 UPDATE/DELETE，对 DML 用它会真的改数据，生产慎用；慢 SELECT 也会再跑一遍。
- 生产上长 SQL 排查优先 `EXPLAIN FOR CONNECTION`，不用复制 SQL 重跑。

## 3. 行锁等待 / 死锁

> 注意概念：**死锁** InnoDB 会自动检测并回滚一方（报 1213），无需人工 KILL；需要人工介入的通常是**锁等待**（报 1205 超时）和长事务阻塞。

### 3.1 谁在阻塞谁

```sql
-- 5.7 / 8.0 通用（推荐）：sys 视图直接给出 blocking_pid 和 sql_kill_blocking_query
SELECT wait_age, locked_table, locked_type,
       waiting_pid, waiting_query,
       blocking_pid, blocking_query, blocking_trx_age,
       sql_kill_blocking_connection
FROM sys.innodb_lock_waits;

-- [8.0] 原生表
SELECT r.trx_mysql_thread_id AS waiting_thread, r.trx_query AS waiting_sql,
       b.trx_mysql_thread_id AS blocking_thread, b.trx_query AS blocking_sql
FROM performance_schema.data_lock_waits w
JOIN information_schema.innodb_trx b ON b.trx_id = w.blocking_engine_transaction_id
JOIN information_schema.innodb_trx r ON r.trx_id = w.requesting_engine_transaction_id;

-- [5.7] 原生表（8.0 已删除 innodb_locks / innodb_lock_waits）
SELECT r.trx_mysql_thread_id AS waiting_thread, r.trx_query AS waiting_sql,
       b.trx_mysql_thread_id AS blocking_thread, b.trx_query AS blocking_sql
FROM information_schema.innodb_lock_waits w
JOIN information_schema.innodb_trx b ON b.trx_id = w.blocking_trx_id
JOIN information_schema.innodb_trx r ON r.trx_id = w.requesting_trx_id;
```

| 用途 | 5.7 | 8.0 |
|---|---|---|
| 当前锁 | `information_schema.innodb_locks` | `performance_schema.data_locks` |
| 锁等待 | `information_schema.innodb_lock_waits` | `performance_schema.data_lock_waits` |
| 事务 | `information_schema.innodb_trx` | 同左 |

- `blocking_sql` 经常是 NULL：阻塞者已执行完语句但事务未提交（见第 1 节 Sleep 长事务）。

### 3.2 活跃事务列表（按开始时间）

```sql
SELECT trx_id, trx_mysql_thread_id, trx_state, trx_started,
       TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS run_sec,
       trx_weight, trx_query, trx_tables_in_use, trx_tables_locked,
       trx_lock_structs, trx_rows_locked, trx_rows_modified,
       trx_isolation_level, trx_is_read_only
FROM information_schema.innodb_trx
ORDER BY trx_started;
```

- 用 `TIMESTAMPDIFF(SECOND, trx_started, NOW())`：`trx_started` 是会话时区时间，若用 `UNIX_TIMESTAMP() - TO_SECONDS(...)` 这类混算，会因时区偏移算错（非 UTC 时区差 N 小时）。

### 3.3 死锁现场与统计

```sql
SHOW ENGINE INNODB STATUS\G          -- LATEST DETECTED DEADLOCK 段只保留最近一次
SELECT name, count FROM information_schema.innodb_metrics WHERE name = 'lock_deadlocks';  -- 死锁累计次数
SHOW GLOBAL STATUS LIKE 'Innodb_row_lock_%';   -- 行锁"等待"次数/时长，不是死锁次数
SET GLOBAL innodb_print_all_deadlocks = ON;    -- 把每次死锁都写进 error log，便于事后分析
```

```bash
mysql --login-path=<NAME> -e "SHOW ENGINE INNODB STATUS\G" > innodb_status_$(date +%F_%H%M%S).txt
```

## 4. 元数据锁（MDL）：DDL 卡住、表访问全卡在 "Waiting for table metadata lock"

```sql
-- 5.7 默认未开启 MDL instrument，需要先开（8.0 默认已开）：
-- UPDATE performance_schema.setup_instruments SET enabled='YES', timed='YES' WHERE name='wait/lock/metadata/sql/mdl';

SELECT * FROM sys.schema_table_lock_waits\G     -- 直接给出 blocking_pid 和 sql_kill_blocking_connection

SELECT ml.object_schema, ml.object_name, ml.lock_type, ml.lock_duration, ml.lock_status,
       t.processlist_id, t.processlist_user, t.processlist_host, t.processlist_time, t.processlist_info
FROM performance_schema.metadata_locks ml
JOIN performance_schema.threads t ON ml.owner_thread_id = t.thread_id
WHERE ml.object_schema = '<DB>'            -- 去掉条件看全部
ORDER BY ml.lock_status DESC;              -- PENDING 在前，GRANTED 中找持有者
```

- 排障思路：PENDING 的通常是 DDL；持有 GRANTED `SHARED_READ`/`SHARED_WRITE` 的往往是**未提交事务**（哪怕只是一个 SELECT），杀它而不是杀 DDL。

## 5. 处理：KILL

```sql
KILL QUERY <ID>;   -- 只终止当前语句，连接保留（首选）
KILL <ID>;         -- 断开连接，未提交事务回滚（大事务回滚可能很久，期间仍持锁）

-- 批量生成 KILL 语句（先人工审查输出再执行）
SELECT CONCAT('KILL QUERY ', id, ';')
FROM information_schema.processlist
WHERE db = '<DB>' AND command NOT IN ('Sleep', 'Binlog Dump', 'Binlog Dump GTID', 'Daemon')
  AND user NOT IN ('system user', 'event_scheduler', '<REPL_USER>')
  AND id <> CONNECTION_ID()               -- 排除自己
  AND time > 5;
```

- 杀之前判断 `trx_rows_modified`：修改量大的事务 KILL 后回滚耗时与原执行相当，可能不如等它跑完。

## 6. 内存占用高

```sql
SHOW VARIABLES LIKE 'innodb_buffer_pool_size';
SHOW VARIABLES LIKE 'max_connections';
SHOW VARIABLES LIKE '%buffer_size';      -- sort/join/read 等会话级 buffer，× 连接数 才是峰值风险

SELECT * FROM sys.memory_global_by_current_bytes LIMIT 20;    -- 全局热点
SELECT user, host, event_name, sys.format_bytes(current_number_of_bytes_used) AS used
FROM performance_schema.memory_summary_by_account_by_event_name
ORDER BY current_number_of_bytes_used DESC LIMIT 10;          -- 按账号
SELECT thread_id, event_name, sys.format_bytes(current_number_of_bytes_used) AS used
FROM performance_schema.memory_summary_by_thread_by_event_name
ORDER BY current_number_of_bytes_used DESC LIMIT 20;          -- 按线程，再用 threads 表映射到 processlist_id

-- Buffer Pool 命中率
SELECT (1 - r.v / q.v) * 100 AS hit_rate_pct FROM
 (SELECT variable_value AS v FROM performance_schema.global_status WHERE variable_name='Innodb_buffer_pool_reads') r,
 (SELECT variable_value AS v FROM performance_schema.global_status WHERE variable_name='Innodb_buffer_pool_read_requests') q;
```

- `[5.7]` memory instrument 默认大多关闭，上述 memory 视图数据不全；需在 `setup_instruments` 开启 `memory/%`（只统计开启之后的分配）。8.0 默认开启。
- 命中率是累计值，刚重启时偏低；长期 < 99% 才考虑扩 buffer pool。
- RSS 远大于 buffer_pool + 会话 buffer 时，考虑 glibc malloc 碎片（换 jemalloc/tcmalloc 是常见手段）。

## 7. 网络流量大

```sql
SHOW GLOBAL STATUS WHERE variable_name IN ('Bytes_sent', 'Bytes_received');  -- 间隔采样两次求速率

-- 每个连接已发送字节（会话累计值，不是速率）
SELECT t.processlist_id, t.processlist_user, t.processlist_host,
       CAST(s.variable_value AS UNSIGNED) AS bytes_sent,
       ROUND(stmt.timer_wait/1e12, 3) AS stmt_s, LEFT(stmt.sql_text, 200) AS sql_text
FROM performance_schema.status_by_thread s
JOIN performance_schema.threads t ON s.thread_id = t.thread_id
LEFT JOIN performance_schema.events_statements_current stmt ON t.thread_id = stmt.thread_id
WHERE s.variable_name = 'Bytes_sent' AND t.processlist_id IS NOT NULL
ORDER BY bytes_sent DESC LIMIT 10;
```

- `variable_value` 是字符串，**必须 CAST** 再排序，否则按字典序（"9" > "100000"）。
- `sys.host_summary_by_file_io_type` 是**文件 IO**，不是网络流量，别用错。
- 大流量常见根因：`SELECT *` 拉大字段、无 LIMIT 全表导出、binlog dump 给多个从库/CDC。

## 8. 磁盘用量

```sql
-- [8.0] information_schema.tables 统计默认缓存 24h（information_schema_stats_expiry=86400），先刷新：
SET SESSION information_schema_stats_expiry = 0;

SELECT table_schema, ROUND(SUM(data_length + index_length)/1024/1024/1024, 2) AS size_gb,
       ROUND(SUM(data_free)/1024/1024/1024, 2) AS free_gb
FROM information_schema.tables GROUP BY table_schema ORDER BY size_gb DESC;

SELECT table_schema, table_name, table_rows,
       ROUND(data_length/1024/1024, 2) AS data_mb,
       ROUND(index_length/1024/1024, 2) AS index_mb,
       ROUND((data_length + index_length)/1024/1024, 2) AS total_mb,
       ROUND(data_free/1024/1024, 2) AS free_mb
FROM information_schema.tables
WHERE table_schema = '<DB>'
ORDER BY data_length + index_length DESC;
```

- InnoDB 的 `table_rows` 是**估算值**（误差可达 40%+），精确行数只能 `COUNT(*)`。
- `data_free` 大 = 碎片多，`OPTIMIZE TABLE`（InnoDB 下等于重建表，耗 IO 且需双倍空间）可回收。
- 实际磁盘还要算 binlog、undo、redo、临时表空间、error/slow log：`du -sh <DATADIR>/*`。

## 9. 索引

```sql
SHOW INDEX FROM <DB>.<TABLE>;

-- 没有主键的 InnoDB 表（MGR 要求必须有主键；无主键表在 ROW 复制下从库会极慢）
SELECT t.table_schema, t.table_name
FROM information_schema.tables t
LEFT JOIN information_schema.table_constraints c
  ON t.table_schema = c.table_schema AND t.table_name = c.table_name AND c.constraint_type = 'PRIMARY KEY'
WHERE t.table_type = 'BASE TABLE' AND t.engine = 'InnoDB'
  AND t.table_schema NOT IN ('mysql','information_schema','performance_schema','sys')
  AND c.constraint_name IS NULL;

SELECT * FROM sys.schema_unused_indexes;      -- 自上次重启以来未使用；刚重启/低峰期数据不可信
SELECT * FROM sys.schema_redundant_indexes;   -- 冗余索引，含建议的 DROP 语句

-- 索引使用与读写比
SELECT object_schema, object_name, index_name, count_star, count_read, count_write,
       CONCAT(TRUNCATE(count_read/count_star*100,0), ':', TRUNCATE(count_write/count_star*100,0)) AS rw_pct,
       ROUND(sum_timer_wait/1e12, 2) AS total_s
FROM performance_schema.table_io_waits_summary_by_index_usage
WHERE index_name IS NOT NULL AND count_star > 0
ORDER BY sum_timer_wait DESC;
```

- 删除"未使用"索引前：确认覆盖一个完整业务周期（月结/报表），8.0 可先 `ALTER TABLE ... ALTER INDEX <IDX> INVISIBLE` 观察，再删。

## 10. 主从复制 / MGR

```sql
SHOW REPLICA STATUS\G     -- [8.0.22+]；老版本 SHOW SLAVE STATUS\G（8.4 已移除）
-- 关注：Replica_IO_Running / Replica_SQL_Running、Seconds_Behind_Source、Last_*_Error、Retrieved/Executed_Gtid_Set

-- MGR 成员状态
SELECT member_id, member_host, member_port, member_state, member_role, member_version
FROM performance_schema.replication_group_members;
-- MGR 事务积压（certifier/applier 队列）
SELECT member_id, count_transactions_in_queue, count_transactions_remote_in_applier_queue
FROM performance_schema.replication_group_member_stats;

STOP GROUP_REPLICATION;  START GROUP_REPLICATION;
SHOW VARIABLES LIKE 'group_replication_start_on_boot';
SET PERSIST group_replication_start_on_boot = ON;            -- [8.0] PERSIST 写入 mysqld-auto.cnf
SELECT group_replication_set_as_primary('<MEMBER_ID>');      -- [8.0.13+] 单主模式手动切主
```

- `Seconds_Behind_Source` 只反映 SQL 线程相对 relay log 的延迟；IO 线程断了它可能显示 NULL 或 0，要结合 IO 线程状态判断。

## 11. 账号与授权 [8.0]

```sql
CREATE USER '<USER>'@'<HOST_PATTERN>' IDENTIFIED BY '<PASSWORD>';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER, INDEX, REFERENCES,
      CREATE TEMPORARY TABLES, LOCK TABLES, CREATE VIEW, SHOW VIEW,
      CREATE ROUTINE, ALTER ROUTINE, EVENT, TRIGGER, EXECUTE
ON <DB>.* TO '<USER>'@'<HOST_PATTERN>';
SHOW GRANTS FOR '<USER>'@'<HOST_PATTERN>';
DROP USER '<USER>'@'<HOST_PATTERN>';   -- 会同时清理其授权
```

- 8.0 起 `GRANT` 不再隐式建用户，必须先 `CREATE USER`。
- `GRANT/CREATE USER/DROP USER` 自动生效，**不需要** `FLUSH PRIVILEGES`（只有直接改 mysql.* 系统表才需要）。
- 慎用 `WITH GRANT OPTION`：等于允许该账号把权限再转授他人。
- 密码不要写进脚本/片段；交互输入或走密钥管理。

## 12. 表与库结构

```sql
SHOW FULL TABLES FROM <DB>;                       -- Table_type 区分表/视图
SHOW CREATE DATABASE <DB>\G
DESC <DB>.<TABLE>;
SHOW CREATE TABLE <DB>.<TABLE>\G
SHOW TABLE STATUS FROM <DB> LIKE '<TABLE>'\G      -- 引擎、行数估算、Data_free、Auto_increment
```

## 13. 客户端技巧

```bash
# 免明文密码登录（凭据混淆存于 ~/.mylogin.cnf）
mysql_config_editor set --login-path=<NAME> --host=<HOST> --port=<PORT> --user=<USER> --password  # 交互输入
mysql_config_editor print --all
mysql_config_editor remove --login-path=<NAME>
mysql --login-path=<NAME>

mysql --login-path=<NAME> --prompt='\u@\h [\d]> '    # 多实例时提示符带上主机，防止连错库
```

```sql
prompt <ALIAS> [\d]>      -- 会话内改提示符（\h 太长时用静态别名，如 prod-xx）
pager less -SFX           -- 宽结果横向滚动，不清屏
pager grep -i <KEYWORD>   -- 过滤输出；也可 pager wc -l
nopager
tee /tmp/session.log      -- 会话内容落盘
notee
\! <SHELL_CMD>            -- 执行 shell
\e                        -- 外部编辑器写长 SQL
```
