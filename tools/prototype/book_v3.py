"""Book v3 prototype on the real journals, with the same MiniLM the phone will run.

No language model in the loop: segment → central passage → dedup → themes → order.
Usage: python3 -I book_v3.py <journals.json> <minilm_dir> [--cache emb.npz]
"""
import json, re, sys, math, collections, os, pickle
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from minilm import MiniLM

FILLER = re.compile(r"\b(?:uh+|um+|hmm+|mm+-?hmm+|mhm|yeah|okay|ok|you know|i mean|i guess|kind of|sort of|basically|actually|like,)\b[,.]?\s*", re.I)
STOP = set("""a about above after again against all also am an and any are as at be because been before being below between both but by
can could did do does doing down during each even every few for from further had has have having he her here hers him his how i if in
into is it its itself just let me more most my myself no nor not now of off on once only or other our ours out over own really same
she should so some something such than that the their them then there these they thing things think this those through to too under
until up very was we were what when where which while who why will with would you your yeah okay know mean guess maybe want going get
got go lot kind sort actually basically right well like said say says one also much many way stuff need see feel things people time
today something anything everything someone everybody somebody whatever also again still already even always never""".split())

def clean(s):
    s = FILLER.sub("", s)
    s = re.sub(r"\b(\w+)( \1\b)+", r"\1", s, flags=re.I)
    s = re.sub(r"\s+([,.!?])", r"\1", s); s = re.sub(r"([,.!?])[,.]+", r"\1", s)
    s = re.sub(r"\s{2,}", " ", s).strip(" ,.")
    return (s[:1].upper() + s[1:] + ("." if s and s[-1].isalnum() else "")) if s else s

def sentences(text):
    text = re.sub(r"\s+", " ", text)
    return [s.strip() for s in re.split(r"(?<=[.!?])\s+", text) if s.strip()]

def words(t):
    return [w for w in re.findall(r"[a-z][a-z'-]+", t.lower()) if len(w) > 2 and w not in STOP]

def shingles(t, n):
    w = re.findall(r"[a-z']+", t.lower())
    return {" ".join(w[i:i + n]) for i in range(len(w) - n + 1)}

def containment(a, b):
    return len(a & b) / max(1, min(len(a), len(b)))

DANGLING = re.compile(r"^(?:and|but|so|or|because|that|this|these|those|it|which|then|also|to|of|for|with|as|anyway|he|she|they)\b", re.I)

def substance(text):
    """Share of content words: low for small talk and logistics."""
    w = re.findall(r"[a-zA-Z']+", text)
    return len(words(text)) / max(1, len(w))

class Embedder:
    def __init__(self, model, cache_path=None):
        self.m, self.path = model, cache_path
        self.cache = pickle.load(open(cache_path, "rb")) if cache_path and os.path.exists(cache_path) else {}
    def __call__(self, text):
        if text not in self.cache: self.cache[text] = self.m.embed(text)
        return self.cache[text]
    def save(self):
        if self.path: pickle.dump(self.cache, open(self.path, "wb"))

def segment(sents, vecs, window=3, min_len=4, max_len=14):
    """TextTiling with sentence vectors: cut where the next sentences turn away from the last ones."""
    n = len(sents)
    if n <= min_len: return [(0, n)]
    gaps = []
    for i in range(1, n):
        a = vecs[max(0, i - window):i].mean(0); b = vecs[i:i + window].mean(0)
        gaps.append(float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-9)))
    gaps = np.array(gaps)
    depth = np.zeros_like(gaps)
    for i in range(len(gaps)):
        left = gaps[:i + 1].max() if i else gaps[0]; right = gaps[i:].max()
        lmax = max(gaps[max(0, i - 3):i + 1]); rmax = max(gaps[i:i + 4])
        depth[i] = (lmax - gaps[i]) + (rmax - gaps[i])
    cut_at = depth.mean() + 0.5 * depth.std()
    bounds, start = [], 0
    for i in np.argsort(-depth):
        pass
    cuts = sorted(i + 1 for i in range(len(gaps)) if depth[i] >= cut_at
                  and (i == 0 or depth[i] >= depth[i - 1]) and (i == len(gaps) - 1 or depth[i] >= depth[i + 1]))
    for c in cuts:
        if c - start >= min_len and n - c >= 2:
            bounds.append((start, c)); start = c
    bounds.append((start, n))
    # Split segments that are still too long.
    out = []
    for a, b in bounds:
        while b - a > max_len:
            out.append((a, a + max_len // 2 + 3)); a = a + max_len // 2 + 3
        out.append((a, b))
    return out

def central_passage(sents, vecs, a, b):
    """The 3–5 sentence window closest to its segment's meaning, starting where a thought starts."""
    centroid = vecs[a:b].mean(0); centroid /= np.linalg.norm(centroid) + 1e-9
    best = None
    for i in range(a, b):
        if DANGLING.match(sents[i]): continue
        for n in (3, 4, 5):
            if i + n > b: break
            text = " ".join(sents[i:i + n])
            wc = len(text.split())
            if not 30 <= wc <= 120: continue
            v = vecs[i:i + n].mean(0); v /= np.linalg.norm(v) + 1e-9
            score = float(v @ centroid) + 0.6 * substance(text)
            if best is None or score > best[0]: best = (score, text)
    return best[1] if best else None

def build(journals, embed):
    # 1. repeat journals
    kept, seen = [], []
    for j in sorted(journals, key=lambda r: r["created_at"]):
        s = shingles(j["body"], 3)
        if any(containment(s, o) >= 0.5 for o in seen): continue
        seen.append(s); kept.append(j)
    passages = []
    for j in kept:
        sents = [clean(s) for s in sentences(j["body"])]
        sents = [s for s in sents if len(s.split()) >= 4]
        if len(sents) < 3: continue
        vecs = np.stack([embed(s) for s in sents])
        budget = max(1, min(10, len(j["body"]) // 1500 + 1))
        found = []
        for a, b in segment(sents, vecs):
            text = central_passage(sents, vecs, a, b)
            if not text or substance(text) < 0.33: continue
            found.append((substance(text), a, text))
        # Keep the most substantial segments, in their original order.
        for _, a, text in sorted(sorted(found, reverse=True)[:budget], key=lambda x: x[1]):
            passages.append({"text": text, "journal": j["id"], "title": j["title"], "date": j["created_at"][:10], "seq": a})
    E = np.stack([embed(p["text"]) for p in passages])
    # 2. repeat passages
    keep = []
    for i, p in enumerate(passages):
        if any(float(E[i] @ E[k]) >= 0.85 or containment(shingles(p["text"], 4), shingles(passages[k]["text"], 4)) >= 0.35 for k in keep):
            continue
        keep.append(i)
    passages = [passages[i] for i in keep]; E = E[keep]
    return passages, E, len(journals) - len(kept)

def kmeans_themes(E, k, restarts=12, iters=40):
    """Spherical k-means (k-means++ init, fixed seeds) — balanced themes, no chaining."""
    n = len(E); best = None
    for r in range(restarts):
        rng = np.random.default_rng(r)
        C = [E[rng.integers(n)]]
        for _ in range(1, k):
            d = 1 - np.max(np.stack([E @ c for c in C]), axis=0)
            C.append(E[rng.choice(n, p=d.clip(0) ** 2 / (d.clip(0) ** 2).sum())])
        C = np.stack(C)
        for _ in range(iters):
            lab = np.argmax(E @ C.T, axis=1)
            newC = np.stack([E[lab == j].mean(0) if (lab == j).any() else C[j] for j in range(k)])
            newC /= np.linalg.norm(newC, axis=1, keepdims=True) + 1e-9
            if np.allclose(newC, C): break
            C = newC
        score = float(np.sum(np.max(E @ C.T, axis=1)))
        if best is None or score > best[0]: best = (score, lab.copy())
    lab = best[1]
    groups = [list(np.where(lab == j)[0]) for j in range(k)]
    S = E @ E.T
    big = [g for g in groups if len(g) >= 3]
    for g in groups:
        if len(g) >= 3: continue
        for i in g:
            kk = max(range(len(big)), key=lambda q: S[i, big[q]].mean()); big[kk].append(i)
    return big, S

def themes(E, target):
    n = len(E)
    S = E @ E.T
    members = [[i] for i in range(n)]
    alive = set(range(n)); link = S.copy()
    while len(alive) > target:
        ids = sorted(alive); best, pair = -9, None
        for x in range(len(ids)):
            for y in range(x + 1, len(ids)):
                if link[ids[x], ids[y]] > best: best, pair = link[ids[x], ids[y]], (ids[x], ids[y])
        a, b = pair; na, nb = len(members[a]), len(members[b])
        for c in alive:
            if c in (a, b): continue
            link[a, c] = link[c, a] = (na * link[a, c] + nb * link[b, c]) / (na + nb)
        members[a] += members[b]; members[b] = []; alive.remove(b)
    groups = [members[i] for i in alive]
    big = [g for g in groups if len(g) >= 3]
    for g in groups:
        if len(g) >= 3: continue
        for i in g:
            k = max(range(len(big)), key=lambda k: S[i, big[k]].mean())
            big[k].append(i)
    return big, S

def keyphrases(texts, all_texts, k=4):
    """Distinctive one- and two-word phrases of a theme (class-based TF-IDF)."""
    def grams(t):
        w = words(t)
        return w + [a + " " + b for a, b in zip(w, w[1:])]
    df = collections.Counter(g for t in all_texts for g in set(grams(t)))
    tf = collections.Counter(g for t in texts for g in grams(t))
    N = len(all_texts)
    score = {g: c * math.log(N / df[g]) * (1.6 if " " in g else 1) for g, c in tf.items() if c >= 2 and df[g] <= N * 0.3}
    out = []
    for g, _ in sorted(score.items(), key=lambda x: -x[1]):
        if any(g in o or o in g for o in out): continue
        out.append(g)
        if len(out) == k: break
    return out

def main():
    journals = json.load(open(sys.argv[1]))
    model = MiniLM(sys.argv[2])
    cache = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--cache=")), None)
    embed = Embedder(model, cache)
    passages, E, skipped = build(journals, embed)
    embed.save()
    target = max(1, min(14, round(math.sqrt(len(passages) / 2))))
    groups, S = kmeans_themes(E, target) if "--agglo" not in sys.argv else themes(E, target)
    texts = [p["text"] for p in passages]
    # chapters: earliest theme first, then nearest; inside, chronological
    cent = [E[g].mean(0) / np.linalg.norm(E[g].mean(0)) for g in groups]
    order = [min(range(len(groups)), key=lambda k: min(passages[i]["date"] for i in groups[k]))]
    left = set(range(len(groups))) - set(order)
    while left:
        nxt = max(left, key=lambda k: float(cent[order[-1]] @ cent[k])); order.append(nxt); left.remove(nxt)
    chapters = [sorted(groups[k], key=lambda i: (passages[i]["date"], passages[i]["seq"])) for k in order]
    within = [float(S[a, b]) for ch in chapters for a, b in zip(ch, ch[1:])]
    cohesion = [float(np.mean([S[i, j] for i in ch for j in ch if i < j])) for ch in chapters]
    print(f"skipped {skipped} repeat journals; {len(passages)} passages; {len(chapters)} chapters; "
          f"neighbour sim {np.mean(within):.3f}; mean chapter cohesion {np.mean(cohesion):.3f}")
    out = {"chapters": []}
    for c, ch in enumerate(chapters):
        kp = keyphrases([texts[i] for i in ch], texts)
        print(f"\n=== {c + 1}. {' · '.join(kp)}  ({len(ch)}, cohesion {cohesion[order.index(order[c])] if False else np.mean([S[i, j] for i in ch for j in ch if i < j]):.2f}) ===")
        for i in ch:
            print(f"  [{passages[i]['date']}] {texts[i]}")
        out["chapters"].append({"keyphrases": kp, "passages": [passages[i] | {"vec": E[i].tolist()} for i in ch]})
    json.dump(out, open("book_v3.json", "w"))

if __name__ == "__main__":
    main()
