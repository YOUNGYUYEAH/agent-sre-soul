---
name: linux-performance
description: Linux 性能诊断命令：进程/线程资源排行、pidstat、perf 采样（CPU/内存/IO 系统调用）、bcc-tools（slab、页缓存、内存泄漏、块 IO 延迟）
metadata:
  type: reference
---

# Linux 性能诊断

## 1. 先找嫌疑进程 / 线程

```bash
ps aux --sort -%cpu | head -20
ps aux --sort -%mem | head -20
ps -T -p <PID> -o pid,spid,%cpu,%mem,stat,comm     # 线程级（spid=TID，可转 16 进制对 jstack 的 nid）

# 僵尸进程：Z 状态，处理的是它的父进程（父进程不 wait），kill 僵尸本身无效
ps -A -o stat,ppid,pid,cmd | grep -e '^[Zz]'
```

**pidstat（sysstat）：按时间序列看单进程**
```bash
pidstat -p <PID> -t 1 5      # 间隔 1s 共 5 次（省略次数则持续输出）；默认 CPU，-t 展开线程
# -r 内存(缺页/RSS)  -d 磁盘IO  -w 上下文切换(cswch 自愿=等资源, nvcswch 非自愿=抢CPU)  -v 线程数与 fd 数
```

## 2. perf

**常规步骤：stat 看总量 → record 采样 → report 看调用栈**
```bash
perf list                         # 所有事件
perf list 'syscalls:*'            # 按模式过滤事件（如只看 syscall tracepoint）

perf report -i <perf.data> -g graph --stdio     # 默认读当前目录 perf.data
```

**CPU 热点**
```bash
perf stat -e cycles,instructions,context-switches,syscalls:sys_enter_futex -p <PID> -- sleep 30   # IPC 低、futex 多 → 锁竞争
perf record -F 99 -g -p <PID> -- sleep 30                 # 指定进程
perf record -F 99 -a -g -- sleep 30                       # 全系统
perf record -F 99 -p <PID> --call-graph dwarf -- sleep 30 # 无帧指针的程序用 dwarf 栈（数据量大）
perf record -e sched:sched_switch -p <PID> -g -- sleep 30 # 调度切换：被抢占/主动让出 CPU
```
- 关键：`perf record ... -- sleep 30` 不带 `-p`/`-a` 时只采样 `sleep` 这个命令自身，什么都看不到。

**内存分配（系统调用层面）**
```bash
perf stat -e syscalls:sys_enter_mmap,syscalls:sys_enter_munmap,syscalls:sys_enter_brk -p <PID> -- sleep 10   # mmap 远多于 munmap → 疑似不回收
perf record -e syscalls:sys_enter_mmap -p <PID> -g -- sleep 30
perf record -e syscalls:sys_enter_brk  -p <PID> -g -- sleep 30
```
- 只能看到向内核要内存的动作；glibc 小块 malloc 在已有 arena 内分配不触发 syscall，泄漏要用 memleak（见下）。

**IO 系统调用**
```bash
perf stat -e syscalls:sys_enter_read,syscalls:sys_enter_write,syscalls:sys_enter_fsync -p <PID> -- sleep 10   # fsync 次数 = 刷盘频率
perf record -e syscalls:sys_enter_write  -p <PID> -g -- sleep 30
perf record -e syscalls:sys_enter_openat -p <PID> -g -- sleep 30   # 谁在频繁打开文件
```

## 3. bcc-tools（eBPF）

- 路径：RHEL 系 `/usr/share/bcc/tools/<tool>`；Debian/Ubuntu 命令名带后缀 `<tool>-bpfcc`。新内核也可用 libbpf-tools 或 bpftrace 同名工具。
- 位置参数一般是 `<间隔秒> <次数>`。

**内存**
```bash
slabratetop -C 5 10       # 内核 slab 分配速率；-C 不清屏（便于留存输出）；列：CACHE / ALLOCS / BYTES
cachetop 5                # 按进程看页缓存：HITS / MISSES / DIRTIES / READ_HIT% / WRITE_HIT%

memleak -p <PID> 10 3                 # 每 10s 报告一次，共 3 次，未释放的分配调用栈
memleak -p <PID> -a -o 5000 -s 100    # -a 显示每笔分配地址与大小；-o 只报告存活超过 5000 毫秒的分配；-s 每 100 次分配采样 1 次（降开销）
memleak -p <PID> -T 5                 # 只显示 Top 5 分配栈（默认 10）；不带 -p 则跟踪内核内存分配
memleak -p <PID> -Z 1024              # 只跟踪 <=1024 字节的分配；-z 为 >= 下限（单位字节）
```
- memleak 开销较大，生产上加 `-s` 采样并限定时长。

**块设备 IO**
```bash
biolatency -D -Q          # 按盘输出延迟直方图；-Q 包含 OS 队列等待时间；-m 改为毫秒
biolatency -D -Q 30 1     # 采 30s 输出 1 次后退出
biosnoop -Q | awk '$9 > 10'   # 每个 IO 明细，过滤总延迟 >10ms；列：TIME COMM PID DISK T SECTOR BYTES QUE(ms) LAT(ms)
biotop                    # 按进程实时看块 IO
```
- awk 列号依赖版本与 COMM 是否含空格，先看表头再过滤。
- 延迟经验值：<200µs 内存盘/NVMe；200µs~数 ms 普通 SSD；>10ms 机械盘寻道或排队拥堵；>100ms 严重异常（盘故障、调度、存储后端）。
- QUE 高而服务时间低 → 排队（并发过高/队列深度）；两者都高 → 盘本身慢。
