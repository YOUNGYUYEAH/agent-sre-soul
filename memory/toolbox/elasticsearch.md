---
name: elasticsearch
description: Elasticsearch 运维速查（集群诊断、索引/数据流/ILM 管理、DSL/KQL/SQL 查询、日志聚合排障、导出），已修正常见写法错误并标注 7.x/8.x 差异
metadata:
  type: reference
---

# Elasticsearch 运维速查

约定：`ES="curl -s -u $ES_USER:$ES_PASS"`，地址 `<ES_HOST>`（含端口）。
- 7.x 默认 `http://`；**8.x 默认开启安全与 HTTP TLS**，需 `https://` + `--cacert <CA_CRT>`（临时可 `-k`）。
- GET 请求不需要 `-H Content-Type`，带 body 的 PUT/POST 才需要 `-H 'Content-Type: application/json'`。
- 密码放环境变量，不要写进命令历史；URL 内嵌密码时特殊字符需 URL 编码（`@`→`%40`）。
- Dev Tools 写法（`GET /<INDEX>/_search {...}`）与 curl 等价，下文混用。

## 1. 集群诊断（先看这一节）

| 目的 | 命令 | 关键说明 |
|---|---|---|
| 健康 | `$ES "<ES_HOST>/_cluster/health?pretty"` | red=有主分片未分配；yellow=副本未分配 |
| 为何未分配 | `$ES "<ES_HOST>/_cluster/allocation/explain?pretty"` | 比 grep UNASSIGNED 更直接给出原因（磁盘水位、分配过滤、节点丢失） |
| 未分配分片 | `$ES "<ES_HOST>/_cat/shards?v&h=index,shard,prirep,state,unassigned.reason" \| grep UNASSIGNED` | |
| 磁盘 | `$ES "<ES_HOST>/_cat/allocation?v&h=node,shards,disk.percent,disk.used,disk.avail&s=disk.percent:desc"` | **用 `h=` 显式指定列**再 awk；8.x 新版本 `_cat/allocation` 增加了列，原 `awk '$6>=80'` 会错位 |
| 节点资源 | `$ES "<ES_HOST>/_cat/nodes?v&h=ip,name,node.role,master,cpu,heap.percent,load_1m,disk.used_percent&s=heap.percent:desc"` | heap 长期 >85% 关注 GC/大聚合 |
| 是否只读 | `$ES "<ES_HOST>/*/_settings/index.blocks.read_only_allow_delete?pretty"` | 有输出即被 flood_stage 锁定 |
| 线程池拒绝 | `$ES "<ES_HOST>/_cat/thread_pool?v&h=node_name,name,active,queue,rejected" \| awk 'NR==1 \|\| $5>0'` | 看 write/search 的 rejected；默认列序为 node_name name active queue rejected |
| 热线程 | `$ES "<ES_HOST>/_nodes/hot_threads?threads=10&type=cpu"` | 纯文本输出，CPU 高时抓 2~3 次对比 |
| 后台任务 | `$ES "<ES_HOST>/_tasks?detailed=true&actions=*reindex*,*forcemerge*&pretty"` | 取消：`POST _tasks/<TASK_ID>/_cancel` |

### 磁盘水位应急
默认 low/high/flood_stage = 85%/90%/95%。达到 flood_stage 后索引被加 `read_only_allow_delete`，写入报 `FORBIDDEN/12/index read-only`。

```bash
# 临时调高水位（应急，事后务必恢复）
$ES -X PUT "<ES_HOST>/_cluster/settings" -H 'Content-Type: application/json' -d '{
  "persistent": {
    "cluster.routing.allocation.disk.watermark.low": "90%",
    "cluster.routing.allocation.disk.watermark.high": "95%",
    "cluster.routing.allocation.disk.watermark.flood_stage": "97%"
  }
}'
# 恢复默认：把上面三个值设为 null
# 7.4 之前：磁盘降下来后需手工解锁（7.4+ 低于 high 后自动解除）
$ES -X PUT "<ES_HOST>/*/_settings" -H 'Content-Type: application/json' -d '{"index.blocks.read_only_allow_delete": null}'
```
- `transient` 在 7.16+ 已不推荐，用 `persistent`，但 persistent 重启不丢，**必须记得回退**。
- 根本解决：删过期索引 / 缩短 ILM 保留 / 扩盘，调水位只是争取时间。

## 2. 索引管理

```bash
$ES "<ES_HOST>/<INDEX>/_settings?pretty"                       # 索引设置
$ES "<ES_HOST>/_index_template/<TEMPLATE_NAME>*" | jq          # 按「模板名」查（支持通配），不是按索引 pattern
$ES "<ES_HOST>/_cat/indices?v&s=store.size:desc"               # 按占用倒序
$ES "<ES_HOST>/_cat/indices/<PATTERN_A>*,<PATTERN_B>*?v"       # 逗号多个匹配
$ES "<ES_HOST>/_cat/indices/*,-<EXCLUDE>*?v"                   # 先 * 再 - 排除，顺序不能反
$ES "<ES_HOST>/_cat/indices?v&health=yellow"                   # 非 green 索引，直接用 health 参数（red 同理）
$ES "<ES_HOST>/_cat/indices?v&expand_wildcards=all"            # 含 closed/hidden（hidden 需与 open/closed/all 组合）
```
- 用 awk 过滤时注意列序：`health status index uuid pri rep ...`，health 是 **$1**（原片段写 `$3` 是错的）。

### 开关、只读、删除
```bash
$ES -X POST "<ES_HOST>/<INDEX>/_close"   # 关闭后不占堆，但不可查询
$ES -X POST "<ES_HOST>/<INDEX>/_open"
$ES -X PUT  "<ES_HOST>/<INDEX>/_block/write"     # 加写阻塞（7.9+）
# 去掉写阻塞：7.x/8.x 没有 DELETE _block API，用 settings：
$ES -X PUT "<ES_HOST>/<INDEX>/_settings" -H 'Content-Type: application/json' -d '{"index.blocks.write": false}'
# !! 删除索引：先 _cat/indices 核对名字；生产建议 action.destructive_requires_name=true（8.x 默认）禁止通配删除
$ES -X DELETE "<ES_HOST>/<INDEX>"
```

### shrink / split / clone
前置：源索引必须先 `_block/write`，且集群 green。

```bash
# shrink 额外前置：所有主分片副本要落到同一节点
$ES -X PUT "<ES_HOST>/<INDEX>/_settings" -H 'Content-Type: application/json' -d '{
  "index.routing.allocation.require._name": "<NODE_NAME>", "index.blocks.write": true }'
# 目标分片数须是源分片数的因数；在目标上清掉继承的分配约束与写阻塞
$ES -X POST "<ES_HOST>/<INDEX>/_shrink/<TARGET_INDEX>" -H 'Content-Type: application/json' -d '{
  "settings": { "index.number_of_shards": 1,
    "index.routing.allocation.require._name": null, "index.blocks.write": null } }'

# split：目标分片数须是源分片数的整数倍（受 index.number_of_routing_shards 限制）
$ES -X POST "<ES_HOST>/<INDEX>/_split/<TARGET_INDEX>" -H 'Content-Type: application/json' -d '{
  "settings": { "index.number_of_shards": <N>, "index.blocks.write": null } }'

# clone：分片数不变，可在 body 里改 settings
$ES -X POST "<ES_HOST>/<INDEX>/_clone/<TARGET_INDEX>"
```
- 目标索引会继承源的 `index.blocks.write`，忘记清掉会导致新索引也写不进。

## 3. 数据流（Data Stream，7.9+）

```bash
$ES "<ES_HOST>/_data_stream?filter_path=data_streams.name&pretty"   # 只看名字
$ES "<ES_HOST>/_data_stream/<DATA_STREAM>?pretty"                   # 看 backing index、模板、ILM
$ES -X POST "<ES_HOST>/<DATA_STREAM>/_rollover"                     # 手动滚动，生成新写索引
# !! 删除整个数据流（连同所有 backing index），支持逗号和通配
$ES -X DELETE "<ES_HOST>/_data_stream/<DATA_STREAM>"
```
- **非写入的 backing index（`.ds-<DATA_STREAM>-<日期>-<序号>`）可以直接 `DELETE /<BACKING_INDEX>` 删除**，不必先解绑；只有当前写索引不能删，需先 `_rollover`。
- 需要把某个 backing index 从数据流剥离但保留数据时，才用 `_modify`（7.16+）：
```bash
$ES -X POST "<ES_HOST>/_data_stream/_modify" -H 'Content-Type: application/json' -d '{
  "actions": [ { "remove_backing_index": { "data_stream": "<DATA_STREAM>", "index": "<BACKING_INDEX>" } } ] }'
```

## 4. ILM 生命周期

```bash
# 7 天删除策略
$ES -X PUT "<ES_HOST>/_ilm/policy/<ILM_POLICY>" -H 'Content-Type: application/json' -d '{
  "policy": { "phases": {
    "hot":    { "actions": { "rollover": { "max_age": "1d", "max_primary_shard_size": "50gb" } } },
    "delete": { "min_age": "7d", "actions": { "delete": {} } } } } }'

# 挂到可组合模板（7.8+）：PUT 会整体覆盖模板，先 GET 原模板再合并修改
$ES "<ES_HOST>/_index_template/<TEMPLATE_NAME>" | jq '.index_templates[0].index_template'
#   在 template.settings 中加 "index.lifecycle.name": "<ILM_POLICY>" 后整体 PUT 回去

# 模板只对新索引生效；存量索引直接改 settings
$ES -X PUT "<ES_HOST>/<INDEX>/_settings" -H 'Content-Type: application/json' -d '{"index.lifecycle.name": "<ILM_POLICY>"}'

# 检查 ILM 执行状态（比看 settings 更有用，能看到卡在哪一步和报错）
$ES "<ES_HOST>/<INDEX>/_ilm/explain?pretty"
```
- 数据流/滚动场景必须有 hot 阶段 rollover（`max_primary_shard_size` 7.13+ 可用，更早版本用 `max_size`），否则写索引永远不滚动、也不会被删除。
- 有 rollover 时 `min_age` 从**滚动时刻**算起，不是从创建时刻。
- ILM 检查周期默认 10 分钟（`indices.lifecycle.poll_interval`），改完策略不会立刻生效。

## 5. 查询 DSL 基础（bool 逻辑）

| 子句 | 语义 | 是否算分 |
|---|---|---|
| `must` | AND，必须匹配 | 是 |
| `filter` | AND，必须匹配（**保留**匹配文档，不是过滤掉） | 否，可缓存，范围/精确条件优先放这里 |
| `must_not` | NOT | 否 |
| `should` | OR | 是 |

```json
// A and !B（多个子句之间要有逗号）
"query": { "bool": {
  "filter":   [ { "term": { "<FIELD>.keyword": "500" } } ],
  "must_not": [ { "term": { "method.keyword": "GET" } } ]
} }

// A and (B or C)：bool 中同时存在 must/filter 时 should 默认可不匹配（只影响打分），
// 必须加 minimum_should_match: 1，否则结果等于只有 A
"query": { "bool": {
  "filter": [ { "term": { "method.keyword": "GET" } } ],
  "should": [ { "term": { "status.keyword": "500" } }, { "term": { "status.keyword": "502" } } ],
  "minimum_should_match": 1
} }

// 多值 OR 更简洁：terms
"query": { "terms": { "status.keyword": ["500", "502"] } }

// 时间范围：ES 存储 UTC，无时区的绝对时间按 UTC 解释；用 time_zone 指定
"query": { "bool": { "filter": [ { "range": { "@timestamp": {
  "gte": "2026-06-01T00:00:00", "lte": "2026-06-02T00:00:00", "time_zone": "+08:00" } } } ] } }
// 相对时间：now-3d、now-1h、now/d（取整到天）
```
- `term` 不分词：text 字段要用 `.keyword` 子字段，否则查不到；全文检索用 `match`。

## 6. 日志查询与聚合排障（以 ingress/nginx 访问日志为例）

先确认字段名和类型，不同日志管道字段名各不相同：
```
GET /<INDEX>/_mapping
GET /<INDEX>/_mapping/field/<FIELD_A>,<FIELD_B>
```

```json
// 近 3 天非 200 的状态码分布
GET /<INDEX>/_search
{
  "track_total_hits": true,
  "size": 0,
  "query": { "bool": {
    "must_not": [ { "term": { "status.keyword": "200" } } ],
    "filter":   [ { "range": { "@timestamp": { "gte": "now-3d" } } } ] } },
  "aggs": { "status_buckets": { "terms": { "field": "status.keyword", "size": 100 } } }
}

// 嵌套聚合：每个状态码下的 Top URI（并列写两个 aggs 则是各自独立统计）
GET /<INDEX>/_search
{
  "size": 0,
  "query": { "bool": { "filter": [ { "range": { "@timestamp": { "gte": "now-30m" } } } ] } },
  "aggs": { "status_buckets": { "terms": { "field": "status.keyword", "size": 10 },
    "aggs": { "uri_buckets": { "terms": { "field": "<URI_FIELD>.keyword", "size": 10 } } } } }
}

// 慢请求：请求耗时 > 3s 的 URI Top10；把字段换成上游耗时/上游地址即可定位慢后端
GET /<INDEX>/_search
{
  "size": 0,
  "query": { "bool": { "filter": [
    { "range": { "<REQUEST_TIME_FIELD>": { "gt": 3 } } },
    { "range": { "@timestamp": { "gte": "now-3h" } } } ] } },
  "aggs": {
    "uri_buckets": { "terms": { "field": "<URI_PATTERN_FIELD>.keyword", "size": 10 } },
    "ups_buckets": { "terms": { "field": "<UPSTREAM_ADDR_FIELD>.keyword", "size": 10 } } }
}
```
排障经验：
- URI 带 ID/参数会导致基数爆炸，优先聚合「归一化后的 URI 模式」字段（在采集端把数字/UUID 替换掉）。
- 耗时字段若被映射成 keyword/text，range 会按字符串比较，结果错乱，先查 mapping 确认是数值类型。
- `track_total_hits: true` 才返回精确总数（默认上限 10000）；只看聚合时 `size: 0`。
- terms 聚合是近似的，多分片下看 `doc_count_error_upper_bound`。

## 7. 性能分析

```json
GET /<INDEX>/_search
{ "profile": true, "size": 0, "query": { ... } }   // 各查询/聚合阶段耗时，Kibana Search Profiler 可视化

GET /<INDEX>/_search
{ "explain": true, "query": { ... } }              // 每条命中的打分明细；单文档：GET /<INDEX>/_explain/<DOC_ID>
```

## 8. KQL（Kibana 查询栏）

```
service_name: ser*              # 通配符不能加引号；加引号 "ser*" 会按字面短语匹配
service_name.keyword: ser*      # keyword 上按整值前缀匹配；text 字段上匹配的是分词后的 token
status >= 500 and not method: GET
status: (500 or 502 or 503)
not field: *                    # 字段不存在
```
- 前导通配（`*ser`）是否允许由 Kibana 高级设置 `query:allowLeadingWildcards` 控制（默认开启），但开销大，尽量避免。

## 9. SQL（7.x+ 内置，适合简单查询）

```
POST /_sql?format=txt          # txt=类 CLI 表格；TSV 用 format=tsv，另有 csv/json/yaml
{ "query": "SELECT \"@timestamp\", status FROM \"<INDEX>\" WHERE \"@timestamp\" > NOW() - INTERVAL 3 DAY LIMIT 50" }

POST /_sql/translate           # SQL 转 DSL，用来学写法
{ "query": "..." }
```
- 索引名含 `-`、`*` 或字段含 `@` 要用双引号；Dev Tools 里可用 `"""..."""` 三引号包长 SQL。
- 比较时类型要一致：status 若是 keyword，要写 `status <> '200'`，与数字比较会报类型错误。

## 10. 深分页：滚动 / PIT / 异步查询

```
# scroll（导出全量；会占用资源，用完必须清理）
POST /<INDEX>/_search?scroll=1m
{ "size": 1000, "sort": ["_doc"], "query": { ... } }
POST /_search/scroll
{ "scroll": "1m", "scroll_id": "<SCROLL_ID>" }
DELETE /_search/scroll
{ "scroll_id": "<SCROLL_ID>" }

# 7.10+ 推荐 PIT + search_after 替代 scroll
POST /<INDEX>/_pit?keep_alive=1m
POST /_search
{ "size": 1000, "pit": { "id": "<PIT_ID>", "keep_alive": "1m" },
  "sort": [ { "@timestamp": "asc" }, { "_shard_doc": "asc" } ],
  "search_after": [ <上一页最后一条的 sort 值> ] }
DELETE /_pit
{ "id": "<PIT_ID>" }

# 异步查询（7.7+）：大范围聚合避免 HTTP 超时
POST /<INDEX>/_async_search?wait_for_completion_timeout=2s&keep_alive=10m
{ ... }
GET /_async_search/<ASYNC_ID>          # 取结果
GET /_async_search/status/<ASYNC_ID>   # 只看进度
DELETE /_async_search/<ASYNC_ID>       # 取消/清理
```

## 11. 导出数据（elasticdump）

```bash
$ES "<ES_HOST>/_cat/indices/*<KEYWORD>*?v"        # 先核对真实索引名（数据流的 backing index 以 .ds- 开头）
docker run --rm -ti -v "$(pwd)":/backup elasticdump/elasticsearch-dump \
  --input="http://${ES_USER}:${ES_PASS_URLENCODED}@<ES_HOST>/<INDEX>" \
  --output=/backup/<INDEX>.json \
  --type=data                                     # mapping 另外导：--type=mapping
```
- URL 中的密码特殊字符要 URL 编码（`@`→`%40`，`#`→`%23`）。
- 8.x 自签证书 HTTPS：加 `-e NODE_TLS_REJECT_UNAUTHORIZED=0` 或挂载 CA。
- 大索引导出慢，可调 `--limit`（每批条数），或改用快照（snapshot）。

## 12. 7.x 与 8.x 主要差异速记
- 8.x 默认开启安全、TLS；`_type` 彻底移除；`action.destructive_requires_name` 默认 true（不能通配删除）。
- 7.8+ 可组合模板 `_index_template`，旧版 `_template` 已废弃；数据流 7.9+；`_data_stream/_modify` 7.16+。
- rollover 条件 `max_primary_shard_size` 7.13+ 才有。
