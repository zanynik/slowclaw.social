"""Discovery prototype: theme queries → live Google News / YouTube → ranked by closeness to the
author's own passages (MiniLM, same as the phone). Usage:
  python3 -I discover_v3.py book_v3.json minilm [--source=news|videos] [--queries=keyphrase|bigram]
"""
import json, re, sys, os, urllib.request, urllib.parse, html as htmlmod, xml.etree.ElementTree as ET
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from minilm import MiniLM

UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

def get(url, cookie=None):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Language": "en", **({"Cookie": cookie} if cookie else {})})
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read().decode("utf-8", "replace")

def news(query, days=30):
    q = urllib.parse.urlencode({"q": f"{query} when:{days}d", "hl": "en-US", "gl": "US", "ceid": "US:en"})
    root = ET.fromstring(get("https://news.google.com/rss/search?" + q))
    out = []
    for it in root.iter("item"):
        title = it.findtext("title") or ""; src = it.findtext("source") or ""
        if src and title.endswith(" - " + src): title = title[: -len(src) - 3]
        out.append({"title": title, "source": src, "url": it.findtext("link")})
    return out

def videos(query):
    page = get("https://www.youtube.com/results?" + urllib.parse.urlencode({"search_query": query, "sp": "EgIQAQ=="}), cookie="SOCS=CAI")
    m = re.search(r"var ytInitialData = (\{.*?\});</script>", page, re.S)
    if not m: return []
    data = json.loads(m.group(1)); out = []
    def walk(n):
        if isinstance(n, dict):
            r = n.get("videoRenderer")
            if isinstance(r, dict) and len(r.get("videoId", "")) == 11:
                t = lambda v: (v or {}).get("simpleText") or "".join(x.get("text", "") for x in (v or {}).get("runs", []))
                out.append({"title": t(r.get("title")), "source": t(r.get("ownerText")), "duration": t(r.get("lengthText")),
                            "url": "https://youtu.be/" + r["videoId"]})
            for v in n.values(): walk(v)
        elif isinstance(n, list):
            for v in n: walk(v)
    walk(data)
    seen = set(); return [v for v in out if not (v["url"] in seen or seen.add(v["url"]))]

def seconds(d):
    s = 0
    for p in d.split(":"):
        s = s * 60 + (int(p) if p.isdigit() else 0)
    return s

def main():
    book = json.load(open(sys.argv[1])); m = MiniLM(sys.argv[2])
    source = next((a.split("=")[1] for a in sys.argv if a.startswith("--source=")), "news")
    mode = next((a.split("=")[1] for a in sys.argv if a.startswith("--queries=")), "keyphrase")
    all_scores = []
    for ch in book["chapters"]:
        P = np.array([p["vec"] for p in ch["passages"]], dtype=np.float32)
        cent = P.mean(0); cent /= np.linalg.norm(cent)
        kp = ch["keyphrases"]
        query = " ".join(kp[:2]) if mode == "keyphrase" else next((k for k in kp if " " in k), kp[0])
        try:
            items = news(query) if source == "news" else [v for v in videos(query) if 240 <= seconds(v["duration"]) <= 10800]
        except Exception as e:
            print("fetch failed", query, e); continue
        for it in items:
            v = m.embed(it["title"])
            it["score"] = 0.5 * float(np.max(P @ v)) + 0.5 * float(cent @ v)
        items.sort(key=lambda x: -x["score"])
        all_scores += [it["score"] for it in items]
        print(f"\n### {' · '.join(kp)}  →  query “{query}”  ({len(items)} results)")
        for it in items[:5]:
            print(f"   {it['score']:.2f}  {it['title'][:110]}  — {it['source']}")
        if len(items) > 5:
            print(f"   … lowest: {items[-1]['score']:.2f}  {items[-1]['title'][:90]}")
    if all_scores:
        print(f"\nscore percentiles 25/50/75/90: {np.percentile(all_scores, [25, 50, 75, 90]).round(2).tolist()}")

if __name__ == "__main__":
    main()
