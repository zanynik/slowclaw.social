#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Iterable


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Transcribe one journal audio/video file with faster-whisper."
    )
    parser.add_argument("--input", required=True, help="Absolute or relative media path")
    parser.add_argument("--output", required=True, help="Absolute or relative transcript path")
    parser.add_argument("--model", default="base", help="faster-whisper model name or local path")
    parser.add_argument("--language", default=None, help="Optional language hint (e.g. en, de)")
    parser.add_argument("--device", default="auto", help="Device: auto, cpu, cuda")
    parser.add_argument(
        "--compute-type",
        default="int8",
        help="Compute type, e.g. int8, int8_float16, float16, float32",
    )
    parser.add_argument("--beam-size", type=int, default=5, help="Beam size for decoding")
    return parser.parse_args()


def resolve_path(raw: str) -> Path:
    path = Path(raw)
    if path.is_absolute():
        return path
    return (Path.cwd() / path).resolve()


def normalize_model_name(raw_model: str) -> str:
    model = (raw_model or "").strip()
    if not model:
        return "base"

    # Preserve explicit local model directories/files.
    maybe_path = Path(model)
    if maybe_path.exists():
        return model

    lowered = model.lower()
    aliases = {
        "whisper-large-v3-turbo": "large-v3",
        "whisper-large-v3": "large-v3",
        "whisper-large-v2": "large-v2",
        "whisper-large-v1": "large-v1",
        "whisper-large": "large",
        "whisper-medium": "medium",
        "whisper-small": "small",
        "whisper-base": "base",
        "whisper-tiny": "tiny",
    }
    return aliases.get(lowered, model)


def discover_cached_model_dirs() -> list[Path]:
    roots: list[Path] = []
    home = os.environ.get("HOME", "").strip()
    if home:
        roots.append(Path(home) / ".cache" / "huggingface" / "hub")
    hf_home = os.environ.get("HF_HOME", "").strip()
    if hf_home:
        roots.append(Path(hf_home) / "hub")

    found: list[Path] = []
    for root in roots:
        if not root.exists() or not root.is_dir():
            continue
        for entry in root.iterdir():
            if not entry.is_dir():
                continue
            name = entry.name.lower()
            if name.startswith("models--") and "faster-whisper" in name:
                found.append(entry)
    return found


def infer_aliases_from_cache_dir_name(dir_name: str) -> Iterable[str]:
    lower = dir_name.lower()
    if "faster-whisper-large-v3-turbo" in lower:
        yield "whisper-large-v3-turbo"
        yield "large-v3"
    if "faster-whisper-large-v3" in lower:
        yield "large-v3"
    if "faster-whisper-large-v2" in lower:
        yield "large-v2"
    if "faster-whisper-large-v1" in lower:
        yield "large-v1"
    if "faster-whisper-large" in lower:
        yield "large"
    if "faster-whisper-medium" in lower:
        yield "medium"
    if "faster-whisper-small" in lower:
        yield "small"
    if "faster-whisper-base" in lower:
        yield "base"
    if "faster-whisper-tiny" in lower:
        yield "tiny"


def resolve_local_model(raw_model: str) -> str:
    normalized = normalize_model_name(raw_model)

    # Explicit local path remains highest priority.
    explicit = Path(normalized)
    if explicit.exists():
        return str(explicit)

    # If the user provided a common model id, keep it (local_files_only=True will
    # ensure it only succeeds when cache already exists and never downloads).
    common_ids = {
        "tiny",
        "tiny.en",
        "base",
        "base.en",
        "small",
        "small.en",
        "medium",
        "medium.en",
        "large-v1",
        "large-v2",
        "large-v3",
        "large",
        "distil-large-v2",
        "distil-medium.en",
        "distil-small.en",
        "distil-large-v3",
        "distil-large-v3.5",
    }
    if normalized in common_ids:
        return normalized

    # Try to map non-standard aliases to already cached custom directories.
    cached_dirs = discover_cached_model_dirs()
    requested = raw_model.strip().lower()
    normalized_lower = normalized.lower()
    for directory in cached_dirs:
        candidates = {directory.name.lower()}
        candidates.update(alias.lower() for alias in infer_aliases_from_cache_dir_name(directory.name))
        if requested in candidates or normalized_lower in candidates:
            return str(directory)

    # Fallback to normalized id and let loader report cache miss (without downloading).
    return normalized


def available_local_model_labels() -> list[str]:
    labels: set[str] = {"tiny", "base", "small", "medium", "large-v3", "large-v2", "large-v1", "large"}
    for directory in discover_cached_model_dirs():
        labels.add(directory.name)
        for alias in infer_aliases_from_cache_dir_name(directory.name):
            labels.add(alias)
    return sorted(labels)


def main() -> int:
    args = parse_args()
    resolved_model = resolve_local_model(args.model)

    input_path = resolve_path(args.input)
    output_path = resolve_path(args.output)

    if not input_path.exists() or not input_path.is_file():
        print(json.dumps({"ok": False, "error": f"Input file not found: {input_path}"}))
        return 2

    try:
        from faster_whisper import WhisperModel  # type: ignore
    except Exception as exc:  # noqa: BLE001
        print(
            json.dumps(
                {
                    "ok": False,
                    "error": f"faster-whisper import failed: {exc}",
                }
            )
        )
        return 3

    try:
        model = WhisperModel(
            resolved_model,
            device=args.device,
            compute_type=args.compute_type,
            local_files_only=True,
        )
        segments, _ = model.transcribe(
            str(input_path),
            language=(args.language if args.language else None),
            beam_size=max(1, args.beam_size),
            vad_filter=True,
        )
        lines: list[str] = []
        for segment in segments:
            text = str(getattr(segment, "text", "")).strip()
            if text:
                lines.append(text)

        transcript = "\n".join(lines).strip()
        if not transcript:
            print(json.dumps({"ok": False, "error": "Transcription produced empty text"}))
            return 4

        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(f"{transcript}\n", encoding="utf-8")

        print(
            json.dumps(
                {
                    "ok": True,
                    "path": str(output_path),
                    "text": transcript,
                    "model": resolved_model,
                    "device": args.device,
                    "computeType": args.compute_type,
                },
                ensure_ascii=False,
            )
        )
        return 0
    except Exception as exc:  # noqa: BLE001
        available = ", ".join(available_local_model_labels())
        print(
            json.dumps(
                {
                    "ok": False,
                    "error": f"Transcription failed: {exc}",
                    "availableModels": available,
                }
            )
        )
        return 5


if __name__ == "__main__":
    raise SystemExit(main())
