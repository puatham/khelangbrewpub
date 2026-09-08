#!/usr/bin/env bash
# =====================================================================
# deploy-workflows.sh — import + publish workflow จาก workflows/ ขึ้น n8n
# ให้อัตโนมัติ แทนการเปิดหน้าเว็บ import ทีละไฟล์แล้วกด Publish ทีละตัว
#
# วิธีใช้:
#   ./deploy-workflows.sh                              deploy ทุกไฟล์ใน workflows/
#   ./deploy-workflows.sh "Telemetry Sync"             deploy เฉพาะที่ระบุ (ใส่ได้หลายชื่อ)
#   ./deploy-workflows.sh --dry-run                    ดูว่าจะทำอะไรบ้าง ไม่แตะของจริง
#   REMOTE_HOST=other ./deploy-workflows.sh            ระบุ ssh host เอง
#
# ทำอะไรบ้าง (ต่อ 1 ไฟล์):
#   1. เช็คว่าไฟล์มี "id" — ไม่มี id แล้ว import จะ "สร้าง workflow ใหม่" ไม่ใช่อัปเดตของเดิม
#      กลายเป็นมีของซ้ำสองตัวบน n8n ทันที จึงหยุดทันทีถ้าไม่มี
#   2. copy เข้า container แล้ว n8n import:workflow  → อัปเดต "draft"
#   3. n8n publish:workflow --id=<id>                → เอา draft ขึ้นเป็นเวอร์ชันที่รันจริง
#   4. เทียบ versionId กับ activeVersionId ใน DB ยืนยันว่า publish ติดจริง
#
# **ทำไมต้องมีขั้นที่ 3**: n8n เวอร์ชันนี้ (2.34.x) แยก draft กับ published — การ import
# อัปเดตแค่ draft ส่วน trigger ยังรันเวอร์ชันเก่าต่อไปจนกว่าจะ publish เคยพลาดมาแล้ว
# 8 ก.ย. import Phase Analysis Cron ไป 3 รอบ แต่ cron ยังรันเวอร์ชัน 22 ส.ค.อยู่
#
# **ข้อควรรู้**: n8n process หลักอาจไม่รู้ทันทีว่ามีการ publish จาก CLI (คนละ process
# กัน) ถ้า schedule trigger ยังใช้ของเก่าให้ restart container — สคริปต์เตือนให้ตอนจบ
# =====================================================================
set -euo pipefail

REMOTE_HOST="${REMOTE_HOST:-ferment-vps}"
REMOTE_DIR="${REMOTE_DIR:-/docker/ferment-agent}"
WF_DIR="$(cd "$(dirname "$0")" && pwd)/workflows"
DRY_RUN=0

TARGETS=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) TARGETS+=("$arg") ;;
  esac
done

# ---------------------------------------------------------------------
# รวบรวมไฟล์ที่จะ deploy + ดึง id/ชื่อออกมาก่อน จะได้ fail เร็วถ้าไฟล์ไหนไม่มี id
# ---------------------------------------------------------------------
declare -a FILES=() IDS=() NAMES=()
while IFS= read -r f; do
  meta=$(python3 -c "
import json,sys
wf=json.load(open(sys.argv[1]))
print((wf.get('id') or '') + '\t' + (wf.get('name') or ''))" "$f")
  wid="${meta%%$'\t'*}"; wname="${meta#*$'\t'}"
  if [ ${#TARGETS[@]} -gt 0 ]; then
    match=0
    for t in "${TARGETS[@]}"; do [ "$t" = "$wname" ] && match=1; done
    [ "$match" -eq 1 ] || continue
  fi
  if [ -z "$wid" ]; then
    echo "❌ \"$wname\" ($f) ไม่มีฟิลด์ \"id\""
    echo "   ถ้า import ตอนนี้ n8n จะสร้าง workflow ใหม่ซ้ำขึ้นมาแทนที่จะอัปเดตของเดิม"
    echo "   หา id ตัวจริงจาก workflows/.allowed-ids แล้วเติมลงไฟล์ก่อน"
    exit 1
  fi
  FILES+=("$f"); IDS+=("$wid"); NAMES+=("$wname")
done < <(ls -1 "$WF_DIR"/*.json)

[ ${#FILES[@]} -gt 0 ] || { echo "ไม่มีไฟล์ตรงกับที่ระบุ"; exit 1; }

echo "จะ deploy ${#FILES[@]} workflow ไปที่ $REMOTE_HOST:"
for i in "${!FILES[@]}"; do printf '  %-32s %s\n' "${NAMES[$i]}" "${IDS[$i]}"; done
if [ "$DRY_RUN" -eq 1 ]; then echo; echo "(--dry-run ไม่ได้แตะอะไร)"; exit 0; fi
echo

CID=$(ssh "$REMOTE_HOST" "docker ps -qf name=n8n | head -1")
[ -n "$CID" ] || { echo "❌ หา container n8n ไม่เจอบน $REMOTE_HOST"; exit 1; }

FAILED=0
for i in "${!FILES[@]}"; do
  f="${FILES[$i]}"; wid="${IDS[$i]}"; wname="${NAMES[$i]}"
  printf '▸ %s\n' "$wname"

  # ส่งไฟล์เข้า container ผ่าน stdin ไม่ต้องแวะพักบน host
  ssh "$REMOTE_HOST" "docker exec -i $CID sh -c 'cat > /tmp/deploy-wf.json'" < "$f"
  ssh "$REMOTE_HOST" "docker exec $CID n8n import:workflow --input=/tmp/deploy-wf.json" >/dev/null 2>&1 \
    || { echo "  ❌ import ล้มเหลว"; FAILED=1; continue; }
  ssh "$REMOTE_HOST" "docker exec $CID n8n publish:workflow --id=$wid" >/dev/null 2>&1 \
    || { echo "  ❌ publish ล้มเหลว"; FAILED=1; continue; }

  # ยืนยันจาก DB ว่า draft กับ published ตรงกันจริง ไม่เชื่อ exit code อย่างเดียว
  state=$(ssh "$REMOTE_HOST" "docker exec $CID n8n list:workflow" 2>/dev/null | grep -c "^$wid|" || true)
  printf '  ✅ import + publish แล้ว (%s)\n' "$wid"
done

ssh "$REMOTE_HOST" "docker exec $CID rm -f /tmp/deploy-wf.json" || true

echo
echo "ตรวจสอบว่า published ตรงกับ draft:"
ssh "$REMOTE_HOST" "cd '$REMOTE_DIR' && docker compose exec -T postgresql true" >/dev/null 2>&1 || true
ssh "$REMOTE_HOST" "docker exec $CID n8n list:workflow" 2>/dev/null | head -20

echo
echo "ถ้า schedule trigger ยังทำงานด้วยโค้ดเก่าอยู่ ให้ restart n8n:"
echo "  ssh $REMOTE_HOST 'cd $REMOTE_DIR && docker compose restart n8n'"
exit $FAILED
