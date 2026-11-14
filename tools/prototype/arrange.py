"""Book v4 arrangement: one reading path through every passage, then the best cuts into chapters.

Written with plain loops so that ios-app/SlowClawApp/Book/BookOrganizer.swift can mirror it line by
line. Everything here is checkable:

  * the path is compared with a lower bound no path can beat (the minimum spanning tree);
  * for a given path, the chapter cuts are exactly optimal (dynamic programming);
  * `python3 arrange.py` checks the solver against brute force on small cases.
"""
import itertools, math
import numpy as np

SPOKEN_BONUS = 0.15   # what "this was said right after that" is worth, in similarity units
MIN_CHAPTER = 4

def mst_weight(D):
    """Weight of the minimum spanning tree: no path through all points can be shorter."""
    n = len(D)
    if n < 2: return 0.0
    done = [False] * n; done[0] = True; dist = [float(D[0][j]) for j in range(n)]; total = 0.0
    for _ in range(n - 1):
        j = min((x for x in range(n) if not done[x]), key=lambda x: dist[x])
        total += dist[j]; done[j] = True
        for x in range(n):
            if not done[x] and D[j][x] < dist[x]: dist[x] = float(D[j][x])
    return total

def path_cost(order, C): return float(sum(C[a][b] for a, b in zip(order, order[1:])))

def _improve(o, X, symmetric):
    """Local search on a tour whose first stop is a dummy at distance 0 from everything (so the tour
    is really an open path). Reverses stretches (symmetric costs only) and relocates runs of one to
    three stops, until no move shortens it."""
    N = len(o); improved = True
    while improved:
        improved = False
        if symmetric:
            for i in range(N - 1):
                for j in range(i + 2, N):
                    a, b, c, d = o[i], o[i + 1], o[j], o[(j + 1) % N]
                    if X[a][c] + X[b][d] - X[a][b] - X[c][d] < -1e-6:
                        o[i + 1:j + 1] = o[i + 1:j + 1][::-1]; improved = True
        for L in (1, 2, 3):
            i = 1
            while i + L <= N:
                p, s0, s1, q = o[i - 1], o[i], o[i + L - 1], o[(i + L) % N]
                gain = X[p][s0] + X[s1][q] - X[p][q]
                best, at, flip = gain - 1e-6, -1, False
                for k in range(N):
                    if i - 1 <= k <= i + L - 1: continue
                    a, b = o[k], o[(k + 1) % N]
                    c = X[a][s0] + X[s1][b] - X[a][b]
                    if c < best: best, at, flip = c, k, False
                    if symmetric:
                        c = X[a][s1] + X[s0][b] - X[a][b]
                        if c < best: best, at, flip = c, k, True
                if at >= 0:
                    seg = o[i:i + L]
                    if flip: seg = seg[::-1]
                    anchor = o[at]; del o[i:i + L]
                    k = o.index(anchor); o[k + 1:k + 1] = seg; improved = True
                else:
                    i += 1
    return o

def shortest_path(C, starts=4):
    """Order of all rows of the symmetric cost matrix C that makes neighbours as close as possible."""
    n = len(C)
    if n <= 2: return list(range(n))
    X = [[float(C[a][b]) if a < n and b < n else 0.0 for b in range(n + 1)] for a in range(n + 1)]
    best, best_cost = None, 0.0
    for t in range(min(starts, n)):
        s = t * (n - 1) // max(1, min(starts, n) - 1)
        o = [n, s]; left = [x for x in range(n) if x != s]
        while left:
            j = min(left, key=lambda x: X[o[-1]][x]); o.append(j); left.remove(j)
        o = _improve(o, X, True)
        c = path_cost(o[1:], C)
        if best is None or c < best_cost - 1e-6: best, best_cost = o[1:], c
    return best

def directed_refine(order, W):
    """Same search for costs that depend on direction: runs are relocated but never reversed."""
    n = len(order)
    if n <= 2: return list(order)
    X = [[float(W[a][b]) if a < n and b < n else 0.0 for b in range(n + 1)] for a in range(n + 1)]
    return _improve([n] + list(order), X, False)[1:]

def cut_chapters(order, S, k, allowed, lo=MIN_CHAPTER, hi=None):
    """Exact best split of `order` into at most k chapters of lo..hi passages, cutting only before the
    positions in `allowed`. Maximises, over chapters, (sum of pairwise similarity inside) / size."""
    m = len(order); hi = hi or m
    P = [[0.0] * (m + 1) for _ in range(m + 1)]
    for a in range(m):
        row = 0.0
        for b in range(m):
            row += float(S[order[a]][order[b]]); P[a + 1][b + 1] = P[a][b + 1] + row
    score = lambda a, b: (P[b][b] - P[a][b] - P[b][a] + P[a][a]) / (b - a)
    pts = [0] + [t for t in range(1, m) if t in allowed] + [m]
    NEG = -1e18
    best = [[NEG] * len(pts) for _ in range(k + 1)]; arg = [[0] * len(pts) for _ in range(k + 1)]; best[0][0] = 0.0
    for q in range(1, k + 1):
        for bi in range(1, len(pts)):
            for ai in range(bi):
                size = pts[bi] - pts[ai]
                if size < lo or size > hi or best[q - 1][ai] == NEG: continue
                v = best[q - 1][ai] + score(pts[ai], pts[bi])
                if v > best[q][bi]: best[q][bi] = v; arg[q][bi] = ai
    q = k
    while q > 0 and best[q][len(pts) - 1] == NEG: q -= 1
    if q == 0: return [list(order)]
    out, bi = [], len(pts) - 1
    while q > 0:
        ai = arg[q][bi]; out.append(list(order[pts[ai]:pts[bi]])); bi = ai; q -= 1
    return out[::-1]

def spoken_next(journal, seq):
    """Pairs (a, b) where passage b was said right after passage a in the same sitting."""
    by = {}
    for i, j in enumerate(journal): by.setdefault(j, []).append(i)
    pairs = set()
    for ids in by.values():
        ids.sort(key=lambda i: (seq[i], i))
        for a, b in zip(ids, ids[1:]): pairs.add((a, b))
    return pairs

def organize(E, journal, seq, bonus=SPOKEN_BONUS):
    """Chapters as lists of passage indices, in reading order."""
    n = len(E)
    if n == 0: return []
    S = (np.asarray(E) @ np.asarray(E).T).tolist(); nxt = spoken_next(journal, seq)
    if n < 6: return [sorted(range(n), key=lambda i: (journal[i], seq[i]))]
    link = lambda a, b: (a, b) in nxt or (b, a) in nxt
    C = [[0.0 if a == b else 1 - S[a][b] + (0 if link(a, b) else bonus) for b in range(n)] for a in range(n)]
    W = [[1 - S[a][b] - (bonus if (a, b) in nxt else 0) for b in range(n)] for a in range(n)]
    path = shortest_path(C)
    fwd, bwd = directed_refine(path, W), directed_refine(path[::-1], W)
    order = bwd if path_cost(bwd, W) < path_cost(fwd, W) - 1e-6 else fwd
    allowed = {t for t in range(1, n) if (order[t - 1], order[t]) not in nxt}
    k = max(1, min(14, round(math.sqrt(n / 2))))
    return cut_chapters(order, S, k, allowed, MIN_CHAPTER, max(3 * MIN_CHAPTER, math.ceil(2 * n / k)))

def gaps(chapters, E, journal, seq):
    """Joins where the book jumps: far below the book's usual closeness and not a spoken continuation."""
    S = np.asarray(E) @ np.asarray(E).T; nxt = spoken_next(journal, seq)
    joins = [(a, b) for ch in chapters for a, b in zip(ch, ch[1:])]
    if len(joins) < 8: return []
    sims = [float(S[a][b]) for a, b in joins]
    bar = min(0.25, float(np.mean(sims) - 1.5 * np.std(sims)))
    return [(a, b) for (a, b), s in zip(joins, sims) if s < bar and (a, b) not in nxt]

if __name__ == "__main__":
    rng = np.random.default_rng(1); worst = 0.0
    for _ in range(40):
        P = rng.normal(size=(8, 5)); P /= np.linalg.norm(P, axis=1, keepdims=True); D = (1 - P @ P.T).tolist()
        opt = min(path_cost(p, D) for p in itertools.permutations(range(8)))
        assert mst_weight(D) <= opt + 1e-9
        worst = max(worst, path_cost(shortest_path(D), D) / opt - 1)
    print(f"8 points, 40 cases: worst excess over the true shortest path {worst:.1%}")
    P = rng.normal(size=(200, 20)); P /= np.linalg.norm(P, axis=1, keepdims=True); D = (1 - P @ P.T).tolist()
    o = shortest_path(D); assert sorted(o) == list(range(200))
    print(f"200 points: path is {path_cost(o, D) / mst_weight(D):.2f}x the lower bound")
    S = (P @ P.T).tolist(); ch = cut_chapters(o, S, 10, set(range(1, 200)), 4, 40)
    assert [i for c in ch for i in c] == o and all(4 <= len(c) <= 40 for c in ch)
    print("cuts:", [len(c) for c in ch])
