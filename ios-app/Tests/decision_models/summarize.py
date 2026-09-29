#!/usr/bin/env python3
from __future__ import annotations

import json
import statistics
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "artifacts" / "decision-model-benchmark"

def pct(value):
    return "n/a" if value is None else f"{100 * value:.1f}%"

def ms(value):
    return "n/a" if value is None else f"{value:.0f} ms"

def mb(value):
    return "n/a" if value is None else f"{value:.0f} MB"

def load(name):
    path = OUT / f"{name}.json"
    return json.loads(path.read_text()) if path.exists() else None

def kev_baseline():
    path = ROOT / "ios-app" / "Tests" / "kev" / "item-state-results.json"
    data = json.loads(path.read_text())
    cases = data["cases"]
    rel = sum((c["relevance"] >= 0.5) == bool(c["expected_relevant"]) for c in cases)
    topic = sum(c["topic"] == c["expected_topic"] for c in cases)
    inj = [c for c in cases if c["id"] in {"injection_negative", "delimiter_negative"}]
    inj_ok = sum(c["relevance"] < 0.5 for c in inj)
    times_ms = [1000 * c["packed_seconds"] for c in cases]
    return {
        "model": "Kev-0.5B (historical FP32)",
        "relevance_accuracy": rel / len(cases),
        "topic_accuracy": topic / len(cases),
        "injection_accuracy": inj_ok / len(inj),
        "reads_median_ms": statistics.median(times_ms),
        "reads_p95_ms": sorted(times_ms)[max(0, round(0.95 * (len(times_ms) - 1)))],
        "note": "Existing SlowClaw item-state fixture; 2-thread Linux CPU, float32. Timing is not same-run hardware.",
    }

def row(d):
    return {
        "model": d["model"]["name"],
        "relevance_accuracy": d["accuracy"]["reads_relevance"]["accuracy"],
        "topic_accuracy": d["accuracy"]["reads_topic"]["accuracy"],
        "injection_accuracy": d["accuracy"]["reads_prompt_injection_negatives"]["accuracy"],
        "journal_accuracy": d["accuracy"]["journal_fields"]["overall"]["accuracy"],
        "create_accuracy": d["accuracy"]["create_best_sentence"]["accuracy"],
        "reads_median_ms": d["timing"]["reads_5_heads_wall"]["median_ms"],
        "reads_p95_ms": d["timing"]["reads_5_heads_wall"]["p95_ms"],
        "journal_median_ms": d["timing"]["journal_5_heads_wall"]["median_ms"],
        "create_median_ms": d["timing"]["create_1_head_wall"]["median_ms"],
        "load_s": d["model"]["model_load_s"],
        "peak_rss_mb": d["model"]["peak_rss_mb"],
        "snapshot_mb": d["model"]["snapshot_size_bytes"] / 1_000_000,
        "cpu": d["environment"]["cpu"],
    }

def main():
    gliner = load("gliner")
    intern = load("intern")
    if not gliner or not intern:
        raise SystemExit("Both gliner.json and intern.json are required")

    rows = [row(gliner), row(intern)]
    kev = kev_baseline()

    lines = [
        "# SlowClaw local decision-model benchmark",
        "",
        "Synthetic, project-specific smoke benchmark. It compares model behavior on SlowClaw-shaped decisions; it is not a population-level or held-out model-quality claim.",
        "",
        "## Same-run results",
        "",
        "| Model | Reads relevance | Reads topic | Injection negatives | Journal fields | Create best sentence | Reads 5-head median | Journal 5-head median | Create median | Peak RSS | Model snapshot |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for r in rows:
        lines.append(
            f"| {r['model']} | {pct(r['relevance_accuracy'])} | {pct(r['topic_accuracy'])} | {pct(r['injection_accuracy'])} | "
            f"{pct(r['journal_accuracy'])} | {pct(r['create_accuracy'])} | {ms(r['reads_median_ms'])} | "
            f"{ms(r['journal_median_ms'])} | {ms(r['create_median_ms'])} | {mb(r['peak_rss_mb'])} | {r['snapshot_mb']:.0f} MB |"
        )

    lines += [
        "",
        f"Runner CPU: {rows[0]['cpu']}.",
        "",
        "## Existing Kev reference",
        "",
        f"Kev argmax relevance on the same 12 Reads fixtures: {pct(kev['relevance_accuracy'])}; topic: {pct(kev['topic_accuracy'])}; "
        f"two prompt-injection negatives: {pct(kev['injection_accuracy'])}. Historical median packed CPU time was {ms(kev['reads_median_ms'])}. "
        "That timing came from the earlier 2-thread FP32 run, so it is not a same-hardware speed comparison.",
        "",
        "## Per-field journal accuracy",
        "",
        "| Field | GLiNER | Intern-Decision |",
        "|---|---:|---:|",
    ]
    fields = gliner["accuracy"]["journal_fields"]["per_field"].keys()
    for field in fields:
        g = gliner["accuracy"]["journal_fields"]["per_field"][field]["accuracy"]
        i = intern["accuracy"]["journal_fields"]["per_field"][field]["accuracy"]
        lines.append(f"| {field} | {pct(g)} | {pct(i)} |")

    lines += [
        "",
        "## Length probes",
        "",
        "| Model | Target words | Wall time | Result |",
        "|---|---:|---:|---|",
    ]
    for data in (gliner, intern):
        for p in data["timing"]["latency_probes"]:
            result = "ok" if not p["error"] else p["error"].replace("|", "\\|")
            lines.append(f"| {data['model']['name']} | {p['target_words']} | {ms(p['wall_ms'])} | {result} |")

    lines += [
        "",
        "## Fixture scope",
        "",
        "- Reads: the existing 12-case SlowClaw Kev fixture, with five decisions in one request: relevance, worth-reading, topic, novelty, priority.",
        "- Journal: 12 synthetic journal passages x five decisions: durable-memory value, todo detection, content type, shareability, topic.",
        "- Create: eight synthetic journals where the model chooses one exact source sentence (or abstains) as the strongest standalone insight.",
        "- All benchmark text is synthetic and project-scoped; no private journal content is used.",
        "",
        "Raw outputs are in gliner.json and intern.json.",
    ]

    report = "\n".join(lines) + "\n"
    (OUT / "report.md").write_text(report)
    print(report)

if __name__ == "__main__":
    main()
