#!/usr/bin/env bash
#
# backup-workflows.sh
#
# export workflow ทั้งหมดจาก n8n ลงโฟลเดอร์ workflows/ แล้ว commit ให้อัตโนมัติ
# ใช้แทน Source Control ของ n8n ที่เป็นฟีเจอร์แบบเสียเงิน (Community Edition ไม่มี)
#
# ต้องรันบนเครื่องที่ n8n container ทำงานอยู่ (VPS) และมี repo นี้ clone ไว้
#
#   ./backup-workflows.sh              export + commit
#   ./backup-workflows.sh --push       export + commit + push ขึ้น GitHub
#   ./backup-workflows.sh --dry-run    export มาดูเฉยๆ ไม่ commit
#
# ถ้า repo นี้ถูก clone ไว้เป็นโฟลเดอร์ย่อยของ deployment จริง (เช่น
# /docker/ferment-agent/repo/) docker compose project name ที่เดาจาก
# basename จะไม่ตรงกับของจริง (ferment-agent) ตั้งค่าเองได้ด้วย:
#   COMPOSE_PROJECT_NAME=ferment-agent ./backup-workflows.sh
# (ค่า default คือ ferment-agent อยู่แล้ว ปกติไม่ต้องตั้งเอง)
#
# ตั้ง cron ให้ backup ทุกวันตี 3:
#   0 3 * * * /docker/ferment-agent/repo/backup-workflows.sh --push >> /var/log/n8n-backup.log 2>&1
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$REPO_ROOT/workflows"
N8N_SERVICE="${N8N_SERVICE:-n8n}"
# ชื่อ compose project ของ stack ที่รันอยู่จริง — ถ้า repo นี้ถูก clone ไว้เป็น
# โฟลเดอร์ย่อยของ deployment จริง (เช่น /docker/ferment-agent/repo/) ชื่อ
# project ที่ docker compose เดาจาก basename ของโฟลเดอร์นี้จะไม่ตรงกับของจริง
# ระบุตรงๆ กันพลาด
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-ferment-agent}"
DC=(docker compose -p "$COMPOSE_PROJECT_NAME")
# โฟลเดอร์ชั่วคราวใน container (ไม่ยุ่งกับ /files ที่ mount ไว้ใช้งานอย่างอื่น)
TMP_IN_CONTAINER="/tmp/n8n-export-$$"

DO_COMMIT=1
DO_PUSH=0

while [ $# -gt 0 ]; do
  case "$1" in
    --push)    DO_PUSH=1 ;;
    --dry-run) DO_COMMIT=0 ;;
    -h|--help) sed -n '3,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ไม่รู้จัก option: $1 (ดู --help)" >&2; exit 2 ;;
  esac
  shift
done

cd "$REPO_ROOT"

# ---- ตรวจสภาพแวดล้อมก่อน -------------------------------------------------
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "ผิดพลาด: $REPO_ROOT ไม่ใช่ git repo" >&2; exit 1; }

docker compose version >/dev/null 2>&1 \
  || { echo "ผิดพลาด: ไม่พบ 'docker compose' บนเครื่องนี้" >&2; exit 1; }

"${DC[@]}" ps --status running --services 2>/dev/null | grep -qx "$N8N_SERVICE" \
  || { echo "ผิดพลาด: ไม่พบ service '$N8N_SERVICE' ที่รันอยู่ใน compose project '$COMPOSE_PROJECT_NAME' (ลอง: docker compose up -d หรือกำหนด COMPOSE_PROJECT_NAME ให้ตรงกับของจริง)" >&2; exit 1; }

# ---- export ออกมาก่อน ----------------------------------------------------
# เขียนลง /tmp ใน container ก่อน แล้วค่อย copy ออก ถ้า export พังจะได้ไม่ไป
# แตะไฟล์เดิมใน repo เลย
cleanup() { "${DC[@]}" exec -T "$N8N_SERVICE" rm -rf "$TMP_IN_CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> export workflow จาก n8n ..."
"${DC[@]}" exec -T "$N8N_SERVICE" \
  n8n export:workflow --all --separate --output="$TMP_IN_CONTAINER"

COUNT="$("${DC[@]}" exec -T "$N8N_SERVICE" \
  sh -c "ls -1 $TMP_IN_CONTAINER/*.json 2>/dev/null | wc -l" | tr -d '[:space:]')"

if [ "${COUNT:-0}" -eq 0 ]; then
  echo "ผิดพลาด: export ไม่ได้ไฟล์เลย — ยกเลิก ไม่แตะไฟล์เดิมใน repo" >&2
  exit 1
fi
echo "    ได้ $COUNT workflow"

# ---- ย้ายเข้า repo -------------------------------------------------------
# ล้างของเดิมทิ้งก่อน เพื่อให้ workflow ที่ถูกลบใน n8n หายไปจาก repo ด้วย
# (ทำตรงนี้เพราะ export สำเร็จแล้ว ถึงจุดนี้ข้อมูลใหม่อยู่ในมือแน่นอน)
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/*.json
"${DC[@]}" cp "$N8N_SERVICE:$TMP_IN_CONTAINER/." "$OUT_DIR/"

if [ "$DO_COMMIT" -eq 0 ]; then
  echo "==> --dry-run: ข้ามการ commit"
  git status --short -- "$OUT_DIR"
  exit 0
fi

# ---- commit เฉพาะเมื่อมีอะไรเปลี่ยนจริง ----------------------------------
git add -A -- "$OUT_DIR"

if git diff --cached --quiet -- "$OUT_DIR"; then
  echo "==> ไม่มี workflow ไหนเปลี่ยน ไม่ต้อง commit"
  exit 0
fi

git commit -q -m "Backup n8n workflows ($COUNT workflows) - $(date '+%Y-%m-%d %H:%M')" -- "$OUT_DIR"
echo "==> commit แล้ว: $(git log --oneline -1)"

if [ "$DO_PUSH" -eq 1 ]; then
  echo "==> push ขึ้น remote ..."
  git push
  echo "==> เรียบร้อย"
fi
