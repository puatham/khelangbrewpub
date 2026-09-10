#!/usr/bin/env python3
# =====================================================================
# rename-node.py — เปลี่ยนชื่อ node พร้อมตามไปแก้ทุกที่ที่อ้างถึงมัน
#
# n8n ผูก node เข้าหากันด้วย "ชื่อ" ไม่ใช่ id การเปลี่ยนชื่อจึงต้องแก้ 3 ที่พร้อมกัน:
#   1. nodes[].name
#   2. connections — ทั้ง key (สายออก) และ .node (ปลายทาง)
#   3. $('ชื่อเดิม') ที่กระจายอยู่ใน jsCode และ expression ของ node อื่น
# ลืมข้อไหนข้อหนึ่งจะไม่มีอะไรเตือนจนกว่าจะรันจริง — validate-workflows.py จับได้
# แต่ดีกว่านั้นคือไม่ต้องพลาดตั้งแต่แรก
#
# ใช้:  ./rename-node.py <ไฟล์.json> "ชื่อเดิม" "ชื่อใหม่" ["ชื่อเดิม2" "ชื่อใหม่2" ...]
# =====================================================================
import io
import json
import re
import sys


def rename(wf, old, new):
    hits = {'node': 0, 'conn_key': 0, 'conn_target': 0, 'refs': 0}

    names = {n['name'] for n in wf['nodes']}
    if old not in names:
        raise SystemExit(f'❌ ไม่เจอ node ชื่อ "{old}"')
    if new in names:
        raise SystemExit(f'❌ มี node ชื่อ "{new}" อยู่แล้ว')

    for n in wf['nodes']:
        if n['name'] == old:
            n['name'] = new
            hits['node'] += 1

    conns = wf.get('connections') or {}
    if old in conns:
        conns[new] = conns.pop(old)
        hits['conn_key'] += 1
    for conn in conns.values():
        for branch in conn.get('main', []) or []:
            for link in branch or []:
                if link.get('node') == old:
                    link['node'] = new
                    hits['conn_target'] += 1

    # $('ชื่อ') รองรับทั้ง single/double quote และช่องว่างในวงเล็บ
    pattern = re.compile(r"(\$\(\s*)(['\"])" + re.escape(old) + r"\2(\s*\))")

    def sub_all(value):
        nonlocal hits
        if isinstance(value, str):
            out, n = pattern.subn(lambda m: f"{m.group(1)}{m.group(2)}{new}{m.group(2)}{m.group(3)}", value)
            hits['refs'] += n
            return out
        if isinstance(value, dict):
            return {k: sub_all(v) for k, v in value.items()}
        if isinstance(value, list):
            return [sub_all(v) for v in value]
        return value

    for n in wf['nodes']:
        n['parameters'] = sub_all(n.get('parameters', {}))

    return hits


def main():
    if len(sys.argv) < 4 or len(sys.argv) % 2 != 0:
        raise SystemExit('ใช้: ./rename-node.py <ไฟล์.json> "เดิม" "ใหม่" ["เดิม2" "ใหม่2" ...]')
    path = sys.argv[1]
    pairs = list(zip(sys.argv[2::2], sys.argv[3::2]))
    wf = json.load(open(path, encoding='utf-8'))
    for old, new in pairs:
        h = rename(wf, old, new)
        print(f'  {old:26} → {new:26} '
              f'(สาย {h["conn_key"]}+{h["conn_target"]}, อ้างถึง {h["refs"]} จุด)')
    with io.open(path, 'w', encoding='utf-8') as f:
        json.dump(wf, f, ensure_ascii=False, indent=2)
        f.write('\n')


if __name__ == '__main__':
    main()
