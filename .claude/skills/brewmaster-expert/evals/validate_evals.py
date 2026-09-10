#!/usr/bin/env python3
import json
from collections import Counter
from pathlib import Path

p = Path(__file__).with_name('evals_v1.jsonl')
rows = [json.loads(line) for line in p.read_text(encoding='utf-8').splitlines() if line.strip()]
errors=[]
if len(rows)!=100: errors.append(f'expected 100 rows, got {len(rows)}')
ids=[r.get('id') for r in rows]
if len(ids)!=len(set(ids)): errors.append('duplicate ids')
domains=Counter(r.get('domain') for r in rows)
for d in 'ABCDEFGHIJ':
    if domains[d]!=10: errors.append(f'domain {d} has {domains[d]} rows, expected 10')
required={'id','domain','mode','prompt','required_checks','forbidden_or_failure','hard_fail_if_violated','source_hint','scoring'}
for i,r in enumerate(rows,1):
    missing=required-set(r)
    if missing: errors.append(f'row {i} missing {sorted(missing)}')
    if not r['required_checks']: errors.append(f"{r['id']} has no required checks")
print('rows=',len(rows))
print('domains=',dict(sorted(domains.items())))
print('hard_fail_cases=',sum(bool(r['hard_fail_if_violated']) for r in rows))
if errors:
    for e in errors: print('ERROR:',e)
    raise SystemExit(1)
print('VALID: eval structure and coverage checks passed')
