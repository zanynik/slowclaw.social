#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import tempfile
import textwrap
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Render a simple black-background text-card video clip from audio."
    )
    parser.add_argument("--plan", required=True, help="Path to render plan JSON")
    parser.add_argument("--output", required=True, help="Output mp4 path")
    parser.add_argument("--ffmpeg", default="ffmpeg", help="ffmpeg binary")
    parser.add_argument("--ffprobe", default="ffprobe", help="ffprobe binary")
    return parser.parse_args()


def resolve_path(raw: str) -> Path:
    path = Path(raw)
    if path.is_absolute():
        return path
    return (Path.cwd() / path).resolve()


def require_binary(name: str) -> None:
    if shutil.which(name) is None:
        raise RuntimeError(f"Required binary not found on PATH: {name}")


def load_plan(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise RuntimeError(f"Plan file not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Invalid plan JSON: {exc}") from exc


def ffprobe_duration(ffprobe_bin: str, audio_path: Path) -> float:
    cmd = [
        ffprobe_bin,
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        str(audio_path),
    ]
    result = subprocess.run(cmd, check=False, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "ffprobe failed")
    try:
        return float(result.stdout.strip())
    except ValueError as exc:
        raise RuntimeError(f"Could not parse audio duration: {result.stdout.strip()}") from exc


def normalize_cards(cards: list[dict], duration: float) -> list[dict]:
    valid = [card for card in cards if str(card.get("text", "")).strip()]
    if not valid:
        raise RuntimeError("Plan must contain at least one card with text")

    if all(card.get("start") is not None and card.get("end") is not None for card in valid):
        normalized: list[dict] = []
        for card in valid:
            start = max(0.0, float(card["start"]))
            end = max(start + 0.05, float(card["end"]))
            normalized.append({"text": str(card["text"]).strip(), "start": start, "end": end})
        return normalized

    slot = duration / max(1, len(valid))
    normalized = []
    cursor = 0.0
    for index, card in enumerate(valid):
        end = duration if index == len(valid) - 1 else min(duration, cursor + slot)
        normalized.append(
            {
                "text": str(card["text"]).strip(),
                "start": cursor,
                "end": max(cursor + 0.05, end),
            }
        )
        cursor = end
    return normalized


def wrap_card_text(text: str) -> str:
    wrapped = textwrap.fill(text.strip(), width=18)
    return wrapped.strip()


def escape_drawtext_path(path: Path) -> str:
    return str(path).replace("\\", "\\\\").replace(":", "\\:")


def build_filter_complex(card_files: list[Path], cards: list[dict], width: int, height: int) -> str:
    font_size = max(42, int(min(width, height) * 0.065))
    box_border = max(18, int(font_size * 0.4))
    filters = ["[0:v]format=yuv420p[v0]"]
    current = "v0"
    for index, (card_file, card) in enumerate(zip(card_files, cards, strict=True), start=1):
        next_label = f"v{index}"
        start = max(0.0, float(card["start"]))
        end = max(start + 0.05, float(card["end"]))
        filters.append(
            f"[{current}]drawtext="
            f"textfile='{escape_drawtext_path(card_file)}':"
            f"fontcolor=white:fontsize={font_size}:"
            f"x=(w-text_w)/2:y=(h-text_h)/2:"
            f"line_spacing=18:"
            f"box=1:boxcolor=black@0.85:boxborderw={box_border}:"
            f"enable='between(t,{start:.3f},{end:.3f})'"
            f"[{next_label}]"
        )
        current = next_label
    filters.append(f"[{current}]copy[vout]")
    return ";".join(filters)


def main() -> int:
    args = parse_args()
    require_binary(args.ffmpeg)
    require_binary(args.ffprobe)

    plan_path = resolve_path(args.plan)
    output_path = resolve_path(args.output)
    plan = load_plan(plan_path)

    audio_value = str(plan.get("audio_path", "")).strip()
    if not audio_value:
        raise RuntimeError("Plan is missing 'audio_path'")
    audio_path = resolve_path(audio_value)
    if not audio_path.exists() or not audio_path.is_file():
        raise RuntimeError(f"Audio file not found: {audio_path}")

    width = max(360, int(plan.get("width", 1080)))
    height = max(360, int(plan.get("height", 1920)))
    fps = max(12, int(plan.get("fps", 30)))

    audio_start = max(0.0, float(plan.get("audio_start", 0.0)))
    audio_end_raw = plan.get("audio_end")
    full_duration = ffprobe_duration(args.ffprobe, audio_path)
    if audio_end_raw is None:
        duration = max(0.25, full_duration - audio_start)
    else:
        duration = max(0.25, float(audio_end_raw) - audio_start)

    cards = normalize_cards(plan.get("cards") or [], duration)

    output_path.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="zeroclaw_clip_") as tmp_dir:
        tmp_root = Path(tmp_dir)
        card_files: list[Path] = []
        for index, card in enumerate(cards, start=1):
            card_path = tmp_root / f"card_{index:02d}.txt"
            card_path.write_text(wrap_card_text(card["text"]) + "\n", encoding="utf-8")
            card_files.append(card_path)

        filter_complex = build_filter_complex(card_files, cards, width, height)
        cmd = [
            args.ffmpeg,
            "-y",
            "-f",
            "lavfi",
            "-i",
            f"color=c=black:s={width}x{height}:r={fps}:d={duration:.3f}",
            "-ss",
            f"{audio_start:.3f}",
            "-t",
            f"{duration:.3f}",
            "-i",
            str(audio_path),
            "-filter_complex",
            filter_complex,
            "-map",
            "[vout]",
            "-map",
            "1:a:0",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-shortest",
            str(output_path),
        ]
        result = subprocess.run(cmd, check=False, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "ffmpeg failed")

    print(
        json.dumps(
            {
                "ok": True,
                "output": str(output_path),
                "cards": len(cards),
                "duration": round(duration, 3),
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(json.dumps({"ok": False, "error": str(exc)}))
        raise SystemExit(1)
