#!/usr/bin/env bash
#
# clear-data.sh
#
# เคลียร์ข้อมูลทดสอบทั้งหมดใน Postgres ให้กลับไปเป็น DB ว่างเปล่า สำหรับเริ่ม
# รอบทดสอบใหม่ (ใช้ระหว่าง dev/test เท่านั้น — ไม่ใช่สำหรับ production data จริง)
#
# ค่า default รันจากเครื่อง local โดย ssh ไปเคลียร์บน VPS ให้ (ต้องมี ssh
# alias/host ชื่อ "ferment-vps" ตั้งไว้ใน ~/.ssh/config หรือระบุเองผ่าน
# REMOTE_HOST) ถ้ากำลัง login อยู่บน VPS เองอยู่แล้วให้ใช้ --local แทน
#
#   ./clear-data.sh                      ssh ไปเคลียร์บน VPS (ferment-vps) ถามยืนยันก่อน
#   ./clear-data.sh --yes                เหมือนบนแต่ไม่ถามยืนยัน (ใช้ตอน automate)
#   ./clear-data.sh --local              รันตรงบนเครื่องนี้เลย (ใช้ตอน login อยู่บน VPS แล้ว)
#   REMOTE_HOST=other-host ./clear-data.sh   ระบุ ssh host เอง (ค่า default: ferment-vps)
#
# สิ่งที่ทำ:
#   1. TRUNCATE ตารางข้อมูลทั้งหมด (devices, batches, pill_readings,
#      temp_controller_readings, phase_log, control_log) พร้อม RESTART IDENTITY
#      (ตาราง bot_state ไม่ถูก TRUNCATE เพราะต้องคุม cursor เอง ดูข้อ 2)
#   2. reset bot_state.last_discord_message_id เป็น Discord snowflake ของเวลา
#      ปัจจุบัน (ไม่ใช่ '0') — กัน Discord Command Intake (ถ้ายัง publish อยู่)
#      replay ข้อความเก่าทั้งหมดในแชทซ้ำหลังเคลียร์ (ดู README ข้อ 8.3/8.5)
#
# ลำดับหลังเคลียร์แล้ว (ดู README ข้อ 14 Quick Start):
#   1. รัน "Sync Devices" ใน n8n
#   2. เช็คว่า Pill จับคู่ (pair) กับ Controller ไว้แล้วในแอป RAPT
#   3. ลงทะเบียน batch ใหม่ผ่าน /ferment_start
#
set -euo pipefail

PG_SERVICE="${PG_SERVICE:-postgresql}"
POSTGRES_USER="${POSTGRES_USER:-root}"
POSTGRES_DB="${POSTGRES_DB:-rapt}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-ferment-agent}"
REMOTE_HOST="${REMOTE_HOST:-ferment-vps}"
REMOTE_DIR="${REMOTE_DIR:-/docker/ferment-agent}"

RUN_LOCAL=0
CONFIRM=1
while [ $# -gt 0 ]; do
  case "$1" in
    --local)   RUN_LOCAL=1 ;;
    --yes|-y)  CONFIRM=0 ;;
    -h|--help) sed -n '3,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ไม่รู้จัก option: $1 (ดู --help)" >&2; exit 2 ;;
  esac
  shift
done

DC_CMD="docker compose -p '$COMPOSE_PROJECT_NAME'"

# ---- เลือกว่าจะรันคำสั่งตรงๆ (--local) หรือ ssh ไปรันที่ VPS (ค่า default) ----
if [ "$RUN_LOCAL" -eq 1 ]; then
  remote_exec() { bash -c "$1"; }
else
  command -v ssh >/dev/null 2>&1 \
    || { echo "ผิดพลาด: ไม่พบ ssh บนเครื่องนี้ (หรือใช้ --local ถ้ากำลังอยู่บน VPS แล้ว)" >&2; exit 1; }
  remote_exec() { ssh -n "$REMOTE_HOST" "cd '$REMOTE_DIR' && $1"; }
fi

# ---- เช็คว่าเจอ postgres service ที่รันอยู่จริงก่อน --------------------------
remote_exec "$DC_CMD ps --status running --services" 2>/dev/null | grep -qx "$PG_SERVICE" \
  || {
    if [ "$RUN_LOCAL" -eq 1 ]; then
      echo "ผิดพลาด: ไม่พบ service '$PG_SERVICE' ที่รันอยู่ใน compose project '$COMPOSE_PROJECT_NAME' บนเครื่องนี้" >&2
    else
      echo "ผิดพลาด: ไม่พบ service '$PG_SERVICE' ที่รันอยู่บน '$REMOTE_HOST' (เช็ค ssh host/REMOTE_DIR หรือลอง --local ถ้ากำลัง login อยู่บน VPS แล้ว)" >&2
    fi
    exit 1
  }

if [ "$CONFIRM" -eq 1 ]; then
  TARGET_DESC="DB '$POSTGRES_DB'"
  [ "$RUN_LOCAL" -eq 1 ] || TARGET_DESC="$TARGET_DESC บน '$REMOTE_HOST'"
  echo "จะ TRUNCATE ตาราง devices, batches, pill_readings, temp_controller_readings, phase_log, control_log ทั้งหมดใน $TARGET_DESC (แก้คืนไม่ได้)"
  read -r -p "พิมพ์ 'yes' เพื่อยืนยัน: " ans
  [ "$ans" = "yes" ] || { echo "ยกเลิก"; exit 0; }
fi

# Discord snowflake ของเวลาปัจจุบัน — ใช้เป็น cursor เริ่มต้นให้ bot_state กัน
# replay ข้อความเก่า (ดูเหตุผลใน README ข้อ 8.3)
SNOWFLAKE="$(python3 -c 'import time; print((int(time.time()*1000) - 1420070400000) << 22)')"

SQL="$(cat <<SQLEOF
TRUNCATE TABLE control_log, phase_log, temp_controller_readings, pill_readings, batches, devices RESTART IDENTITY;
UPDATE bot_state SET value = '$SNOWFLAKE' WHERE key = 'last_discord_message_id';
SELECT 'batches' t, count(*) FROM batches
UNION ALL SELECT 'devices', count(*) FROM devices
UNION ALL SELECT 'pill_readings', count(*) FROM pill_readings
UNION ALL SELECT 'temp_controller_readings', count(*) FROM temp_controller_readings
UNION ALL SELECT 'phase_log', count(*) FROM phase_log
UNION ALL SELECT 'control_log', count(*) FROM control_log;
TABLE bot_state;
SQLEOF
)"

echo "==> เคลียร์ข้อมูล ..."
if [ "$RUN_LOCAL" -eq 1 ]; then
  eval "$DC_CMD exec -T '$PG_SERVICE' psql -U '$POSTGRES_USER' -d '$POSTGRES_DB'" <<<"$SQL"
else
  ssh "$REMOTE_HOST" "cd '$REMOTE_DIR' && $DC_CMD exec -T '$PG_SERVICE' psql -U '$POSTGRES_USER' -d '$POSTGRES_DB'" <<<"$SQL"
fi

echo "==> เรียบร้อย DB ว่างหมดแล้ว ลำดับถัดไป: รัน 'Sync Devices' ใน n8n แล้วค่อยลงทะเบียน batch ใหม่ผ่าน /ferment_start (ดู README ข้อ 14)"
