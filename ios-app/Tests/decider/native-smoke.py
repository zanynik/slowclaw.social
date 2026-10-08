#!/usr/bin/env python3
"""Validate real native scores against the frozen v21 reference, and failure paths."""
import argparse,json,math,subprocess,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--binary',required=True);p.add_argument('--model',required=True);p.add_argument('--output',required=True);a=p.parse_args()
root=Path(__file__).parent;reference=json.loads((root/'reference-results.json').read_text())['cases']
requests=[r['request'] for r in reference]
requests.extend({'state':requests[0]['state'],'questions':[q]} for q in requests[0]['questions'])
requests.extend([requests[0],{'state':'','questions':requests[0]['questions']}, {'state':' x'*4000,'questions':requests[0]['questions']}, {'state':'source','questions':[{'instruction':'pick','options':['one\ntwo','three']}]}])
started=time.monotonic()
print(f'Running {len(requests)} native requests (reference, isolation, repeat and rejection)', flush=True)
rows=[]
with subprocess.Popen([a.binary,a.model],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True) as run:
    for index,request in enumerate(requests,1):
        run.stdin.write(json.dumps(request,ensure_ascii=False)+'\n');run.stdin.flush()
        line=run.stdout.readline()
        if not line:
            raise RuntimeError(f'Native runner stopped before result {index}; exit={run.poll()}')
        rows.append(json.loads(line))
        print(f'Native request {index}/{len(requests)} complete ({time.monotonic()-started:.1f}s)', flush=True)
    run.stdin.close()
    if run.stdout.read().strip():
        raise RuntimeError('Native runner returned unexpected extra results')
    if run.wait()!=0:
        raise RuntimeError(f'Native runner failed: exit={run.returncode}')
assert len(rows)==len(requests)
assert rows[-1] is None and rows[-2] is None and rows[-3] is None
assert rows[-4]==rows[0], 'same input must be repeatable'
deltas=[];winners=[]
for row,ref in zip(rows,reference):
    expected=sum(ref['probabilities'],[]);assert row is not None and len(row)==len(expected)
    assert all(math.isfinite(x) and 0<=x<=1 for x in row)
    offset=0
    for q,probs in zip(ref['request']['questions'],ref['probabilities']):
        values=row[offset:offset+len(q['options'])];assert abs(sum(values)-1)<1e-6
        winners.append(max(range(len(values)),key=values.__getitem__)==max(range(len(probs)),key=probs.__getitem__))
        offset+=len(values)
    deltas.append(max(abs(x-y) for x,y in zip(row,expected)))
isolated=sum(rows[len(reference):len(reference)+5],[])
assert max(abs(x-y) for x,y in zip(isolated,rows[0]))<1e-6
# A conversion/head/token-position regression is materially larger than this drift.
report={'model':Path(a.model).name,'cases':len(reference),'max_reference_delta':max(deltas),'same_winners':sum(winners),'questions':len(winners),'packed_separate_identical':True,'repeat_identical':True,'invalid_inputs_abstain':True,'seconds':time.monotonic()-started,'probabilities':rows[:len(reference)]}
Path(a.output).write_text(json.dumps(report,indent=2)+'\n')
assert max(deltas)<0.08, deltas
assert sum(winners)>=len(winners)-1, 'Reference choices regressed'
print(json.dumps({k:v for k,v in report.items() if k!='probabilities'}))
