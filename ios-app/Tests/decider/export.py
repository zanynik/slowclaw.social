#!/usr/bin/env python3
"""Export the pinned Strands Decider v21 torso + FP32 calibrated pointer head."""
import argparse, hashlib, json, subprocess, sys
from pathlib import Path
import torch
from huggingface_hub import snapshot_download
from transformers import AutoConfig, AutoTokenizer, Qwen3_5ForCausalLM
from safetensors.torch import load_file
from peft import PeftModel
BASE = 'b1485b2fa6dfa1287294f269f5fb618e03d52d7c'
ADAPTER = '2b52a6235c1b8306bbfa30b00b9d4b74b63a39f5'
CONVERTER = '8f4646a63ee29f2e0ab971b0290b141938769762'
def main():
    p=argparse.ArgumentParser();p.add_argument('--converter',type=Path,required=True);p.add_argument('--work',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--precision',choices=['q8','f16'],default='q8');p.add_argument('--reuse-merged',action='store_true');a=p.parse_args()
    assert subprocess.check_output(['git','-C',str(a.converter),'rev-parse','HEAD'],text=True).strip()==CONVERTER
    torch.set_num_threads(2);torch.manual_seed(0)
    run=Path(snapshot_download('StrandsAgents/strands-decider-2B-hobson-v21',revision=ADAPTER))
    config=json.loads((run/'strands_decider_config.json').read_text())
    assert config['base_model']=='Qwen/Qwen3.5-2B-Base' and config['head_type']=='pointer' and config['pointer_dim']==256
    head=load_file(run/'head.safetensors')
    shapes={'norm.weight':[2048],'norm.bias':[2048],'q.weight':[256,2048],'q.bias':[256],'k.weight':[256,2048],'k.bias':[256]}
    assert set(head)==set(shapes)
    for key,shape in shapes.items():assert list(head[key].shape)==shape and torch.isfinite(head[key]).all()
    if not a.reuse_merged:
        cfg=AutoConfig.from_pretrained(config['base_model'],revision=BASE).get_text_config()
        model=Qwen3_5ForCausalLM.from_pretrained(config['base_model'],revision=BASE,config=cfg,dtype=torch.bfloat16)
        model.model=PeftModel.from_pretrained(model.model,run/'lora').merge_and_unload()
        a.work.mkdir(parents=True,exist_ok=True);model.save_pretrained(a.work,safe_serialization=True)
        AutoTokenizer.from_pretrained(run).save_pretrained(a.work);del model
    sys.path.insert(0,str(a.converter));sys.path.insert(0,str(a.converter/'gguf-py'))
    import gguf
    from conversion.qwen import Qwen3_5TextModel
    class DeciderModel(Qwen3_5TextModel):
        model_arch = gguf.MODEL_ARCH.QWEN35
        no_mtp = True
        def set_gguf_parameters(self):
            super().set_gguf_parameters()
            self.gguf_writer.add_string('slowclaw.decider.version','strands-decider-v21')
            self.gguf_writer.add_string('slowclaw.decider.adapter',ADAPTER)
            self.gguf_writer.add_float32('slowclaw.decider.temperature',config['temperature_by_kind']['choice'])
            for key in shapes:self.gguf_writer.add_array('slowclaw.decider.'+key,head[key].float().contiguous().flatten().tolist())
    DeciderModel(a.work,gguf.LlamaFileType.MOSTLY_Q8_0 if a.precision=='q8' else gguf.LlamaFileType.MOSTLY_F16,a.output,model_name='Strands Decider v21',eager=True).write()
    h=hashlib.sha256()
    with a.output.open('rb') as f:
        while chunk:=f.read(1048576):h.update(chunk)
    manifest={'file':a.output.name,'sha256':h.hexdigest(),'bytes':a.output.stat().st_size,'base_revision':BASE,'adapter_revision':ADAPTER,'converter_revision':CONVERTER,'precision':a.precision}
    a.output.with_suffix('.json').write_text(json.dumps(manifest,indent=2)+'\n');print(json.dumps(manifest),flush=True)
if __name__=='__main__':main()
