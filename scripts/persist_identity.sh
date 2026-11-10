#!/bin/sh
# persist_identity.sh —— 把 GPON 身份写入猫棒的【三处】并提示重启验收
#
#   1) uboot env   (fw_setenv nSerial / nPassword)   ← 权威源
#   2) UCI         (gpon.onu.nSerial / ploam_password)
#   3) EEPROM      (sfp_i2c -i8 / -i11)
#
# 少写任何一处，冷启动都会被 uboot env 里的旧值覆盖。
#
# 用法:
#   ./persist_identity.sh --host 192.168.1.10 --user root \
#       --serial CIOT04XXXXXXXX --ploam-password '1234567890' [--pvid 41]
#
# ⚠️ 会修改设备配置。请先自行备份（fw_printenv > fw_printenv_backup.txt）。

set -eu

HOST="192.168.1.10"
USER="root"
PASS="${ONT_PASS:-}"
PORT=22
SERIAL=""
PLOAM=""
PVID=""
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --host)          HOST="$2"; shift 2 ;;
    --user)          USER="$2"; shift 2 ;;
    --password)      PASS="$2"; shift 2 ;;
    --port)          PORT="$2"; shift 2 ;;
    --serial)        SERIAL="$2"; shift 2 ;;
    --ploam-password) PLOAM="$2"; shift 2 ;;
    --pvid)          PVID="$2"; shift 2 ;;
    --dry-run)       DRY=1; shift ;;
    -h|--help)       sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

[ -n "$SERIAL" ] || { echo "缺少 --serial" >&2; exit 1; }
[ -n "$PLOAM" ]  || { echo "缺少 --ploam-password" >&2; exit 1; }

# 明文 -> 十进制 ASCII 的 hex 串（fw_setenv 需空格分隔的 hex）
HEX=$(printf '%s' "$PLOAM" | od -An -tx1 -v | tr -s ' ' | sed 's/^ //; s/ $//')

echo "== 目标 =="
echo "   SN        : $SERIAL"
echo "   PLOAM 明文: $PLOAM"
echo "   PLOAM hex : $HEX"
[ -n "$PVID" ] && echo "   PVID      : $PVID"
echo

# 远端脚本
REMOTE=$(cat <<EOF
set -e
export PATH=/usr/sbin:/opt/lantiq/bin:/sbin:/bin:/usr/bin:\$PATH
echo "--- 写入前 ---"
fw_printenv nSerial 2>/dev/null || true
fw_printenv nPassword 2>/dev/null || true
uci -q get gpon.onu.nSerial || true
uci -q get gpon.onu.ploam_password || true
sfp_i2c -g 2>&- | head -3

echo "--- 1/3 写 uboot env（权威源，值含空格必须加引号）---"
fw_setenv nSerial "$SERIAL"
fw_setenv nPassword "$HEX"

echo "--- 2/3 写 UCI ---"
uci set gpon.onu.nSerial="$SERIAL"
uci set gpon.onu.ploam_password="$PLOAM"
$( [ -n "$PVID" ] && echo "uci set gpon.onu.uvlan=$PVID" )
uci set gpon.onu.iopmask=1
uci commit gpon

echo "--- 3/3 写 EEPROM ---"
/opt/lantiq/bin/sfp_i2c -i8 -s "$SERIAL"
/opt/lantiq/bin/sfp_i2c -i11 -s "$PLOAM"
sync

echo "--- 写入后（重启前自检）---"
fw_printenv nSerial
fw_printenv nPassword
uci -q get gpon.onu.nSerial
uci -q get gpon.onu.ploam_password
sfp_i2c -g 2>&- | head -3
EOF
)

if [ "$DRY" = "1" ]; then
  echo "[DRY-RUN] 将执行的远端脚本："
  echo "$REMOTE"
  exit 0
fi

run() {
  if [ -n "$PASS" ] && command -v sshpass >/dev/null 2>&1; then
    sshpass -p "$PASS" ssh -p "$PORT" -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null "$USER@$HOST" "$REMOTE"
  else
    ssh -p "$PORT" -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null "$USER@$HOST" "$REMOTE"
  fi
}

run

cat <<EOT

================ 下一步（必做）================
1) 先备份：
     fw_printenv > fw_printenv_backup.txt
     tar czf ponstick-backup-\$(date +%Y%m%d).tar.gz /etc/config 2>/dev/null
2) 【断电重启】猫棒（拔插 SFP 模块最直接）
3) 重启后回来跑 ont_health_check.sh 验收：
     - onu ploamsg 的 curr_state == 5
     - fw_printenv nSerial 仍是 $SERIAL
     - onu gtcpg 的 password == $PLOAM
   三项都对，才算真的持久化成功。
4) 若 curr_state 不是 5：
     - 检查 SN/PLOAM 是否与原光猫完全一致（大小写、字符集）
     - 确认 PLOAM 密码没有多余空格或引号被吞
     - 猫棒管理口不通 => 先解决物理层（SFP 是否插紧、交换机口是否供电）
EOT
