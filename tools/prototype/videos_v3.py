import json, sys, os, urllib.request, xml.etree.ElementTree as ET, concurrent.futures as cf
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from minilm import MiniLM
from channels import IDS, NS

def entries(cid):
    try:
        root = ET.fromstring(urllib.request.urlopen(f"https://www.youtube.com/feeds/videos.xml?channel_id={cid}", timeout=20).read())
    except Exception:
        return []
    ch = root.findtext("a:title", namespaces=NS); out = []
    for e in root.findall("a:entry", NS):
        g = e.find("m:group", NS)
        out.append({"id": e.findtext("yt:videoId", namespaces=NS), "title": e.findtext("a:title", namespaces=NS), "channel": ch,
                    "published": e.findtext("a:published", namespaces=NS)[:10],
                    "desc": (g.findtext("m:description", namespaces=NS) or "") if g is not None else ""})
    return out

def main():
    book = json.load(open(sys.argv[1])); m = MiniLM(sys.argv[2]); threshold = float(sys.argv[3]) if len(sys.argv) > 3 else 0.45
    with cf.ThreadPoolExecutor(8) as ex: vids = [v for vs in ex.map(entries, IDS) for v in vs]
    vids = [v for v in vids if "#shorts" not in (v["title"] + v["desc"]).lower()]
    themes = []
    for ch in book["chapters"]:
        P = np.array([p["vec"] for p in ch["passages"]], dtype=np.float32); c = P.mean(0); c /= np.linalg.norm(c)
        themes.append((ch["keyphrases"], P, c))
    for v in vids:
        e = m.embed(v["title"] + ". " + v["desc"][:300])
        scores = [0.5 * float(np.max(P @ e)) + 0.5 * float(c @ e) for _, P, c in themes]
        v["theme"] = int(np.argmax(scores)); v["score"] = max(scores)
    print(len(vids), "videos; score percentiles 50/75/90/97:", np.percentile([v["score"] for v in vids], [50, 75, 90, 97]).round(3).tolist())
    for t, (kp, _, _) in enumerate(themes):
        mine = sorted([v for v in vids if v["theme"] == t], key=lambda v: -v["score"])
        keep = [v for v in mine if v["score"] >= threshold][:4]
        print(f"\n### {' · '.join(kp[:3])}")
        for v in keep: print(f"   ✓ {v['score']:.2f}  {v['title'][:90]}  — {v['channel']}")
        for v in mine[len(keep):len(keep) + 1]: print(f"   ✗ {v['score']:.2f}  {v['title'][:90]}  — {v['channel']}")

if __name__ == "__main__":
    main()
