"""Reads: long-form posts (NIP-23) from the app's default writers, scored against the book's themes.

    python3 tools/prototype/reads_v3.py book_v3.json ./minilm 0.45

Needs `pip install websockets`. The writers are read from the app's Swift source, so there is one list.
Only that list of public keys is sent to the relays; nothing from the book leaves this machine.
"""
import asyncio, json, os, re, ssl, sys, time
import numpy as np
import websockets
sys.path.insert(0, os.path.dirname(__file__))
from minilm import MiniLM

HERE = os.path.dirname(os.path.abspath(__file__))
SWIFT = open(os.path.join(HERE, "../../ios-app/SlowClawApp/Discover/Reads.swift"), encoding="utf-8").read()
AUTHORS = dict(re.findall(r'\("([0-9a-f]{64})", "([^"]+)"\)', SWIFT))
RELAYS = re.findall(r'"(wss://[^"]+)"', SWIFT)

async def fetch(relay, flt):
    out = []
    try:
        async with websockets.connect(relay, ssl=ssl.create_default_context(), max_size=16_000_000, open_timeout=15) as ws:
            await ws.send(json.dumps(["REQ", "reads", flt]))
            while True:
                m = json.loads(await asyncio.wait_for(ws.recv(), 20))
                if m[0] != "EVENT": break
                out.append(m[2])
    except Exception as e:
        print(relay, "failed:", repr(e)[:80])
    return out

def tag(e, name):
    return next((t[1] for t in e["tags"] if len(t) > 1 and t[0] == name), None)

async def main():
    book = json.load(open(sys.argv[1])); m = MiniLM(sys.argv[2]); threshold = float(sys.argv[3]) if len(sys.argv) > 3 else 0.45
    flt = {"kinds": [30023], "authors": list(AUTHORS), "since": int(time.time()) - 180 * 86400, "limit": 400}
    newest = {}
    for events in await asyncio.gather(*[fetch(r, flt) for r in RELAYS]):
        for e in events:
            key = (e["pubkey"], tag(e, "d"))
            if e["pubkey"] in AUTHORS and (key not in newest or newest[key]["created_at"] < e["created_at"]): newest[key] = e
    essays = [e for e in newest.values() if (tag(e, "title") or "").strip() and len(e["content"]) >= 1500]
    themes = []
    for ch in book["chapters"]:
        P = np.array([p["vec"] for p in ch["passages"]], dtype=np.float32); c = P.mean(0); c /= np.linalg.norm(c)
        themes.append((ch["keyphrases"], P, c))
    rows = []
    for e in essays:
        v = m.embed(tag(e, "title").strip() + ". " + (tag(e, "summary") or e["content"][:280])[:280])
        scores = [0.5 * float(np.max(P @ v)) + 0.5 * float(c @ v) for _, P, c in themes]
        rows.append((max(scores), int(np.argmax(scores)), tag(e, "title").strip(), AUTHORS[e["pubkey"]]))
    print(len(essays), "essays; score percentiles 50/75/90/97:", np.percentile([r[0] for r in rows], [50, 75, 90, 97]).round(3).tolist())
    for t, (kp, _, _) in enumerate(themes):
        mine = sorted([r for r in rows if r[1] == t], reverse=True)
        keep = [r for r in mine if r[0] >= threshold][:3]
        print(f"\n### {' · '.join(kp[:3])}")
        for r in keep: print(f"   ✓ {r[0]:.2f}  {r[2][:90]}  — {r[3]}")
        for r in mine[len(keep):len(keep) + 1]: print(f"   ✗ {r[0]:.2f}  {r[2][:90]}  — {r[3]}")

if __name__ == "__main__":
    asyncio.run(main())
