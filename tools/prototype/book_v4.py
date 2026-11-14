"""Book v4: re-arrange the passages of book_v3.json and compare with v3's arrangement.

    python3 tools/prototype/book_v4.py book_v3.json [--print]      # writes book_v4.json

Measures, for each arrangement: how alike neighbouring passages are, how many joins are weak,
how alike a chapter's passages are, how many spoken continuations stay together, and how far the
reading path is from a bound no path can beat. See docs/book.md.
"""
import json, sys
import numpy as np
from arrange import organize, gaps, spoken_next, mst_weight

def report(name, chapters, S, nxt):
    order = [i for ch in chapters for i in ch]; pos = {v: p for p, v in enumerate(order)}
    adj = [S[a][b] for ch in chapters for a, b in zip(ch, ch[1:])]
    coh = [np.mean([S[i][j] for i in ch for j in ch if i < j]) for ch in chapters if len(ch) > 1]
    kept = np.mean([pos[b] - pos[a] == 1 for a, b in nxt]) if nxt else 0
    length = sum(1 - S[a][b] for a, b in zip(order, order[1:]))
    print(f"{name:28s} chapters {len(chapters):2d}  neighbours alike {np.mean(adj):.3f}  weak joins (<0.2) {np.mean(np.array(adj) < 0.2):4.0%}  "
          f"chapter cohesion {np.mean(coh):.3f}  spoken continuations kept {kept:4.0%}  path / lower bound {length / mst_weight((1 - S).tolist()):.2f}")

def main():
    book = json.load(open(sys.argv[1]))
    P = [p for ch in book["chapters"] for p in ch["passages"]]
    E = np.array([p["vec"] for p in P], dtype=np.float32); S = E @ E.T
    journal = [p["journal"] for p in P]; seq = [p["seq"] for p in P]; nxt = spoken_next(journal, seq)
    v3, t = [], 0
    for ch in book["chapters"]: v3.append(list(range(t, t + len(ch["passages"])))); t += len(ch["passages"])
    rng = np.random.default_rng(0)
    report("shuffled inside chapters", [list(rng.permutation(c)) for c in v3], S, nxt)
    report("v3: themes, date order", v3, S, nxt)
    v4 = organize(E, journal, seq)
    report("v4: one path, best cuts", v4, S, nxt)
    g = set(gaps(v4, E, journal, seq)); print(f"gaps marked: {len(g)}; chapter sizes: {[len(c) for c in v4]}")
    if "--print" in sys.argv:
        for c, ch in enumerate(v4):
            print(f"\n=== chapter {c + 1} ({len(ch)}) ===")
            for a, b in zip([None] + ch, ch):
                if a is not None and (a, b) in g: print("      · · ·  (gap)")
                print(f"  [{P[b]['date']}] {P[b]['text']}")
    json.dump({"chapters": [{"keyphrases": [], "passages": [P[i] for i in ch]} for ch in v4]}, open("book_v4.json", "w"))

if __name__ == "__main__":
    main()
