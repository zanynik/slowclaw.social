"""Search queries per theme from named things and recurring concept phrases (no person names).
Prototype stand-in for NLTagger (organizations/places/other names) on device."""
import json, re, sys, os, pickle, collections, math
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from book_v3 import sentences, clean, words, STOP

# People are never put into searches. Like the phone, only products and acronyms count as named
# things (DeepMind, OpenAI, GPU): ordinary capitalised words, which include first names, never do.
NOT_NAMES = set("""i i'm i've i'll okay ok yeah so and but the a an this that it it's we they he she you my our anyway now then
maybe because when what why how yes no hello well also just like right english german indian monday tuesday wednesday thursday
friday saturday sunday january february march april may june july august september october november december""".split())

def named_phrases(text):
    """Products and acronyms: mixed or full capitals (DeepMind, OpenAI, GPU, MCP)."""
    out = []
    for w in re.findall(r"[A-Za-z][A-Za-z0-9-]+", text):
        if w.lower() in NOT_NAMES or not w[0].isupper(): continue
        uppers = sum(c.isupper() for c in w)
        if (uppers == len(w) and len(w) <= 6) or (uppers >= 2 and any(c.islower() for c in w[1:])):
            out.append(w)
    return out

def concept_phrases(text):
    w = words(text)
    return [a + " " + b for a, b in zip(w, w[1:]) if a != b]

def main():
    book = json.load(open(sys.argv[1])); journals = {j["id"]: j for j in json.load(open(sys.argv[2]))}
    emb = pickle.load(open(sys.argv[3], "rb"))
    all_named = collections.Counter(); all_concepts = collections.Counter()
    theme_text = []
    for ch in book["chapters"]:
        P = np.array([p["vec"] for p in ch["passages"]], dtype=np.float32); c = P.mean(0); c /= np.linalg.norm(c)
        # The theme's sentences: from its journals, the ones closest to the theme.
        sents = []
        for jid in {p["journal"] for p in ch["passages"]}:
            for s in sentences(journals[jid]["body"]):
                cs = clean(s)
                if cs in emb and float(emb[cs] @ c) >= 0.35: sents.append(cs)
        text = " ".join(sents + [p["text"] for p in ch["passages"]])
        theme_text.append(text)
        all_named.update(set(named_phrases(text))); all_concepts.update(set(concept_phrases(text)))
    out = []
    for ch, text in zip(book["chapters"], theme_text):
        named = collections.Counter(named_phrases(text)); concepts = collections.Counter(concept_phrases(text))
        n = len(theme_text)
        score_named = {p: c * math.log(1 + n / all_named[p]) for p, c in named.items() if c >= 2}
        score_conc = {p: c * math.log(1 + n / all_concepts[p]) for p, c in concepts.items() if c >= 3}
        top_named = [p for p, _ in sorted(score_named.items(), key=lambda x: -x[1])][:4]
        top_conc = [p for p, _ in sorted(score_conc.items(), key=lambda x: -x[1])][:4]
        print(f"\n{' · '.join(ch['keyphrases'])}\n   named: {top_named}\n   concepts: {top_conc}")
        out.append({"named": top_named, "concepts": top_conc})
    json.dump(out, open("queries_v3.json", "w"))

if __name__ == "__main__":
    main()
