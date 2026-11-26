---
name: java
description: Java 线上诊断：JDK 自带工具（jstat/jcmd/jmap/jstack）、Arthas 常用命令与 K8s 批模式、async-profiler(asprof) 容器内非交互采样
metadata:
  type: reference
---

# Java 诊断

## 1. JDK 自带工具

```bash
jstat -gcutil <PID> 1000 10                  # 每 1s 一次共 10 次；看 O(老年代) 是否持续上涨、FGC 次数/耗时
jcmd <PID> GC.heap_info                      # 堆使用概况（JDK 9+ 替代 jmap -heap）
jhsdb jmap --heap --pid <PID>                # JDK 9+；jmap -heap 只在 JDK 8 可用
jcmd <PID> GC.run                            # 手动触发 Full GC（会 STW）

jmap -dump:live,format=b,file=<PATH>.hprof <PID>   # live 会先触发 Full GC；不加 live 不 GC 但文件更大
jcmd <PID> GC.heap_dump <PATH>.hprof               # 等价方式

jstack <PID> > /tmp/jstack.log
jstack <PID> | grep 'java.lang.Thread.State' | sort | uniq -c | sort -nr   # 线程状态分布
jcmd <PID> Thread.print > thread-dump.txt
```
- 高 CPU 线程定位：`ps -T -p <PID> -o spid,%cpu --sort -%cpu | head` → `printf '%x\n' <TID>` → 在 jstack 里找 `nid=0x<hex>`。
- 容器内常见"attach 失败"：执行用户必须与 JVM 进程用户一致，且 /tmp 需共享（同一容器内执行即可）。
- heap dump 体积≈堆大小，先确认目标目录空间。

## 2. Arthas

**容器里使用**
```bash
curl -fSLO <arthas-boot.jar 官方下载地址>
kubectl cp arthas-boot.jar <NS>/<POD>:/tmp/arthas-boot.jar      # kubectl cp 依赖容器内有 tar

# 批模式：一次性执行后退出（不能用 watch/dashboard/trace 等持续输出的命令）
kubectl exec -n <NS> <POD> -- java -jar /tmp/arthas-boot.jar 1 -c "<CMD1>;<CMD2>"   # 容器内 JVM 通常是 PID 1

# 交互式
java -jar arthas-boot.jar <PID>
```

**JVM 概况**
```bash
dashboard                    # 实时面板
jvm                          # JVM 信息、GC、类加载
memory                       # 各内存区用量
sysprop                      # 系统属性
vmoption                     # 查看 VM 参数；vmoption <KEY> <VALUE> 动态修改（仅 manageable 参数）
```

**线程**
```bash
thread -n 5                  # CPU 占用 Top 5 线程及栈
thread -b                    # 找持锁阻塞其他线程的线程（仅 synchronized）
thread --state BLOCKED       # 按状态筛选，可选 RUNNABLE / BLOCKED / WAITING / TIMED_WAITING 等，一次一个
thread --all
thread <ID>
```

**dump / heapdump 区别**
- `dump <CLASS>`：导出类字节码 .class（看实际加载的版本、类加载器），文件小。
- `heapdump <PATH>.hprof`：堆转储（内存泄漏、OOM、对象分析），文件大；`heapdump --live` 会触发 Full GC。

**profiler（内置 async-profiler）**
```bash
profiler list                # 支持的事件
profiler status / meminfo    # 后台采样状态 / 自身内存占用
profiler start --event cpu  --duration 30 --exclude '*Unsafe.park*'   # CPU 火焰图，排除 park 等待
profiler start --event alloc --duration 60                            # 内存分配热点
profiler start --event lock  --duration 60                            # 锁竞争（慢接口、线程等待）
profiler start --event cpu   --duration 60 --format jfr               # 输出 jfr（-o 是 --format 的短写）
```
- 带 `--duration` 到时自动停止并生成文件；不带则需手动 `profiler stop`。

**vmtool**
```bash
vmtool --action forceGc                       # 强制 GC（慎用）
vmtool --action mallocTrim                    # 让 glibc 归还空闲内存：RSS 高但堆不高时验证是否 glibc 内存碎片
vmtool --action mallocStats                   # glibc 分配统计
vmtool --action heapAnalyze --classNum 20 --objectNum 20                              # 堆对象统计（较新版本 Arthas 才有）
vmtool --action referenceAnalyze --className <CLASS> --objectNum 20 --backtraceNum 2  # 对象引用链（同上）
```

**JMX（mbean）**
```bash
mbean java.lang:type=Memory
mbean java.lang:type=Threading
mbean java.lang:type=OperatingSystem
mbean 'java.nio:type=BufferPool,name=*'           # 堆外：direct / mapped 缓冲区
mbean 'java.lang:type=MemoryPool,name=*'          # 各内存池（含 Metaspace、CodeCache）
mbean 'java.lang:type=GarbageCollector,name=*'    # GC 次数/耗时；名称随收集器变化（MarkSweepCompact 只属于 Serial GC，G1 为 "G1 Old Generation"）
mbean -i 1000 -n 10 java.lang:type=Memory         # 每 1s 刷新共 10 次
```

## 3. async-profiler（asprof）容器内非交互采样

- 要拷贝**整个发行包**（bin + lib），只拷 asprof 会缺 libasyncProfiler.so。

```bash
kubectl cp -n <NS> async-profiler-<VER>-linux-x64.tar.gz <POD>:/tmp/
kubectl exec -n <NS> <POD> -- tar zxf /tmp/async-profiler-<VER>-linux-x64.tar.gz -C /tmp
kubectl exec -n <NS> <POD> -- /tmp/async-profiler-<VER>-linux-x64/bin/asprof -d 30 -e cpu -f /tmp/cpu.html 1
kubectl cp -n <NS> <POD>:/tmp/cpu.html ./cpu.html
```
- `-d` 秒数、`-e` 事件（cpu/alloc/lock/wall…）、`-f` 输出文件（扩展名 .html 自动生成火焰图，.jfr 为 JFR）、最后是 PID。
- 容器里常因 `perf_event_paranoid` / seccomp 无法用 perf_events，`-e cpu` 报错时改 `-e itimer`（或 `ctimer`）。
- 线程在等 IO/锁导致"慢但 CPU 不高"时用 `-e wall` 看墙钟时间。
