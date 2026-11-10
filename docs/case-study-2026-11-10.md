# 实战案例：用 NOKIA G-010S-A 猫棒替换中国移动光猫

> 日期：2026-11-10　总耗时：约 14.5 小时（含大量弯路）
> **本文已脱敏**：所有账号、密码、SN、IP、MAC 均替换为占位符。

## 一、目标与最终结果

把运营商配的光猫（`GM219-S`）换成一根 NOKIA G-010S-A 猫棒（SFP 形态 ONT）+ 一台自备路由器，让宽带继续可用且**跑满带宽**。

**最终结果**：

| 线路 | 下载（并发聚合） | 延迟 | 丢包 |
|---|---|---|---|
| 旧线：WiFi → 原光猫 | 17 / 37 Mbps | 23.3 ms | 0% |
| **新线：猫棒 → 路由器** | **665 Mbps** | **9.97 ms** | 0% |

附带结论：**旧线慢的真凶是 WiFi（2.4GHz / 20MHz 窄信道），不是宽带。**

---

## 二、最终拓扑

```
光纤
 └─► 猫棒 NOKIA G-010S-A（CM753 交换机的 6 号 SFP+ 口，纯桥接 ONT）
        └─► CM753 的 5 号口 ──► 路由器 WAN（PPPoE 拨号，拿到 <PPPOE_ASSIGNED_IP>）
                                 └─► LAN1 ──► 电脑
                                 └─► WiFi <ROUTER_SSID>
原光猫：断电保留作备份
```

交换机（4×2.5G RJ45 + 1×SFP+）有端口隔离：「**1-4 不能互相通信，只能与 5、6 通信**」。
→ 路由器接 **5 号口**、电脑接 **2/3/4 号口**，隔离口↔上行口可通，两边都能访问。
→ 反过来（路由器和电脑各接 1~4）则互相看不见，后台都进不去。

---

## 三、四个根因

### ① 身份没持久化，一重启就废（决定性）
- `config_onu.sh` 的 `load_config()` 启动时从 **`fw_printenv nSerial/nPassword`** 灌进 UCI；
- 而 LuCI「保存&应用」**只写 UCI + EEPROM，从不写 uboot env**；
- 于是 11-09 当初改的身份**从没进过 uboot env**，冷启动被旧线身份覆盖 → 猫棒拿旧身份插在新线 PON 上，`PLOAM state 3`，注册不上。

**修复**：uboot env + UCI + EEPROM **三处同写**，验收标准是「**断电重启后仍是新值**」。

### ② ME171 VLAN 规则没配 PVID
`uvlan` 未设时，固件下发的默认规则会丢弃 untagged 帧 → **连 PADO 都回不来**。
**修复**：`uci set gpon.onu.uvlan=41`（+ `iop.sh restart`）。

### ③ macOS 自带 pppd 不兼容该 BRAS 的报文乱序
抓包实证：
```
client → AC : PADR
AC     → client : LCP Conf-Request   ← PADS 还没来就先发 LCP
AC     → client : PADS
```
macOS pppd 判定非法 → **立刻 PADT 拆会话** → 永远到不了认证阶段。
**这被误判成「密码错」整整很久**（日志里从未出现 PAP/CHAP 行，说明密码从未被验证）。

**修复**：改用 Linux 内核的路由器拨号，**一次就通**。

### ④ 端口隔离（见上）

---

## 四、时间账单：14.5 小时花在哪

| 浪费 | 真相 | 教训 |
|---|---|---|
| ≈3 h | 我建的 `~/.ppprc` 里 `logfile /tmp/xxx.log` 被 pppd 以 root 创建后普通用户删不掉，**pppd 卡死不启动、连 PADI 都不发**，误判为「链路不通」 | 临时调试文件要确认**谁创建、能否删干净**；主通道被自己堵住时先怀疑自己 |
| ≈1 h | 自己开了 `forceuvlan`/`forcemerule`，两个「强制」开关让 ME171 规则与 `uvlan` 互相覆盖，把 PADO 都弄丢 | 「强制」类开关在每轮循环里都会跑，**不要随手开** |
| ≈1 h | 路由器后台用 curl 试了 8 组密码全 401，实际是页面未就绪 → **真实浏览器点一次就登进去** | curl 反复失败要**换手段**而不是换密码 |
| ≈1 h | 反复 `networksetup -ordernetworkservices` 漏列服务，**弄丢了 Tailscale 网络服务条目**（至今未恢复） | 会重排系统服务的脚本必须**全量列表 + 备份** |
| 贯穿 | **全程靠日志猜，没先抓包**。抓包一次看清「BRAS 主动发 LCP + 乱序」 | **先建立观测能力再动配置**：抓包 > 日志 > 猜 |

**最大的方法论错误**：在客户机（macOS）上验证运营商级协议。**一开始就该直接用路由器试。**

---

## 五、复现步骤（可直接照做）

```bash
# ── 1. 备份（务必）
fw_printenv > fw_printenv_backup.txt
tar czf ponstick-backup-$(date +%Y%m%d).tar.gz /etc/config

# ── 2. 身份三处写入
fw_setenv nSerial <GPON_SN>
fw_setenv nPassword "<PLOAM_PASSWORD_HEX>"      # 含空格必须加引号！
uci set gpon.onu.nSerial=<GPON_SN>
uci set gpon.onu.ploam_password=<PLOAM_PASSWORD_PLAIN>
uci commit gpon
/opt/lantiq/bin/sfp_i2c -i8 -s <GPON_SN>
/opt/lantiq/bin/sfp_i2c -i11 -s <PLOAM_PASSWORD_PLAIN>
sync

# ── 3. VLAN
uci set gpon.onu.uvlan=41
uci set gpon.onu.iopmask=1
uci commit gpon
/etc/init.d/iop.sh restart
cat /tmp/me171_rule          # 期望含 ... 00 0f 80 00 00 00 01 4c

# ── 4. 断电重启，验收
onu ploamsg                 # curr_state=5
fw_printenv nSerial         # 仍是新 SN
onu gtcpg                   # password=新密码

# ── 5. 路由器 PPPoE
#    账号 <BROADBAND_ACCOUNT> / 密码 <PPPOE_PASSWORD>
#    VLAN 模式 = UNTAG（猫棒负责打 tag）/ MTU 1492 / NAT 启用
```

---

## 六、经验清单

1. **猫棒只做桥接，拨号交给路由器。** 反过来（猫棒拨号）会让猫棒的路由/NAT 功能拖累性能。
2. **身份三处写，且以重启后验证为准。**
3. **PVID 规则编码 = `PVID*8+4` 的 hex**（41 → `01 4c`）。
4. **端口隔离交换机：隔离口 ↔ 上行口才通。**
5. **`fw_setenv` 带空格的值必须加引号。**
6. **改系统配置前先备份**；`route change default` 报 `Address already in use` 时用 `route delete default && route add default <gw>`。
7. **测速用多路并发**（单连接会被源站限流）。
8. **无线段可能是真凶** —— 先看 WiFi 频段与信道宽度。
9. **不要在客户机上验证运营商级协议** —— 用真机。

## 免责声明

替换运营商光猫通常违反宽带服务条款，并可能影响运营商侧设备绑定与远程运维配置。请自行确认线路允许第三方 ONT 接入，保留原光猫断电作备份。本文仅用于个人技术学习与自有线路排障。
