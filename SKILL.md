---
name: ponstick-gpon-bridge
description: 用 GPON SFP 猫棒（PON stick / 光猫棒，如 Nokia G-010S-A、Huawei MA5671A、ODI HSGQ）替代运营商光猫、自己接管宽带接入。适用于「PPPoE 拨不上」「PON 注册上不去 / PLOAM state 不是 5」「能注册但收不到 PADO」「运营商光猫被锁定换不了」「猫棒重启后配置丢失」等场景。覆盖：SN/PLOAM 身份持久化（uboot env + UCI + EEPROM 三处同时写）、ME171 VLAN 规则与默认 PVID、带端口隔离的交换机接线规划、路由器侧 PPPoE 对接参数、链路分层抓包排障、以及带宽/延迟基准测试。
---

# 用猫棒（PON stick）替代光猫接管宽带

## 角色分工（先搞清楚这件事，能省掉 80% 的无效排查）

| 设备 | 职责 | 绝对不做 |
|---|---|---|
| **猫棒**（SFP 形态 ONT） | 只做**光电转换 + 二层透明桥接**，让 PON 上的 VLAN 41 帧原样落地到以太网侧 | **不拨号、不配 IP、不做 NAT** |
| **路由器**（或任何能跑 PPPoE 的设备） | **PPPoE 拨号**、拿 IP、NAT/DHCP/DNS | 不碰光路 |

> ⚠️ **绝对不要用 macOS/Windows 自带的 PPPoE 客户端做最终验证**。原因见「铁律 ③」——很多运营商 BRAS 的报文顺序不符合客户端预期，客户端会自己把会话拆掉，而**这不是密码问题**，会让你在错误的方向上耗掉几个小时。用真机（路由器）验证。

## 执行顺序（严格按序，每步都有验收标准）

### 0. 备份（不可跳过）
```bash
# 猫棒完整配置备份（务必先做）
tar czf ponstick-backup-$(date +%Y%m%d).tar.gz etc/config etc/fw_env.config 2>/dev/null
fw_printenv > fw_printenv_backup.txt
```

### 1. 物理接线（先画图再插线）
带**端口隔离**的交换机（如 CM753：4×2.5G RJ45 + 1×SFP+）规则通常是「**端口 1-4 不能互相通信，只能与 5、6 通信**」。据此规划：

```
光纤 ──► 猫棒 ──► 交换机 SFP+ 口（6 号，上行口）
                  ├─ 5 号口 ──► 路由器 WAN
                  └─ 2/3/4 号 ──► 你的电脑（想抓包旁观时）
```
- 路由器接 **5 号口**，电脑接 **2/3/4 号口** → 隔离口 ↔ 上行口可通，两边都能访问
- 路由器接 1~4 口、电脑接另一个 1~4 口 → **互相看不见**（隔离），后台都进不去

### 2. 身份三处写入（最容易漏、后果最严重的一步）
猫棒的 GPON 身份（SN / PLOAM 密码）存在于**三个位置**，缺一不可：

| 位置 | 写入方式 | 谁读它 |
|---|---|---|
| **uboot env** | `fw_setenv nSerial ...` / `fw_setenv nPassword "0x61 0x32 ..."` | 启动脚本 `config_onu.sh load` → **权威源** |
| **UCI** | `uci set gpon.onu.nSerial=...` / `gpon.onu.ploam_password=...` + `uci commit gpon` | LuCI 显示层、`config_onu.sh init` |
| **EEPROM (SFP A2 区)** | `sfp_i2c -i8 -s <SN>`（SN）、`sfp_i2c -i11 -s <PLOAM密码>` | 硬件注册路径 |

**为什么必须三处都写**：多数改版固件的 LuCI「保存&应用」**只写 UCI + EEPROM，从不写 uboot env**；而启动时 `config_onu.sh load` 会**用 uboot env 覆盖 UCI**。结果就是——运行时一切正常，**一重启就退回旧身份**。

⚠️ `fw_setenv` 的值**含空格时必须加引号**，否则 shell 只会传第一个 token：
```bash
fw_setenv nPassword "0x61 0x32 0x34 0x30 0x33 0x36 0x35 0x34 0x36 0x33"   # ← 引号必须有
```
（PLOAM 密码要转成十进制 ASCII 的 hex 串；`xxd -r` 可以把 hex 转回明文核对）

### 3. 验收「持久化」（唯一可靠的验收方式）
```bash
fw_setenv nSerial <SN>; fw_setenv nPassword "<HEX>"
uci set gpon.onu.nSerial=<SN>; uci set gpon.onu.ploam_password=<PLAIN>; uci commit gpon
/opt/lantiq/bin/sfp_i2c -i8 -s <SN>; /opt/lantiq/bin/sfp_i2c -i11 -s <PLAIN>
sync
# 然后【断电重启】，回来检查：
onu ploamsg          # 期望 curr_state=5
fw_printenv nSerial  # 期望仍是新 SN
onu gtcpg            # 期望 password=<新密码>
```
**重启后仍然对，才算配好。** 只看运行时状态不算。

### 4. VLAN 业务通道（ME171）
ONT 的 Extended VLAN config（ME171）不配默认 PVID，untagged 帧会被丢弃 → **连 PADO 都回不来**：
```bash
uci set gpon.onu.uvlan=41          # 默认 PVID
uci set gpon.onu.iopmask=1
uci commit gpon
/etc/init.d/iop.sh restart          # 只重启 vlanexec，不动 PON 注册
cat /tmp/me171_rule                 # 期望含 ...00 0f 80 00 00 00 <VLANID>
```
> 规则里 `<VLANID>` 是 `PVID*8+4` 的十六进制形式（41 → 0x014c → `01 4c`）。

### 5. 路由器侧 PPPoE
| 参数 | 值 | 说明 |
|---|---|---|
| 上网方式 | PPPoE 拨号 | |
| 账号 | `<宽带账号>` | 从原光猫 WAN 页读，通常是 `手机号@139.gd` |
| 密码 | `<PPPoE密码>` | 运营商短信/App 重置后拿到 |
| **VLAN 模式** | **UNTAG** | 猫棒 `uvlan` 负责打 tag，**下挂设备不要再打 tag**（双重 tag 必失败） |
| MTU | 1492 | |
| NAT | 启用 | |

### 6. 验证
路由器后台 WAN 连接显示「已连接」并拿到 IP 即可。

---

## 三条铁律（都是踩过的坑）

**① 动手前先建立观测能力，再改配置。**
先能抓包、再能看日志，最后才动手。`tcpdump -i <if> -e 'ether proto 0x8863 or ether proto 0x8864'` 抓 PPPoE，能一次看清：PADI/PADO 是否通、LCP 是否协商、**谁先发的 PADS**。本次一个卡了 9 小时的故障，抓包 3 分钟就定位了。

**② 不要用 macOS 自带 pppd 验证运营商级协议。**
用路由器。若一定要在 Mac 上验证，注意两个坑：
- pppd 详细日志：写 `~/.ppprc` 只含一行 `debug`，日志走 SystemConfiguration 的 `Logfile`（`/var/log/ppp.log`）。
- ⚠️ **`~/.ppprc` 里的 `logfile` 指向 `/tmp` 会被 pppd 以 root 创建，普通用户之后删不掉**，它会静默卡死 pppd（表现为「连 PADI 都不发」）。排查前先 `ls -l` 确认文件属主。

**③ 变量一次只改一个，每次改动都可逆。**
- 随手勾选「强制创建默认PVID / 强制设置ME规则」这类开关，会让 ME171 规则与 `uvlan` **互相覆盖**，把本来通的 PADO 都弄丢。
- 改系统配置前先备份；`route change default` 若表里已有两条 default 会报 `Address already in use`，要用 `route delete default && route add default <gw>`。

---

## 症状速查表（完整版见 `references/troubleshooting.md`）

| 现象 | 最可能原因 | 下一步 |
|---|---|---|
| `onu ploamsg` 的 `curr_state` 不是 5 | 身份没写进 uboot env，冷启动被旧值覆盖 | 三处写入 + 重启验证 |
| O5 正常但**收不到 PADO** | ME171 没配默认 PVID / `force*` 开关互相覆盖 | 查 `/tmp/me171_rule`，只保留 `uvlan` |
| 收到 PADO、**LCP 零回应** | 客户端不兼容 BRAS 报文乱序 | **换路由器拨号**，别调密码 |
| 拨得上但**认证不通过** | 密码错 / 认证协议不匹配 | 路由器后台看 691(密码错) / 651(不通) |
| 交换机上设备**互相看不见** | 端口隔离 | 隔离口 ↔ 上行口才通 |
| 重启后配置全丢 | 只改了 UCI/EEPROM | 补 `fw_setenv` |

---

## 脚本

```bash
# 体检：一次性检查 PON 状态 / 三处身份一致性 / VLAN 规则
scripts/ont_health_check.sh --host 192.168.1.10 --user root

# 写入身份并提示重启验收（会改设备，先备份！）
scripts/persist_identity.sh --host 192.168.1.10 --user root \
    --serial <SN> --ploam-password <明文> --pvid 41
```

## 参考资料

- `references/firmware-internals.md` —— 猫棒固件内部机制（uboot env / config_onu.sh / ME171 / vlanexec）
- `references/backend-profiles.md` —— 路由器后台协议与页面结构（含 ZTE/RAISECOM 系明文登录逆向）
- `references/troubleshooting.md` —— 完整症状→根因对照表
- `references/benchmarking.md` —— 带宽/延迟基准测试方法与端口规则
- `docs/case-study-2026-11-10.md` —— 完整实战复盘（已脱敏）

## 免责声明

替换运营商光猫通常违反宽带服务条款，且可能影响运营商侧设备绑定与远程运维配置。请先确认你的宽带允许第三方 ONT 接入，保留原光猫断电作备份。本 skill 仅用于个人技术学习与自有线路排障。
