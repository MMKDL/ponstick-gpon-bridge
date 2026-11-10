#!/bin/sh
# ont_health_check.sh —— 猫棒(PON stick)状态体检
#
# 一次性检查：PON 注册状态 / 三处身份是否一致 / VLAN(ME171) 规则 / 关键进程
# 只读，不修改任何配置。
#
# 用法:
#   ./ont_health_check.sh --host 192.168.1.10 --user root
#   ./ont_health_check.sh --host 192.168.1.10 --user root --password 'xxx'
#   ONT_PASS=xxx ./ont_health_check.sh --host 192.168.1.10
#
# 需要 ssh/sshpass（无 sshpass 时请用 --ask 交互输入）

set -eu

HOST="192.168.1.10"
USER="root"
PASS="${ONT_PASS:-}"
ASK=0
PORT=22

while [ $# -gt 0 ]; do
  case "$1" in
    --host)     HOST="$2"; shift 2 ;;
    --user)     USER="$2"; shift 2 ;;
    --password) PASS="$2"; shift 2 ;;
    --port)     PORT="$2"; shift 2 ;;
    --ask)      ASK=1; shift ;;
    -h|--help)  sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

# ---- 构造远端命令 ----
REMOTE='
export PATH=/usr/sbin:/opt/lantiq/bin:/sbin:/bin:/usr/bin:$PATH
echo "### PON 状态"
onu ploamsg 2>/dev/null
echo "### 生效中的身份（硬件层）"
onu gtcsng 2>/dev/null
onu gtcpg 2>/dev/null
echo "### uboot env（权威源）"
fw_printenv nSerial 2>/dev/null
fw_printenv nPassword 2>/dev/null
echo "### UCI"
uci -q get gpon.onu.nSerial
uci -q get gpon.onu.ploam_password
uci -q get gpon.onu.uvlan
uci -q get gpon.onu.iopmask
for f in forceuvlan forcemerule vlandebug mtvlan mib_customized; do
  v=$(uci -q get gpon.onu.$f 2>/dev/null || true)
  [ -n "$v" ] && echo "$f=$v"
done
echo "### EEPROM"
sfp_i2c -g 2>&- | head -3
echo "### VLAN 规则"
cat /tmp/me171_rule 2>/dev/null || echo "(无 /tmp/me171_rule)"
echo "### 采集信息"
cat /tmp/collect 2>/dev/null
echo "### 进程"
ps w 2>/dev/null | grep -E "vlanexec|omcid" | grep -v grep
'

# ---- 执行 ----
if [ "$ASK" = "1" ]; then
  ssh -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$USER@$HOST" "$REMOTE"
elif command -v sshpass >/dev/null 2>&1 && [ -n "$PASS" ]; then
  sshpass -p "$PASS" ssh -p "$PORT" -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null "$USER@$HOST" "$REMOTE"
else
  echo "提示: 未提供密码，将尝试免密或交互登录" >&2
  ssh -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$USER@$HOST" "$REMOTE"
fi

cat <<'EOT'

================ 判读要点 ================
1) onu ploamsg 的 curr_state 必须 = 5 (O5)。否则先查身份。
2) 三处身份（uboot env / UCI / EEPROM）应一致：
   - 不一致 => 冷启动会按 uboot env 覆盖，必须三处重写。
3) 生效身份(onu gtcpg)若仍是旧密码 => 说明 uboot env 没改成功。
4) uvlan 应等于你的上网 VLAN；/tmp/me171_rule 里应含对应规则
   (PVID*8+4 的 hex，如 PVID=41 => 01 4c)。
5) forceuvlan / forcemerule 同时存在会互相覆盖规则，排查期应全部关闭。
6) vlanexec.sh 与 omcid 进程必须在。
EOT
