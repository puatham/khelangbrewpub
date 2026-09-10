#!/usr/bin/env python3
# =====================================================================
# validate-workflows.py — ตรวจ workflow JSON ก่อน deploy
#
# มีเพราะบั๊กที่หลุดขึ้น production จริงเมื่อ 9 ก.ย. ทั้งที่ตรวจได้ด้วยสคริปต์:
#   `cache_control:{type:'ephemeral'}}]`  →  n8n เห็น }} แล้วปิด expression ตรงนั้น
#   ที่เหลือกลายเป็นข้อความเปล่า → "invalid syntax" → Phase Analysis Engine พังทั้งตัว
#   กว่าจะรู้คือรอ cron รันจริงแล้วดู log
#
# เช็ค 8 อย่าง:
#   1. ไฟล์ parse เป็น JSON ได้ และมี id (ไม่มี id = import แล้วได้ workflow ใหม่ซ้ำ)
#   2. jsCode ทุกก้อนผ่าน node --check
#   3. expression ไม่มี }} ติดกันอยู่ข้างใน
#   4. จำนวนค่าใน queryReplacement ตรงกับจำนวน $n สูงสุดใน query
#   5. node ที่รันเองต้องตั้ง errorWorkflow (ไม่งั้นพังเงียบ)
#   6. $('ชื่อ node') ต้องชี้ไป node ที่มีอยู่จริง (เปลี่ยนชื่อแล้วลืมแก้ที่อ้าง)
#   7. Code node ที่ป้อนเข้า HTTP ต้องส่งฟิลด์ที่ URL ของมันใช้ — ลืมแล้ว path เพี้ยนเงียบๆ
#   8. ทุก action ใน actionMap ต้องมี rule ใน Switch รองรับ (ไม่งั้นคำสั่งเงียบ)
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


def check_node_refs(wf_name, node_name, code_or_expr, known_nodes, where):
    """$('ชื่อ node') ต้องชี้ไป node ที่มีอยู่จริงในไฟล์เดียวกัน

    n8n ผูก node ด้วย "ชื่อ" ไม่ใช่ id — เปลี่ยนชื่อ node แล้วลืมแก้ที่อ้างถึง จะไม่มีอะไร
    เตือนเลยจนกว่าจะรันจริงแล้วเจอ "Referenced node is unexecuted" กลางทาง
    """
    for m in re.finditer(r"\$\(\s*'([^']+)'\s*\)|\$\(\s*\"([^\"]+)\"\s*\)", code_or_expr):
        ref = m.group(1) or m.group(2)
        if ref not in known_nodes:
            close = [n for n in known_nodes if n.lower().replace(' ', '') == ref.lower().replace(' ', '')]
            hint = f' — ใกล้เคียง: "{close[0]}"' if close else ''
            fail(wf_name, node_name, f'อ้างถึง node ที่ไม่มีอยู่: $(\'{ref}\') ใน {where}{hint}')


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


def check_http_inputs(wf_name, wf, nodes_by_name):
    """node ที่ป้อนเข้า HTTP ต้องส่งฟิลด์ที่ URL/body ของมันอ้างถึงมาด้วย

    n8n อ้าง $json ของ "item ที่ไหลเข้ามา" ไม่ใช่ของ node ต้นทางตามชื่อ ถ้า Code node
    ลืมส่งฟิลด์ต่อ ค่าจะกลายเป็น undefined เงียบๆ แล้วไปพังที่ปลายทางแทน
    เจอจริง 10 ก.ย.: Build Event Message ส่งแต่ content ทำให้ URL เป็น
    /webhooks///messages/@original แล้ว Discord ตอบ "Value \"messages\" is not snowflake"
    """
    incoming = {}
    for src, conn in (wf.get('connections') or {}).items():
        for branch in conn.get('main', []) or []:
            for link in branch or []:
                incoming.setdefault(link.get('node'), []).append(src)

    for node in wf['nodes']:
        if not node['type'].endswith('httpRequest'):
            continue
        # ตรวจเฉพาะฟิลด์ที่อยู่ใน "url" — พวกนี้เป็นโครงสร้าง ขาดแล้ว path เพี้ยนทันที
        # ส่วนฟิลด์ใน body มักเป็น optional (เช่น $json.embeds ที่อยู่ในเงื่อนไข ternary)
        # ถ้าตรวจ body ด้วยจะ fail node ที่ทำงานถูกอยู่แล้วทั้งหมด
        url = node.get('parameters', {}).get('url') or ''
        needed = set()
        for m in re.finditer(r'\$json\.(\w+)', url):
            seg = url[max(0, m.start() - 40):m.start()]
            if "$(" not in seg[-25:]:
                needed.add(m.group(1))
        if not needed:
            continue
        for src in incoming.get(node['name'], []):
            code = nodes_by_name.get(src, {}).get('parameters', {}).get('jsCode')
            if not code:
                continue          # ตรวจได้เฉพาะ Code node ที่อ่านโค้ดได้
            missing = sorted(f for f in needed if f not in code)
            if missing:
                fail(wf_name, src,
                     f'ไม่ได้ส่งฟิลด์ที่ "{node["name"]}" ต้องใช้: {", ".join(missing)}',
                     'n8n อ่าน $json จาก item ที่ไหลเข้า ไม่ใช่จาก node ต้นทางตามชื่อ —\n'
                     '    ลืมส่งต่อแล้วจะเป็น undefined เงียบๆ ไปพังที่ HTTP node แทน')


def check_action_routing(wf_name, wf):
    """ทุกค่าที่ actionMap สร้างได้ ต้องมีปลายทางใน Switch ที่ route ตาม $json.action

    ยุบ IF 7 ตัวเป็น Switch แล้วเพิ่มคำสั่งใหม่ทีหลัง ถ้าลืมเพิ่ม rule คำสั่งนั้นจะเงียบ
    ไม่มี error ไม่มีคำตอบ ผู้ใช้ได้แต่ "is thinking..." ค้างไว้ — จับตอน deploy ดีกว่า
    """
    actions = set()
    for node in wf['nodes']:
        code = node.get('parameters', {}).get('jsCode') or ''
        m = re.search(r'actionMap\s*=\s*\{(.*?)\}', code, re.S)
        if m:
            actions |= {v for v in re.findall(r":\s*'([^']+)'", m.group(1))}
    if not actions:
        return

    routed = set()
    switch_names = []
    for node in wf['nodes']:
        if not node['type'].endswith('.switch'):
            continue
        blob = json.dumps(node.get('parameters', {}), ensure_ascii=False)
        if '$json.action' not in blob:
            continue
        switch_names.append(node['name'])
        for rule in node['parameters'].get('rules', {}).get('values', []):
            for cond in rule.get('conditions', {}).get('conditions', []):
                if 'action' in str(cond.get('leftValue', '')):
                    routed.add(cond.get('rightValue'))
    if not switch_names:
        return                      # ยังใช้ IF chain อยู่ ไม่ตรวจ

    missing = sorted(actions - routed - {'unknown'})
    if missing:
        fail(wf_name, switch_names[0],
             f'action ที่ไม่มีปลายทาง: {", ".join(missing)}',
             'actionMap สร้างค่าเหล่านี้ได้ แต่ Switch ไม่มี rule รองรับ —\n'
             '    คำสั่งจะเงียบ ไม่มี error ผู้ใช้เห็นแค่ "is thinking..." ค้าง')

    stray = sorted(routed - actions)
    if stray:
        fail(wf_name, switch_names[0],
             f'Switch มี rule ที่ actionMap ไม่เคยสร้าง: {", ".join(stray)}',
             'สะกดผิด หรือเหลือค้างจากคำสั่งที่ถอดไปแล้ว')


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

        known = {n['name'] for n in wf['nodes']}
        for node in wf['nodes']:
            params = node.get('parameters', {})
            walk(name, node['name'], params)
            if params.get('jsCode'):
                check_js(name, node['name'], params['jsCode'])
                check_node_refs(name, node['name'], params['jsCode'], known, 'jsCode')
            check_query_params(name, node['name'], params)
            # expression ก็อ้าง node ด้วยไวยากรณ์เดียวกันได้ เช่น {{ $('Get RAPT Token').first() }}
            # ตัด jsCode ออกก่อน ไม่งั้นรายงานซ้ำกับรอบบน
            others = {k: v for k, v in params.items() if k != 'jsCode'}
            check_node_refs(name, node['name'], json.dumps(others, ensure_ascii=False), known, 'expression')

        check_http_inputs(name, wf, {x['name']: x for x in wf['nodes']})
        check_action_routing(name, wf)

        # สายที่ต่อไว้ใน connections ต้องชี้ไป node ที่มีจริงเช่นกัน
        for src, conn in (wf.get('connections') or {}).items():
            if src not in known:
                fail(name, '-', f'connections มีสายออกจาก node ที่ไม่มีอยู่: "{src}"')
            for branch in conn.get('main', []) or []:
                for link in branch or []:
                    if link.get('node') not in known:
                        fail(name, src, f'สายชี้ไป node ที่ไม่มีอยู่: "{link.get("node")}"')

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
