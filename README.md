# ponstick-gpon-bridge

**用 GPON SFP 猫棒（PON stick）替代运营商光猫，自己接管宽带接入。**

把 `Nokia G-010S-A` / `Huawei MA5671A` / `ODI HSGQ` 这类 SFP 形态的 ONT 插进交换机或路由器的 SFP+ 口，
让它只做**光电转换 + 二层桥接**，由你自己的一台路由器做 **PPPoE 拨号**——摆脱运营商光猫的路由限制、
TR069 远程管控与设备绑定。

---

## 这个 skill 解决什么

网上教程大多只讲「怎么填 SN 让它注册上」，但真正卡住人的是后面这几件事，本 skill 全部覆盖：

| 痛点 | 本 skill 的答案 |
|---|---|
| 配好了，一重启就退回旧身份 | **身份三处写入**（uboot env + UCI + EEPROM），并以「断电重启后仍为新值」为验收标准 |
| 注册上 O5，但收不到 PADO | **ME171 / `uvlan` 默认 PVID** 规则怎么算、为什么 `force*` 开关会互相覆盖 |
| PADO 有了，LCP 零回应 | **某些 BRAS 报文乱序会让 macOS pppd 自己拆会话** —— 这跟密码无关，换路由器即可 |
| 换了口设备就互相看不见 | **带端口隔离的交换机**该怎么接线 |
| 后台点不动 | **ZTE/RAISECOM 系后台的明文登录协议与页面结构**（可脚本化） |
| 不知道是不是宽带没跑满 | **多路并发测速方法** + 「WiFi 才是真凶」的识别方式 |

---

## 快速开始

```bash
# 1) 体检：PON 状态 / 三处身份是否一致 / VLAN 规则
scripts/ont_health_check.sh --host <ONT_IP> --user root

# 2) 写入身份（先备份！脚本会提示重启验收）
scripts/persist_identity.sh --host <ONT_IP> --user root \
    --serial <GPON_SN> --ploam-password '<PLOAM_PASSWORD>' --pvid 41
```

## 目录

```
SKILL.md                          skill 主文件：角色分工、执行顺序、三条铁律、症状速查
references/
  firmware-internals.md           猫棒固件内部机制（uboot env / config_onu.sh / ME171 / vlanexec）
  backend-profiles.md             路由器后台协议逆向（明文登录、页面结构、WAN 表单控件）
  troubleshooting.md              分层排障：L0 物理 → L7 取址 的症状→根因对照表
  benchmarking.md                带宽/延迟基准测试方法
scripts/
  ont_health_check.sh             猫棒状态体检（只读）
  persist_identity.sh            身份三处写入 + 重启验收指引
docs/
  case-study-2026-11-10.md       完整实战复盘（已脱敏），含 14.5 小时的时间账单
```

## 核心流程（TL;DR）

```
光纤 ──► 猫棒(SFP+ 口) ──► 交换机 ──► 路由器 WAN (PPPoE 拨号) ──► 你的设备
```

1. **备份**：`fw_printenv > backup.txt` + 备份 `/etc/config`
2. **身份三处写入**：`fw_setenv`（权威源）/ `uci` / `sfp_i2c`（EEPROM）
3. **断电重启，验收**：`onu ploamsg` = 5、`fw_printenv nSerial` 仍是新值、`onu gtcpg` 密码已生效
4. **配 VLAN**：`gpon.onu.uvlan=<PVID>`，并**只保留这一项**（关掉 `forceuvlan`/`forcemerule`）
5. **路由器 PPPoE**：账号/密码/**VLAN 模式 UNTAG**/MTU 1492/NAT 开启
6. **验证**：路由器后台显示「已连接」并拿到 IP
7. **测速**：8~16 路并发，单连接会被源站限流

## 免责声明

替换运营商光猫通常违反宽带服务条款，并可能影响运营商侧的设备绑定与远程运维配置。
请自行确认你的宽带允许第三方 ONT 接入，**保留原光猫断电作备份**。
本项目仅用于个人技术学习与自有线路排障。
