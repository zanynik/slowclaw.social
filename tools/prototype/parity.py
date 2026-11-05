import sys, numpy as np, onnxruntime as ort, json
from tokenizers import Tokenizer
sys.path.insert(0, sys.argv[2]); from minilm import MiniLM
d = sys.argv[1]
m = MiniLM(d); tok = Tokenizer.from_file(d + "/tokenizer.json"); tok.no_padding(); tok.no_truncation()
sess = ort.InferenceSession(d + "/model.onnx")
texts = ["I meditate to watch my cravings without reacting.", "Zero-profit grocery stores could change the economy!",
         "Naïve café résumé — Ünïcödé, punctuation; and numbers 2026.", "So, yeah, um, I think the food hub should return profits."]
worst_tok, worst = 0, 1.0
for t in texts:
    enc = tok.encode(t); ids = enc.ids
    mine = m.encode(t)
    worst_tok += int(ids != mine)
    out = sess.run(None, {"input_ids": np.array([ids], dtype=np.int64), "attention_mask": np.ones((1, len(ids)), dtype=np.int64),
                          "token_type_ids": np.zeros((1, len(ids)), dtype=np.int64)})[0][0]
    ref = out.mean(0); ref /= np.linalg.norm(ref)
    worst = min(worst, float(ref @ m.embed(t)))
print("token mismatches:", worst_tok, "| lowest cosine(numpy, onnx):", round(worst, 6))
