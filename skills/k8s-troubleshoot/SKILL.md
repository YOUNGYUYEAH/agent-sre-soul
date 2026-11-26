---
name: k8s-troubleshoot
description: Kubernetes 排障（兵分两路：止血 + 根因）。用户报告 Pod 崩溃/重启、Pending、CrashLoopBackOff、OOMKilled、ImagePullBackOff、Service 不通、DNS 失败、502/503、PVC 不绑定、RBAC 403、节点 NotReady、HPA 不扩容，或说“看下集群状态”“服务起不来”“容器一直重启”时使用；即使没明说 Kubernetes 也应主动使用。
---

# Kubernetes 排障

默认**只读**。任何会改变集群状态的动作（delete、rollout restart、scale、edit、cordon/drain、patch）先给出命令和影响，等用户确认后再执行。

## 0. 确认目标（不要猜）

```bash
kubectl config current-context
kubectl version --client          # 1.28+ 已移除 --short
kubectl cluster-info --request-timeout=5s | head -2
```

- 上下文、命名空间、服务名以用户给的为准；没给就先列出来让用户确认，**不要默认切到生产**。
- 多集群时每条命令显式带 `--context <CTX> -n <NS>`，避免切错集群。
- 凭据过期、连不上 API Server：先报告并询问，不要绕过。

## 1. 兵分两路

| 线 1：止血 | 线 2：根因 |
|---|---|
| 影响面多大？最快的恢复手段是什么（回滚、扩副本、重启、切流、临时调资源）？给一套方案等用户拍板 | 事件时间线 → 对照组（同服务正常 Pod / 正常节点）→ 证据 → 结论分「已证实 / 推断」 |

**止血前先保留现场**（重启/删 Pod 会丢证据）：

```bash
kubectl describe pod <POD> -n <NS> > /tmp/<POD>-describe.txt
kubectl logs <POD> -n <NS> --all-containers --previous --tail=500 > /tmp/<POD>-prev.log 2>&1
kubectl get events -n <NS> --sort-by=.metadata.creationTimestamp > /tmp/<NS>-events.txt
```

## 2. 第一轮巡检（先事件，后日志）

```bash
# 事件解释“K8s 为什么这么做”，最先看。lastTimestamp 在新版本常为空，用 creationTimestamp 排序
kubectl get events -n <NS> --sort-by=.metadata.creationTimestamp | tail -30
kubectl get events -A --field-selector type=Warning --sort-by=.metadata.creationTimestamp | tail -30

kubectl get pods -n <NS> -o wide
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
kubectl get nodes -o wide
```

服务级状态（按需）：

```bash
kubectl get deploy,sts,ds,hpa -n <NS>
kubectl top pods -n <NS> --sort-by=memory
kubectl top nodes
kubectl describe nodes | grep -A8 "Allocated resources"      # 调度视角：requests/limits 占比
kubectl describe nodes | grep -E "MemoryPressure|DiskPressure|PIDPressure" | grep -v False
```

高重启 Pod（遍历所有容器，不只第一个）：

```bash
kubectl get pods -n <NS> -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.restartCount}{" "}{end}{"\n"}{end}' | awk '{s=0; for(i=2;i<=NF;i++) s+=$i; if(s>3) print}'
```

多个症状同时出现时，从**事件时间线上最早的那个**开始查，后面的往往是连锁反应。

## 3. 按症状深入

| 症状 | 先看什么 | 常见根因 |
|---|---|---|
| Pending | `describe pod` 的 Events：`Insufficient cpu/memory`、`didn't match node affinity/selector`、`untolerated taint`、`unbound PVC` | requests 过大、节点池满、亲和/污点不匹配、PVC 未绑定、配额 ResourceQuota |
| ContainerCreating 卡住 | Events 里的 CNI / 挂载错误 | IP 耗尽（子网/Pod CIDR）、CNI 异常、Secret/ConfigMap 不存在、卷 attach 失败 |
| CrashLoopBackOff | `logs --previous`、`describe` 的 Last State 与 Exit Code | 1=应用错误；137=OOMKill 或被 kill；139=段错误；143=SIGTERM；配置/依赖缺失；探针过严 |
| OOMKilled | `describe` 的 `Reason: OOMKilled`、`top pod`、limit 值 | limit 过小、JVM 堆未按容器内存设置、内存泄漏 |
| ImagePullBackOff | Events 里的 pull 报错 | tag 不存在、仓库鉴权（imagePullSecret / 托管身份）、网络到仓库不通 |
| Running 但不 Ready | `describe` 的 Readiness 探针结果 | 探针路径/端口错、启动慢没配 startupProbe、依赖未就绪 |
| Service 不通 | `get endpoints/endpointslices <SVC>` 是否为空 | selector 与 Pod 标签不匹配、targetPort 错、Pod 未 Ready、NetworkPolicy 拦截 |
| DNS 失败 | 在 debug Pod 里 `nslookup <svc>.<ns>.svc.cluster.local`；CoreDNS 日志 | CoreDNS 异常/限流、ndots 导致的多次查询、上游 DNS 不通 |
| 502/503/504 | Ingress/网关日志、后端 endpoints、超时配置 | 后端无 Ready 实例、滚动发布无 preStop/优雅下线、超时不匹配 |
| PVC Pending | `describe pvc`、StorageClass、provisioner 日志 | StorageClass 不存在、可用区不匹配、配额 |
| 403 / Forbidden | `kubectl auth can-i <verb> <res> --as=system:serviceaccount:<NS>:<SA>` | RBAC 缺权限、PodSecurity 拦截 |
| 节点 NotReady | `describe node` 的 Conditions、kubelet 日志、`kubectl debug node/<N>` | kubelet/容器运行时异常、磁盘/PID 压力、网络分区 |
| HPA 不扩容 | `describe hpa`、`kubectl top`、metrics-server | 指标 `<unknown>`、未设 requests、已到 maxReplicas |

工具：

```bash
kubectl debug -it <POD> -n <NS> --image=busybox --target=<CONTAINER>    # 精简镜像里调试，不改原 Pod
kubectl debug node/<NODE> -it --image=busybox --profile=sysadmin        # flag 必须写在 -- 之前
kubectl auth can-i --list --as=system:serviceaccount:<NS>:<SA>
```

## 4. 结论与汇报

- 根因必须有具体证据支撑（某条事件、某行日志、某个命令输出），否则标为「推断」并写明还缺什么证据。
- 汇报结构：**止血进展**（做了什么、业务是否恢复）→ **根因进展**（已证实 / 推断 / 待核实）→ **根治方案**（前置条件、禁忌）→ **防复发**（补什么告警或巡检）。
- 状态写清：已恢复 / 已恢复未根治 / 已根治。
- 修复后复查：`kubectl get pods -n <NS> -w` 观察状态，再看一遍事件，确认没有新的失败。
