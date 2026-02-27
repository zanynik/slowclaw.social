#!/usr/bin/env python3
from __future__ import annotations

import argparse
import dataclasses
import json
import math
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path
from typing import Any, Iterable

_SCRIPT_DIR = Path(__file__).resolve().parent
_PY_TAG = f"py{sys.version_info.major}{sys.version_info.minor}"
_VERSIONED_VENDOR = _SCRIPT_DIR / f".vendor-{_PY_TAG}"
_LEGACY_VENDOR = _SCRIPT_DIR / ".vendor"
if _VERSIONED_VENDOR.exists():
    sys.path.insert(0, str(_VERSIONED_VENDOR))
elif _LEGACY_VENDOR.exists():
    sys.path.insert(0, str(_LEGACY_VENDOR))


FILLER_WORDS = {
    "um",
    "uh",
    "erm",
    "ah",
    "like",
    "you know",
    "i mean",
    "sort of",
    "kind of",
    "basically",
    "actually",
    "literally",
}


@dataclasses.dataclass
class Word:
    text: str
    start: float
    end: float


@dataclasses.dataclass
class Segment:
    id: int
    text: str
    start: float
    end: float
    words: list[Word]


@dataclasses.dataclass
class Line:
    line_id: int
    start: float
    end: float
    text: str
    segment_ids: list[int]


@dataclasses.dataclass
class Insight:
    title: str
    line_ids: list[int]
    note: str = ""


def run(cmd: list[str], *, cwd: Path | None = None, input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    print(f"$ {' '.join(shlex.quote(c) for c in cmd)}", file=sys.stderr)
    return subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        input=input_text,
        text=True,
        capture_output=True,
        check=False,
    )


def require_cmd(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise RuntimeError(f"Required command not found: {name}")
    return path


def ffprobe_duration(path: Path) -> float:
    cp = run(
        [
            require_cmd("ffprobe"),
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            str(path),
        ]
    )
    if cp.returncode != 0:
        raise RuntimeError(f"ffprobe failed for {path}:\n{cp.stderr}")
    return float(cp.stdout.strip())


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def clamp(v: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, v))


def normalize_text(s: str) -> str:
    return re.sub(r"\s+", " ", s or "").strip()


def is_filler(text: str) -> bool:
    t = normalize_text(text).lower().strip(".,!?;:- ")
    return t in FILLER_WORDS


def parse_whisper_json(json_path: Path) -> list[Segment]:
    payload = json.loads(json_path.read_text(encoding="utf-8"))
    raw_segments = payload.get("segments") or []
    segments: list[Segment] = []
    for idx, seg in enumerate(raw_segments):
        words: list[Word] = []
        for raw_w in seg.get("words") or []:
            start = raw_w.get("start")
            end = raw_w.get("end")
            if start is None or end is None:
                continue
            words.append(
                Word(
                    text=str(raw_w.get("word") or raw_w.get("text") or "").strip(),
                    start=float(start),
                    end=float(end),
                )
            )
        segments.append(
            Segment(
                id=int(seg.get("id", idx)),
                text=normalize_text(seg.get("text", "")),
                start=float(seg.get("start", 0.0)),
                end=float(seg.get("end", 0.0)),
                words=words,
            )
        )
    return [s for s in segments if s.end > s.start]


def _try_cli_whisper(audio: Path, model: str, out_dir: Path, language: str | None) -> Path | None:
    whisper_cmd = shutil.which("whisper")
    if not whisper_cmd:
        return None
    cmd = [
        whisper_cmd,
        str(audio),
        "--model",
        model,
        "--output_dir",
        str(out_dir),
        "--output_format",
        "json",
        "--word_timestamps",
        "True",
    ]
    if language:
        cmd += ["--language", language]
    cp = run(cmd)
    if cp.returncode != 0:
        raise RuntimeError(f"whisper CLI failed:\n{cp.stderr}")
    candidate = out_dir / f"{audio.stem}.json"
    if not candidate.exists():
        raise RuntimeError(f"whisper CLI succeeded but JSON not found: {candidate}")
    return candidate


def _try_python_whisper(audio: Path, model: str, out_dir: Path, language: str | None, python_bin: str) -> Path | None:
    probe = run([python_bin, "-c", "import whisper; print('ok')"])
    if probe.returncode != 0:
        return None
    cmd = [
        python_bin,
        "-m",
        "whisper",
        str(audio),
        "--model",
        model,
        "--output_dir",
        str(out_dir),
        "--output_format",
        "json",
        "--word_timestamps",
        "True",
    ]
    if language:
        cmd += ["--language", language]
    cp = run(cmd)
    if cp.returncode != 0:
        raise RuntimeError(f"python -m whisper failed:\n{cp.stderr}")
    candidate = out_dir / f"{audio.stem}.json"
    if not candidate.exists():
        raise RuntimeError(f"python -m whisper succeeded but JSON not found: {candidate}")
    return candidate


def _try_faster_whisper(audio: Path, model: str, out_dir: Path, language: str | None, python_bin: str) -> Path | None:
    code = r"""
import json, sys
from faster_whisper import WhisperModel
audio_path, model_name, out_json, lang = sys.argv[1:5]
device = "cpu"
compute_type = "int8"
model = WhisperModel(model_name, device=device, compute_type=compute_type)
segments, info = model.transcribe(audio_path, word_timestamps=True, language=(None if lang == "None" else lang))
payload = {"language": info.language, "segments": []}
for i, seg in enumerate(segments):
    words = []
    for w in (seg.words or []):
        if w.start is None or w.end is None:
            continue
        words.append({"word": w.word, "start": w.start, "end": w.end})
    payload["segments"].append({
        "id": i,
        "start": seg.start,
        "end": seg.end,
        "text": seg.text,
        "words": words,
    })
with open(out_json, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2)
"""
    probe = run([python_bin, "-c", "import faster_whisper; print('ok')"])
    if probe.returncode != 0:
        return None
    out_json = out_dir / f"{audio.stem}.json"
    cp = run([python_bin, "-c", code, str(audio), model, str(out_json), str(language)])
    if cp.returncode != 0:
        raise RuntimeError(f"faster_whisper backend failed:\n{cp.stderr}")
    return out_json


def transcribe_with_whisper(
    audio: Path, model: str, language: str | None, out_dir: Path, whisper_python: str
) -> list[Segment]:
    ensure_dir(out_dir)
    last_error: RuntimeError | None = None
    for attempt in (_try_cli_whisper, _try_python_whisper, _try_faster_whisper):
        try:
            if attempt is _try_cli_whisper:
                json_path = attempt(audio, model, out_dir, language)
            else:
                json_path = attempt(audio, model, out_dir, language, whisper_python)
            if json_path:
                return parse_whisper_json(json_path)
        except RuntimeError as e:
            last_error = e
    msg = (
        "No local Whisper backend available. Install one of:\n"
        "1) `whisper` CLI / openai-whisper\n"
        "2) Python package `whisper`\n"
        "3) Python package `faster-whisper`\n"
    )
    if last_error:
        msg += f"\nLast backend error:\n{last_error}"
    raise RuntimeError(msg)


def enhance_audio(input_audio: Path, output_audio: Path, *, max_input_seconds: int | None = None) -> None:
    ensure_dir(output_audio.parent)
    ffmpeg = require_cmd("ffmpeg")
    # Basic "podcast-ish" cleanup: HPF, denoise, de-ess-ish top trim, compressor, loudness normalize.
    af = ",".join(
        [
            "highpass=f=70",
            "lowpass=f=12000",
            "afftdn=nf=-20",
            "acompressor=threshold=-18dB:ratio=3:attack=5:release=50:makeup=3",
            "loudnorm=I=-16:LRA=11:TP=-1.5",
        ]
    )
    cmd = [
        ffmpeg,
        "-y",
        "-i",
        str(input_audio),
        "-vn",
    ]
    if max_input_seconds and max_input_seconds > 0:
        cmd += ["-t", str(max_input_seconds)]
    cmd += [
        "-af",
        af,
        "-ar",
        "48000",
        "-ac",
        "1",
        str(output_audio),
    ]
    cp = run(cmd)
    if cp.returncode != 0:
        raise RuntimeError(f"ffmpeg enhance failed:\n{cp.stderr}")


def build_keep_intervals(
    segments: list[Segment],
    total_duration: float,
    *,
    pad: float = 0.08,
    min_word_dur: float = 0.05,
    max_gap_to_merge: float = 0.25,
) -> list[tuple[float, float]]:
    intervals: list[tuple[float, float]] = []
    has_words = any(s.words for s in segments)
    if has_words:
        for seg in segments:
            for w in seg.words:
                txt = normalize_text(w.text)
                if not txt:
                    continue
                if is_filler(txt):
                    continue
                start = clamp(w.start - pad, 0.0, total_duration)
                end = clamp(max(w.end + pad, start + min_word_dur), 0.0, total_duration)
                if end > start:
                    intervals.append((start, end))
    else:
        for seg in segments:
            if not normalize_text(seg.text):
                continue
            cleaned_words = [t for t in seg.text.split() if not is_filler(t)]
            if not cleaned_words:
                continue
            start = clamp(seg.start - pad, 0.0, total_duration)
            end = clamp(seg.end + pad, 0.0, total_duration)
            if end > start:
                intervals.append((start, end))

    if not intervals:
        return [(0.0, total_duration)]

    intervals.sort()
    merged = [intervals[0]]
    for s, e in intervals[1:]:
        ps, pe = merged[-1]
        if s <= pe + max_gap_to_merge:
            merged[-1] = (ps, max(pe, e))
        else:
            merged.append((s, e))
    return [(clamp(s, 0.0, total_duration), clamp(e, 0.0, total_duration)) for s, e in merged if e - s > 0.03]


def _ffmpeg_concat_trim_audio(input_audio: Path, output_audio: Path, intervals: list[tuple[float, float]]) -> None:
    ffmpeg = require_cmd("ffmpeg")
    parts: list[str] = []
    for idx, (s, e) in enumerate(intervals):
        parts.append(f"[0:a]atrim=start={s:.3f}:end={e:.3f},asetpts=PTS-STARTPTS[a{idx}]")
    concat_inputs = "".join(f"[a{i}]" for i in range(len(intervals)))
    filter_complex = ";".join(parts + [f"{concat_inputs}concat=n={len(intervals)}:v=0:a=1[outa]"])
    cmd = [
        ffmpeg,
        "-y",
        "-i",
        str(input_audio),
        "-filter_complex",
        filter_complex,
        "-map",
        "[outa]",
        "-ar",
        "48000",
        "-ac",
        "1",
        str(output_audio),
    ]
    cp = run(cmd)
    if cp.returncode != 0:
        raise RuntimeError(f"ffmpeg trim/concat failed:\n{cp.stderr}")


def create_clean_audio(input_audio: Path, output_audio: Path, segments: list[Segment]) -> list[tuple[float, float]]:
    duration = ffprobe_duration(input_audio)
    intervals = build_keep_intervals(segments, duration)
    _ffmpeg_concat_trim_audio(input_audio, output_audio, intervals)
    return intervals


def load_kept_intervals_json(path: Path) -> list[tuple[float, float]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    out: list[tuple[float, float]] = []
    for item in payload.get("intervals", []):
        if isinstance(item, (list, tuple)) and len(item) == 2:
            out.append((float(item[0]), float(item[1])))
    return out


def chunk_lines(segments: list[Segment], max_chars: int = 95, max_segments: int = 2) -> list[Line]:
    lines: list[Line] = []
    current_texts: list[str] = []
    current_seg_ids: list[int] = []
    current_start: float | None = None
    current_end: float | None = None

    def flush() -> None:
        nonlocal current_texts, current_seg_ids, current_start, current_end
        if not current_texts or current_start is None or current_end is None:
            current_texts, current_seg_ids = [], []
            current_start = current_end = None
            return
        text = normalize_text(" ".join(current_texts))
        if text:
            lines.append(
                Line(
                    line_id=len(lines) + 1,
                    start=current_start,
                    end=current_end,
                    text=text,
                    segment_ids=current_seg_ids[:],
                )
            )
        current_texts, current_seg_ids = [], []
        current_start = current_end = None

    for seg in segments:
        seg_text = normalize_text(seg.text)
        if not seg_text:
            continue
        proposed = normalize_text(" ".join(current_texts + [seg_text]))
        should_flush = False
        if current_texts and len(proposed) > max_chars:
            should_flush = True
        if current_texts and len(current_seg_ids) >= max_segments:
            should_flush = True
        if current_end is not None and seg.start - current_end > 1.5:
            should_flush = True
        if should_flush:
            flush()
        if current_start is None:
            current_start = seg.start
        current_end = seg.end
        current_texts.append(seg_text)
        current_seg_ids.append(seg.id)
    flush()
    return lines


def transcript_lines_text(lines: list[Line]) -> str:
    out: list[str] = []
    for line in lines:
        out.append(f"[{line.line_id}] ({line.start:.2f}-{line.end:.2f}) {line.text}")
    return "\n".join(out)


def transcript_plain_text_from_segments(segments: list[Segment]) -> str:
    parts = [normalize_text(seg.text) for seg in segments if normalize_text(seg.text)]
    return "\n".join(parts)


def call_gemini_rewrite_script(transcript_text: str, *, gemini_model: str) -> str:
    gemini = require_cmd("gemini")
    prompt = f"""
Rewrite the transcript below into a crisper, higher-density knowledge script.

Goals:
- Make it suitable for a spoken podcast/narration segment.
- Preserve the speaker's original voice, personality, and speaking style.
- Preserve the speaker's conversational cadence and phrasing (don't make it sound corporate or essay-like).
- Keep the meaning and factual content intact.
- Remove filler, repetition, and drift.
- Increase clarity and information density.
- Keep it natural to speak out loud.
- Prefer natural spoken punctuation and sentence flow.
- Avoid shorthand abbreviations in prose unless the speaker explicitly used them and they sound natural when spoken aloud.
- Prefer contractions when they fit the speaker's style (it's, don't, you're).
- Output plain text only (no markdown, no timestamps, no headings unless the speaker naturally used them).
- English only.

Transcript:
{transcript_text}
""".strip()
    cp = run([gemini, "-m", gemini_model, "-p", prompt])
    if cp.returncode != 0:
        raise RuntimeError(f"gemini rewrite failed:\n{cp.stderr}")
    out = cp.stdout.strip()
    if not out:
        raise RuntimeError("gemini rewrite returned empty output")
    return out


def write_transcript_json(lines: list[Line], path: Path) -> None:
    payload = {
        "lines": [
            {
                "line_id": line.line_id,
                "start": line.start,
                "end": line.end,
                "text": line.text,
                "segment_ids": line.segment_ids,
            }
            for line in lines
        ]
    }
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def load_transcript_json(path: Path) -> list[Line]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    out: list[Line] = []
    for item in payload.get("lines", []):
        out.append(
            Line(
                line_id=int(item["line_id"]),
                start=float(item["start"]),
                end=float(item["end"]),
                text=str(item["text"]),
                segment_ids=[int(x) for x in item.get("segment_ids", [])],
            )
        )
    return out


def total_selected_seconds(lines: list[Line], insights: list[Insight]) -> float:
    by_id = {l.line_id: l for l in lines}
    total = 0.0
    for ins in insights:
        chosen = [by_id[i] for i in ins.line_ids if i in by_id]
        if chosen:
            total += max(0.0, chosen[-1].end - chosen[0].start)
    return total


def _ranges_to_insights(
    raw_ranges: list[dict[str, Any]],
    valid_line_ids: set[int],
    max_insights: int,
) -> list[Insight]:
    insights: list[Insight] = []
    last_end = 0
    for item in raw_ranges:
        if not isinstance(item, dict):
            continue
        if "line_ids" in item:
            ids = [int(x) for x in item.get("line_ids", []) if str(x).strip().isdigit()]
            ids = sorted(dict.fromkeys(ids))
            if not ids:
                continue
            start_id, end_id = ids[0], ids[-1]
        else:
            start_id = int(item.get("start_line_id"))
            end_id = int(item.get("end_line_id"))
            if end_id < start_id:
                continue
            ids = list(range(start_id, end_id + 1))
        if any(i not in valid_line_ids for i in ids):
            continue
        if ids[-1] - ids[0] + 1 != len(ids):
            continue
        if start_id <= last_end:
            continue
        insights.append(
            Insight(
                title=normalize_text(str(item.get("title", ""))) or f"Insight {len(insights)+1}",
                line_ids=ids,
                note=normalize_text(str(item.get("note", ""))),
            )
        )
        last_end = end_id
        if len(insights) >= max_insights:
            break
    return insights


def heuristic_fallback_insights(lines: list[Line], max_insights: int, min_total_seconds: float) -> list[Insight]:
    # Prefer long contiguous chunks that look content-dense (length/second) and non-overlapping.
    if not lines:
        return []
    candidates: list[tuple[float, int, int, float]] = []  # score,start_idx,end_idx,dur
    for i in range(len(lines)):
        for j in range(i, min(len(lines), i + 14)):
            dur = lines[j].end - lines[i].start
            if dur < 20 or dur > 140:
                continue
            text_len = sum(len(lines[k].text) for k in range(i, j + 1))
            score = text_len / max(1.0, dur)
            # Penalize obvious intro/outro lines.
            text_blob = " ".join(lines[k].text.lower() for k in range(i, j + 1))
            if "thank you for listening" in text_blob:
                score -= 5
            candidates.append((score, i, j, dur))
    candidates.sort(reverse=True)
    picked: list[tuple[int, int]] = []
    for _, i, j, _ in candidates:
        if any(not (j < pi or i > pj) for pi, pj in picked):
            continue
        picked.append((i, j))
        picked.sort()
        out = [
            Insight(
                title=f"Insight {k+1}",
                line_ids=list(range(lines[a].line_id, lines[b].line_id + 1)),
            )
            for k, (a, b) in enumerate(picked[:max_insights])
        ]
        if len(out) >= max_insights or total_selected_seconds(lines, out) >= min_total_seconds:
            return out
    if not picked:
        longest = max(lines, key=lambda l: l.end - l.start)
        return [Insight(title="Selected Clip", line_ids=[longest.line_id])]
    return [
        Insight(
            title=f"Insight {k+1}",
            line_ids=list(range(lines[a].line_id, lines[b].line_id + 1)),
        )
        for k, (a, b) in enumerate(picked[:max_insights])
    ]


def call_gemini_for_insights(
    lines: list[Line],
    max_insights: int,
    *,
    gemini_model: str,
    min_total_seconds: float,
) -> list[Insight]:
    gemini = require_cmd("gemini")
    transcript = transcript_lines_text(lines)
    avg_target = max(30, int(min_total_seconds / max(1, max_insights)))
    prompt = f"""
You are selecting the most insightful and interesting parts of a transcript for short-form videos.

Rules:
- Return ONLY valid JSON.
- Use only the provided original transcript lines.
- Do not rewrite transcript lines.
- Select between 1 and {max_insights} clips.
- Preserve original narrative order (linear order only).
- Each clip must be a contiguous line range.
- No overlap between clips.
- Prefer coherent chunks (not isolated lines) that can stand alone as meaningful insight.
- Prefer substance over setup, repetition, throat-clearing, or meta chatter.
- Aim for total selected duration >= {int(min_total_seconds)} seconds if possible.
- Prefer each clip duration around {avg_target}-90 seconds when possible.
- Do not select outro/goodbye unless it is itself insightful.

JSON schema:
{{
  "insights": [
    {{
      "title": "short title",
      "start_line_id": 3,
      "end_line_id": 12,
      "note": "optional short reason"
    }}
  ]
}}

Transcript lines:
{transcript}
""".strip()
    cp = run([gemini, "-m", gemini_model, "-o", "json", prompt])
    if cp.returncode != 0:
        raise RuntimeError(f"gemini command failed:\n{cp.stderr}")
    text = cp.stdout.strip()
    payload = _extract_json(text)
    raw_insights = payload.get("insights") or []
    valid_line_ids = {l.line_id for l in lines}
    insights = _ranges_to_insights(raw_insights, valid_line_ids, max_insights)
    if not insights or total_selected_seconds(lines, insights) < min_total_seconds * 0.6:
        insights = heuristic_fallback_insights(lines, max_insights, min_total_seconds)
    return insights


def _extract_json(text: str) -> dict[str, Any]:
    try:
        payload = json.loads(text)
        if isinstance(payload, dict):
            return payload
    except json.JSONDecodeError:
        pass
    match = re.search(r"\{.*\}", text, re.S)
    if not match:
        raise RuntimeError(f"Could not parse JSON from gemini output:\n{text[:1000]}")
    payload = json.loads(match.group(0))
    if not isinstance(payload, dict):
        raise RuntimeError("Gemini output JSON root must be an object")
    return payload


def select_lines(all_lines: list[Line], line_ids: Iterable[int]) -> list[Line]:
    wanted = set(line_ids)
    return [l for l in all_lines if l.line_id in wanted]


def make_clip_audio(input_audio: Path, output_audio: Path, start: float, end: float) -> None:
    ffmpeg = require_cmd("ffmpeg")
    cmd = [
        ffmpeg,
        "-y",
        "-i",
        str(input_audio),
        "-ss",
        f"{start:.3f}",
        "-to",
        f"{end:.3f}",
        "-c:a",
        "aac",
        "-b:a",
        "192k",
        str(output_audio),
    ]
    cp = run(cmd)
    if cp.returncode != 0:
        raise RuntimeError(f"ffmpeg clip audio failed:\n{cp.stderr}")


def make_voice_reference_sample(input_audio: Path, output_wav: Path, *, max_seconds: int = 30) -> None:
    make_voice_reference_sample_at(input_audio, output_wav, start_seconds=0.0, max_seconds=max_seconds)


def make_voice_reference_sample_at(
    input_audio: Path,
    output_wav: Path,
    *,
    start_seconds: float = 0.0,
    max_seconds: int = 30,
) -> None:
    ffmpeg = require_cmd("ffmpeg")
    ensure_dir(output_wav.parent)
    cmd = [
        ffmpeg,
        "-y",
        "-i",
        str(input_audio),
        "-vn",
        "-ss",
        f"{max(0.0, start_seconds):.3f}",
        "-t",
        str(max_seconds),
        "-af",
        "highpass=f=70,lowpass=f=12000,loudnorm=I=-16:LRA=11:TP=-1.5",
        "-ar",
        "24000",
        "-ac",
        "1",
        str(output_wav),
    ]
    cp = run(cmd)
    if cp.returncode != 0:
        raise RuntimeError(f"ffmpeg voice reference sample failed:\n{cp.stderr}")


def _collect_words(segments: list[Segment]) -> list[Word]:
    words: list[Word] = []
    for seg in segments:
        if seg.words:
            for w in seg.words:
                txt = normalize_text(w.text)
                if not txt:
                    continue
                words.append(Word(text=txt, start=float(w.start), end=float(w.end)))
            continue
        seg_words = [t for t in seg.text.split() if t.strip()]
        if not seg_words:
            continue
        dur = max(0.1, seg.end - seg.start)
        step = dur / len(seg_words)
        for i, txt in enumerate(seg_words):
            s = seg.start + i * step
            e = seg.start + (i + 1) * step
            words.append(Word(text=txt, start=s, end=e))
    words.sort(key=lambda w: (w.start, w.end))
    return words


def select_best_voice_reference_window(
    segments: list[Segment],
    *,
    window_seconds: int = 30,
) -> tuple[float, float, dict[str, float]]:
    words = _collect_words(segments)
    if not words:
        return (0.0, float(window_seconds), {"score": 0.0, "wpm": 0.0, "word_count": 0.0, "filler_ratio": 0.0})

    last_end = max((w.end for w in words), default=float(window_seconds))
    if last_end <= window_seconds:
        spoken = len([w for w in words if not is_filler(w.text)])
        filler = len(words) - spoken
        dur = max(1.0, last_end)
        return (
            0.0,
            max(float(window_seconds), last_end),
            {
                "score": spoken / dur,
                "wpm": spoken * 60.0 / dur,
                "word_count": float(spoken),
                "filler_ratio": (filler / max(1, len(words))),
            },
        )

    best: tuple[float, float, dict[str, float]] | None = None
    step = 1.0
    t = 0.0
    while t <= max(0.0, last_end - window_seconds):
        ws, we = t, t + window_seconds
        in_window = [w for w in words if w.end > ws and w.start < we]
        if not in_window:
            t += step
            continue
        spoken_words = [w for w in in_window if not is_filler(w.text)]
        filler_count = len(in_window) - len(spoken_words)
        if not spoken_words:
            t += step
            continue
        spoken_time = sum(max(0.0, min(w.end, we) - max(w.start, ws)) for w in spoken_words)
        pauses = 0.0
        prev_end: float | None = None
        for w in spoken_words:
            s = max(w.start, ws)
            e = min(w.end, we)
            if prev_end is not None and s > prev_end:
                pauses += max(0.0, s - prev_end)
            prev_end = max(prev_end or s, e)
        if prev_end is not None and we > prev_end:
            pauses += we - prev_end
        density = len(spoken_words) / max(1.0, window_seconds)
        filler_ratio = filler_count / max(1, len(in_window))
        speech_coverage = spoken_time / max(1.0, window_seconds)
        pause_ratio = pauses / max(1.0, window_seconds)
        score = density + 0.35 * speech_coverage - 0.4 * filler_ratio - 0.2 * pause_ratio
        meta = {
            "score": score,
            "wpm": len(spoken_words) * 60.0 / max(1.0, window_seconds),
            "word_count": float(len(spoken_words)),
            "filler_ratio": filler_ratio,
            "speech_coverage": speech_coverage,
            "pause_ratio": pause_ratio,
        }
        if best is None or score > best[2]["score"]:
            best = (ws, we, meta)
        t += step

    if best is None:
        return (0.0, float(window_seconds), {"score": 0.0, "wpm": 0.0, "word_count": 0.0, "filler_ratio": 0.0})
    return best


def export_pocket_tts_voice(voice_audio: Path, voice_embedding_path: Path) -> None:
    pocket_tts = require_cmd("pocket-tts")
    ensure_dir(voice_embedding_path.parent)
    cp = run([pocket_tts, "export-voice", str(voice_audio), str(voice_embedding_path)])
    if cp.returncode != 0:
        raise RuntimeError(f"pocket-tts export-voice failed:\n{cp.stderr}")
    if not voice_embedding_path.exists():
        raise RuntimeError(f"pocket-tts export-voice did not produce file: {voice_embedding_path}")


def generate_pocket_tts_audio(
    script_text: str,
    voice_embedding: Path | None,
    output_wav: Path,
    *,
    fallback_voice: str = "alba",
    strict_voice_clone: bool = False,
) -> str:
    pocket_tts = require_cmd("pocket-tts")
    ensure_dir(output_wav.parent)
    if voice_embedding is None:
        if strict_voice_clone:
            raise RuntimeError("Strict voice clone enabled, but no Pocket TTS voice embedding is available.")
        cp = run(
            [
                pocket_tts,
                "generate",
                "--voice",
                fallback_voice,
                "--text",
                script_text,
                "--output-path",
                str(output_wav),
            ]
        )
        if cp.returncode != 0:
            raise RuntimeError(f"pocket-tts fallback generate failed:\n{cp.stderr}")
        if not output_wav.exists():
            raise RuntimeError(f"pocket-tts fallback did not produce output file: {output_wav}")
        return f"catalog:{fallback_voice}"
    cmd = [
        pocket_tts,
        "generate",
        "--voice",
        str(voice_embedding),
        "--text",
        script_text,
        "--output-path",
        str(output_wav),
    ]
    cp = run(cmd)
    if cp.returncode != 0:
        err = cp.stderr or ""
        if "VOICE_CLONING_UNSUPPORTED" in err or "accept the terms" in err or "voice cloning" in err.lower():
            if strict_voice_clone:
                raise RuntimeError(f"pocket-tts voice cloning failed in strict mode:\n{cp.stderr}")
            print(
                f"Pocket TTS voice cloning unavailable (likely gated model/auth). Falling back to catalog voice '{fallback_voice}'.",
                file=sys.stderr,
            )
            cp = run(
                [
                    pocket_tts,
                    "generate",
                    "--voice",
                    fallback_voice,
                    "--text",
                    script_text,
                    "--output-path",
                    str(output_wav),
                ]
            )
            if cp.returncode != 0:
                raise RuntimeError(f"pocket-tts fallback generate failed:\n{cp.stderr}")
            if not output_wav.exists():
                raise RuntimeError(f"pocket-tts fallback did not produce output file: {output_wav}")
            return f"catalog:{fallback_voice}"
        raise RuntimeError(f"pocket-tts generate failed:\n{cp.stderr}")
    if not output_wav.exists():
        raise RuntimeError(f"pocket-tts did not produce output file: {output_wav}")
    return "voice-clone"


def srt_time(seconds: float) -> str:
    ms = int(round(seconds * 1000))
    h, rem = divmod(ms, 3600000)
    m, rem = divmod(rem, 60000)
    s, rem = divmod(rem, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{rem:03d}"


def parse_srt_timecode(s: str) -> float:
    hh, mm, rest = s.split(":")
    ss, ms = rest.split(",")
    return int(hh) * 3600 + int(mm) * 60 + int(ss) + int(ms) / 1000.0


def parse_srt(path: Path) -> list[tuple[float, float, str]]:
    text = path.read_text(encoding="utf-8")
    blocks = re.split(r"\n\s*\n", text.strip(), flags=re.M)
    entries: list[tuple[float, float, str]] = []
    for block in blocks:
        lines = [ln.rstrip("\r") for ln in block.splitlines() if ln.strip() != ""]
        if len(lines) < 2:
            continue
        tc_line = lines[1] if re.search(r"-->", lines[1]) else (lines[0] if re.search(r"-->", lines[0]) else None)
        if tc_line is None:
            continue
        m = re.match(r"\s*(\d{2}:\d{2}:\d{2},\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2},\d{3})\s*", tc_line)
        if not m:
            continue
        start = parse_srt_timecode(m.group(1))
        end = parse_srt_timecode(m.group(2))
        text_lines_start = 2 if tc_line == lines[1] else 1
        caption_text = "\n".join(lines[text_lines_start:]).strip()
        entries.append((start, end, caption_text))
    return entries


def _drawtext_escape(text: str) -> str:
    return (
        text.replace("\\", r"\\\\")
        .replace(":", r"\:")
        .replace("'", r"\'")
        .replace(",", r"\,")
        .replace("[", r"\[")
        .replace("]", r"\]")
        .replace("%", r"\%")
        .replace("\n", r"\n")
    )


def make_drawtext_video(
    audio_path: Path,
    srt_path: Path,
    output_video: Path,
    *,
    width: int = 1920,
    height: int = 1080,
    fps: int = 30,
) -> None:
    ffmpeg = require_cmd("ffmpeg")
    duration = ffprobe_duration(audio_path)
    captions = parse_srt(srt_path)
    font_size = max(56, int(height * 0.075))
    line_spacing = max(14, int(font_size * 0.28))
    x_margin = max(60, int(width * 0.06))
    y_margin = max(50, int(height * 0.07))
    filters: list[str] = []
    for start, end, text in captions:
        escaped = _drawtext_escape(text)
        filters.append(
            "drawtext="
            f"text='{escaped}':"
            f"font='Georgia':fontcolor=white:fontsize={font_size}:line_spacing={line_spacing}:"
            f"x={x_margin}:y={y_margin}:"
            "box=0:shadowx=0:shadowy=0:borderw=2:bordercolor=black:"
            f"enable='between(t,{start:.3f},{end:.3f})'"
        )
    vf = ",".join(filters) if filters else "null"
    cmd = [
        ffmpeg,
        "-y",
        "-f",
        "lavfi",
        "-i",
        f"color=c=black:s={width}x{height}:r={fps}:d={duration:.3f}",
        "-i",
        str(audio_path),
        "-vf",
        vf,
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        "-c:a",
        "aac",
        "-shortest",
        str(output_video),
    ]
    cp = run(cmd)
    if cp.returncode != 0:
        raise RuntimeError(f"ffmpeg drawtext video failed:\n{cp.stderr}")


def _pick_font(size: int):
    from PIL import ImageFont

    candidates = [
        "/System/Library/Fonts/Supplemental/Georgia.ttf",
        "/System/Library/Fonts/Supplemental/Times New Roman.ttf",
        "/Library/Fonts/Georgia.ttf",
        "/Library/Fonts/Times New Roman.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/SFNS.ttf",
        "/Library/Fonts/Arial.ttf",
        "/System/Library/Fonts/Supplemental/Helvetica.ttc",
    ]
    for p in candidates:
        try:
            return ImageFont.truetype(p, size=size)
        except Exception:
            continue
    try:
        return ImageFont.truetype("DejaVuSans.ttf", size=size)
    except Exception:
        return ImageFont.load_default()


def make_pillow_text_video(
    audio_path: Path,
    srt_path: Path,
    output_video: Path,
    *,
    width: int = 1920,
    height: int = 1080,
    fps: int = 30,
) -> None:
    from PIL import Image, ImageDraw

    ffmpeg = require_cmd("ffmpeg")
    duration = ffprobe_duration(audio_path)
    captions = parse_srt(srt_path)
    font_size = max(56, int(height * 0.075))
    line_spacing = max(14, int(font_size * 0.28))
    x_margin = max(60, int(width * 0.06))
    y_margin = max(50, int(height * 0.07))
    font = _pick_font(font_size)

    with tempfile.TemporaryDirectory(prefix="frames_", dir=str(output_video.parent)) as td:
        frames_dir = Path(td)
        concat_path = frames_dir / "concat.txt"

        # Build timed visual segments (including blank gaps) so we render one image per subtitle state,
        # rather than one image per frame. This keeps long videos feasible without ffmpeg text filters.
        segments: list[tuple[float, float, str]] = []
        t_cur = 0.0
        for start, end, txt in captions:
            s = clamp(start, 0.0, duration)
            e = clamp(end, 0.0, duration)
            if e <= s:
                continue
            if s > t_cur:
                segments.append((t_cur, s, ""))
            segments.append((s, e, txt))
            t_cur = max(t_cur, e)
        if t_cur < duration:
            segments.append((t_cur, duration, ""))
        if not segments:
            segments = [(0.0, max(0.1, duration), "")]

        # Merge adjacent identical text segments to reduce image count.
        merged: list[tuple[float, float, str]] = []
        for s, e, txt in segments:
            if merged and merged[-1][2] == txt and abs(merged[-1][1] - s) < 1e-6:
                merged[-1] = (merged[-1][0], e, txt)
            else:
                merged.append((s, e, txt))
        segments = merged

        image_cache: dict[str, Path] = {}

        def render_text_image(txt: str, idx: int) -> Path:
            cached = image_cache.get(txt)
            if cached is not None:
                return cached
            img = Image.new("RGB", (width, height), (0, 0, 0))
            draw = ImageDraw.Draw(img)
            if txt:
                bbox = draw.multiline_textbbox((0, 0), txt, font=font, spacing=line_spacing, align="left")
                _tw = bbox[2] - bbox[0]
                _th = bbox[3] - bbox[1]
                x = x_margin
                y = y_margin
                for dx, dy in [(-2, 0), (2, 0), (0, -2), (0, 2)]:
                    draw.multiline_text((x + dx, y + dy), txt, font=font, fill=(0, 0, 0), spacing=line_spacing, align="left")
                draw.multiline_text((x, y), txt, font=font, fill=(255, 255, 255), spacing=line_spacing, align="left")
            path = frames_dir / f"seg_{idx:06d}.png"
            img.save(path)
            image_cache[txt] = path
            return path

        concat_lines: list[str] = []
        last_img: Path | None = None
        for idx, (start, end, txt) in enumerate(segments):
            seg_dur = max(0.001, end - start)
            img_path = render_text_image(txt, idx)
            safe_img_path = str(img_path).replace("'", r"'\''")
            concat_lines.append("file '" + safe_img_path + "'")
            concat_lines.append(f"duration {seg_dur:.6f}")
            last_img = img_path
        if last_img is not None:
            # ffmpeg concat demuxer ignores duration of final entry unless file is repeated.
            safe_last_img_path = str(last_img).replace("'", r"'\''")
            concat_lines.append("file '" + safe_last_img_path + "'")
        concat_path.write_text("\n".join(concat_lines) + "\n", encoding="utf-8")

        cmd = [
            ffmpeg,
            "-y",
            "-f",
            "concat",
            "-safe",
            "0",
            "-i",
            str(concat_path),
            "-i",
            str(audio_path),
            "-vf",
            f"fps={fps}",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-shortest",
            str(output_video),
        ]
        cp = run(cmd)
        if cp.returncode != 0:
            raise RuntimeError(f"ffmpeg encode/mux after Pillow render failed:\n{cp.stderr}")


def _timed_words_from_lines(lines: list[Line], clip_start: float, clip_end: float) -> list[tuple[float, float, str]]:
    timed_words: list[tuple[float, float, str]] = []
    clip_dur = max(0.0, clip_end - clip_start)
    for line in lines:
        line_start = clamp(line.start - clip_start, 0.0, clip_dur)
        line_end = clamp(line.end - clip_start, 0.0, clip_dur)
        if line_end <= line_start:
            continue
        words = [w for w in line.text.split() if w]
        if not words:
            continue
        dur = max(0.1, line_end - line_start)
        step = dur / max(1, len(words))
        for w_idx, word in enumerate(words):
            start = clamp(line_start + w_idx * step, 0.0, clip_dur)
            end = clamp(line_start + (w_idx + 1) * step, 0.0, clip_dur)
            if end <= start:
                continue
            timed_words.append((start, end, word))
    return timed_words


def _timed_words_from_text_duration(text: str, total_duration: float) -> list[tuple[float, float, str]]:
    words = re.findall(r"\S+", text)
    if not words:
        return []
    dur = max(0.5, total_duration)
    step = dur / len(words)
    timed_words: list[tuple[float, float, str]] = []
    for idx, word in enumerate(words):
        start = clamp(idx * step, 0.0, dur)
        end = clamp((idx + 1) * step, 0.0, dur)
        if end <= start:
            continue
        timed_words.append((start, end, word))
    return timed_words


def _paginate_words_fixed_layout(
    timed_words: list[tuple[float, float, str]],
    *,
    max_chars_per_line: int = 24,
    max_lines_per_page: int = 20,
) -> list[list[list[tuple[float, float, str]]]]:
    pages: list[list[list[tuple[float, float, str]]]] = []
    page: list[list[tuple[float, float, str]]] = []
    line_words: list[tuple[float, float, str]] = []
    line_len = 0

    for item in timed_words:
        word = item[2]
        add_len = len(word) if not line_words else (1 + len(word))
        if line_words and line_len + add_len > max_chars_per_line:
            page.append(line_words)
            line_words = []
            line_len = 0
        if not line_words and len(page) >= max_lines_per_page:
            pages.append(page)
            page = []
        line_words.append(item)
        line_len += add_len if line_len else len(word)

    if line_words:
        page.append(line_words)
    if page:
        pages.append(page)
    return pages


def write_clip_srt(lines: list[Line], clip_start: float, clip_end: float, out_path: Path) -> None:
    timed_words = _timed_words_from_lines(lines, clip_start, clip_end)
    clip_dur = max(0.0, clip_end - clip_start)
    if not timed_words:
        out_path.write_text(f"1\n00:00:00,000 --> {srt_time(max(0.5, clip_dur))}\n\n", encoding="utf-8")
        return

    pages = _paginate_words_fixed_layout(timed_words)
    entries: list[str] = []
    idx = 1
    flat_pages = [word for page in pages for line_words in page for word in line_words]
    next_start_by_idx: list[float] = []
    for i, (start, end, _word) in enumerate(flat_pages):
        if i + 1 < len(flat_pages):
            next_start_by_idx.append(flat_pages[i + 1][0])
        else:
            next_start_by_idx.append(clip_dur)

    global_i = 0
    for page in pages:
        page_lines_words = [[w[2] for w in line_words] for line_words in page]
        page_revealed_counts = [0] * len(page)
        for line_idx, line_words in enumerate(page):
            for local_word_idx, (start, end, _word) in enumerate(line_words):
                page_revealed_counts[line_idx] = local_word_idx + 1
                parts: list[str] = []
                for li, words in enumerate(page_lines_words):
                    visible_n = page_revealed_counts[li]
                    if visible_n <= 0:
                        continue
                    parts.append(" ".join(words[:visible_n]))
                caption = "\n".join(parts).strip()
                next_start = next_start_by_idx[global_i]
                entry_end = max(end, next_start)
                if entry_end <= start:
                    global_i += 1
                    continue
                entries.append(f"{idx}\n{srt_time(start)} --> {srt_time(entry_end)}\n{caption}\n")
                idx += 1
                global_i += 1

    out_path.write_text("\n".join(entries), encoding="utf-8")


def write_script_srt(script_text: str, audio_duration: float, out_path: Path, *, max_lines_per_page: int = 5) -> None:
    timed_words = _timed_words_from_text_duration(script_text, audio_duration)
    if not timed_words:
        out_path.write_text(f"1\n00:00:00,000 --> {srt_time(max(0.5, audio_duration))}\n\n", encoding="utf-8")
        return

    pages = _paginate_words_fixed_layout(
        timed_words,
        # Wider line budget for 1920x1080 top-left subtitles so we use more horizontal space.
        max_chars_per_line=52,
        max_lines_per_page=max_lines_per_page,
    )
    entries: list[str] = []
    idx = 1
    flat_pages = [word for page in pages for line_words in page for word in line_words]
    next_start_by_idx: list[float] = []
    for i, (start, end, _word) in enumerate(flat_pages):
        if i + 1 < len(flat_pages):
            next_start_by_idx.append(flat_pages[i + 1][0])
        else:
            next_start_by_idx.append(audio_duration)

    global_i = 0
    for page in pages:
        page_lines_words = [[w[2] for w in line_words] for line_words in page]
        page_revealed_counts = [0] * len(page)
        for line_idx, line_words in enumerate(page):
            for local_word_idx, (start, end, _word) in enumerate(line_words):
                page_revealed_counts[line_idx] = local_word_idx + 1
                parts: list[str] = []
                for li, words in enumerate(page_lines_words):
                    visible_n = page_revealed_counts[li]
                    if visible_n <= 0:
                        continue
                    parts.append(" ".join(words[:visible_n]))
                caption = "\n".join(parts).strip()
                next_start = next_start_by_idx[global_i]
                entry_end = max(end, next_start)
                if entry_end <= start:
                    global_i += 1
                    continue
                entries.append(f"{idx}\n{srt_time(start)} --> {srt_time(entry_end)}\n{caption}\n")
                idx += 1
                global_i += 1

    out_path.write_text("\n".join(entries), encoding="utf-8")


def make_subtitle_video(
    audio_path: Path,
    srt_path: Path,
    output_video: Path,
    *,
    width: int = 1920,
    height: int = 1080,
    fps: int = 30,
) -> None:
    ffmpeg = require_cmd("ffmpeg")
    duration = ffprobe_duration(audio_path)
    # Use explicit `filename=` and escape chars ffmpeg filter parser treats specially.
    srt_escaped = (
        str(srt_path)
        .replace("\\", "\\\\")
        .replace(":", r"\:")
        .replace(",", r"\,")
        .replace("[", r"\[")
        .replace("]", r"\]")
        .replace("=", r"\=")
    )
    style = ",".join(
        [
            "FontName=Georgia",
            "FontSize=78",
            "PrimaryColour=&H00FFFFFF",
            "OutlineColour=&H00000000",
            "BackColour=&H00000000",
            "Bold=0",
            "Italic=0",
            "BorderStyle=1",
            "Outline=2",
            "Shadow=0",
            "Alignment=7",
            "MarginL=110",
            "MarginR=110",
            "MarginV=90",
        ]
    )
    vf = f"subtitles=filename='{srt_escaped}':force_style='{style}'"
    cmd = [
        ffmpeg,
        "-y",
        "-f",
        "lavfi",
        "-i",
        f"color=c=black:s={width}x{height}:r={fps}:d={duration:.3f}",
        "-i",
        str(audio_path),
        "-vf",
        vf,
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        "-c:a",
        "aac",
        "-shortest",
        str(output_video),
    ]
    cp = run(cmd)
    if cp.returncode == 0:
        return
    if "No such filter: 'subtitles'" in cp.stderr:
        # Large progressive-reveal SRTs can make drawtext command generation/execution impractical
        # (argv limits and huge filter strings). Skip directly to Pillow in that case.
        try:
            if srt_path.stat().st_size > 250_000:
                make_pillow_text_video(audio_path, srt_path, output_video, width=width, height=height, fps=fps)
                return
        except OSError:
            pass
        try:
            make_drawtext_video(audio_path, srt_path, output_video, width=width, height=height, fps=fps)
            return
        except (RuntimeError, OSError) as e:
            err_text = str(e)
            # Fallback to Pillow when drawtext is unavailable or command construction is too large
            # for the OS argv limit (common with long full-length progressive subtitle renders).
            if ("No such filter: 'drawtext'" in err_text) or ("Argument list too long" in err_text):
                make_pillow_text_video(audio_path, srt_path, output_video, width=width, height=height, fps=fps)
                return
            raise
    raise RuntimeError(f"ffmpeg subtitle video failed:\n{cp.stderr}")


def sanitize_filename(s: str) -> str:
    s = re.sub(r"[^a-zA-Z0-9._ -]+", "", s).strip()
    s = re.sub(r"\s+", "_", s)
    return s[:80] or "clip"


def write_insights_json(insights: list[Insight], out_path: Path) -> None:
    out_path.write_text(
        json.dumps(
            {"insights": [dataclasses.asdict(i) for i in insights]},
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Convert audio/video into a Gemini-condensed script video with Pocket TTS voice cloning."
    )
    parser.add_argument("input_audio", type=Path, help="Path to .m4a/.mp3/.wav input")
    parser.add_argument("--out-dir", type=Path, default=Path("outputs"), help="Output directory")
    parser.add_argument("--whisper-model", default="base", help="Local Whisper model name/path")
    parser.add_argument("--gemini-model", default="gemini-3-flash-preview", help="Gemini model for script rewrite")
    parser.add_argument("--language", default=None, help="Whisper language code (optional)")
    parser.add_argument(
        "--resume-from-output",
        type=Path,
        default=None,
        help="Deprecated for the new Pocket TTS flow; ignored unless artifacts are manually reused",
    )
    parser.add_argument(
        "--whisper-python",
        default=sys.executable,
        help="Python executable to use for Whisper backends (default: current interpreter)",
    )
    parser.add_argument("--voice-ref-seconds", type=int, default=30, help="Seconds from input to use as Pocket TTS voice reference")
    parser.add_argument(
        "--voice-embedding-path",
        type=Path,
        default=None,
        help="Reusable Pocket TTS voice embedding (.safetensors). If present and exists, it will be reused.",
    )
    parser.add_argument(
        "--refresh-voice-embedding",
        action="store_true",
        help="Regenerate the voice embedding from the current input even if the embedding file already exists",
    )
    parser.add_argument("--pocket-tts-fallback-voice", default="alba", help="Fallback Pocket TTS catalog voice if cloning weights are unavailable")
    parser.add_argument("--strict-voice-clone", action="store_true", help="Fail immediately unless Pocket TTS voice cloning succeeds")
    parser.add_argument("--max-input-seconds", type=int, default=None, help="Trim input to first N seconds for faster test runs")
    parser.add_argument("--video-width", type=int, default=1920, help="Output video width (default: 1920)")
    parser.add_argument("--video-height", type=int, default=1080, help="Output video height (default: 1080)")
    parser.add_argument("--keep-temp", action="store_true", help="Keep intermediate temp files")
    args = parser.parse_args()

    input_audio = args.input_audio.resolve()
    if not input_audio.exists():
        raise SystemExit(f"Input file not found: {input_audio}")
    if input_audio.suffix.lower() not in {".m4a", ".mp3", ".wav", ".mp4"}:
        raise SystemExit("Input must be .m4a, .mp3, .wav, or .mp4 (audio track)")

    require_cmd("ffmpeg")
    require_cmd("ffprobe")
    require_cmd("gemini")
    require_cmd("pocket-tts")

    out_dir = args.out_dir.resolve()
    ensure_dir(out_dir)
    stem_dir = args.resume_from_output.resolve() if args.resume_from_output else (out_dir / sanitize_filename(input_audio.stem))
    ensure_dir(stem_dir)
    ensure_dir(stem_dir / "artifacts")
    ensure_dir(stem_dir / "clips")
    ensure_dir(stem_dir / "videos")

    temp_dir = Path(tempfile.mkdtemp(prefix="audio_to_video_", dir=str(stem_dir / "artifacts")))
    try:
        enhanced_audio = temp_dir / "01_enhanced.wav"
        transcript_txt = stem_dir / "artifacts" / "transcript_lines.txt"
        transcript_json = stem_dir / "artifacts" / "transcript_lines.json"
        transcript_plain_txt = stem_dir / "artifacts" / "transcript_plain.txt"
        knowledge_script_txt = stem_dir / "artifacts" / "knowledge_script.txt"
        voice_ref_wav = temp_dir / "02_voice_reference.wav"
        voice_ref_embedding = (
            args.voice_embedding_path.resolve()
            if args.voice_embedding_path is not None
            else (stem_dir / "artifacts" / "voice_reference.safetensors")
        )

        enhance_audio(input_audio, enhanced_audio, max_input_seconds=args.max_input_seconds)
        tx_dir = temp_dir / "whisper"
        segments = transcribe_with_whisper(enhanced_audio, args.whisper_model, args.language, tx_dir, args.whisper_python)
        if not segments:
            raise RuntimeError("Whisper produced no segments")

        lines = chunk_lines(segments)
        transcript_txt.write_text(transcript_lines_text(lines) + "\n", encoding="utf-8")
        write_transcript_json(lines, transcript_json)

        plain_transcript = transcript_plain_text_from_segments(segments)
        transcript_plain_txt.write_text(plain_transcript + "\n", encoding="utf-8")

        knowledge_script = call_gemini_rewrite_script(plain_transcript, gemini_model=args.gemini_model)
        knowledge_script_txt.write_text(knowledge_script + "\n", encoding="utf-8")

        voice_embedding_for_tts: Path | None = voice_ref_embedding
        embedding_reused = bool(voice_ref_embedding.exists() and not args.refresh_voice_embedding)
        if embedding_reused:
            ref_start, ref_end, ref_meta = (0.0, 0.0, {"reused_embedding": 1.0})
            print(f"Reusing voice embedding: {voice_ref_embedding}", file=sys.stderr)
        else:
            ref_start, ref_end, ref_meta = select_best_voice_reference_window(
                segments,
                window_seconds=max(5, args.voice_ref_seconds),
            )
            make_voice_reference_sample_at(
                enhanced_audio,
                voice_ref_wav,
                start_seconds=ref_start,
                max_seconds=max(5, args.voice_ref_seconds),
            )
            try:
                export_pocket_tts_voice(voice_ref_wav, voice_ref_embedding)
            except RuntimeError as e:
                if args.strict_voice_clone:
                    raise
                print(f"{e}\nFalling back to Pocket TTS catalog voice.", file=sys.stderr)
                voice_embedding_for_tts = None

        full_title = "Knowledge_Script"
        clip_audio = stem_dir / "clips" / f"01_{full_title}.wav"
        clip_srt = stem_dir / "clips" / f"01_{full_title}.srt"
        clip_video = stem_dir / "videos" / f"01_{full_title}.mp4"
        tts_voice_mode = generate_pocket_tts_audio(
            knowledge_script,
            voice_embedding_for_tts,
            clip_audio,
            fallback_voice=args.pocket_tts_fallback_voice,
            strict_voice_clone=args.strict_voice_clone,
        )
        synth_duration = ffprobe_duration(clip_audio)
        write_script_srt(knowledge_script, synth_duration, clip_srt, max_lines_per_page=5)
        make_subtitle_video(
            clip_audio,
            clip_srt,
            clip_video,
            width=args.video_width,
            height=args.video_height,
        )

        manifest: dict[str, Any] = {
            "input_audio": str(input_audio),
            "enhanced_audio": str(enhanced_audio),
            "source_trim_seconds": (int(args.max_input_seconds) if args.max_input_seconds else None),
            "voice_reference_audio": (str(voice_ref_wav) if voice_ref_wav.exists() else None),
            "voice_reference_embedding": str(voice_ref_embedding),
            "voice_reference_window": {
                "start_seconds": round(ref_start, 3),
                "end_seconds": round(ref_end, 3),
                "selected_duration_seconds": round(ref_end - ref_start, 3),
                "selection_metrics": {k: round(float(v), 4) for k, v in ref_meta.items()},
                "embedding_reused": embedding_reused,
            },
            "transcript_plain_file": str(transcript_plain_txt),
            "knowledge_script_file": str(knowledge_script_txt),
            "full_render": {
                "title": "Knowledge Script",
                "audio_clip": str(clip_audio),
                "subtitle_file": str(clip_srt),
                "video_file": str(clip_video),
                "clip_duration_seconds": round(synth_duration, 3),
                "tts_voice_mode": tts_voice_mode,
                "video_width": int(args.video_width),
                "video_height": int(args.video_height),
                "subtitle_layout": {"max_lines_per_page": 5, "anchor": "top-left"},
            },
        }

        (stem_dir / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")

        print(f"Done. Output directory: {stem_dir}")
        print(f"Videos: {stem_dir / 'videos'}")
        print(f"Transcript (plain): {transcript_plain_txt}")
        print(f"Knowledge script: {knowledge_script_txt}")
        print(f"Subtitle file: {clip_srt}")
    finally:
        if args.keep_temp:
            print(f"Kept temp dir: {temp_dir}", file=sys.stderr)
        else:
            shutil.rmtree(temp_dir, ignore_errors=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
