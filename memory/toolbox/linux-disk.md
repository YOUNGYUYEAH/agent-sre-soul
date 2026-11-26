---
name: linux-disk
description: Linux 磁盘排障与变更命令：IO 性能定位、新盘识别、LVM 扩容/新建、磁盘空间清理（含 Docker）
metadata:
  type: reference
---

# Linux 磁盘

## 1. IO 慢 / 磁盘繁忙

**目的：确认是哪块盘、多忙、延迟多少**
```bash
iostat -dxm 1            # 看 %util、r_await/w_await、aqu-sz；%util 对 SSD/NVMe 参考意义有限，以 await 为准
```

**目的：定位哪个进程 / 哪个线程在打 IO**
```bash
# iotop 的 -p 实际按 TID 过滤，只给 PID 只能看到主线程；把所有线程 TID 展开传入
# 第一轮采样没有差值（全是 0），批处理至少取 2 轮
iotop -b -o -n 2 -d 1 $(printf ' -p %s' $(ls /proc/<PID>/task/))

# 等价且更省事：sysstat 的 pidstat
pidstat -d -t -p <PID> 1
```
- 更深入（每个 IO 的延迟分布、慢 IO 明细）见 `linux-performance.md` 的 bcc-tools 部分（biolatency / biosnoop / biotop）。

## 2. 新加盘 / 扩容盘后系统识别不到

```bash
# 新加盘：重扫所有 SCSI host
for h in /sys/class/scsi_host/host*/scan; do echo "- - -" > "$h"; done

# 已有盘在云/虚拟化平台上扩大了容量：重扫该设备
echo 1 > /sys/class/block/<DEV>/device/rescan
lsblk
```

## 3. LVM 扩容（加新盘方式，按顺序执行）

```bash
lsblk; fdisk -l; blkid                  # 1. 找到新盘 <DEV>（如 sdb/vdb），确认无数据、无分区
pvcreate /dev/<DEV>                     # 2. 建 PV
vgs                                     # 3. 找到目标 <VG>
vgextend <VG> /dev/<DEV>                # 4. VG 纳入新 PV
lvs -a -o +lv_layout,data_percent,metadata_percent   # 5. 看清 LV 是普通(厚)卷还是 thin 卷
```

**6. 扩 LV**
```bash
# 6-1 普通(厚置备) LV：-r 同时扩文件系统，省掉第 7 步（推荐）
lvextend -r -l +100%FREE /dev/<VG>/<LV>

# 6-2 精简置备(thin)：池和 thin LV 是两回事
lvextend -l +100%FREE /dev/<VG>/<POOL>   # 只增加池的物理容量，thin LV 的大小不变
lvextend -r -L +<SIZE> /dev/<VG>/<LV>    # 要让文件系统变大，必须再扩 thin LV 的虚拟大小（thin LV 不能用 %FREE）
# 关注池 metadata 使用率，满了会导致池只读：必要时 lvextend --poolmetadatasize +<SIZE> <VG>/<POOL>
```

**7. 扩文件系统（未用 -r 时）**
```bash
df -Th                                   # 先确认文件系统类型和挂载点
xfs_growfs <MOUNTPOINT>                  # xfs：参数是挂载点（必须已挂载）；xfs 只能扩不能缩
resize2fs /dev/<VG>/<LV>                 # ext4：参数是设备，支持在线扩
```

**经验**
- 云盘「原盘扩大」而非加新盘：rescan → `growpart /dev/<DEV> <分区号>`（若 PV 在分区上）→ `pvresize /dev/<DEV或分区>` → lvextend → 扩 FS。
- 扩容前确认 `vgs` 的 VFree 真的增加了，再动 LV。

## 4. LVM 新建并挂载

```bash
pvcreate /dev/<DEV>
vgcreate <VG> /dev/<DEV>
lvcreate -l 100%FREE -n <LV> <VG>        # 新建用 100%FREE（不带 +），最后一个参数是 VG

mkfs.xfs  /dev/<VG>/<LV>                 # 或 mkfs.ext4 /dev/<VG>/<LV>（二选一）
mkdir -p <MOUNTPOINT>
mount /dev/<VG>/<LV> <MOUNTPOINT>

# 持久化：写入 /etc/fstab（建议用 UUID），并用 mount -a 验证，避免重启进不了系统
blkid /dev/<VG>/<LV>
echo 'UUID=<UUID> <MOUNTPOINT> xfs defaults 0 0' >> /etc/fstab
mount -a && findmnt <MOUNTPOINT>
```

## 5. 磁盘满 / 空间清理

**定位占用**
```bash
du -xs /* 2>/dev/null | sort -nr | head -5 | numfmt --field 1 --from-unit=1024 --to=si | column -t   # -x 不跨文件系统，自动跳过 /proc 等
find / -xdev -type f -size +100M -exec ls -lh {} + 2>/dev/null | sort -rh -k5                          # 全盘扫描耗时长
```

**df 满但 du 对不上 → 已删除但仍被进程占用的文件**
```bash
lsof +L1 2>/dev/null | sort -k7 -nr | head     # 重启进程，或 truncate /proc/<PID>/fd/<FD>
```

**清空日志（不要 rm 正在写的日志，rm 后空间不释放）**
```bash
truncate -s 0 <FILE>.log
truncate -s 0 /var/lib/docker/containers/*/*-json.log                      # 所有容器日志
truncate -s 0 "$(docker inspect --format='{{.LogPath}}' <CONTAINER>)"      # 指定容器
```
- 根治：daemon.json 配 `"log-opts": {"max-size": "100m", "max-file": "3"}`（仅对新建容器生效）。

**journal**
```bash
journalctl --disk-usage
journalctl --vacuum-size=500M
journalctl --vacuum-time=3d
```

**按时间删旧日志：先预览再删**
```bash
find <DIR> -type f -name "*.log*" -mtime +3 -print            # 先确认清单
find <DIR> -type f -name "*.log*" -mtime +3 -delete           # 再删除
```
- 不要用 `-iname "*log*"`：会误删 `logback.xml`、`catalog.*`、`login.*` 等；按修改时间用 `-mtime`，`-ctime` 会被 chmod/chown 等元数据变更刷新。

**Docker overlay2 占用大：找出是哪个容器**
```bash
# 1. 找出大目录（sort -h 才能正确比较 G/M 混合单位）
du -sh /var/lib/docker/overlay2/*/ 2>/dev/null | sort -rh | head -20

# 2. 用目录 ID <DIR_ID> 反查容器：容器自己写入的数据在 UpperDir（可写层）
docker ps -aq | xargs docker inspect --format '{{.Name}} {{.GraphDriver.Data.UpperDir}}' | grep "<DIR_ID>"

# 3. 进容器内删除/清理大文件（直接在宿主机改 overlay 目录有风险）
docker exec -it <CONTAINER> /bin/sh
```
- 若大目录属于镜像层（LowerDir），说明是镜像本身大，用 `docker system df -v` / `docker image prune` 处理。
