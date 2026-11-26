---
name: container
description: Docker 主机侧常用运维片段（清理悬空镜像、容器 PID 定位、磁盘占用分析）及注意事项
metadata:
  type: reference
---

# 容器（Docker）速查

## 清理镜像 / 释放磁盘

```bash
docker system df -v                       # 先看谁占空间：镜像 / 容器可写层 / 卷 / build cache
docker image prune -f                     # 删悬空镜像（<none>:<none>），列表为空时也不报错
docker image prune -a --filter "until=168h"   # !! 删 7 天前且未被任何容器使用的镜像
docker builder prune --filter "until=168h"    # build cache 常是大头
```
- 原写法 `docker rmi $(docker images -f dangling=true -q)` 在没有悬空镜像时会报 "requires at least 1 argument"，用 `docker image prune` 替代。
- `docker system prune --volumes` 会删未挂载的卷，数据卷场景别用。
- 日志撑爆磁盘：看 `/var/lib/docker/containers/*/*-json.log`，在 daemon.json 配置 `log-opts.max-size/max-file`（只对新建容器生效）。

## 容器 ↔ 宿主机 PID

```bash
docker inspect -f '{{.State.Pid}} {{.Name}}' $(docker ps -q)       # 所有运行中容器的宿主机 PID
nsenter -t <PID> -n ss -lntp                                          # 进入容器网络命名空间用宿主机工具排查（容器内无工具时）
# 反查：宿主机上某个高负载进程属于哪个容器
cat /proc/<PID>/cgroup
```
K8s 节点（containerd）上对应工具是 `crictl ps` / `crictl inspect <ID> | jq .info.pid`。
