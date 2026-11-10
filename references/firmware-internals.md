# 猫棒固件内部机制（Lantiq Falcon / OpenWRT 7.5.3 系）

适用：Nokia G-010S-A / G-010S-P、Huawei MA5671A、ODI HSGQ 等刷了 Lantiq OpenWRT 改版固件的 SFP 形态 ONT。

## 1. 三层身份模型（最重要的一张图）

```
        ┌──────────────────────────────────────────┐
uboot   │ nSerial / nPassword / omci_loid / ...    │  ← 权威源（启动时覆盖 UCI）
env     └──────────────────────────────────────────┘
            │  config_onu.sh load
            ▼
UCI     ┌──────────────────────────────────────────┐
gpon.onu│ nSerial / ploam_password / uvlan / ...    │  ← LuCI 显示层 + init 的输入
        └──────────────────────────────────────────┘
            │  config_onu.sh set / init
            ▼
EEPROM  ┌──────────────────────────────────────────┐
(SFP A2)│ i8=SN  i11=PLOAM密码  i6/i7=Equipment/Vendor │ ← 硬件注册路径
        └──────────────────────────────────────────┘
            │  sfp_i2c -g（读回）
            ▼
硬件    ┌──────────────────────────────────────────┐
PON    │ PLOAM 注册用 SN + PLOAM 密码                │
        └──────────────────────────────────────────┘
```

**记住一句话**：`fw_printenv` 是权威源，`uci` 是显示层，EEPROM 是硬件层。三处不一致时，**冷启动后以 uboot env 为准**。

## 2. `config_onu.sh` 命令全解

路径：`/opt/lantiq/bin/config_onu.sh`（由 `iop.sh` 经 procd 拉起）

| 命令 | 作用 | 写 uboot env？ | 写 EEPROM？ |
|---|---|---|---|
| `load` | 从 uboot env 读取 → 灌进 UCI | 读 | 否 |
| `set` | 从 UCI 读取 → 写 EEPROM + 回写 UCI | **否** | 是（i6/i7/i8/i9/i10/i11） |
| `init` | 从 UCI 读取 → **无条件**写 EEPROM（omcid 启动前调用） | 否 | 是 |
| `setip` | 同步 LAN/网关/HOST MAC，其中 **HOST MAC 会 `fw_setenv ethaddr`** | **是（仅 ethaddr/ipaddr/gatewayip）** | 否 |
| `update` | 更新 GOI 标定数据 | 是（goi_config） | 否 |
| `mod` / `restore` | 改 / 还原 omcid 版本字符串 | 否 | 改二进制 |
| `disable` | 打 RX_LOS 驱动补丁 | 否 | 改内核模块 |
| `ignore` | 让 ONU 忽略 PLOAM Rx loss | 否 | 运行时 |
| `rebootcause` / `rebootnum` / `reboot` | 重启原因 / 次数 / 延迟重启 | 是 | 否 |
| `switch` | 切换启动分区（A/B image） | 是（committed_image / next_active） | 否 |
| `switchasc` / `initasc` | 开关 TTL 串口控制台 | 是（asc0） | 否 |
| `factoryreset` | 清空 EEPROM 身份 + 恢复默认网参 | 是 | 是 |

> 🔴 **LuCI 的「保存&应用」只调用 `set`/`mod`/`disable`/`ignore`/`reboot`/`switchasc` + 重启 `iop.sh`/`monitomcid`/`monitoptic`，从不调用任何写 nSerial/nPassword 到 uboot env 的路径。**
> 所以「在 LuCI 里改了 SN/PLOAM」= 只写了 UCI + EEPROM = **重启即回滚**。

## 3. 启动顺序（`/etc/init.d/onu.sh`）

```
START=61
ploam_config()  →  nSerial = sfp_i2c -g        (EEPROM 优先)
                            fallback: fw_printenv nSerial
                →  onu ploam_init ; onu gtcsns <nSerial>
gtc_config()    →  nPassword = fw_printenv nPassword   (uboot env 唯一来源)
                →  onu gtccs ... $nPassword
gpei / phy11g / ... →  GPE 硬件初始化
config_onu.sh ignore
```

**注意这个不对称**：SN 优先读 EEPROM，PLOAM 密码**只**读 uboot env。所以：
- SN 改了 EEPROM 不生效 → 还要改 uboot env（因为 `load` 会把 UCI 的值灌回去，再由 `init` 写 EEPROM）
- PLOAM 密码**必须**改 uboot env

## 4. `vlanexec.sh` 与 ME171 规则表

路径：`/opt/lantiq/bin/vlanexec.sh`（`iop.sh` 拉起，procd 管理）

UCI 参数（`gpon.onu.*`）：

| 参数 | 含义 |
|---|---|
| `iopmask` | 互操作兼容模式开关（多数功能的前置） |
| `uvlan` | **默认 PVID**：给 untagged 帧打上该 VLAN；填 `u` 表示 untag→untag 透传 |
| `forceuvlan` | 「强制创建默认PVID」：PVID 不生效时勾选 |
| `forcemerule` | 「强制设置ME规则」：O5 了却拨不通时勾选 |
| `tvlan` | VLAN 转换/绑定，格式如 `2:41,3:43,4:u,5:44@5`（用户侧:网络侧[:优先级]） |
| `mvlan` / `mvlansource` | 下行组播 VLAN 转换（IPTV 用，非 IPTV 留空） |
| `mtvlan` | 启用 N:1 VLAN 转换模式 |
| `vlandebug` | 打开 VLAN 脚本日志（排查必开） |
| `forceme309` | 强制创建 ME309 规则（IPoE 组播异常时） |
| `mib_customized` | 自定义 MIB（可导致无限重启，慎用） |

关键函数：
- `extendvlan()` —— 从 MIB 读 ME171 实例号
- `me171rulecheck()` —— 期望的**默认规则**（华为 OLT 分支）：
  ```
  f8 00 00 00 e8 00 00 00 00 0f 00 00 00 0f 00 00   (single tag)
  e8 00 00 00 e8 00 00 00 00 0f 00 00 00 0f 00 00   (double tag)
  ```
- `uvlanset()` —— 下发 `uvlan` 规则（`PVID*8+4` 的 hex）：
  ```
  PVID=41 → match171 = f8 00 00 00 f8 00 00 00 00 0f 80 00 00 00 01 4c
  ```
- `/tmp/me171_rule` —— 当前规则表快照，排查时直接看

> ⚠️ `forcemerule` 与 `uvlan` 会**互相覆盖**：主循环里 `meruleset`（跑 me171rulecheck）和 `uvlanset` 依次执行，且每轮循环都会跑。**同时开启会让规则在两套之间反复横跳，把本来通的 PADO 都弄丢。排查期只保留 `uvlan`。**

## 5. 常用命令速查

```bash
export PATH=/usr/sbin:/opt/lantiq/bin:/sbin:/bin:/usr/bin:$PATH

onu ploamsg              # PON 状态：curr_state=5 即 O5
onu gtcpg                # 当前生效的 PLOAM 密码
onu gtcsng               # 当前生效的 SN
fw_printenv nSerial      # uboot env 里的 SN（权威）
fw_printenv nPassword    # uboot env 里的 PLOAM 密码（hex 串）
sfp_i2c -g               # 读 EEPROM 里的身份
cat /tmp/me171_rule       # 当前 ME171 规则
cat /tmp/collect          # 采集到的 OLT 类型 / ME171 实例 / 桥端口信息
ps w | grep vlanexec     # 确认 vlanexec 在跑
/etc/init.d/iop.sh restart# 只重启 vlanexec（不动 PON 注册）
```

## 6. 固件/仓库线索（找同类源码最有效）

GitHub 上有几个**完整固件 dump 仓库**，直接读源码比看二手教程准确得多：

- `furkankadirguzeloglu/SFPFirmwareDumps` —— 含 Nokia G-010S-A / Huawei MA5671A / Alcatel G-010S-P 的 **Right.Com.Cn 改版固件 squashfs-root**
- `MrLenin/8311-lantiq-firmware` —— 8311 社区改版固件
- `typefe/home-lab` 的 `gpon-sfp-ont-replacement.md` —— 英文实战手册，Step 5 专门讲「fw_setenv 后必须重启验证」

搜源码的关键字：`config_onu.sh`、`me171rulecheck`、`uvlanset`、`gtccs`、`ploam_config`。

## 7. A/B 双分区

固件有两个 image 分区（`image0` / `image1`，`mtd` 里各 6MB）。`config_onu.sh switch` 会切分区。
**排查「重启后配置全丢」时，先确认当前跑的是哪个分区**（`fw_printenv | grep -i image`、`cat /proc/mtd`）——如果固件更新时切了分区，配置可能落在另一个 image 的环境里。
