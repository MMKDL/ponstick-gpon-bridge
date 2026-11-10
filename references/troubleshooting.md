# 症状 → 根因速查表（分层排障）

按**分层证据链**逐层排除，不要跳层猜测。每一层都有明确的「验收命令」。

---

## L0 物理层

| 现象 | 检查 | 处理 |
|---|---|---|
| 设备管理口不通 | `ping <ONT_IP>`、看交换机对应口 LED 是否亮/闪 | SFP 未插紧、交换机口没供电、插错口 |
| 光纤不通 PON | `onu ploamsg` 的 `curr_state`；光功率读数 | 清洁光纤端面、确认 SC/APC 头型一致 |
| 换了口就连不上 | 交换机是否有端口隔离 | 见 L1 |

> 💡 **管理口不通 = SFP 模块没被交换机识别/供电**，与 PON 状态无关。先解决物理层再谈上层。

---

## L1 二层 / 交换机

**现象**：交换机上设备互相看不见、后台能 ping 到的设备变了。

常见于带**端口隔离**的交换机（如 4×2.5G + 1×SFP+ 的型号），规则通常是：
> 端口 1-4 **不能互相通信**，只能与端口 **5、6** 通信

**正确接法**：

```
猫棒 → SFP+ 口（6，上行口）
路由器 WAN → 5 号口（上行口）
你的电脑 → 2/3/4 号口（隔离口，隔离口 ↔ 上行口可通）
```
→ 电脑能同时访问猫棒（6）与路由器（5）。

**错误接法**：路由器接 1~4 口 + 电脑接另一个 1~4 口 → **两者互相隔离**，后台都进不去。

---

## L2 PON 注册（PLOAM）

| `onu ploamsg` | 含义 | 下一步 |
|---|---|---|
| `curr_state=5` | O5，注册成功 | 进 L3 |
| `curr_state=2/3` | 未注册 / 正在注册 | 查身份 |
| `curr_state=1` | 无光 | 查光纤/光功率 |

**身份不一致是最常见根因**：

```bash
fw_printenv nSerial            # uboot env（权威源）
uci get gpon.onu.nSerial        # UCI
sfp_i2c -g                     # EEPROM
onu gtcsng                     # 硬件实际用的
```
> 四者不一致 → 冷启动后一定以 uboot env 为准覆盖其余 → **三处全部重写**，然后**断电重启**再验。

---

## L3 OMCI / VLAN 业务通道（ME171）

| 现象 | 检查 | 修复 |
|---|---|---|
| O5 正常但**收不到 PADO** | `cat /tmp/me171_rule` 是否含你的 PVID 规则 | `uci set gpon.onu.uvlan=<PVID>` + `iop.sh restart` |
| PADO 时有时无 | 是否同时开了 `forceuvlan` / `forcemerule` | **全部关掉**，只留 `uvlan` |
| 想让下挂设备自己打 tag | `tvlan`（如 `2:41,4:u`）或 `uvlan=u` 透传 | 二选一，别混 |

PVID 规则编码：`PVID*8+4` 的十六进制。PVID=41 → `01 4c`，完整规则：
```
f8 00 00 00 f8 00 00 00 00 0f 80 00 00 00 01 4c
```

---

## L4 PPPoE 发现（广播）

| 现象 | 含义 |
|---|---|
| 连 PADI 都发不出去 | **客户端没启动**（不是链路问题！）→ 查 pppd 是否活着、`en0` 发包计数是否递增 |
| PADI 发出、无 PADO | 上行广播没到 ONU/局端 → 查 L1/L2/L3 |
| 有 PADO、无 PADR | 会话建立被拒 → 稍等（局端可能限流/旧会话未释放） |

**「客户端没发 PADI」的经典陷阱**：客户端 pppd 卡在初始化（日志停在 `SecKeychainFindGenericPassword` 之后），此时 `en0` **发包增量为 0**，看起来像「链路不通」，实际是**软件问题**。

---

## L5 PPP 会话协商（单播）

**最容易被误判为「密码错」的一层。**

抓包看 PPPoE 会话帧（`ether proto 0x8864`），关注**报文顺序**：

正常顺序：
```
client → AC : PADR
AC     → client : PADS
client → AC : LCP ConfReq
AC     → client : LCP ConfAck
```

**某些 BRAS 的实际顺序**（异常但合法存在）：
```
client → AC : PADR
AC     → client : LCP ConfReq   ← PADS 还没来就先发 LCP！
AC     → client : PADS
```
- **macOS pppd 遇到这种乱序** → 判定为非法帧 → **立刻发 PADT 拆会话** → 永远走不到认证
- **Linux 内核 pppd** 能容忍 → 正常建立会话

👉 **结论：遇到「PADO 有、LCP 零回应」，先换路由器拨号，别调密码。**

日志特征（macOS `/var/log/ppp.log`）：
```
sent [LCP ConfReq id=0x1 ...]
（无 rcvd）
```
且**从未出现** PAP/CHAP 行 → 说明根本没到认证阶段，**密码从未被验证**。

---

## L6 认证

| 路由器后台错误码 | 含义 |
|---|---|
| **691** | 账号或密码错误 |
| **651** | 网络不通（VLAN/桥接/光路问题） |
| 一直「连接中」 | 没收到 PADO（回 L4） |

---

## L7 IPCP / 取址

| 现象 | 检查 |
|---|---|
| 认证过了但没 IP | `onu ploamsg` 是否仍 O5；客户端 `ifconfig ppp0` 是否 UP 且有 `inet` |
| 拿到私网 IP 但出不去 | NAT 是否启用；MTU 是否 1492（PPPoE 扣 8 字节） |

---

## 排障时的自我检查清单（本次实战总结）

- [ ] **先抓包再改配置** —— 抓一次包能省几小时
- [ ] 临时文件是谁创建的？**能不能删掉？**（root 创建的 `/tmp` 文件会让 pppd 静默卡死）
- [ ] 一次只改一个变量，每次改动可逆
- [ ] 别随手勾「强制」类开关（`forceuvlan` / `forcemerule` 会互相覆盖）
- [ ] 改系统配置（plist / 路由 / 服务顺序）前先备份
- [ ] **不要在客户机上验证运营商级协议** —— 用真机
- [ ] 改 `fw_setenv` 后**必须重启验证**，只读运行时不算
- [ ] `route change default` 报 `Address already in use` → 用 `route delete default && route add default <gw>`
