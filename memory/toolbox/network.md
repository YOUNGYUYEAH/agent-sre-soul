---
name: network
description: 网络排障命令：连通性/端口探测、curl 指定解析、grpcurl、tcpdump 抓包与 tshark 分析、pwru 内核丢包定位、流量监控工具
metadata:
  type: reference
---

# 网络排障

## 1. 连通性 / 端口

```bash
nc -zv <IP> <PORT>
nc -zv -w 2 <IP> <PORT_START>-<PORT_END>   # 端口段 + 2s 超时；端口段为 OpenBSD nc 语法，RHEL 的 ncat 不支持
timeout 2 telnet <IP> <PORT>               # 没有 nc 时的替代
timeout 2 bash -c '</dev/tcp/<IP>/<PORT>' && echo open   # 什么都没装时

mtr -r -c 10 <HOST>        # 报告模式，逐跳丢包/延迟；中间跳丢包但末跳不丢通常是 ICMP 限速，非真实丢包
trip <HOST>                # trippy，mtr 的 TUI 替代（GitHub: fujiapple852/trippy），需 root
```
其他：`iperf3`（带宽）、`hping3`（构造 TCP/UDP 探测）、`tcping`（TCP 层 ping）。

## 2. TCP 状态 / 协议栈计数

```bash
ss -s                                            # 汇总
ss -ant | awk 'NR>1 {++S[$1]} END {for(a in S) print a, S[a]}'
netstat -an | awk '/^tcp/ {++S[$NF]} END {for(a in S) print a, S[a]}'   # 旧系统
netstat -s | grep -Ei 'retrans|overflow|drop|reset'   # 重传、accept 队列溢出、丢弃
```

## 3. HTTP / gRPC

```bash
# 绕过 DNS，把域名指到指定 IP（SNI 和 Host 头仍是域名，适合验证某个后端/切流前验证）
curl -v --resolve <HOST>:<PORT>:<IP> https://<HOST>:<PORT>/

# grpcurl（GitHub: fullstorydev/grpcurl releases）；list/describe 依赖服务端开启 reflection，否则需 -proto/-import-path
grpcurl -plaintext <IP>:<PORT> list
grpcurl -plaintext <IP>:<PORT> describe <SERVICE>
```

## 4. tcpdump 抓包

```bash
tcpdump -i any -nn -c 1000                     # -nn：不把 IP 解析成主机名、不把端口解析成服务名
tcpdump -i any -Q in                           # 只抓入方向（-Q out 出方向）
tcpdump -i <NIC> -nn -tttt                     # -tttt 打印带日期的时间戳
tcpdump -i <NIC> -s 0 -w <FILE>.pcap           # 全包写文件
tcpdump -i <NIC> -s 128 -C 100 -W 5 -w <FILE>.pcap   # 环形抓包：每个文件约 100MB(-C，单位百万字节)，最多 5 个文件(-W) 循环覆盖
```

**snaplen 取舍（-s）**

| 场景 | snaplen |
|---|---|
| 只看连接（SYN/RTT/重传） | 96 / 128 |
| 常规排障 | 128 / 256 |
| HTTP 等明文协议 | 512 ~ 1024 |
| TLS / 需要完整 payload | 0（全包） |
| 生产长期抓包 | 96，配合 -C/-W 环形 |

**过滤器**（带括号必须整体加引号，否则 shell 报语法错误）
```bash
tcpdump -i <NIC> -nn '(port 80 or port 443) and host <IP>'
tcpdump -i <NIC> -nn 'udp port 53'
tcpdump -i <NIC> -nn 'tcp[tcpflags] & (tcp-syn|tcp-rst) != 0'   # 只看建连和 RST
# 原语：src host / dst host / net <CIDR> / portrange <A>-<B> / not
```

## 5. tshark 离线分析

```bash
tshark -r <FILE>.pcap -n -q -z http,stat          # HTTP 状态码统计
tshark -r <FILE>.pcap -n -q -z http_req,tree      # 按 URI 统计请求
tshark -r <FILE>.pcap -n -q -z conv,ip            # IP 会话（谁和谁流量最大）
tshark -r <FILE>.pcap -n -q -z expert             # 专家信息：重传、乱序、零窗口等

# 导出 HTTP 请求明细
tshark -r <FILE>.pcap -n -Y 'http.request' -T fields \
  -e frame.number -e ip.src -e ip.dst -e http.request.method -e http.request.uri \
  -E header=y -E separator=' ' | column -t

# 来源 IP 请求计数
tshark -r <FILE>.pcap -n -Y 'http.request' -T fields -e ip.src | sort | uniq -c | sort -nr | head

# TCP 平均 ACK RTT（间隔给极大值 = 整个文件一个区间）
tshark -r <FILE>.pcap -n -q -o tcp.desegment_tcp_streams:TRUE \
  -z io,stat,99999999,'AVG(tcp.analysis.ack_rtt)tcp.analysis.ack_rtt'
```

## 6. pwru：定位包在内核哪里被丢 / 卡住

- 获取：GitHub `cilium/pwru` releases（`pwru-linux-amd64.tar.gz`）。
- v1.x 起过滤用 **pcap-filter 表达式**（位置参数）；旧版的 `--filter-src-ip/--filter-dst-port` 等参数已移除。
- **不要裸跑**：必须带过滤条件，并用 `timeout` 或 `--output-limit-lines` 限制，否则输出量巨大、开销高。
- 在容器里运行需要 privileged，并挂载 debugfs：`mount -t debugfs none /sys/kernel/debug`。

```bash
# 长时间采集写文件
timeout 30 pwru '<PCAP_FILTER>' --output-file capture.log --output-json --timestamp current

# 短时查看
pwru '<PCAP_FILTER>' --output-limit-lines 500 --output-stack --output-caller --output-tcp-flags
```

| 参数 | 作用 |
|---|---|
| `--output-stack` | 打印内核调用栈 |
| `--output-caller` | 打印调用者函数名 |
| `--output-tcp-flags` | 打印 TCP flags |
| `--output-tuple` | 打印 L4 五元组（默认开启） |
| `--timestamp` | current / relative / absolute / none（默认 none） |
| `--filter-func '<RE2>'` | 只探测匹配的内核函数 |
| `--filter-ifname <NIC>` | 按网卡过滤（在 --filter-netns 指定的 netns 内） |
| `--filter-netns` | `/proc/<PID>/ns/net` 或 `inode:<INODE>`，定位容器网络命名空间 |
| `--filter-track-skb` | NAT/隧道解封装后仍继续跟踪同一个包 |

**场景用例**
```bash
# 访问 <IP>:<PORT> 卡住：看包走到哪个函数为止
pwru 'host <IP> and port <PORT>' --output-limit-lines 100

# 包发出去收不到响应 / 怀疑被丢：只看释放点，带栈找丢包原因
pwru 'host <IP>' --filter-func 'kfree_skb.*' --output-stack --output-limit-lines 100

# iptables/netfilter 丢包多：看 netfilter 钩子路径（仍建议加 pcap 过滤缩小范围）
pwru '<PCAP_FILTER>' --filter-func 'nf_hook_slow' --output-stack --output-limit-lines 100
```

## 7. 流量 / 网卡

```bash
nload <NIC>       # 单网卡实时带宽
ifstat            # 多网卡同时看实时流量
bmon              # 交互式网卡流量
ethtool <NIC>                 # 速率/双工/链路
ethtool -S <NIC> | grep -Ei 'drop|err|miss'   # 网卡层丢包计数
```
其他：`tcpreplay`（回放 pcap）、`tcpflow`（按 TCP 流还原内容）。
