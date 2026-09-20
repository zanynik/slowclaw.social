#!/usr/bin/env python3
"""Merge pinned Kev LoRA, export Q8 GGUF, and carry the FP32 pointer head as metadata."""
import argparse, hashlib, json, subprocess, sys
from pathlib import Path
import torch
from huggingface_hub import snapshot_download
from transformers import AutoModelForCausalLM, AutoTokenizer
from peft import PeftModel

BASE = '060db6499f32faf8b98477b0a26969ef7d8b9987'
ADAPTER = 'edf1dc6d7f8d983c0adfd251e80a686e5539fc61'
CONVERTER = '8f4646a63ee29f2e0ab971b0290b141938769762'

def main():
    p = argparse.ArgumentParser(); p.add_argument('--converter', type=Path, required=True)
    p.add_argument('--work', type=Path, required=True); p.add_argument('--output', type=Path, required=True)
    p.add_argument('--precision', choices=['q8', 'f32'], default='q8'); a=p.parse_args()
    assert subprocess.check_output(['git','-C',str(a.converter),'rev-parse','HEAD'],text=True).strip() == CONVERTER
    torch.set_num_threads(2); torch.manual_seed(0)
    run=snapshot_download('jaredpalmer/kev-0.5b',revision=ADAPTER,allow_patterns=['*.json','*.safetensors','head.pt'])
    meta=torch.load(Path(run)/'head.pt', map_location='cpu', weights_only=True)
    assert meta['base']=='Qwen/Qwen2.5-0.5B' and not meta.get('option_isolation',False)
    model=AutoModelForCausalLM.from_pretrained(meta['base'],revision=BASE,torch_dtype=torch.float32)
    model.model=PeftModel.from_pretrained(model.model,run).merge_and_unload()
    a.work.mkdir(parents=True,exist_ok=True)
    model.save_pretrained(a.work,safe_serialization=True)
    AutoTokenizer.from_pretrained(meta['base'],revision=BASE).save_pretrained(a.work)
    del model
    sys.path.insert(0,str(a.converter));sys.path.insert(0,str(a.converter/'gguf-py'))
    import gguf
    from conversion.qwen import Qwen2Model
    class KevModel(Qwen2Model):
        model_arch = gguf.MODEL_ARCH.QWEN2
        def set_gguf_parameters(self):
            super().set_gguf_parameters()
            self.gguf_writer.add_string('slowclaw.kev.version','kev-0.5b-v1')
            self.gguf_writer.add_string('slowclaw.kev.adapter',ADAPTER)
            for key in ['q.weight','q.bias','k.weight','k.bias']:
                t=meta['head'][key].float().contiguous()
                assert list(t.shape)==([256,896] if 'weight' in key else [256])
                self.gguf_writer.add_array('slowclaw.kev.'+key,t.flatten().tolist())
    ftype=gguf.LlamaFileType.MOSTLY_Q8_0 if a.precision=='q8' else gguf.LlamaFileType.ALL_F32
    KevModel(a.work,ftype,a.output,model_name='Kev-0.5B SlowClaw Lite',eager=True).write()
    digest=hashlib.sha256()
    with a.output.open('rb') as f:
        while chunk:=f.read(1048576):digest.update(chunk)
    manifest={'file':a.output.name,'sha256':digest.hexdigest(),'bytes':a.output.stat().st_size,
        'base_revision':BASE,'adapter_revision':ADAPTER,'converter_revision':CONVERTER,'precision':a.precision}
    a.output.with_suffix('.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps(manifest),flush=True)

if __name__=='__main__':main()
