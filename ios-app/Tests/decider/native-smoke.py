#!/usr/bin/env python3
"""Validate real native scores against the frozen v21 reference, and failure paths."""
import argparse,json,math,subprocess,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--binary',required=True);p.add_argument('--model',required=True);p.add_argument('--output',required=True);a=p.parse_args()
root=Path(__file__).parent;reference=json.loads((root/'reference-results.json').read_text())['cases']
requests=[r['request'] for r in reference]
requests.extend({'state':requests[0]['state'],'questions':[q]} for q in requests[0]['questions'])
requests.extend([requests[0],{'state':'','questions':requests[0]['questions']}, {'state':' x'*4000,'questions':requests[0]['questions']}, {'state':'source','questions':[{'instruction':'pick','options':['one\ntwo','three']}]}])
started=time.monotonic();run=subprocess.run([a.binary,a.model],input='\n'.join(json.dumps(r,ensure_ascii=False) for r in requests)+'\n',text=True,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,check=True)
rows=[json.loads(line) for line in run.stdout.splitlines()];assert len(rows)==len(requests)
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
