"""all-MiniLM-L6-v2 in plain numpy: WordPiece tokenizer + BERT forward + mean pooling + L2 norm.

Written to mirror, step for step, the Swift implementation that runs on the iPhone, so that
what is measured here is what the phone computes.
"""
import json, struct, unicodedata, sys, os
import numpy as np

class MiniLM:
    def __init__(self, folder, dtype=np.float32):
        self.vocab = {}
        with open(os.path.join(folder, "vocab.txt"), encoding="utf-8") as f:
            for i, line in enumerate(f):
                self.vocab[line.rstrip("\n")] = i
        self.w = load_safetensors(os.path.join(folder, "model.safetensors"), dtype)
        cfg = json.load(open(os.path.join(folder, "config.json")))
        self.layers, self.heads, self.hidden = cfg["num_hidden_layers"], cfg["num_attention_heads"], cfg["hidden_size"]
        self.eps = cfg["layer_norm_eps"]

    # ---------- tokenizer (BERT uncased) ----------
    @staticmethod
    def _is_punct(ch):
        cp = ord(ch)
        if 33 <= cp <= 47 or 58 <= cp <= 64 or 91 <= cp <= 96 or 123 <= cp <= 126: return True
        return unicodedata.category(ch).startswith("P")

    def basic_tokens(self, text):
        text = "".join(" " if unicodedata.category(c) in ("Zs",) or c in "\t\n\r" else c for c in text
                       if not (ord(c) == 0 or ord(c) == 0xFFFD or (unicodedata.category(c).startswith("C") and c not in "\t\n\r")))
        out = []
        for word in text.lower().split():
            word = "".join(c for c in unicodedata.normalize("NFD", word) if unicodedata.category(c) != "Mn")
            cur = ""
            for ch in word:
                if self._is_punct(ch) or 0x4E00 <= ord(ch) <= 0x9FFF:
                    if cur: out.append(cur); cur = ""
                    out.append(ch)
                else:
                    cur += ch
            if cur: out.append(cur)
        return out

    def wordpiece(self, word):
        if len(word) > 100: return [self.vocab["[UNK]"]]
        ids, start = [], 0
        while start < len(word):
            end, found = len(word), None
            while start < end:
                piece = word[start:end] if start == 0 else "##" + word[start:end]
                if piece in self.vocab: found = self.vocab[piece]; break
                end -= 1
            if found is None: return [self.vocab["[UNK]"]]
            ids.append(found); start = end
        return ids

    def encode(self, text, max_len=256):
        ids = [self.vocab["[CLS]"]]
        for t in self.basic_tokens(text): ids += self.wordpiece(t)
        ids = ids[: max_len - 1] + [self.vocab["[SEP]"]]
        return ids

    # ---------- model ----------
    def layer_norm(self, x, name):
        mu = x.mean(-1, keepdims=True); var = ((x - mu) ** 2).mean(-1, keepdims=True)
        return (x - mu) / np.sqrt(var + self.eps) * self.w[name + ".weight"] + self.w[name + ".bias"]

    def dense(self, x, name):
        return x @ self.w[name + ".weight"].T + self.w[name + ".bias"]

    def embed(self, text):
        ids = self.encode(text)
        n = len(ids)
        x = self.w["embeddings.word_embeddings.weight"][ids] + self.w["embeddings.position_embeddings.weight"][:n] \
            + self.w["embeddings.token_type_embeddings.weight"][0]
        x = self.layer_norm(x, "embeddings.LayerNorm")
        d = self.hidden // self.heads
        for l in range(self.layers):
            p = f"encoder.layer.{l}."
            q = self.dense(x, p + "attention.self.query").reshape(n, self.heads, d).transpose(1, 0, 2)
            k = self.dense(x, p + "attention.self.key").reshape(n, self.heads, d).transpose(1, 0, 2)
            v = self.dense(x, p + "attention.self.value").reshape(n, self.heads, d).transpose(1, 0, 2)
            s = q @ k.transpose(0, 2, 1) / np.sqrt(d)
            s = np.exp(s - s.max(-1, keepdims=True)); s /= s.sum(-1, keepdims=True)
            ctx = (s @ v).transpose(1, 0, 2).reshape(n, self.hidden)
            x = self.layer_norm(self.dense(ctx, p + "attention.output.dense") + x, p + "attention.output.LayerNorm")
            h = self.dense(x, p + "intermediate.dense")
            h = 0.5 * h * (1 + erf(h / np.sqrt(2)))
            x = self.layer_norm(self.dense(h, p + "output.dense") + x, p + "output.LayerNorm")
        v = x.mean(0)
        return (v / np.linalg.norm(v)).astype(np.float32)

def erf(x):
    # Abramowitz-Stegun 7.1.26 is too coarse; use numpy's vectorised math via the gamma relation.
    from math import erf as _erf
    return np.vectorize(_erf, otypes=[np.float64])(x)

def load_safetensors(path, dtype):
    with open(path, "rb") as f:
        n = struct.unpack("<Q", f.read(8))[0]
        header = json.loads(f.read(n))
        data = f.read()
    out = {}
    for name, meta in header.items():
        if name == "__metadata__": continue
        a, b = meta["data_offsets"]
        if meta["dtype"] != "F32": continue   # e.g. the position_ids buffer
        out[name] = np.frombuffer(data[a:b], dtype=np.float32).reshape(meta["shape"]).astype(dtype)
    return out

if __name__ == "__main__":
    m = MiniLM(sys.argv[1])
    a, b, c = (m.embed(t) for t in ["I meditate to watch my cravings without reacting.",
                                     "Vipassana teaches observing sensations with equanimity.",
                                     "GPU shortages and the AI investment bubble."])
    print("sim related", float(a @ b), "unrelated", float(a @ c))
