---
name: postgresql-toolbox
description: PostgreSQL 建库建用户（含 public schema 权限收紧，区分 PG14- / PG15+）、psql 常用元命令、.pgpass + pg_service.conf 免密别名登录
metadata:
  type: reference
---

# PostgreSQL 速查

## 1. 建一个"只给某个用户用"的库

```sql
-- 1) 建用户（密码交互设置更安全：psql 里 \password <USER>）
CREATE USER <USER> WITH PASSWORD '<PASSWORD>';

-- 2) 建库并指定 owner；用 template0 才能指定与模板不同的编码/排序规则
CREATE DATABASE <DB>
  OWNER <USER>
  ENCODING 'UTF8'
  LC_COLLATE 'en_US.utf8'
  LC_CTYPE   'en_US.utf8'
  TEMPLATE template0;

-- 3) 禁止其他人连接该库（默认 PUBLIC 有 CONNECT 权限）
REVOKE CONNECT ON DATABASE <DB> FROM PUBLIC;

-- 4) 进入新库，收紧 public schema（必须在目标库内执行，schema 权限是库级别的）
\c <DB>
REVOKE CREATE ON SCHEMA public FROM PUBLIC;   -- PG14 及以前默认所有人可在 public 建表
ALTER SCHEMA public OWNER TO <USER>;          -- 或：GRANT ALL ON SCHEMA public TO <USER>;
```

关键说明：
- `REVOKE ... ON SCHEMA public` 只作用于**当前连接的库**。在 `postgres` 库里执行对新建库无效；想让以后所有新库都生效，在 `template1` 里执行一次。
- PG15+ 已默认收回 PUBLIC 在 public schema 的 CREATE 权限，且 public schema 归 `pg_database_owner`（即库 owner）所有，第 4 步大多可省；PG14 及以前必须做。
- `LC_COLLATE/LC_CTYPE` 的 locale 必须在 OS 上存在（`locale -a` 查看）；PG 依赖 glibc 排序规则，**跨 glibc 大版本升级（如 2.28）后需重建相关索引**。
- 库 owner 不是超级用户，但能删库；只给应用读写可再单独建只读/读写角色。

## 2. psql 常用元命令

```text
\l              列出所有库（\l+ 带大小）
\c <DB>         切换库
\dn             列 schema
\dt <SCHEMA>.*  列表        \d+ <TABLE>  看表结构/索引/大小
\du+            列角色及属性
\x auto         宽结果自动竖排
\timing on      显示每条 SQL 耗时
\i <FILE.sql>   执行 SQL 文件
\o <FILE>       之后的查询结果输出到文件（不是导出表/SQL）；单独 \o 恢复输出到屏幕
\q              退出
```

```sql
SELECT usename, usesuper, usecreatedb, usebypassrls FROM pg_user;   -- 用户属性
```

## 3. 免密 + 别名登录

```bash
# ~/.pgpass：每行 host:port:dbname:user:password，可用 * 通配
touch ~/.pgpass && chmod 0600 ~/.pgpass      # 权限不是 0600 时 libpq 会直接忽略该文件
echo '<HOST>:5432:*:<USER>:<PASSWORD>' >> ~/.pgpass

# ~/.pg_service.conf：连接别名（不放密码，密码仍从 .pgpass 取）
cat >> ~/.pg_service.conf <<'EOF'
[<ALIAS>]
host=<HOST>
port=5432
user=<USER>
dbname=<DB>
EOF

psql service=<ALIAS>          # 或 PGSERVICE=<ALIAS> psql
```

- `.pgpass` 的 host 字段要和连接时写的 host **字面一致**（`localhost` 与 `127.0.0.1` 不互通；走 Unix socket 时匹配 `localhost`）。
- 系统级 service 文件位置：`pg_config --sysconfdir`/pg_service.conf，或用 `PGSERVICEFILE` 指定。
