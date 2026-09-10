#!/usr/bin/env python3
# =====================================================================
# validate-workflows.py — ตรวจ workflow JSON ก่อน deploy
#
# มีเพราะบั๊กที่หลุดขึ้น production จริงเมื่อ 9 ก.ย. ทั้งที่ตรวจได้ด้วยสคริปต์:
#   `cache_control:{type:'ephemeral'}}]`  →  n8n เห็น }} แล้วปิด expression ตรงนั้น
#   ที่เหลือกลายเป็นข้อความเปล่า → "invalid syntax" → Phase Analysis Engine พังทั้งตัว
#   กว่าจะรู้คือรอ cron รันจริงแล้วดู log
#
# เช็ค 5 อย่าง:
#   1. ไฟล์ parse เป็น JSON ได้ และมี id (ไม่มี id = import แล้วได้ workflow ใหม่ซ้ำ)
#   2. jsCode ทุกก้อนผ่าน node --check
#   3. expression ไม่มี }} ติดกันอยู่ข้างใน
#   4. จำนวนค่าใน queryReplacement ตรงกับจำนวน $n สูงสุดใน query
#   5. node ที่รันเองต้องตั้ง errorWorkflow (ไม่งั้นพังเงียบ)
#
# ใช้:  ./validate-workflows.py [ไฟล์...]      ไม่ใส่ = ตรวจ workflows/*.json ทั้งหมด
# คืน exit code 1 ถ้าเจอปัญหา — deploy-workflows.sh เรียกตัวนี้ก่อนส่งขึ้นเซิร์ฟเวอร์
# =====================================================================
import json
import os
import re
import subprocess
import sys
import tempfile

ERROR_ALERT_ID = 'XwfLoJXuD9Fk5nvn'
# workflow ที่มี trigger ของตัวเองต้องมี errorWorkflow — ตัว Error Alert เองยกเว้น
# (ชี้กลับหาตัวเองแล้วพังซ้อนพัง) ส่วน manual trigger คนกดเองเห็น error อยู่แล้วบนหน้าจอ
SELF_RUNNING = ('scheduleTrigger', 'webhook', 'executeWorkflowTrigger')

problems = []


def fail(wf_name, node, msg, detail=''):
    problems.append((wf_name, node, msg, detail))


def check_expression_braces(wf_name, node_name, path, value):
    """หา {{ ... }} ที่ปีกกาข้างในไม่สมดุล = n8n จะตัดจบ expression ผิดที่"""
    if not (isinstance(value, str) and value.startswith('=')):
        return
    body = value[1:]
    i = body.find('{{')
    while i >= 0:
        j = body.find('}}', i + 2)
        if j < 0:
            break
        inner = body[i + 2:j]
        if inner.count('{') != inner.count('}'):
            fail(wf_name, node_name,
                 f'expression มี }}}} ติดกันข้างใน ({path})',
                 'n8n จะปิด expression ตรงนั้น — เว้นวรรคก่อนปีกกาปิด เช่น "} }" แทน "}}"\n'
                 f'    {value[:150]}')
        i = body.find('{{', j + 2)


def walk(wf_name, node_name, value, path='parameters'):
    if isinstance(value, str):
        check_expression_braces(wf_name, node_name, path, value)
    elif isinstance(value, dict):
        for k, v in value.items():
            walk(wf_name, node_name, v, f'{path}.{k}')
    elif isinstance(value, list):
        for idx, v in enumerate(value):
            walk(wf_name, node_name, v, f'{path}[{idx}]')


def check_js(wf_name, node_name, code):
    """node --check จับ syntax error ที่ตามองข้าม — ห่อเป็นฟังก์ชันก่อนเพราะโค้ดใน
    Code node มี return ที่ระดับบนสุด ซึ่งผิดไวยากรณ์ถ้าอยู่นอกฟังก์ชัน"""
    wrapped = 'function __n8n($input, $, $json, $now, DateTime) {\n' + code + '\n}'
    with tempfile.NamedTemporaryFile('w', suffix='.js', delete=False, encoding='utf-8') as fh:
        fh.write(wrapped)
        tmp = fh.name
    try:
        r = subprocess.run(['node', '--check', tmp], capture_output=True, text=True)
        if r.returncode != 0:
            msg = [l for l in r.stderr.splitlines() if 'SyntaxError' in l]
            fail(wf_name, node_name, 'jsCode syntax error',
                 msg[0].strip() if msg else r.stderr.strip()[:200])
    finally:
        os.unlink(tmp)


def check_query_params(wf_name, node_name, params):
    """$n ใน query ต้องมีค่าป้อนครบ ไม่งั้น Postgres ตีกลับตอนรัน
    (เกินก็ไม่ได้ — "bind message supplies N parameters, but ... requires M")"""
    query = params.get('query')
    if not query:
        return
    used = {int(m.group(1)) for m in re.finditer(r'\$(\d+)', query)}
    repl = params.get('options', {}).get('queryReplacement')
    if not used and not repl:
        return
    if used and not repl:
        fail(wf_name, node_name, f'query ใช้ $1..${max(used)} แต่ไม่ได้ตั้ง queryReplacement')
        return
    if repl and not used:
        fail(wf_name, node_name, 'ตั้ง queryReplacement ไว้ แต่ query ไม่ได้ใช้ $n เลย')
        return
    # นับค่าที่ป้อน: comma ที่อยู่นอก {{ }} เท่านั้น (ข้างในมี comma ได้)
    s = repl[1:] if repl.startswith('=') else repl
    depth, count = 0, 1
    k = 0
    while k < len(s):
        if s.startswith('{{', k):
            depth += 1
            k += 2
            continue
        if s.startswith('}}', k):
            depth -= 1
            k += 2
            continue
        if s[k] == ',' and depth == 0:
            count += 1
        k += 1
    if count != max(used):
        fail(wf_name, node_name,
             f'queryReplacement ป้อน {count} ค่า แต่ query ใช้ถึง ${max(used)}',
             f'    {repl[:150]}')


def main():
    files = sys.argv[1:] or sorted(
        os.path.join('workflows', f) for f in os.listdir('workflows') if f.endswith('.json'))
    for path in files:
        try:
            wf = json.load(open(path, encoding='utf-8'))
        except Exception as e:
            fail(os.path.basename(path), '-', 'JSON เสีย', str(e)[:150])
            continue
        name = wf.get('name', os.path.basename(path))
        if not wf.get('id'):
            fail(name, '-', 'ไม่มีฟิลด์ id',
                 'import แล้ว n8n จะสร้าง workflow ใหม่ซ้ำแทนที่จะอัปเดตของเดิม')

        types = {n['type'].split('.')[-1] for n in wf['nodes']}
        if types & set(SELF_RUNNING) and wf['id'] != ERROR_ALERT_ID:
            if not wf.get('settings', {}).get('errorWorkflow'):
                fail(name, '-', 'ไม่ได้ตั้ง errorWorkflow',
                     'workflow ที่รันเองต้องมี ไม่งั้นพังแล้วเงียบ (เจอจริง 8 ก.ย.)')

        for node in wf['nodes']:
            params = node.get('parameters', {})
            walk(name, node['name'], params)
            if params.get('jsCode'):
                check_js(name, node['name'], params['jsCode'])
            check_query_params(name, node['name'], params)

    if problems:
        print(f'❌ เจอปัญหา {len(problems)} จุด\n')
        for wf_name, node, msg, detail in problems:
            print(f'  {wf_name} / {node}')
            print(f'    {msg}')
            if detail:
                print(f'    {detail}')
            print()
        return 1
    print(f'✅ ตรวจ {len(files)} workflow ผ่านหมด')
    return 0


if __name__ == '__main__':
    sys.exit(main())
