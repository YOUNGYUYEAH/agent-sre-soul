---
name: linux-troubleshoot
description: Linux 主机排障（兵分两路：止血 + 根因）。用户反映主机卡顿、负载高、CPU/内存/磁盘 IO 打满、磁盘满、服务起不来或频繁退出、OOM、网络不通/丢包/连接堆积、时间同步异常时使用。
---

# Linux 主机排障

默认**只读**。重启服务、kill 进程、清理文件、改内核参数前，先说明影响并等用户确认；写文件前说明写到哪个路径、哪个挂载点。

## 0. 兵分两路

| 线 1：止血 | 线 2：根因 |
|---|---|
| 哪个进程/服务受影响？最快恢复手段（重启服务、清理空间、限流、摘流量）给一套方案等拍板 | 时间线对齐（指标、应用日志、系统日志、变更记录，UTC/本地双标）→ 找对照（同组正常主机）→ 证据 → 已证实 / 推断 |

**止血前先保留现场**：

```bash
top -b -n1 -H -p <PID> > /tmp/top-<PID>.txt          # 线程级 CPU
cat /proc/<PID>/status /proc/<PID>/io > /tmp/proc-<PID>.txt
# 线程栈：Java 用 jcmd <PID> Thread.print；Go 发 SIGQUIT 或用 pprof；C/C++ 用 gdb -p <PID> -batch -ex "thread apply all bt"
ss -tanp > /tmp/ss.txt
```

## 1. 先看全局（USE：使用率 / 饱和度 / 错误）

```bash
uptime; cat /etc/os-release | head -2
dmesg -T | tail -50                     # OOM、IO 错误、网卡、硬件
journalctl -p err -S -1h --no-pager     # 最近一小时的错误（不要 -e，会截断）
last -x | head; journalctl -S -2h | grep -iE 'reboot|shutdown' # 是否刚重启
```

| 资源 | 使用率 | 饱和度 | 错误 |
|---|---|---|---|
| CPU | `mpstat -P ALL 1 3`、`top` | 负载 vs 核数、`vmstat 1` 的 r 列、`pidstat -w`（上下文切换） | `dmesg` |
| 内存 | `free -h`（看 available）、`ps aux --sort=-rss \| head` | `vmstat` 的 si/so、PSI `cat /proc/pressure/memory` | `dmesg -T \| grep -i oom` |
| 磁盘 IO | `iostat -xz 1 5`（%util、await、r/s w/s） | `aqu-sz`、`/proc/pressure/io` | `dmesg` 里的 I/O error |
| 磁盘空间 | `df -hT`、`df -i`（inode） | — | 删了文件空间不释放：`lsof +L1` |
| 网络 | `sar -n DEV 1 3` | `ss -s`、`netstat -s \| grep -iE 'retrans\|overflow\|drop'` | `ip -s link` 的 errors/dropped |

## 2. 定位到进程

```bash
ps aux --sort=-%cpu | head -10
pidstat -u -r -d -t 1 5          # CPU / 内存 / IO，按线程
pidstat -d 1 5                   # 谁在读写盘（第一轮采样常为 0，看后几轮）
strace -c -f -p <PID>            # 系统调用分布（生产数据库进程慎用，开销大）
lsof -p <PID> | wc -l; cat /proc/<PID>/limits | grep -i 'open files'
```

- 周期性尖峰：先对齐 crontab、systemd timer、备份、日志轮转、应用定时任务，用时间线和相关性逐个排除。
- dm/LVM 设备要同时看底层物理盘，区分是哪块盘的瓶颈。

## 3. 服务与日志

```bash
systemctl status <SVC> --no-pager -l
journalctl -u <SVC> -S -1h --no-pager | tail -100
systemctl list-units --failed
```

- 应用日志用 `grep -c` 按分钟统计行数，日志量骤降/骤增的时刻往往就是事件点。
- 先确认日志确实是目标进程写的（线程号、PID 对得上），再下结论。

## 4. 网络

```bash
ip -br addr; ip route
ss -tulpn                                   # 监听
ss -tan state established | wc -l; ss -tan | awk 'NR>1{print $1}' | sort | uniq -c   # 连接状态分布
mtr -rwc 20 <TARGET>                        # 逐跳丢包与延迟
curl -sv --connect-timeout 5 http://<TARGET>  -o /dev/null
dig <DOMAIN> +short; cat /etc/resolv.conf
chronyc tracking 2>/dev/null || timedatectl  # 时间同步异常会引发证书、鉴权、日志错乱
```

需要抓包时：过滤表达式整体加单引号，限定 `-c` 或 `-C/-W`，避免把盘写满。

## 5. 结论与汇报

- 根因要有证据（命令输出、日志行、指标曲线）；缺证据的标「推断」并写明还要采集什么。
- 汇报：止血进展 → 根因进展 → 根治方案（前置条件、禁忌）→ 防复发（告警、巡检、容量）。
- 状态写清：已恢复 / 已恢复未根治 / 已根治。
- 具体命令细节见 `memory/toolbox/linux-*.md`、`network.md`。
