#!/usr/bin/env python3
"""Freeze synthetic choice outputs from the pinned merged torso and FP32 head."""
import argparse,json,time,sys
from pathlib import Path
import torch
from transformers import AutoTokenizer,Qwen3_5ForCausalLM
from safetensors.torch import load_file
from huggingface_hub import snapshot_download
p=argparse.ArgumentParser();p.add_argument('--merged',required=True);p.add_argument('--output',required=True);a=p.parse_args()
torch.set_num_threads(2)
root=Path(__file__).parent
run=Path(snapshot_download('StrandsAgents/strands-decider-2B-hobson-v21',revision='2b52a6235c1b8306bbfa30b00b9d4b74b63a39f5'))
config=json.loads((run/'strands_decider_config.json').read_text());head=load_file(run/'head.safetensors')
tok=AutoTokenizer.from_pretrained(run)
model=Qwen3_5ForCausalLM.from_pretrained(a.merged,dtype=torch.bfloat16).model.eval()
sys.path.insert(0,str(root.parent/'kev'));from evaluate import questions
cases=json.loads((root.parent/'kev'/'cases.json').read_text())
result={'adapter_revision':'2b52a6235c1b8306bbfa30b00b9d4b74b63a39f5','precision':'merged bfloat16 torso, FP32 head','cases':[]}
for case in cases:
    qs=questions()
    for i in (0,1,3,4):qs[i]['instr']+='\nPersonal memory: '+case['memory']
    request={'state':case['item'],'questions':[{'instruction':q['instr'],'options':q['options']} for q in qs]}
    rows=[];token_fixture=[];started=time.monotonic()
    for q in request['questions']:
        state='<state>\n'+request['state'].strip()+'\n</state>\n'
        prefix='<question type="choice">\nSelect exactly one option.\n'+q['instruction'].strip()+'\n<options>\n'
        block='';spans=[]
        for i,option in enumerate(q['options']):
            line=f'{i+1}. {option}';start=len(prefix)+len(block);spans.append((start,start+len(line)));block+=line+'\n'
        question=prefix+block+'</options>\n</question>\n<answer>'
        st=tok.encode(state,add_special_tokens=False);enc=tok(question,add_special_tokens=False,return_offsets_mapping=True)
        positions=[max(i for i,(s,e) in enumerate(enc['offset_mapping']) if s>=lo and e<=hi and e>s) for lo,hi in spans]
        ids=st+enc['input_ids'];inp=torch.tensor([ids])
        with torch.inference_mode():
            hidden=model(input_ids=inp,attention_mask=torch.ones_like(inp),use_cache=False,return_dict=True).last_hidden_state[0].float()
            norm=lambda v:torch.nn.functional.layer_norm(v,(2048,),head['norm.weight'],head['norm.bias'],1e-5)
            query=torch.nn.functional.linear(norm(hidden[-1]),head['q.weight'],head['q.bias'])
            keys=torch.nn.functional.linear(norm(hidden[[len(st)+i for i in positions]]),head['k.weight'],head['k.bias'])
            logits=keys@query/16/config['temperature_by_kind']['choice'];rows.append(torch.softmax(logits,dim=-1).tolist())
        token_fixture.append({'state_tokens':st,'question_tokens':enc['input_ids'],'option_positions':positions})
    result['cases'].append({'id':case['id'],'request':request,'probabilities':rows,'tokens':token_fixture,'seconds':time.monotonic()-started})
    Path(a.output).write_text(json.dumps(result,indent=2)+'\n');print(case['id'],result['cases'][-1]['seconds'],flush=True)
