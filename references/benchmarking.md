# 带宽 / 延迟基准测试

## 1. 测速为什么必须「多路并发」

单个 TCP 流经常被**源站限流**（镜像站常见 100 KB/s ~ 1 MB/s 的单连接上限），测出来的是**源站速度**而不是你的带宽。

实测对照（同一台机器、同一宽带）：
| 方式 | 阿里云 docker 包 |
|---|---|
| 单连接 | 0.9 MB/s |
| 8 路并发 | 56 MB/s |
| 16 路并发 | 83 MB/s（≈665 Mbps） |

→ **结论：用 8~16 路并发，测聚合吞吐。**

## 2. 源站选择（国内可用且不限速的）

| 源 | 备注 |
|---|---|
| `https://mirrors.aliyun.com/docker-ce/linux/static/stable/x86_64/docker-<ver>.tgz` | ✅ 实测能跑满，百兆千兆都吃得下 |
| `https://mirrors.aliyun.com/docker-ce/...`（其他版本号） | 同上，换版本号即可 |
| `mirrors.aliyun.com/ubuntu/ls-lR.gz` | 小文件，几十 MB，只适合粗测 |
| `mirrors.tuna.tsinghua.edu.cn`、`mirrors.ustc.edu.cn` | 单连接被限流（403 / 限速），不适合 |
| `mirrors.cloud.tencent.com` | 路径版本号不对会 404，先列目录取真实文件名 |
| `registry.npmmirror.com` | 速度一般 |
| 国外测速站（digitalocean / cachefly 等） | 出墙或极慢，不适合国内线路 |

**先探活再正式测**（一次跑 8 秒看 `%{http_code}` 和 `%{size_download}`）：
```bash
curl -sL -A "<UA>" --max-time 8 -o /dev/null \
  -w "http=%{http_code} 下载=%{size_download}B 速度=%{speed_download}B/s\n" "<URL>"
```
注意 **ISO 文件名要带完整版本号**（如 `ubuntu-24.04.5.1-desktop-amd64.iso`），少了版本号会 404。
目录列表取真实文件名：
```bash
curl -sL https://<mirror>/ubuntu-releases/24.04/ | grep -oE 'ubuntu-24[^"<> ]*\.iso' | sort -u | head
```

## 3. 测速脚本模板（macOS / Linux 通用）

```bash
#!/bin/bash
DUR=15; CONC=8
U="https://mirrors.aliyun.com/docker-ce/linux/static/stable/x86_64/docker-26.1.3.tgz"
tmp=$(mktemp -d)
for i in $(seq 1 $CONC); do
  (curl -sL -o /dev/null --max-time $DUR -w "%{size_download}\n" "$U" > "$tmp/$i" 2>/dev/null) &
done
wait
total=$(cat "$tmp"/* | awk '{s+=$1} END{printf "%d", s+0}'); rm -rf "$tmp"
awk -v b="$total" -v d="$DUR" 'BEGIN{printf "%.2f MB/s (%.0f Mbps)\n", b/d/1048576, b*8/d/1048576}'
```

## 4. 两条线路对比时怎么切

macOS（`route change` 在已有多条 default 时会报 `Address already in use`）：
```bash
# 切到 B 线路
sudo route delete default && sudo route add default <B_GW>
# 切回 A 线路
sudo route delete default && sudo route add default <A_GW>
```
Linux：`ip route replace default via <GW> dev <IF>`

> 切线期间本机会短暂走新线路，**远程会话/服务可能中断**。测完务必切回并验证：
> `route -n get default | grep -E "gateway|interface"`

## 5. 延迟与丢包

```bash
ping -c 20 -t 2 <目标IP>          # 看 min/avg/max/stddev 与丢包率
# 抖动看 stddev；丢包看 "packet loss"
```
建议对**两个目标**各测一次：
- **运营商 CDN**（同城，如 `120.232.x.x` 移动 CDN）→ 反映真实链路 RTT
- **公网 DNS**（如 `223.5.5.5`）→ 反映基础连通质量

## 6. WiFi 链路的坑（本次实测踩到）

**无线段可能才是瓶颈，而不是宽带。** 检查：
```bash
system_profiler SPAirPortDataType | grep -A8 "Current Network Information"
# 看：PHY Mode / Channel / Channel Width / Transmit Rate / Signal-Noise
```
本次 Mac 连的是 **`Channel 12 (2GHz, 20MHz)`** → 2.4GHz + 20MHz 窄信道，把千兆宽带压到 **17~37 Mbps**；换成有线后同一宽带立刻跑到 **665 Mbps**、延迟从 23ms 降到 10ms。

👉 **判断宽带是否被无线拖累，先看 WiFi 的频段与信道宽度。**

## 7. 结果解读

| 现象 | 判断 |
|---|---|
| 16 路并发 ≈ 665 Mbps（千兆套餐） | 正常（PON 开销 + 源站限制），链路健康 |
| 16 路并发 仍卡在 ~100 Mbps | 可能是链路协商只到百兆（检查两端网口协商速率 / 光猫 SFP 是 1G 还是 100M） |
| 速度高但延迟高/丢包 | 上行或拥塞问题 |
| 换有线后带宽暴涨 | 之前是 WiFi 瓶颈，不是宽带问题 |
