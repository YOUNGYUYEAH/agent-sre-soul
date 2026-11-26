---
name: log-error-triage
description: 日志错误巡检（Elasticsearch/EFK）。按错误签名聚类，与基线窗口对比标出 NEW / SPIKING / STEADY，再结合代码判断是真 bug 还是已知噪音。用户说“看下日志有没有异常”“查一下 ES 里的报错”“发版后有没有新错误”“日志健康巡检”时使用；可配合定时任务做每日巡检。
---

# 日志错误巡检

这是“有没有什么在酝酿”的探索型工具，**补充**而不是替代 OOM、CrashLoop 这类硬阈值告警。价值在判断：哪些错误是新的、在飙升、还是稳定噪音；对应真 bug 还是已处理的降级。

## 参数（都可选，没给就问，不要默认生产）

- 目标环境 / 集群
- 服务（容器名），默认全部
- 分析窗口，默认 `3h`；基线默认为窗口开始前的 **7 天**

## 0. 连接方式

优先在已有采集组件（如 Filebeat）的 Pod 内执行 `curl`，复用 Pod 里的 ES 凭据环境变量：不需要 VPN，不需要在本机处理密码。

```bash
FB=$(kubectl get pods -n <NS> -o name | grep filebeat | head -1 | cut -d/ -f2)
esq() {  # 用法：esq <path> '<json>'
  kubectl exec -n <NS> "$FB" -- sh -c \
    "curl -s -u \"\$ELASTICSEARCH_USERNAME:\$ELASTICSEARCH_PASSWORD\" \
     \"http://\$ELASTICSEARCH_HOST:\$ELASTICSEARCH_PORT/$1\" \
     -H 'Content-Type: application/json' -d '$2'"
}
esq "_cluster/health?pretty" ""     # 先确认可达
```

环境变量名以实际 Pod 为准（先 `kubectl exec ... env | grep -i elastic | cut -d= -f1` 只看变量名）。

## 1. 摸清数据形态（第一次接触某集群时）

- 索引命名：日索引 `filebeat-<svc>-YYYY.MM.dd` 和数据流 `.ds-filebeat-<svc>-*` 可能并存，**两种模式都要查**。
- 错误字段：确认是 `log.level`、`level` 还是只能匹配 message；采集端是否有打标规则。
- 服务字段：聚合要用 `.keyword` 子字段（text 字段聚合会报 `illegal_argument_exception`），过滤用 match 即可。
- 某服务自己的索引为空时，检查它是否落进了 default 索引（采集路由没配上）。

## 2. 按服务统计错误量（窗口 vs 基线）

```bash
esq "filebeat-*,.ds-filebeat-*/_search" '{"size":0,"query":{"bool":{"filter":[{"range":{"@timestamp":{"gte":"now-3h"}}},{"match":{"log.level":"error"}}]}},"aggs":{"by_svc":{"terms":{"field":"kubernetes.container.name.keyword","size":30}}}}'
```

同一查询对基线窗口再跑一次，换算成每小时速率后对比。注意 `hits.total.value` 默认封顶 10000，**以聚合的 doc_count 为准**。

## 3. 按错误签名聚类

对错误量明显的服务，取有限样本（如 `size: 200`，按时间倒序，只取 message、服务名、时间戳）。签名 = 异常类名 + 第一行有意义的消息/堆栈；把 ID、序列号、时间戳、十六进制、IP 等易变部分归一化后再分组计数。

## 4. 与基线对比分类

- **NEW**：基线中不存在或可忽略 → 最高优先级。
- **SPIKING**：基线中有，但窗口速率远高于基线（如 > 3 倍小时均值）。
- **STEADY**：与基线持平 → 大概率是已知噪音。

可对签名中稳定的部分做 `match_phrase` 回查基线窗口。

## 5. 结合代码判断（有代码仓库时）

对 NEW / SPIKING（以及量最大的 STEADY）签名，用 Grep 找到抛出位置并判断：

- **真 bug**：未处理或回归；给出 `file:line` 和疑似原因。
- **已知噪音 / 已处理降级**：catch 后记录并恢复、上游 4xx 已有降级 → 写明理由后忽略。
- **基础设施 / 瞬时问题**：连接重置、选主、再均衡。

服务多时，每个高错误量服务交给一个子代理并行聚类，只回传结论，避免大量样本塞满上下文。

## 6. 报告

```
## 日志错误巡检 — <环境> · <服务> · 最近 <窗口>（基线 7 天）
窗口错误数：N | 签名数：M

### 🔴 新增 / 飙升（需处理）
- [NEW] <签名> — <服务>，窗口 <n> 次（基线 0）
  - 样例：<一行消息/堆栈头>
  - 疑点：<file:line> — <一句话判断>

### 🟡 持续偏高（观察）
- <签名> — <服务>，<n> 次（≈基线）— 为什么大概率没问题 / 什么情况下需要关注

### ⚪ 已忽略噪音（附理由）
- <签名> × <n> — <理由>

### 覆盖说明
- 已巡检的服务；落在 default 索引的服务；采样封顶、索引缺失等情况必须写明，不能让截断看起来像“一切正常”。
```

## 护栏

- **只读**：只用 `_search`、`_query`、`_cat`、`_cluster/health`；不写、不删、不改索引。
- **不打印密码**：凭据只在 Pod 内通过环境变量引用，不 echo，不出现在宿主机命令行。
- **每个查询都要有边界**：必须带时间范围和 size / 聚合上限；大索引上的无界查询可能拖垮单节点集群。
- **不随手建议加告警**：结论是“经过判断的日志信号”。只有故障天然无声、且运维没有其他信号时才建议补告警。
- **如实说明覆盖范围**。
