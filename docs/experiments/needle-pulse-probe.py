"""Synthetic-only Needle 3 Pulse ranking probe; no app/backend changes.

Usage: python docs/experiments/needle-pulse-probe.py MODEL.cact RUNTIME.whl
Download the two pinned public artifacts listed in needle-pulse.md first.
Outputs JSON to stdout. Executes the native runtime only after SHA256 checks.
"""
import ctypes
import hashlib
import json
import math
from pathlib import Path
import platform
import statistics
import sys
import tempfile
import time
import zipfile

MODEL_SHA = "c9d915eca282ed42d1a09b143b592adb4cc6744ffe2d294adf5cfc5548170c38"
WHEEL_SHA = "05770ef9a85686583968ea15f62f9ad44217e078efdaa99559d3208bb8a369b0"
REVISION = "b274efcb211a9eef48c9a88da4b43bd569696a39"


def checked_file(path, expected):
    data = Path(path).read_bytes()
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError("Artifact checksum mismatch")
    return data


def normalize(vector):
    norm = math.sqrt(sum(x * x for x in vector))
    if not math.isfinite(norm) or norm <= 0:
        raise ValueError("Invalid embedding")
    return [x / norm for x in vector]


def run(lib, weights):
    lib.needle_load.argtypes = [ctypes.c_char_p, ctypes.c_uint64]
    lib.needle_load.restype = ctypes.c_int
    lib.needle_init.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]
    lib.needle_init.restype = ctypes.c_int
    lib.needle_embed.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_float), ctypes.c_int]
    lib.needle_embed.restype = ctypes.c_int
    lib.needle_last_error.restype = ctypes.c_char_p
    # Keep archive bytes alive until every call finishes. All calls are serial.
    if lib.needle_load(weights, len(weights)) < 0 or lib.needle_init(b"", b"[]", None) < 0:
        raise RuntimeError(lib.needle_last_error())
    dim = lib.needle_embed(b"", None, 0)
    if not 0 < dim <= 65536:
        raise RuntimeError("Invalid embedding dimension")

    def embed(text):
        out = (ctypes.c_float * dim)()
        if lib.needle_embed(text.encode(), out, dim) != dim:
            raise RuntimeError(lib.needle_last_error())
        return normalize(list(out))

    fixture = json.loads(Path(__file__).with_name("jev-batch-benchmark.json").read_text())
    profiles = {
        "technical": fixture["interests"],
        "food": [{"topic": "Vegetarian cooking", "weight": .6}, {"topic": "Food systems", "weight": .4}],
        "sports": [{"topic": "Football", "weight": 1}],
    }
    centroids = {}
    for name, interests in profiles.items():
        vectors = [(embed(i["topic"]), i["weight"]) for i in interests]
        centroids[name] = normalize([sum(v[j] * w for v, w in vectors) for j in range(dim)])
    # Alternate representation checks whether failure is just short topic labels.
    centroids["technical_description"] = embed("I am interested in local AI on phones, AI agents, data engineering, and data quality.")
    centroids["food_description"] = embed("I am interested in vegetarian cooking and food systems.")
    rows = []
    for item in fixture["items"]:
        start = time.monotonic()
        vector = embed(item["text"])
        elapsed = time.monotonic() - start
        rows.append({"title": item["text"].split("\n")[0], "seconds": elapsed,
                     "scores": {name: sum(a * b for a, b in zip(vector, centroid))
                                for name, centroid in centroids.items()}})
    rankings = {name: [r["title"] for r in sorted(rows, key=lambda r: -r["scores"][name])]
                for name in centroids}
    # A small diagnostic, not a comprehensive retrieval benchmark.
    relevant = {"Local AI on a phone", "Reliable data pipelines", "Agent evaluation", "Specific technical correction"}
    return {"synthetic": True, "revision": REVISION, "dimension": dim,
            "host": platform.system() + " " + platform.machine(),
            "median_embedding_seconds": statistics.median(r["seconds"] for r in rows),
            "rows": rows, "rankings": rankings,
            "technical_precision_at_4": len(set(rankings["technical"][:4]) & relevant) / 4,
            "technical_description_precision_at_4": len(set(rankings["technical_description"][:4]) & relevant) / 4}


if __name__ == "__main__":
    if len(sys.argv) != 3 or platform.system() != "Linux" or platform.machine() != "x86_64":
        raise SystemExit("Usage on Linux x86_64: probe.py MODEL.cact RUNTIME.whl")
    weights = checked_file(sys.argv[1], MODEL_SHA)
    checked_file(sys.argv[2], WHEEL_SHA)
    with tempfile.TemporaryDirectory(prefix="slowclaw-needle-") as directory:
        with zipfile.ZipFile(sys.argv[2]) as wheel:
            path = wheel.extract("needle/libneedle3.so", directory)
        result = run(ctypes.CDLL(path), weights)
        print(json.dumps(result, indent=2))
