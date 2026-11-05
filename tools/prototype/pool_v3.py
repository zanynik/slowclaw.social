import json, sys, os, re, concurrent.futures as cf
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from minilm import MiniLM
from discover_v3 import news, videos, seconds

JUNK = {"since", "are", "one", "god", "social", "earth", "ai.", "since", "big ai"}
def clean_q(q):
    q = re.sub(r"(?:'s|’s)$", "", q.strip(" ."))
    return q if q.lower() not in JUNK and len(q) > 2 else None

def main():
    book = json.load(open(sys.argv[1])); qs = json.load(open(sys.argv[2])); m = MiniLM(sys.argv[3])
    source = next((a.split("=")[1] for a in sys.argv if a.startswith("--source=")), "news")
    threshold = float(next((a.split("=")[1] for a in sys.argv if a.startswith("--min=")), "0.45"))
    kept_total = 0
    for ch, q in zip(book["chapters"], qs):
        P = np.array([p["vec"] for p in ch["passages"]], dtype=np.float32); c = P.mean(0); c /= np.linalg.norm(c)
        queries = list(dict.fromkeys(filter(None, map(clean_q, q["named"][:3] + q["concepts"][:3]))))
        with cf.ThreadPoolExecutor(6) as ex:
            results = list(ex.map(lambda s: (s, (news(s) if source == "news" else [v for v in videos(s) if 240 <= seconds(v["duration"]) <= 10800])[:15]), queries))
        pool = {}
        for s, items in results:
            for it in items: pool.setdefault(it["title"], it | {"query": s})
        for it in pool.values():
            v = m.embed(it["title"])
            it["score"] = 0.5 * float(np.max(P @ v)) + 0.5 * float(c @ v)
        ranked = sorted(pool.values(), key=lambda x: -x["score"])
        best = ranked[0]["score"] if ranked else 0
        keep = [it for it in ranked if it["score"] >= max(threshold, best - 0.12)][:5]
        kept_total += len(keep)
        print(f"\n### {' · '.join(ch['keyphrases'][:3])}  ({len(pool)} pooled from {queries})")
        for it in keep: print(f"   ✓ {it['score']:.2f}  {it['title'][:105]}  — {it['source']}  [{it['query']}]")
        for it in ranked[len(keep):len(keep) + 2]: print(f"   ✗ {it['score']:.2f}  {it['title'][:105]}")
    print("\nkept:", kept_total)

if __name__ == "__main__":
    main()
