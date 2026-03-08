#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Iterable


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Probe or install local faster-whisper transcription setup."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    probe = subparsers.add_parser("probe", help="Inspect local transcription readiness")
    probe.add_argument("--model", default="base", help="Configured faster-whisper model name or local path")

    install = subparsers.add_parser("install", help="Install dependencies and prefetch a model")
    install.add_argument("--model", default="base", help="Configured faster-whisper model name or local path")
    install.add_argument("--device", default="auto", help="Device hint for model prefetch")
    install.add_argument("--compute-type", default="int8", help="Compute type hint for model prefetch")

    return parser.parse_args()


def normalize_model_name(raw_model: str) -> str:
    model = (raw_model or "").strip()
    if not model:
        return "base"

    maybe_path = Path(model)
    if maybe_path.exists():
        return str(maybe_path)

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


def available_local_model_labels() -> list[str]:
    labels: set[str] = set()
    for directory in discover_cached_model_dirs():
        labels.add(directory.name)
        for alias in infer_aliases_from_cache_dir_name(directory.name):
            labels.add(alias)
    return sorted(labels)


def configured_model_ready(raw_model: str) -> bool:
    normalized = normalize_model_name(raw_model)
    maybe_path = Path(normalized)
    if maybe_path.exists():
        return True

    available = {value.lower() for value in available_local_model_labels()}
    return normalized.lower() in available or raw_model.strip().lower() in available


def recommended_model(raw_model: str) -> str:
    normalized = normalize_model_name(raw_model)
    return normalized if normalized.strip() else "base"


def faster_whisper_available() -> bool:
    return importlib.util.find_spec("faster_whisper") is not None


def install_faster_whisper() -> None:
    subprocess.run(
        [sys.executable, "-m", "pip", "install", "faster-whisper"],
        check=True,
    )


def prefetch_model(raw_model: str, device: str, compute_type: str) -> str:
    from faster_whisper import WhisperModel  # type: ignore

    normalized = normalize_model_name(raw_model)
    model = WhisperModel(
        normalized,
        device=(device or "auto").strip() or "auto",
        compute_type=(compute_type or "int8").strip() or "int8",
        local_files_only=False,
    )
    del model
    return normalized


def emit(payload: dict[str, object], exit_code: int = 0) -> int:
    print(json.dumps(payload, ensure_ascii=False))
    return exit_code


def run_probe(raw_model: str) -> int:
    normalized = recommended_model(raw_model)
    available = available_local_model_labels()
    dependency_ready = faster_whisper_available()
    payload = {
        "pythonAvailable": True,
        "pythonVersion": sys.version.split()[0],
        "fasterWhisperAvailable": dependency_ready,
        "availableModels": available,
        "configuredModel": normalized,
        "configuredModelReady": configured_model_ready(raw_model),
        "recommendedModel": normalized,
        "lastError": None if dependency_ready else "faster-whisper is not installed in this Python environment.",
    }
    return emit(payload)


def run_install(raw_model: str, device: str, compute_type: str) -> int:
    try:
        if not faster_whisper_available():
            install_faster_whisper()
        resolved_model = prefetch_model(raw_model, device, compute_type)
        available = available_local_model_labels()
        payload = {
            "pythonAvailable": True,
            "pythonVersion": sys.version.split()[0],
            "fasterWhisperAvailable": True,
            "availableModels": available,
            "configuredModel": resolved_model,
            "configuredModelReady": configured_model_ready(resolved_model),
            "recommendedModel": recommended_model(resolved_model),
            "lastError": None,
        }
        return emit(payload)
    except subprocess.CalledProcessError as exc:
        return emit(
            {
                "pythonAvailable": True,
                "pythonVersion": sys.version.split()[0],
                "fasterWhisperAvailable": faster_whisper_available(),
                "availableModels": available_local_model_labels(),
                "configuredModel": recommended_model(raw_model),
                "configuredModelReady": configured_model_ready(raw_model),
                "recommendedModel": recommended_model(raw_model),
                "lastError": f"Dependency install failed with exit code {exc.returncode}.",
            },
            exit_code=1,
        )
    except Exception as exc:  # noqa: BLE001
        return emit(
            {
                "pythonAvailable": True,
                "pythonVersion": sys.version.split()[0],
                "fasterWhisperAvailable": faster_whisper_available(),
                "availableModels": available_local_model_labels(),
                "configuredModel": recommended_model(raw_model),
                "configuredModelReady": configured_model_ready(raw_model),
                "recommendedModel": recommended_model(raw_model),
                "lastError": str(exc),
            },
            exit_code=1,
        )


def main() -> int:
    args = parse_args()
    if args.command == "probe":
        return run_probe(args.model)
    if args.command == "install":
        return run_install(args.model, args.device, args.compute_type)
    return emit({"lastError": f"Unsupported command: {args.command}"}, exit_code=2)


if __name__ == "__main__":
    raise SystemExit(main())
