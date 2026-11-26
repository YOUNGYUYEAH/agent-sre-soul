---
name: kubernetes
description: kubectl 日常运维与排障速查（上下文/凭证、Deployment、ConfigMap/Secret、HPA/VPA、Node 调度、事件与日志、debug、namespace 卡 Terminating、krew 插件、测试用 YAML），已修正原片段中的错误参数
metadata:
  type: reference
---

# Kubernetes / kubectl 速查

占位符：`<NAMESPACE>` `<POD>` `<DEPLOY>` `<NODE>` `<CONTEXT>` `<KIND>` `<NAME>`。
标 `!!` 的是破坏性/不可逆操作，执行前先 `--dry-run=client|server` 或确认上下文（`kubectl config current-context`）。

## 1. 环境：补全、kubeconfig、多集群切换

```bash
# 补全（永久）
echo 'source <(kubectl completion bash)' >> ~/.bashrc && source ~/.bashrc

# 合并多份 kubeconfig（--flatten 把证书内联，生成的文件含凭据，注意权限 600）
KUBECONFIG=<CFG1>:<CFG2> kubectl config view --flatten > merged.yaml

kubectl config get-contexts
kubectl config current-context

# !! 彻底删除一个上下文需三步（context/user/cluster 是独立条目）
kubectl config delete-context <CONTEXT>
kubectl config unset users.<USER>
kubectl config unset clusters.<CLUSTER>        # 注意是 clusters，不是 clusterts

# kubie：每个 shell 独立上下文，避免多窗口误操作到错误集群
kubie ctx <CONTEXT>
kubie ns <NAMESPACE>
```

AKS 拉凭证见 `azure.md`（`az aks get-credentials`，`--admin` 绕过 Entra RBAC，集群禁用本地账户时不可用）。

## 2. Deployment 发布与回滚

```bash
kubectl rollout status  deploy/<DEPLOY> -n <NAMESPACE>
kubectl rollout history deploy/<DEPLOY> -n <NAMESPACE>
kubectl rollout undo    deploy/<DEPLOY> -n <NAMESPACE> [--to-revision=<N>]
kubectl rollout restart deploy/<DEPLOY> -n <NAMESPACE>     # 滚动重启（改 template 注解触发）
kubectl rollout pause|resume deploy/<DEPLOY> -n <NAMESPACE> # pause 期间改多处只触发一次滚动

kubectl scale deploy/<DEPLOY> --replicas=<N> -n <NAMESPACE> # 有 HPA 时会被 HPA 改回

# 看当前镜像 → 改镜像
kubectl get deploy/<DEPLOY> -n <NAMESPACE> -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\t"}{.image}{"\n"}{end}'
kubectl set image deploy/<DEPLOY> <CONTAINER>=<IMAGE>:<TAG> -n <NAMESPACE>
```

- GitOps（Argo CD 自动同步）管理的资源，手工 `undo/scale/set image` 会被 self-heal 改回，先停自动同步（见 `helm-argocd.md`）。

查看 label / 注解 / 资源配额：

```bash
kubectl get deploy -n <NAMESPACE> --show-labels
kubectl get deploy -n <NAMESPACE> -o json | jq '.items[] | {name:.metadata.name, annotations:.metadata.annotations}'
kubectl get deploy -n <NAMESPACE> -o custom-columns='NAME:.metadata.name,REQ_CPU:.spec.template.spec.containers[*].resources.requests.cpu,REQ_MEM:.spec.template.spec.containers[*].resources.requests.memory,LIM_CPU:.spec.template.spec.containers[*].resources.limits.cpu,LIM_MEM:.spec.template.spec.containers[*].resources.limits.memory'
```

## 3. ConfigMap / Secret

```bash
# 以原文格式读出 ConfigMap 每个 key（go-template 直接输出真实换行，一般不需要再 sed）
kubectl get cm <CM> -n <NAMESPACE> -o go-template='{{range $k,$v := .data}}{{printf "---\n# %s\n%s\n" $k $v}}{{end}}'

# 用文件生成/更新 ConfigMap（key 名为 data）。“create 管道 apply”是幂等更新的惯用法
kubectl create cm <CM> -n <NAMESPACE> --from-file=data=<FILE> --dry-run=client -o yaml            # 预览
kubectl create cm <CM> -n <NAMESPACE> --from-file=data=<FILE> --dry-run=client -o yaml | kubectl diff -f -   # 与线上对比
kubectl create cm <CM> -n <NAMESPACE> --from-file=data=<FILE> --dry-run=client -o yaml | kubectl apply -f -  # 更新
```

- ConfigMap 更新后：以 env 注入的不会生效，需 `rollout restart`；以 volume 挂载的有延迟（kubelet 同步周期），`subPath` 挂载的永远不更新。

```bash
kubectl get secret <SECRET> -n <NAMESPACE> -o json | jq -r '.data | keys[]'     # 只看 key，不打印值
# TLS 证书有效期 / 指纹（key 名里的点要转义）
kubectl get secret <SECRET> -n <NAMESPACE> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates -subject -fingerprint
```

## 4. HPA / VPA

```bash
kubectl describe hpa <HPA> -n <NAMESPACE>          # 看 Conditions/Events：ScalingLimited、FailedGetResourceMetric

# 临时冻结 HPA 扩容（v2 behavior）；先记录原 behavior 以便恢复
kubectl get hpa <HPA> -n <NAMESPACE> -o jsonpath='{.spec.behavior}'
kubectl patch hpa <HPA> -n <NAMESPACE> --type=merge -p '{"spec":{"behavior":{"scaleUp":{"selectPolicy":"Disabled"}}}}'
# 同时冻结扩缩容
kubectl patch hpa <HPA> -n <NAMESPACE> --type=merge -p '{"spec":{"behavior":{"scaleUp":{"selectPolicy":"Disabled"},"scaleDown":{"selectPolicy":"Disabled"}}}}'
```

VPA 推荐值：`kubectl get vpa` 的 MEM 列是带单位的 quantity（如 `262144k`），直接 `numfmt`/awk 做除法会算错。用 jsonpath 取 target 更可靠：

```bash
kubectl get vpa -n <NAMESPACE> -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.recommendation.containerRecommendations[*]}{.containerName}{" cpu="}{.target.cpu}{" mem="}{.target.memory}{"  "}{end}{"\n"}{end}'
```

## 5. Node：污点、封锁、排空

污点效果：`NoSchedule` 不调度新 Pod；`PreferNoSchedule` 尽量不调度；`NoExecute` 还会驱逐已有的、不容忍的 Pod（慎用）。

```bash
kubectl get nodes -o custom-columns=NODE:.metadata.name,TAINTS:.spec.taints
kubectl taint node <NODE> dedicated=special:NoSchedule [--overwrite]
kubectl taint node <NODE> dedicated=special:NoSchedule-     # 删指定 key+effect
kubectl taint node <NODE> dedicated-                        # 删该 key 的所有 effect
# !! 清空某节点全部污点（kubectl taint 没有“删全部”的语法；--all 是“作用于所有节点”）
kubectl patch node <NODE> --type=json -p '[{"op":"remove","path":"/spec/taints"}]'

kubectl cordon <NODE>; kubectl uncordon <NODE>

# drain 自带 cordon，无需先手动 cordon；排查完记得 uncordon
kubectl drain <NODE> --ignore-daemonsets --delete-emptydir-data --dry-run=server   # 先看会驱逐谁
kubectl drain <NODE> --ignore-daemonsets --delete-emptydir-data [--force] --timeout=10m
# --force 会删除无控制器的裸 Pod（不会重建）；PDB 阻塞时 drain 会一直重试，别急着加 --disable-eviction

kubectl get pod -A -o wide --field-selector spec.nodeName=<NODE>
```

查看工作负载的容忍：`kubectl get deploy/<DEPLOY> -n <NAMESPACE> -o jsonpath='{.spec.template.spec.tolerations}' | jq`

## 6. 排障：事件、Pod 状态、日志

```bash
kubectl get events -n <NAMESPACE> --sort-by=.lastTimestamp
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp
kubectl get events -n <NAMESPACE> --sort-by=.lastTimestamp -o custom-columns=TIME:.lastTimestamp,TYPE:.type,REASON:.reason,OBJ:.involvedObject.name,MSG:.message
# 新版本部分事件 lastTimestamp 为空（由 events.k8s.io 写入），排序异常时改用 .metadata.creationTimestamp 或 kubectl events
kubectl events -n <NAMESPACE> --for pod/<POD>

kubectl get po -A --field-selector status.phase!=Running        # 注意：Succeeded 的 Job Pod 也会列出；CrashLoopBackOff 的 Pod phase 仍是 Running，查不到
kubectl get po -A --field-selector metadata.namespace!=kube-system
kubectl get pod <POD> -n <NAMESPACE> -o jsonpath='{.status.conditions}' | jq
kubectl get pod <POD> -n <NAMESPACE> -o jsonpath='{.status.containerStatuses[*].lastState}' | jq   # OOMKilled / exitCode

kubectl logs <POD> -n <NAMESPACE> -p                       # 上一次崩溃容器的日志
kubectl logs -f --tail=100 <POD> -n <NAMESPACE> [-c <CONTAINER>] [--timestamps]
kubectl logs --since=1h <POD> -n <NAMESPACE>
kubectl logs --since-time=2026-01-01T10:00:00Z <POD> -n <NAMESPACE>
kubectl logs -l app=<APP> -n <NAMESPACE> --prefix --max-log-requests=10
```

### 保留故障现场
把故障 Pod 从 ReplicaSet 的 selector 里摘掉：控制器会补一个新 Pod，旧 Pod 留着慢慢查（记得最后手动删）。

```bash
kubectl get deploy/<DEPLOY> -n <NAMESPACE> -o jsonpath='{.spec.selector.matchLabels}'
kubectl label po/<POD> -n <NAMESPACE> <SELECTOR_KEY>- debug=keep
```
注意摘掉的是 selector 里的 label；摘掉后 Service 也不再把流量打给它。

### kubectl debug
`--profile`：`legacy`（1.35 客户端默认仍是它）/ `general` / `baseline` / `restricted` / `netadmin` / `sysadmin`。

```bash
kubectl debug -it <POD> -n <NAMESPACE> --image=busybox --profile=general --target=<CONTAINER>    # --target 共享目标容器进程命名空间
kubectl debug -it <POD> -n <NAMESPACE> --image=nicolaka/netshoot --profile=netadmin
kubectl debug <POD> -n <NAMESPACE> -it --copy-to=<POD>-dbg --share-processes --image=busybox     # 复制一份 Pod 调试，不动原 Pod

# 节点调试：宿主机根目录挂在 /host
kubectl debug -it node/<NODE> --image=busybox --profile=sysadmin
#   chroot /host ; 容器日志 /var/log/containers、/var/log/pods
# 后台常驻、之后 exec 进入（kubectl 的 flag 必须写在 -- 之前，-- 之后全是容器命令参数）
kubectl debug node/<NODE> --image=busybox --profile=sysadmin -- sleep infinity
# 用完删除 node-debugger-* Pod
```
镜像拉不下来时换内网/镜像加速仓库前缀。

## 7. 删除卡住：强删 Pod、Finalizer、Namespace Terminating

```bash
# !! 强删：只删 API 对象，不保证容器已停（节点失联时可能出现双写，StatefulSet 慎用）
kubectl delete pod/<POD> -n <NAMESPACE> --force --grace-period=0

# !! 清 finalizer：跳过控制器的清理逻辑，可能遗留云资源（LB、磁盘等），先搞清楚是谁加的
kubectl patch <KIND> <NAME> -n <NAMESPACE> --type=merge -p '{"metadata":{"finalizers":null}}'
```

Namespace 卡 Terminating 思路：先找残留资源和原因，最后才强制 finalize。

```bash
kubectl get ns <NAMESPACE> -o jsonpath='{.status.conditions}' | jq     # 常见：某个 APIService 不可用、CR 的 finalizer 没人处理
kubectl get apiservice | grep False
kubectl api-resources --verbs=list --namespaced -o name | xargs -n1 -I{} sh -c 'kubectl get {} -n <NAMESPACE> --ignore-not-found --no-headers 2>/dev/null | sed "s|^|{} |"'

# !! 最后手段：清空 spec.finalizers 后调用 finalize 子资源（无需 kubectl proxy）
kubectl get ns <NAMESPACE> -o json | jq '.spec.finalizers=[]' > ns.json
kubectl replace --raw "/api/v1/namespaces/<NAMESPACE>/finalize" -f ns.json
```

## 8. kubectl cp 与大文件

```bash
kubectl cp -n <NAMESPACE> <POD>:<SRC_PATH> ./<FILE> [-c <CONTAINER>] --retries=-1   # 负数 = 无限重试
kubectl cp ./<FILE> -n <NAMESPACE> <POD>:<DST_PATH>
```
- 依赖容器内有 `tar`；distroless 镜像不行（用 `kubectl debug` 带工具镜像）。
- 大文件超时：在容器内先切块再逐块拷，本地合并后校验。
```bash
kubectl exec -n <NAMESPACE> <POD> -- sh -c 'cd /tmp && split -b 100M <FILE> chunk_ && sha256sum <FILE>'
cat chunk_* > <FILE> && sha256sum <FILE>
```

## 9. krew 插件

安装 krew（官方步骤，需完整解压并执行 install）：
```bash
cd "$(mktemp -d)" && OS=linux ARCH=amd64 KREW=krew-${OS}_${ARCH} \
  && curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" \
  && tar zxf "${KREW}.tar.gz" && ./"${KREW}" install krew
echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> ~/.bashrc   # PATH 必须持久化
kubectl krew search <KEYWORD>
kubectl krew install <PLUGIN>      # 不是 krew add；krew index add 是添加第三方插件索引
kubectl krew list / upgrade
```

常用插件（名称以 `kubectl krew search` 为准）：

| 插件 | 用途 | 用法 |
|---|---|---|
| tree | 看 owner 链（Deploy→RS→Pod） | `kubectl tree deploy/<DEPLOY> -n <NAMESPACE>` |
| ctr | 列 Pod 内容器 | `kubectl ctr <POD>` |
| rltop | 节点/Pod 的 用量/Req/Limit 同屏 | `kubectl rltop nodes`、`kubectl rltop pod -n <NAMESPACE>` |
| node-resource | 节点分配率/利用率 | `kubectl node-resource allocation`、`... utilization` |
| history | 工作负载历史版本 diff | `kubectl history list/diff <KIND> <NAME> -n <NAMESPACE>` |
| images | 列出 Pod 镜像 | `kubectl images -n <NAMESPACE>` |
| ttsum | 污点汇总 | `kubectl ttsum taints` |
| wild | 资源名正则匹配批量操作 | `kubectl wild get po '<REGEX>' -n <NAMESPACE>`（正则加引号防 shell 展开；批量删除先 `--dry-run`） |
| triage | 汇总异常 Pod 原因 | 见下 |
| tail（stern 类） | 多 Pod 聚合日志 | `kubectl tail --regex <KEYWORD> -n <NAMESPACE>`、`--deploy <NAME>` |
| popeye | 集群配置体检打分 | `kubectl popeye -A` |
| iexec | 交互式选 Pod exec | `kubectl iexec -n <NAMESPACE>` |
| sniff | Pod 抓包（tcpdump→wireshark） | `kubectl sniff <POD> -n <NAMESPACE> [-o out.pcap]`（非特权容器需 `-p`） |
| rbac-tool | RBAC 查询/可视化 | `kubectl rbac-tool lookup`、`... visualize` |
| radar | 集群可视化 | 本地 Web 端口访问 |
| retina | AKS 网络观测/抓包 | 见下 |

triage 批量（`-A` 输出第一列是 namespace，第二列才是 Pod 名）：
```bash
kubectl get po -A --field-selector status.phase!=Running --no-headers | awk '{print $1, $2}' | xargs -n2 sh -c 'kubectl triage -n "$0" "$1"'
```

Retina 抓包（AKS）：
```bash
kubectl retina capture create --name <CAP> --namespace <NAMESPACE> --duration=2m --node-names <NODE>
kubectl retina capture list -n <NAMESPACE>
kubectl retina capture download --name <CAP> -n <NAMESPACE>
kubectl retina capture delete --name <CAP> -n <NAMESPACE>
```
Retina 的 bpftrace/丢包原因统计子命令依版本而定，先 `kubectl retina --help` 确认；思路是抓 `kfree_skb` 事件按 reason 计数：`... | grep kfree_skb | awk '{print $3}' | sort | uniq -c | sort -nr`。

## 10. 测试用 YAML

网络诊断 Pod（netshoot 工具全）：
```yaml
apiVersion: v1
kind: Pod
metadata: {name: net-debug, namespace: <NAMESPACE>}
spec:
  restartPolicy: Never
  containers:
  - name: net-debug
    image: nicolaka/netshoot:latest
    command: ["sleep", "infinity"]
```
快速临时 Pod：
```bash
kubectl run tmp-shell --rm -it --image=nicolaka/netshoot -n <NAMESPACE> --restart=Never -- bash   # 退出即删
kubectl run test-pod --image=ubuntu -n <NAMESPACE> --restart=Never -- sleep infinity
#   apt update && apt install -y iputils-ping dnsutils curl wget jq netcat-openbsd traceroute telnet redis-tools default-mysql-client postgresql-client kcat
```

CPU/内存压测 Deployment（`requests` 必须 ≤ `limits`；CPU 写 `"1"` 或 `1000m`，写裸数字 `1000` 表示 1000 核）：
```yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: stress, namespace: <NAMESPACE>}
spec:
  replicas: 1
  selector: {matchLabels: {app: stress}}
  template:
    metadata: {labels: {app: stress}}
    spec:
      containers:
      - name: stress
        image: polinux/stress-ng:latest      # 镜像 ENTRYPOINT 即 stress-ng
        args: ["--cpu", "1", "--vm", "1", "--vm-bytes", "256M"]
        resources:
          requests: {cpu: "1", memory: 512Mi}
          limits:   {cpu: "1", memory: 512Mi}
```
用途：验证 HPA 触发、节点扩容、CPU throttling（看 `container_cpu_cfs_throttled_periods_total`）。
