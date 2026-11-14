"""Reassembly benchmark: can an arrangement put a shuffled book back together?

Real essays are cut into passages and shuffled together. The truth is known: which essay a passage
came from (the chapters) and which passage followed which (the order). No journals are involved.

    python3 tools/prototype/reassemble.py essays.json ./minilm [trials]
    python3 tools/prototype/reassemble.py essays.json --onnx model.onnx tokenizer.json ["prefix "] [trials]

essays.json is a list of long plain-text or Markdown strings (the numbers in docs/book.md used 102
public essays). The second form scores another embedding model (pip install onnxruntime tokenizers).
"""
import json, math, re, sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from arrange import organize, shortest_path
from book_v3 import kmeans_themes

def passages_of(md, lo=45, hi=110, most=14):
    md = re.sub(r"```.*?```", " ", md, flags=re.S); md = re.sub(r"!\[[^\]]*\]\([^)]*\)", " ", md)
    md = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", md); md = re.sub(r"<[^>]+>", " ", md)
    out, cur = [], ""
    for p in re.split(r"\n\s*\n", md):
        p = re.sub(r"\s+", " ", re.sub(r"^[#>*\-\d. ]+", "", p)).strip()
        if len(p.split()) < 8: continue
        cur = (cur + " " + p).strip()
        if len(cur.split()) >= lo: out.append(" ".join(cur.split()[:hi])); cur = ""
    return out[:most]

def onnx_embedder(model, tokenizer, prefix=""):
    import onnxruntime as ort; from tokenizers import Tokenizer
    s = ort.InferenceSession(model, providers=["CPUExecutionProvider"]); tok = Tokenizer.from_file(tokenizer); tok.enable_truncation(256)
    ins = {i.name: i for i in s.get_inputs()}; outs = [o.name for o in s.get_outputs()]
    def embed(text):
        ids = np.array([tok.encode(prefix + text).ids], dtype=np.int64); feed = {}
        for name, i in ins.items():  # text inputs; any other modality gets an empty array
            feed[name] = ids if name == "input_ids" else np.ones_like(ids) if name == "attention_mask" else np.zeros_like(ids) if name == "token_type_ids" \
                else np.zeros((0, i.shape[-1]), dtype=np.float32)
        r = dict(zip(outs, s.run(None, feed)))
        v = r["sentence_embedding"][0] if "sentence_embedding" in r else r["last_hidden_state"][0].mean(0)
        return v / np.linalg.norm(v)
    return embed

def rand_index(lab, truth):
    """Adjusted Rand index: 1 = the chapters are exactly the essays, 0 = chance."""
    n = len(lab); ct, sa, sb = {}, {}, {}
    for a, b in zip(lab, truth): ct[(a, b)] = ct.get((a, b), 0) + 1; sa[a] = sa.get(a, 0) + 1; sb[b] = sb.get(b, 0) + 1
    idx = sum(math.comb(c, 2) for c in ct.values()); A = sum(math.comb(c, 2) for c in sa.values()); B = sum(math.comb(c, 2) for c in sb.values())
    exp = A * B / math.comb(n, 2); return (idx - exp) / ((A + B) / 2 - exp)

def main():
    essays = [p for p in (passages_of(t) for t in json.load(open(sys.argv[1]))) if len(p) >= 10]
    args = sys.argv[2:]
    if args[0] == "--onnx":
        rest = args[3:]; prefix = rest[0] if rest and not rest[0].isdigit() else ""
        embed = onnx_embedder(args[1], args[2], prefix); trials = int(rest[-1]) if rest and rest[-1].isdigit() else 10
    else:
        from minilm import MiniLM
        embed = MiniLM(args[0]).embed; trials = int(args[1]) if len(args) > 1 else 10
    res = {}
    for t in range(trials):
        rng = np.random.default_rng(100 + t); texts, essay, nxt = [], [], []
        for c, e in enumerate(rng.choice(len(essays), 8, replace=False)):
            for q, p in enumerate(essays[e]):
                if q: nxt.append((len(texts) - 1, len(texts)))
                texts.append(p); essay.append(c)
        perm = rng.permutation(len(texts)); inv = np.argsort(perm)
        E = np.array([embed(texts[i]) for i in perm], dtype=np.float32); n = len(E)
        truth = [essay[i] for i in perm]; pairs = [(int(inv[a]), int(inv[b])) for a, b in nxt]
        S = E @ E.T; np.fill_diagonal(S, -1); top = np.argsort(-S, axis=1)[:, :5]
        res.setdefault("signal: share of a passage's 5 nearest that are from its essay", []).append(np.mean([[truth[j] == truth[i] for j in top[i]] for i in range(n)]))
        groups, _ = kmeans_themes(E, 8)
        books = {"v3 (themes, no order inside)": [list(map(int, g)) for g in groups],
                 "v4 (one path, best cuts)": organize(E, [str(i) for i in range(n)], [0] * n)}
        for name, chapters in books.items():
            order = [i for ch in chapters for i in ch]; pos = {v: p for p, v in enumerate(order)}; lab = [0] * n
            for c, ch in enumerate(chapters):
                for i in ch: lab[i] = c
            res.setdefault(name + ": chapters right (adjusted Rand)", []).append(rand_index(lab, truth))
            res.setdefault(name + ": true neighbours side by side", []).append(np.mean([abs(pos[a] - pos[b]) == 1 for a, b in pairs]))
    print(f"{len(essays)} essays; {trials} trials of 8 shuffled essays (~{n} passages each)")
    for k, v in res.items(): print(f"  {k:68s} {np.mean(v):.3f} ± {np.std(v) / math.sqrt(len(v)):.3f}")

if __name__ == "__main__":
    main()
