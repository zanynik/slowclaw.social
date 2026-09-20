#!/usr/bin/env python3
"""Exercise production C ABI; compare Q8 scores with frozen FP32 reference.

The tolerance covers quantized-backend numerical drift, not relevance quality.
"""
import argparse, json, math, subprocess
from pathlib import Path
from evaluate import questions
p=argparse.ArgumentParser();p.add_argument('--binary',required=True);p.add_argument('--model',required=True);p.add_argument('--output',required=True);a=p.parse_args()
root=Path(__file__).parent
cases=json.loads((root/'cases.json').read_text());requests=[]
for case in cases:
    qs=questions()
    for i in (0,1,3,4):qs[i]['instr']+='\nPersonal memory: '+case['memory']
    qs=[{'instruction':q['instr'],'options':q['options']} for q in qs]
    requests.append({'state':case['item'],'questions':qs})
    requests.extend({'state':case['item'],'questions':[q]} for q in qs)
requests += [requests[0], {'state':'', 'questions':requests[0]['questions']}, {'state':'word '*3000,'questions':requests[0]['questions']}]
run=subprocess.run([a.binary,a.model],input='\n'.join(json.dumps(r) for r in requests)+'\n',text=True,stdout=subprocess.PIPE,check=True)
rows=[json.loads(line) for line in run.stdout.splitlines()]
assert len(rows)==len(requests) and rows[-1] is None and rows[-2] is None
assert rows[-3]==rows[0], 'same-input inference must be repeatable'
reference=json.loads((root/'item-state-results.json').read_text())['cases']
quant=[];isolation=[]
for i,case in enumerate(reference):
    packed=rows[6*i]; separate=sum(rows[6*i+1:6*i+6],[]); ref=sum(case['probabilities'],[])
    assert len(packed)==15 and all(math.isfinite(v) and 0<=v<=1 for v in packed)
    start=0
    for length in [2,2,6,2,3]:
        assert abs(sum(packed[start:start+length])-1)<1e-6
        start+=length
    quant.append(max(abs(x-y) for x,y in zip(packed,ref)))
    isolation.append(max(abs(x-y) for x,y in zip(packed,separate)))
# Measured ceiling for this pinned Q8 artifact; detects conversion/mask/head regressions.
assert max(quant)<0.05, quant
assert max(isolation)<0.04, isolation
report={'model':Path(a.model).name,'cases':len(cases),'reference_max_delta':max(quant),
    'packed_separate_max_delta':max(isolation),'repeat_identical':True,'invalid_inputs_abstain':True,
    'probabilities':[rows[6*i] for i in range(len(cases))]}
Path(a.output).write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:v for k,v in report.items() if k!='probabilities'}))
