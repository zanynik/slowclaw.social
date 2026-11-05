"""Export all-MiniLM-L6-v2 for the app: fp16 weights in one file + golden vectors for the Swift test.
Format of minilm.weights: b"MLM1", uint32 little-endian header length, JSON header
{name: {"offset": byte offset in data, "shape": [...]}}, then fp16 data."""
import json, struct, sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from minilm import MiniLM, load_safetensors
src, out_dir = sys.argv[1], sys.argv[2]
w = load_safetensors(os.path.join(src, "model.safetensors"), np.float32)
names = sorted(k for k in w if not k.startswith("pooler."))
header, blobs, off = {}, [], 0
for k in names:
    a = w[k].astype(np.float16)
    header[k] = {"offset": off, "shape": list(a.shape)}
    blobs.append(a.tobytes()); off += a.nbytes
h = json.dumps(header, separators=(",", ":")).encode()
os.makedirs(out_dir, exist_ok=True)
with open(os.path.join(out_dir, "minilm.weights"), "wb") as f:
    f.write(b"MLM1"); f.write(struct.pack("<I", len(h))); f.write(h)
    for b in blobs: f.write(b)
os.system(f"cp {os.path.join(src, 'vocab.txt')} {os.path.join(out_dir, 'minilm.vocab')}")
# Golden vectors from the fp16-rounded weights, exactly what the phone loads.
m = MiniLM(src)
m.w = {k: v.astype(np.float16).astype(np.float32) for k, v in m.w.items()}
texts = ["I meditate to watch my cravings without reacting.",
         "Zero-profit grocery stores could change the economy!",
         "Naïve café résumé, Ünïcödé; numbers 2026 and #hashtags."]
gold = {"texts": texts, "ids": [m.encode(t) for t in texts], "vectors": [[round(float(x), 6) for x in m.embed(t)] for t in texts]}
json.dump(gold, open(os.path.join(sys.argv[3]), "w"))
print("weights", os.path.getsize(os.path.join(out_dir, "minilm.weights")) // 1024 // 1024, "MB;", len(names), "tensors")
print("golden cos(0,1) =", float(np.dot(gold["vectors"][0], gold["vectors"][1])))
