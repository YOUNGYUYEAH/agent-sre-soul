---
name: helm-argocd
description: Helm / helmfile 发布全流程（渲染、diff、安装升级回滚、资源保留）与 Argo CD（登录、应用同步回滚、本地账号与 RBAC、仓库集群、Argo Rollouts）速查，已修正原片段错误参数
metadata:
  type: reference
---

# Helm / helmfile / Argo CD 速查

占位符：`<RELEASE>` `<NAMESPACE>` `<CHART>` `<APP>` `<PROJ>` `<ENDPOINT>` `<USER>`。
本地验证版本：helm v3.19、argocd v3.3、helmfile v1.4。Helm 4 中 `--atomic` 更名为 `--rollback-on-failure`，升级 Helm 后注意。

## 1. Helm：写 chart / 发布前检查

```bash
helm lint <CHART> -f values.yaml
# 只渲染某一个模板，排查 values 是否生效
helm template <RELEASE> <CHART> -n <NAMESPACE> -f values.yaml --show-only templates/<FILE>.yaml --debug
# 与线上 release 对比（需 helm-diff 插件；helmfile 也依赖它）
helm diff upgrade <RELEASE> <CHART> -n <NAMESPACE> -f values.yaml
```
- 多个 `-f` 后者覆盖前者；`--set` 优先级最高。

## 2. Helm：安装 / 升级 / 回滚 / 卸载

```bash
helm list -A --all            # --all 才显示 pending-install/pending-upgrade/failed 等状态

helm upgrade --install <RELEASE> <CHART> -n <NAMESPACE> -f values.yaml \
  --create-namespace --atomic --cleanup-on-fail --timeout 10m [--dry-run=server]
```
- `--atomic`：失败自动回滚（install 失败则卸载），隐含 `--wait`。
- `--cleanup-on-fail`：只有 upgrade/rollback 有，删除本次失败新建的资源；`helm install` 没有这个参数。
- `--wait` 只等 Pod/PVC/Service 等就绪，不等 Job（需要 `--wait-for-jobs`）。
- `--dry-run` 不带值等于 `client`，不连集群；`--dry-run=server` 会做 lookup 等服务端校验。输出含 Secret 明文，可加 `--hide-secret`。

```bash
helm history <RELEASE> -n <NAMESPACE>
helm rollback <RELEASE> <REVISION> -n <NAMESPACE> [--cleanup-on-fail] [--no-hooks] [--dry-run]
helm uninstall <RELEASE> -n <NAMESPACE> [--keep-history]

helm get values   <RELEASE> -n <NAMESPACE> [--all] [--revision <N>]   # 不加 --all 只显示用户传入的值
helm get manifest <RELEASE> -n <NAMESPACE>
helm status <RELEASE> -n <NAMESPACE> --show-resources
```

排障：release 卡在 `pending-upgrade` / `pending-install`（上次被中断）时新的 upgrade 会报 "another operation is in progress"：先 `helm history` 看最近成功版本，`helm rollback` 到它；不行再检查 `sh.helm.release.v1.<RELEASE>.v<N>` Secret 的 status 标签。

### 卸载/升级时保留某个资源
```bash
kubectl annotate <KIND> <NAME> -n <NAMESPACE> helm.sh/resource-policy=keep --overwrite
kubectl annotate <KIND> <NAME> -n <NAMESPACE> helm.sh/resource-policy-      # 取消
```
常用于 PVC、CRD、外部依赖的 Secret；保留下来的资源再次 install 会报“已存在且不属于该 release”，需要补 `meta.helm.sh/release-name/namespace` 注解和 `app.kubernetes.io/managed-by=Helm` 标签来“收编”。

## 3. Helm 插件

```bash
helm plugin list
helm plugin install <GIT_URL|LOCAL_PATH>     # 本地路径可离线安装
```
| 插件（GitHub 仓库） | 用途 |
|---|---|
| databus23/helm-diff | upgrade 前差异对比，helmfile 必需 |
| komodorio/helm-dashboard | Web UI 看 release |
| d2iq-labs/helm-list-images | 列出 chart 用到的镜像（离线同步镜像时有用） |
| JovianX/helm-release-plugin | 从已部署 release 反向导出 chart |
| ThalesGroup/helm-spray | 子 chart 分批按权重部署 |

## 4. helmfile

```bash
helmfile -e <ENV> diff                     # 先看差异
helmfile -e <ENV> apply                    # 只对有差异的 release 执行 upgrade
helmfile -e <ENV> -f <DIR_OR_FILE> apply   # 指定状态文件/目录用 -f，不用位置参数
helmfile -e <ENV> -l name=<RELEASE> apply  # 只操作某个 release
```

## 5. Argo CD：登录与上下文

```bash
# 经 Ingress 暴露时常需 gRPC-Web；做成 alias 免每次加参数
echo "alias argocd='argocd --grpc-web'" >> ~/.bashrc

argocd context                       # 列出/切换
argocd context --delete <CONTEXT>
argocd login <ENDPOINT> --username admin --sso | --password <PWD> [--insecure]
# 初始 admin 密码（仅未改过密码的新实例；改密后应删除该 Secret）
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

## 6. Argo CD：应用管理

```bash
argocd app list
argocd app get <APP> [--refresh | --hard-refresh]   # hard-refresh 连 manifest 缓存一起刷新
argocd app diff <APP>
argocd app resources <APP> [--orphaned]             # 查孤儿资源
argocd app logs <APP> [--kind Deployment --name <NAME>]

argocd app sync <APP> --dry-run
argocd app sync <APP> [--prune] [--resource <GROUP>:<KIND>:<NAME>]   # --prune 删除 git 中已不存在的资源
argocd app wait <APP> --health --sync --timeout 300
argocd app terminate-op <APP>                        # 终止卡住的同步
argocd app actions list <APP>                        # DISABLED=true 表示不可用
argocd app actions run <APP> restart --kind Deployment --resource-name <NAME>
```

回滚（自动同步开启时 `rollback` 会被拒绝/被立即覆盖，必须先关）：
```bash
argocd app history <APP>
argocd app set <APP> --sync-policy none            # none 是 manual 的别名
argocd app rollback <APP> <HISTORY_ID>
# 修复 git 后恢复自动同步
argocd app set <APP> --sync-policy automated --auto-prune --self-heal
```

```bash
# !! 删除 Application 但保留集群里的资源
argocd app delete <APP> --cascade=false
```
注意：如果 Application 上有 `resources-finalizer.argocd.argoproj.io` finalizer，直接 `kubectl delete application` 会级联删资源。

## 7. Argo CD：项目、仓库、集群

```bash
argocd proj list | create <PROJ> | delete <PROJ>

argocd repo add <GIT_URL> --username <USER> --password <TOKEN> [--insecure-skip-server-verification]
argocd repo list

# 位置参数是 kubeconfig 里的 context 名
argocd cluster add <KUBE_CONTEXT> [--kubeconfig <PATH>] [--name <DISPLAY_NAME>]
argocd cluster set in-cluster --name <DISPLAY_NAME>     # 给内置集群改显示名
```

## 8. Argo CD：本地账号与 RBAC

1) 在 `argocd-cm` 中声明账号：
```bash
kubectl -n argocd patch cm argocd-cm --type merge -p '{"data":{"accounts.<USER>":"apiKey, login"}}'
```
2) 在 `argocd-rbac-cm` 的 `policy.csv` 绑定角色：`g, <USER>, role:developer`
3) 设置密码（`--current-password` 是**当前登录者**即 admin 的密码）：
```bash
argocd account update-password --account <USER> --current-password <ADMIN_PWD> --new-password <NEW_PWD>
```
4) 校验：
```bash
argocd admin settings rbac validate --namespace argocd          # 或 --policy-file policy.csv
argocd admin settings rbac can <ROLE_OR_USER> sync applications '<PROJ>/<APP>' --namespace argocd   # 离线验证，不用切账号
argocd account can-i sync applications '*'                      # 以当前登录账号验证
argocd account list
```

policy.csv 示例（object 写 `<project>/<app>`，`*` 或 `*/*` 表示全部）：
```csv
p, role:readonly,  applications, get, */*, allow
p, role:readonly,  logs,         get, */*, allow
p, role:readonly,  projects,     get, *,   allow

p, role:developer, applications, get,  */*, allow
p, role:developer, applications, sync, */*, allow
p, role:developer, applications, action/apps/Deployment/restart, */*, allow
p, role:developer, logs,         get,    */*, allow
p, role:developer, exec,         create, */*, allow
p, role:developer, projects,     get,    *,   allow

p, role:operator,  applications, get,      */*, allow
p, role:operator,  applications, create,   */*, allow
p, role:operator,  applications, update,   */*, allow
p, role:operator,  applications, sync,     */*, allow
p, role:operator,  applications, override, */*, allow
p, role:operator,  applications, action/*, */*, allow
p, role:operator,  logs,         get,      */*, allow
p, role:operator,  exec,         create,   */*, allow
p, role:operator,  projects,     get,      *,   allow
p, role:operator,  clusters,     get,      *,   allow
p, role:operator,  repositories, get,      *,   allow

p, role:project-manager, applications, *, */*, allow
p, role:project-manager, logs, get, */*, allow
p, role:project-manager, exec, create, */*, allow
p, role:project-manager, projects, get, *, allow
p, role:project-manager, clusters, get, *, allow
p, role:project-manager, repositories, get, *, allow
```
- 资源 action 的权限名格式是 `action/<group>/<kind>/<action>`，如重启 Deployment 是 `action/apps/Deployment/restart`。
- `exec, create` 还需要在 `argocd-cm` 打开 `exec.enabled: "true"`。
- 可用动作：get create update delete sync override action invoke；资源：clusters projects applications applicationsets repositories write-repositories certificates accounts gpgkeys logs exec extensions。

## 9. Argo Rollouts（需 kubectl-argo-rollouts 插件）

```bash
kubectl argo-rollouts list rollouts -A
kubectl argo-rollouts get rollout <ROLLOUT> -n <NAMESPACE> --watch
kubectl argo-rollouts status <ROLLOUT> -n <NAMESPACE>
kubectl argo-rollouts promote <ROLLOUT> -n <NAMESPACE> [--full]   # 蓝绿切换 / 金丝雀进入下一步（--full 跳过剩余步骤）
kubectl argo-rollouts abort <ROLLOUT> -n <NAMESPACE>              # 中止，流量回稳定版
kubectl argo-rollouts undo <ROLLOUT> -n <NAMESPACE> --to-revision=<N>
```
- 由 Argo CD 管理的 Rollout，undo 前先关闭应用自动同步，否则会被 git 状态覆盖。
