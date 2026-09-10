// =====================================================================
// run-tests.mjs — รันโค้ดใน Code node ของ n8n กับ fixture จริง
//
// **ทำไมต้องมี**: Code node ก้อนใหญ่สุดมี 364 บรรทัด และไม่มีอะไรทดสอบมันเลย
// ที่ผ่านมาเวลาแก้ต้องดึงโค้ดออกมารันใน node ชั่วคราวทุกครั้งแล้วทิ้ง — งานเดิมซ้ำๆ
// และพอ deploy ไปแล้วก็ไม่มีใครรู้ว่าเคสอื่นยังทำงานอยู่ไหม
//
// ตัวนี้อ่าน jsCode ตรงจาก workflow JSON ที่ deploy จริง ไม่ได้ copy โค้ดมาไว้อีกที่
// จึงไม่มีทาง "เทสผ่านแต่ของจริงเป็นอีกแบบ"
//
// ใช้:  node tests/run-tests.mjs           รันทุก fixture
//       node tests/run-tests.mjs temp      รันเฉพาะ fixture ที่ชื่อมี "temp"
// =====================================================================
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..');
const filter = process.argv[2] || '';

function loadNodeCode(workflowName, nodeName) {
  const wf = JSON.parse(readFileSync(join(ROOT, 'workflows', workflowName + '.json'), 'utf8'));
  const node = wf.nodes.find((n) => n.name === nodeName);
  if (!node) throw new Error(`ไม่เจอ node "${nodeName}" ใน ${workflowName}`);
  if (!node.parameters?.jsCode) throw new Error(`"${nodeName}" ไม่ใช่ Code node`);
  return node.parameters.jsCode;
}

// จำลองสภาพแวดล้อมที่ n8n ให้ Code node — $input.all() กับ $('ชื่อ node')
// itemMatching(i) คือตัวที่ n8n ใช้จับคู่ item ข้าม node ต้องมีให้ครบ ไม่งั้นโค้ดที่
// พึ่งมันจะพังคนละแบบกับของจริง
function runNode(code, { input = [], context = {} }) {
  const wrap = (rows) => rows.map((json) => ({ json }));
  const $input = {
    all: () => wrap(input),
    first: () => wrap(input)[0],
    last: () => wrap(input)[input.length - 1]
  };
  const $ = (nodeName) => {
    const rows = context[nodeName];
    if (!rows) throw new Error(`fixture ไม่ได้ให้ context ของ node "${nodeName}"`);
    return {
      all: () => wrap(rows),
      first: () => wrap(rows)[0],
      itemMatching: (i) => {
        const r = rows[i] ?? rows[rows.length - 1];
        return { json: r };
      }
    };
  };
  const fn = new Function('$input', '$', '$now', 'DateTime', code);
  return fn($input, $, new Date(), null);
}

// เทียบเฉพาะ key ที่ fixture ระบุไว้ — ไม่ต้องเขียน output ทั้งก้อนซึ่งยาวและเปราะ
// รองรับ path แบบ "embeds.0.title" และค่าที่ขึ้นต้นด้วย ~ = "ต้องมีข้อความนี้อยู่ข้างใน"
function checkExpectations(actual, expect) {
  const errs = [];
  for (const [path, wants] of Object.entries(expect)) {
    // รับได้ทั้งค่าเดียวและ array ของหลายเงื่อนไขบน path เดียวกัน — ถ้าไม่มี array
    // จะเขียนคีย์ซ้ำใน JSON แล้วเช็คตัวแรกหายเงียบโดยไม่มีอะไรบอก
    for (const want of Array.isArray(wants) ? wants : [wants]) {
    let got = actual;
    for (const part of path.split('.')) got = got?.[part];
    // "ไม่มีคีย์นี้" ต่างจาก "คีย์นี้เป็น null" — บาง guard ตั้งค่าเป็น null ตั้งใจ
    // ส่วนบางเคสคือต้องไม่แตะเลย ถ้าเทียบรวมกันจะเขียนเทสที่หลอกตัวเองได้
    if (want === '__absent__') {
      if (got !== undefined) errs.push(`${path}: ต้องไม่มีค่า แต่ได้ ${JSON.stringify(got)}`);
    } else if (typeof want === 'string' && want.startsWith('~')) {
      const needle = want.slice(1);
      const hay = String(got ?? '');
      if (needle.startsWith('!')) {
        if (hay.includes(needle.slice(1)))
          errs.push(`${path}: ต้องไม่มี "${needle.slice(1)}" แต่เจอใน ${JSON.stringify(hay.slice(0, 90))}`);
      } else if (!hay.includes(needle)) {
        errs.push(`${path}: ต้องมี "${needle}" แต่ได้ ${JSON.stringify(hay.slice(0, 120))}`);
      }
    } else if (JSON.stringify(got) !== JSON.stringify(want)) {
      errs.push(`${path}: ต้องการ ${JSON.stringify(want)} แต่ได้ ${JSON.stringify(got)}`);
    }
    }
  }
  return errs;
}

let pass = 0;
const failures = [];

const files = readdirSync(join(HERE, 'fixtures'))
  .filter((f) => f.endsWith('.json') && f.includes(filter));

for (const file of files) {
  const spec = JSON.parse(readFileSync(join(HERE, 'fixtures', file), 'utf8'));
  const code = loadNodeCode(spec.workflow, spec.node);
  console.log(`\n${spec.workflow} / ${spec.node}  (${file})`);
  for (const c of spec.cases) {
    let out;
    try {
      out = runNode(code, c);
    } catch (e) {
      failures.push([file, c.name, [`โยน error: ${e.message}`]]);
      console.log(`  ✗ ${c.name}`);
      continue;
    }
    const errs = [];
    if (c.expectCount != null && out.length !== c.expectCount)
      errs.push(`จำนวน item: ต้องการ ${c.expectCount} แต่ได้ ${out.length}`);
    if (c.expect) {
      const idx = c.expectIndex ?? 0;
      if (!out[idx]) errs.push(`ไม่มี item ที่ index ${idx}`);
      else errs.push(...checkExpectations(out[idx].json, c.expect));
    }
    if (errs.length) {
      failures.push([file, c.name, errs]);
      console.log(`  ✗ ${c.name}`);
    } else {
      pass++;
      console.log(`  ✓ ${c.name}`);
    }
  }
}

console.log('\n' + '─'.repeat(60));
if (failures.length) {
  console.log(`ผ่าน ${pass} · ไม่ผ่าน ${failures.length}\n`);
  for (const [file, name, errs] of failures) {
    console.log(`  ${file} → ${name}`);
    for (const e of errs) console.log(`      ${e}`);
  }
  process.exit(1);
}
console.log(`✅ ผ่านทั้งหมด ${pass} เคส`);
