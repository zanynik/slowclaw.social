#!/usr/bin/env python3
from __future__ import annotations

import argparse
import dataclasses
import json
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

_SCRIPT_DIR = Path(__file__).resolve().parent
_PY_TAG = f"py{sys.version_info.major}{sys.version_info.minor}"
_VERSIONED_VENDOR = _SCRIPT_DIR / f".vendor-{_PY_TAG}"
_LEGACY_VENDOR = _SCRIPT_DIR / ".vendor"
if _VERSIONED_VENDOR.exists():
    # Prefer interpreter-matched wheels; do not fall back to legacy .vendor if present,
    # because binary extensions there may be built for a different Python version.
    sys.path.insert(0, str(_VERSIONED_VENDOR))
elif _LEGACY_VENDOR.exists():
    sys.path.insert(0, str(_LEGACY_VENDOR))

from audio_to_video import (
    Segment,
    Word,
    clamp,
    ensure_dir,
    enhance_audio,
    export_pocket_tts_voice,
    ffprobe_duration,
    generate_pocket_tts_audio,
    make_subtitle_video,
    make_voice_reference_sample_at,
    normalize_text,
    require_cmd,
    run,
    sanitize_filename,
    select_best_voice_reference_window,
    srt_time,
    transcribe_with_whisper,
)


@dataclasses.dataclass
class TimedToken:
    text: str
    start: float
    end: float
    norm: str


@dataclasses.dataclass
class SourceChunk:
    source_start: float
    source_end: float
    kept_start_idx: int
    kept_end_idx: int


@dataclasses.dataclass
class EditedLexeme:
    text: str
    norm: str


@dataclasses.dataclass
class AlignmentRun:
    kind: str  # "original" or "tts"
    edited_start_idx: int
    edited_end_idx: int
    edited_tokens: list[EditedLexeme]
    original_indices: list[int]


@dataclasses.dataclass
class ClipSelection:
    title: str
    word_ranges: list[tuple[int, int]]
    rationale: str | None = None


_GEMINI_HELP_CACHE: str | None = None


def transcript_plain_text_from_segments(segments: list[Segment]) -> str:
    return "\n".join(normalize_text(seg.text) for seg in segments if normalize_text(seg.text))


def _normalize_lexemes(text: str) -> list[str]:
    tokens = re.findall(r"[A-Za-z0-9]+(?:'[A-Za-z0-9]+)?", text)
    return [t.lower() for t in tokens if t.strip()]


def _token_matches(original_norm: str, edited_norm: str) -> bool:
    if original_norm == edited_norm:
        return True
    o = original_norm.replace("'", "")
    e = edited_norm.replace("'", "")
    if o == e:
        return True
    # Tolerate possessive normalization mismatch (e.g., "buddha's" vs "buddha").
    if o.endswith("s") and o[:-1] == e:
        return True
    if e.endswith("s") and e[:-1] == o:
        return True
    return False


def _token_canon(norm: str) -> str:
    s = (norm or "").lower().replace("'", "")
    if len(s) > 3 and s.endswith("s"):
        return s[:-1]
    return s


def _lcs_align_indices(orig_keys: list[str], edit_keys: list[str]) -> list[tuple[int, int]]:
    # Exact LCS alignment using dynamic programming. Sizes here are manageable
    # (edited transcript is much shorter than original transcript).
    n = len(orig_keys)
    m = len(edit_keys)
    if n == 0 or m == 0:
        return []

    # DP lengths (rolling rows) + compact backtrack directions for exact reconstruction.
    # dirs[(i*(m+1))+j] encodes decision at cell (i,j): 1=diag(match), 2=up, 3=left.
    dirs = bytearray((n + 1) * (m + 1))
    prev = [0] * (m + 1)
    for i in range(1, n + 1):
        cur = [0] * (m + 1)
        oi = orig_keys[i - 1]
        row_base = i * (m + 1)
        prev_row_base = (i - 1) * (m + 1)
        for j in range(1, m + 1):
            if oi == edit_keys[j - 1]:
                cur[j] = prev[j - 1] + 1
                dirs[row_base + j] = 1
            elif prev[j] >= cur[j - 1]:
                cur[j] = prev[j]
                dirs[row_base + j] = 2
            else:
                cur[j] = cur[j - 1]
                dirs[row_base + j] = 3
        prev = cur

    out_rev: list[tuple[int, int]] = []
    i, j = n, m
    while i > 0 and j > 0:
        d = dirs[i * (m + 1) + j]
        if d == 1:
            out_rev.append((i - 1, j - 1))
            i -= 1
            j -= 1
        elif d == 2:
            i -= 1
        else:
            j -= 1
    out_rev.reverse()
    return out_rev


def collect_timed_tokens(segments: list[Segment]) -> list[TimedToken]:
    out: list[TimedToken] = []
    for seg in segments:
        if seg.words:
            for w in seg.words:
                txt = (w.text or "").strip()
                if not txt:
                    continue
                norm_parts = _normalize_lexemes(txt)
                if not norm_parts:
                    continue
                # Some Whisper backends occasionally emit a single "word" token containing
                # multiple lexemes. Split them so subsequence alignment can stay exact.
                w_start = float(w.start)
                w_end = float(w.end)
                span = max(0.01, w_end - w_start)
                step = span / max(1, len(norm_parts))
                for part_idx, part in enumerate(norm_parts):
                    part_start = w_start + part_idx * step
                    part_end = w_start + (part_idx + 1) * step
                    out.append(
                        TimedToken(
                            text=(part if len(norm_parts) > 1 else txt),
                            start=part_start,
                            end=part_end,
                            norm=part,
                        )
                    )
            continue

        words = [w for w in re.findall(r"\S+", seg.text or "") if w.strip()]
        if not words:
            continue
        dur = max(0.05, float(seg.end) - float(seg.start))
        step = dur / len(words)
        for idx, txt in enumerate(words):
            norm_parts = _normalize_lexemes(txt)
            if not norm_parts:
                continue
            word_start = float(seg.start) + idx * step
            word_end = float(seg.start) + (idx + 1) * step
            span = max(0.01, word_end - word_start)
            part_step = span / max(1, len(norm_parts))
            for part_idx, part in enumerate(norm_parts):
                start = word_start + part_idx * part_step
                end = word_start + (part_idx + 1) * part_step
                out.append(
                    TimedToken(
                        text=(part if len(norm_parts) > 1 else txt),
                        start=start,
                        end=end,
                        norm=part,
                    )
                )

    out.sort(key=lambda t: (t.start, t.end))
    cleaned: list[TimedToken] = []
    for t in out:
        start = max(0.0, float(t.start))
        end = max(start + 0.01, float(t.end))
        cleaned.append(TimedToken(text=t.text, start=start, end=end, norm=t.norm))
    return cleaned


def write_word_timing_json(tokens: list[TimedToken], out_path: Path) -> None:
    payload = {
        "words": [
            {"index": i, "text": t.text, "normalized": t.norm, "start": t.start, "end": t.end}
            for i, t in enumerate(tokens)
        ]
    }
    out_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def load_word_timing_json(path: Path) -> list[TimedToken]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    out: list[TimedToken] = []
    for item in payload.get("words", []):
        txt = str(item.get("text", "")).strip()
        norm = str(item.get("normalized", "")).strip().lower()
        if not norm:
            parts = _normalize_lexemes(txt)
            norm = parts[0] if parts else ""
        if not txt or not norm:
            continue
        start = float(item.get("start", 0.0))
        end = float(item.get("end", start + 0.01))
        if end <= start:
            end = start + 0.01
        out.append(TimedToken(text=txt, start=start, end=end, norm=norm))
    if not out:
        raise RuntimeError(f"No valid words found in timing JSON: {path}")
    out.sort(key=lambda t: (t.start, t.end))
    return out


def call_gemini_deletion_only(transcript_text: str, *, gemini_model: str) -> str:
    gemini = require_cmd("gemini")
    prompt = f"""
You are editing a spoken transcript to make it tighter and more information-dense.

Task:
- Remove filler, repetition, drift, and low-value detours.
- Keep the remaining transcript information-dense and insight-rich.
- Preserve original meaning and speaker voice.
- Prefer deletions over rewrites.
- Keep wording changes very, very minimal.
- Do not add new information.
- Do not change the meaning.
- Preserve order and flow as much as possible.
- If a rewrite is needed for clarity, make the smallest possible local change.
- Output only the edited transcript plain text (no markdown, no notes).

Important preference:
- The best output is usually the original transcript with only deletions.
- Minor word changes are allowed only when necessary, and should be rare.

Transcript:
{transcript_text}
""".strip()
    cp = run([gemini, "-m", gemini_model, "-p", prompt])
    if cp.returncode != 0:
        raise RuntimeError(f"gemini deletion-only edit failed:\n{cp.stderr}")
    out = cp.stdout.strip()
    if not out:
        raise RuntimeError("gemini returned empty edited transcript")
    return out


def call_gemini_strict_delete_only(transcript_text: str, *, gemini_model: str) -> str:
    gemini = require_cmd("gemini")
    prompt = f"""
You are editing a spoken transcript by deleting content only.

Rules (strict):
- Delete words/sentences/phrases that are low-value, repetitive, filler, or off-track.
- Do NOT add any new words.
- Do NOT paraphrase.
- Do NOT reorder.
- Do NOT change any word at all (no tense, spelling, plurality, grammar fixes, punctuation fixes).
- Keep the exact original wording for all remaining words.
- If the result is grammatically awkward, keep it awkward.
- Output plain text only. No markdown. No commentary.
- Preserve the original order exactly.
- The output must be created by COPY-PASTE of the original transcript and then deleting parts.
- Never replace one word with another.
- Never move a phrase earlier or later.
- Never summarize.
- Do not normalize names/terms (example: keep \"spread\" vs \"spreads\" exactly as in source).

This must be a strict subsequence of the original transcript text content.
Every remaining word must appear in the same left-to-right order as the source.

Verification before final answer:
1) Check that every output word exists in the source.
2) Check that the order is identical to the source.
3) If any rule is violated, fix it by deleting more words (not by rewriting).
4) If unsure, return the original transcript unchanged.

Bad (forbidden):
- developed -> develop
- moved a phrase to earlier position
- replaced one word with a synonym

Good:
- exact original words, only shorter because parts were deleted

Transcript:
{transcript_text}
""".strip()
    cp = run([gemini, "-m", gemini_model, "-p", prompt])
    if cp.returncode != 0:
        raise RuntimeError(f"gemini strict delete-only edit failed:\n{cp.stderr}")
    out = cp.stdout.strip()
    if not out:
        raise RuntimeError("gemini returned empty edited transcript")
    return out


def _extract_json_object(text: str) -> dict[str, Any]:
    try:
        obj = json.loads(text)
        if isinstance(obj, dict):
            return obj
    except json.JSONDecodeError:
        pass
    m = re.search(r"\{.*\}", text, flags=re.S)
    if not m:
        raise RuntimeError(f"Could not parse JSON from Gemini output:\n{text[:1200]}")
    obj = json.loads(m.group(0))
    if not isinstance(obj, dict):
        raise RuntimeError("Gemini JSON root must be an object")
    return obj


def _unwrap_nested_json_object(payload: dict[str, Any]) -> dict[str, Any]:
    cur = payload
    # Some Gemini CLI versions wrap the actual model JSON in a string field
    # like {"session_id": "...", "response": "{...}"}.
    for _ in range(3):
        nested = cur.get("response") or cur.get("output") or cur.get("text")
        if not isinstance(nested, str):
            break
        s = nested.strip()
        if not s.startswith("{"):
            break
        try:
            nxt = _extract_json_object(s)
        except Exception:
            break
        cur = nxt
    return cur


def _gemini_help_text(gemini_bin: str) -> str:
    global _GEMINI_HELP_CACHE
    if _GEMINI_HELP_CACHE is not None:
        return _GEMINI_HELP_CACHE
    cp = run([gemini_bin, "--help"])
    _GEMINI_HELP_CACHE = (cp.stdout or "") + "\n" + (cp.stderr or "")
    return _GEMINI_HELP_CACHE


def _call_gemini_json(prompt: str, *, gemini_model: str) -> tuple[dict[str, Any], str]:
    gemini = require_cmd("gemini")
    help_text = _gemini_help_text(gemini)
    supports_output_format = "--output-format" in help_text or "-o, --output-format" in help_text

    attempts: list[list[str]] = []
    if supports_output_format:
        attempts.append([gemini, "-m", gemini_model, "--output-format", "json", prompt])
    attempts.append([gemini, "-m", gemini_model, "-o", "json", prompt])

    seen: set[tuple[str, ...]] = set()
    last_err: str | None = None
    for cmd in attempts:
        key = tuple(cmd)
        if key in seen:
            continue
        seen.add(key)
        cp = run(cmd)
        if cp.returncode != 0:
            last_err = cp.stderr or cp.stdout or f"exit={cp.returncode}"
            continue
        raw_out = (cp.stdout or "").strip()
        if not raw_out:
            last_err = "empty stdout"
            continue
        payload = _unwrap_nested_json_object(_extract_json_object(raw_out))
        return payload, raw_out

    raise RuntimeError(f"gemini json call failed:\n{last_err or 'unknown error'}")


def _normalize_index_ranges(
    raw_ranges: Any,
    *,
    total_items: int,
    field_name: str,
) -> list[tuple[int, int]]:
    def _coerce_pair(item: Any) -> tuple[int, int] | None:
        if isinstance(item, dict):
            start_keys = ("start", "start_index", "from", "begin")
            end_keys = ("end", "end_index", "to", "stop")
            s_val = next((item[k] for k in start_keys if k in item), None)
            e_val = next((item[k] for k in end_keys if k in item), None)
            if s_val is None or e_val is None:
                return None
            return (int(s_val), int(e_val))
        if isinstance(item, (list, tuple)) and len(item) >= 2:
            return (int(item[0]), int(item[1]))
        if isinstance(item, str):
            m = re.search(r"(-?\d+)\s*(?:-|,|to|:)\s*(-?\d+)", item, flags=re.I)
            if m:
                return (int(m.group(1)), int(m.group(2)))
        return None

    ranges: list[tuple[int, int]] = []
    for item in raw_ranges or []:
        pair = _coerce_pair(item)
        if pair is None:
            continue
        s, e = pair
        if e < s:
            s, e = e, s
        ranges.append((s, e))
    ranges.sort()
    merged: list[tuple[int, int]] = []
    for s, e in ranges:
        if s < 0 or e >= total_items:
            raise RuntimeError(f"Gemini returned out-of-range {field_name}: {(s, e)}")
        if not merged:
            merged.append((s, e))
            continue
        ps, pe = merged[-1]
        if s <= pe + 1:
            merged[-1] = (ps, max(pe, e))
        else:
            merged.append((s, e))
    return merged


def call_gemini_delete_word_ranges(
    original_tokens: list[TimedToken],
    *,
    gemini_model: str,
) -> list[tuple[int, int]]:
    gemini = require_cmd("gemini")
    indexed_lines: list[str] = []
    for i, tok in enumerate(original_tokens):
        indexed_lines.append(f"{i}:{tok.text}")
    prompt = f"""
You are editing a transcript by deleting words only.

Return ONLY JSON with word index ranges to delete from the indexed list below.

Rules:
- You may only delete words (no additions, no replacements, no reordering).
- Preserve original order of all kept words.
- Prefer deleting filler, repetition, drift, and low-value detours.
- Keep meaning and speaker voice.
- Output valid JSON only.
- Use inclusive indices.
- Ranges must be sorted and non-overlapping.
- If no deletions are needed, return an empty list.

JSON schema:
{{
  "delete_ranges": [
    {{"start": 12, "end": 19}},
    {{"start": 51, "end": 51}}
  ]
}}

Indexed words:
{chr(10).join(indexed_lines)}
""".strip()
    prompt += "\n\nImportant output constraint:\n- Return a JSON object only (no markdown fences, no prose, no comments).\n"
    payload, _raw = _call_gemini_json(prompt, gemini_model=gemini_model)
    return _normalize_index_ranges(
        payload.get("delete_ranges") or [],
        total_items=len(original_tokens),
        field_name="delete index range",
    )


def call_gemini_select_clip_word_ranges(
    original_tokens: list[TimedToken],
    *,
    gemini_model: str,
    clip_count: int,
    clip_min_words: int,
    clip_max_words: int,
    clip_max_ranges: int,
) -> list[ClipSelection]:
    gemini = require_cmd("gemini")
    indexed_words = [f"{i}:{tok.text}" for i, tok in enumerate(original_tokens)]
    prompt = f"""
You are selecting SHORT INSIGHTFUL CLIPS from a long transcript.

Return ONLY JSON with multiple clips. Each clip should be a set of word index ranges from the indexed transcript.

Goal:
- Pick {clip_count} interesting, insightful, self-contained clips.
- Each clip may contain multiple word ranges that together form one coherent clip.
- Prefer strong ideas, stories, surprising insights, concrete examples, or memorable moments.

Rules:
- Use only the provided indexed words.
- No rewrites, no added words, no reordering inside ranges.
- Use inclusive indices.
- Within each clip, ranges must be sorted and non-overlapping.
- Keep each clip roughly between {clip_min_words} and {clip_max_words} selected words total.
- Use at most {clip_max_ranges} ranges per clip.
- Prefer clips that can stand alone as a 1-3 minute excerpt.
- Avoid near-duplicate clips.
- Output valid JSON only.
- Return a JSON object only (no markdown fences, no prose, no comments).

JSON schema:
{{
  "clips": [
    {{
      "title": "Short descriptive title",
      "rationale": "Why this clip is interesting (brief)",
      "word_ranges": [
        {{"start": 120, "end": 170}},
        {{"start": 182, "end": 210}}
      ]
    }}
  ]
}}

Indexed words:
{chr(10).join(indexed_words)}
""".strip()
    payload, raw_out = _call_gemini_json(prompt, gemini_model=gemini_model)
    data_obj = payload.get("data")
    data_clips = data_obj.get("clips") if isinstance(data_obj, dict) else None
    raw_clips = (
        payload.get("clips")
        or payload.get("selected_clips")
        or payload.get("items")
        or payload.get("results")
        or data_clips
    ) or []
    if not isinstance(raw_clips, list):
        raise RuntimeError("Gemini clip-selection JSON must contain a 'clips' array")

    clips: list[ClipSelection] = []
    for idx, item in enumerate(raw_clips):
        if isinstance(item, dict):
            title = str(item.get("title") or item.get("name") or f"Clip {idx + 1}").strip() or f"Clip {idx + 1}"
            rationale_raw = item.get("rationale") or item.get("why") or item.get("description")
            rationale = str(rationale_raw).strip() if rationale_raw else None
            raw_ranges = (
                item.get("word_ranges")
                or item.get("ranges")
                or item.get("segments")
                or item.get("line_ranges")
            ) or []
        else:
            title = f"Clip {idx + 1}"
            rationale = None
            raw_ranges = item
        ranges = _normalize_index_ranges(raw_ranges, total_items=len(original_tokens), field_name=f"clip {idx + 1} word range")
        if not ranges:
            continue
        if len(ranges) > clip_max_ranges:
            ranges = ranges[:clip_max_ranges]
        clips.append(ClipSelection(title=title, word_ranges=ranges, rationale=rationale))
        if len(clips) >= clip_count:
            break

    if not clips:
        raise RuntimeError(
            "Gemini did not return any valid clip selections. "
            f"Raw response preview: {raw_out[:800]!r}"
        )
    return clips


def apply_delete_ranges_to_tokens(
    original_tokens: list[TimedToken],
    delete_ranges: list[tuple[int, int]],
) -> tuple[list[TimedToken], list[int]]:
    delete_mask = [False] * len(original_tokens)
    for s, e in delete_ranges:
        for i in range(s, e + 1):
            delete_mask[i] = True
    kept_tokens: list[TimedToken] = []
    kept_indices: list[int] = []
    for i, tok in enumerate(original_tokens):
        if delete_mask[i]:
            continue
        kept_tokens.append(tok)
        kept_indices.append(i)
    if not kept_tokens:
        raise RuntimeError("Delete-ranges removed all words; refusing empty output")
    return kept_tokens, kept_indices


def apply_keep_ranges_to_tokens(
    original_tokens: list[TimedToken],
    keep_ranges: list[tuple[int, int]],
) -> tuple[list[TimedToken], list[int]]:
    keep_mask = [False] * len(original_tokens)
    for s, e in keep_ranges:
        for i in range(s, e + 1):
            keep_mask[i] = True
    kept_tokens: list[TimedToken] = []
    kept_indices: list[int] = []
    for i, tok in enumerate(original_tokens):
        if not keep_mask[i]:
            continue
        kept_tokens.append(tok)
        kept_indices.append(i)
    if not kept_tokens:
        raise RuntimeError("Keep-ranges selected no words; refusing empty clip")
    return kept_tokens, kept_indices


def _selected_word_count(ranges: list[tuple[int, int]]) -> int:
    return sum((e - s + 1) for s, e in ranges)


def tokenize_edited_lexemes(edited_text: str) -> list[EditedLexeme]:
    out: list[EditedLexeme] = []
    for raw_tok in re.findall(r"\S+", edited_text):
        parts = _normalize_lexemes(raw_tok)
        if not parts:
            continue
        if len(parts) == 1:
            out.append(EditedLexeme(text=raw_tok, norm=parts[0]))
        else:
            for p in parts:
                out.append(EditedLexeme(text=p, norm=p))
    return out


def strict_subsequence_align(
    original: list[TimedToken],
    edited_tokens: list[EditedLexeme],
) -> tuple[list[int | None], dict[str, Any]]:
    matches: list[int | None] = []
    scan = 0
    for tok in edited_tokens:
        hit: int | None = None
        while scan < len(original):
            if _token_matches(original[scan].norm, tok.norm):
                hit = scan
                scan += 1
                break
            scan += 1
        matches.append(hit)
        if hit is None:
            exists_anywhere = any(_token_matches(t.norm, tok.norm) for t in original)
            exists_in_suffix = any(_token_matches(t.norm, tok.norm) for t in original[scan:])
            raise RuntimeError(
                "Strict original-audio-only mode requires deletion-only alignment, but Gemini rewrote or reordered content "
                f"(first unmatched token: {tok.text!r}; exists_anywhere={exists_anywhere}; "
                f"exists_in_remaining_suffix={exists_in_suffix})."
            )
    matched = len(edited_tokens)
    return matches, {
        "original_word_count": len(original),
        "edited_word_count": len(edited_tokens),
        "matched_word_count": matched,
        "tts_word_count": 0,
        "match_ratio": 1.0 if edited_tokens else 0.0,
        "compression_ratio": round(len(edited_tokens) / max(1, len(original)), 4),
        "alignment_method": "strict_subsequence_exact_order",
    }


def align_edited_to_original_greedy(
    original: list[TimedToken],
    edited_tokens: list[EditedLexeme],
) -> tuple[list[int | None], dict[str, Any]]:
    # Global exact alignment avoids the "cascade" problem of greedy matching where one early
    # rewrite causes many later tokens to be marked as unmatched and sent to TTS.
    orig_keys = [_token_canon(t.norm) for t in original]
    edit_keys = [_token_canon(t.norm) for t in edited_tokens]
    matches: list[int | None] = [None] * len(edited_tokens)
    matched = 0
    for oi, ej in _lcs_align_indices(orig_keys, edit_keys):
        if _token_matches(original[oi].norm, edited_tokens[ej].norm):
            matches[ej] = oi
            matched += 1

    unmatched = len(edited_tokens) - matched
    metrics = {
        "original_word_count": len(original),
        "edited_word_count": len(edited_tokens),
        "matched_word_count": matched,
        "tts_word_count": unmatched,
        "match_ratio": round(matched / max(1, len(edited_tokens)), 4),
        "compression_ratio": round(len(edited_tokens) / max(1, len(original)), 4),
        "alignment_method": "lcs_global_exact",
    }
    return matches, metrics


def build_alignment_runs(edited_tokens: list[EditedLexeme], matches: list[int | None]) -> list[AlignmentRun]:
    if len(edited_tokens) != len(matches):
        raise RuntimeError("Alignment length mismatch")
    runs: list[AlignmentRun] = []
    for idx, (tok, match_idx) in enumerate(zip(edited_tokens, matches)):
        kind = "original" if match_idx is not None else "tts"
        if runs and runs[-1].kind == kind:
            if kind == "original":
                prev_idx = runs[-1].original_indices[-1]
                # If order goes backward (should not happen), break the run.
                if match_idx is not None and match_idx < prev_idx:
                    runs.append(
                        AlignmentRun(kind=kind, edited_start_idx=idx, edited_end_idx=idx, edited_tokens=[tok], original_indices=[match_idx])
                    )
                    continue
            runs[-1].edited_end_idx = idx
            runs[-1].edited_tokens.append(tok)
            if match_idx is not None:
                runs[-1].original_indices.append(match_idx)
            continue
        runs.append(
            AlignmentRun(
                kind=kind,
                edited_start_idx=idx,
                edited_end_idx=idx,
                edited_tokens=[tok],
                original_indices=([match_idx] if match_idx is not None else []),
            )
        )
    return runs


def build_chunks_from_kept_words(
    kept_words: list[TimedToken],
    total_duration: float,
    *,
    pad_before: float,
    pad_after: float,
    min_word_dur: float,
    merge_gap: float,
) -> list[SourceChunk]:
    if not kept_words:
        return []

    chunks: list[SourceChunk] = []
    for idx, w in enumerate(kept_words):
        start = clamp(w.start - pad_before, 0.0, total_duration)
        end = clamp(max(w.end + pad_after, start + min_word_dur), 0.0, total_duration)
        if end <= start:
            continue
        if not chunks:
            chunks.append(SourceChunk(start, end, idx, idx))
            continue
        prev = chunks[-1]
        if start <= prev.source_end + merge_gap:
            prev.source_end = max(prev.source_end, end)
            prev.kept_end_idx = idx
        else:
            chunks.append(SourceChunk(start, end, idx, idx))
    return [c for c in chunks if c.source_end - c.source_start > 0.01]


def compute_inter_chunk_pauses(
    chunks: list[SourceChunk],
    *,
    min_pause: float,
    max_pause: float,
) -> list[float]:
    pauses: list[float] = []
    for i in range(max(0, len(chunks) - 1)):
        raw_gap = max(0.0, chunks[i + 1].source_start - chunks[i].source_end)
        pauses.append(clamp(raw_gap, min_pause, max_pause))
    return pauses


def ffmpeg_concat_chunks_with_pauses(
    input_audio: Path,
    output_audio: Path,
    chunks: list[SourceChunk],
    pauses: list[float],
) -> None:
    if not chunks:
        raise RuntimeError("No chunks to concat")
    ffmpeg = require_cmd("ffmpeg")

    parts: list[str] = []
    sequence_labels: list[str] = []
    for i, c in enumerate(chunks):
        chunk_dur = max(0.01, c.source_end - c.source_start)
        fade_in = min(0.008, chunk_dur * 0.25)
        fade_out = min(0.010, chunk_dur * 0.25)
        fade_out_st = max(0.0, chunk_dur - fade_out)
        parts.append(
            "[0:a]"
            f"atrim=start={c.source_start:.6f}:end={c.source_end:.6f},"
            "asetpts=PTS-STARTPTS,"
            f"afade=t=in:st=0:d={fade_in:.6f},"
            f"afade=t=out:st={fade_out_st:.6f}:d={fade_out:.6f}"
            f"[c{i}]"
        )
        sequence_labels.append(f"[c{i}]")
        if i < len(pauses) and pauses[i] > 0.001:
            parts.append(
                "anullsrc=r=48000:cl=mono,"
                f"atrim=start=0:end={pauses[i]:.6f},asetpts=PTS-STARTPTS[g{i}]"
            )
            sequence_labels.append(f"[g{i}]")

    parts.append(f"{''.join(sequence_labels)}concat=n={len(sequence_labels)}:v=0:a=1[outa]")
    cmd = [
        ffmpeg,
        "-y",
        "-i",
        str(input_audio),
        "-filter_complex",
        ";".join(parts),
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
        raise RuntimeError(f"ffmpeg chunk concat failed:\n{cp.stderr}")


def remap_kept_words_to_output(
    kept_words: list[TimedToken],
    chunks: list[SourceChunk],
    pauses: list[float],
) -> list[tuple[float, float, str]]:
    timed_out: list[tuple[float, float, str]] = []
    cursor = 0.0
    for i, chunk in enumerate(chunks):
        for w_idx in range(chunk.kept_start_idx, chunk.kept_end_idx + 1):
            w = kept_words[w_idx]
            start = cursor + max(0.0, w.start - chunk.source_start)
            end = cursor + max(0.01, w.end - chunk.source_start)
            if end <= start:
                end = start + 0.01
            timed_out.append((start, end, w.text))
        cursor += max(0.0, chunk.source_end - chunk.source_start)
        if i < len(pauses):
            cursor += pauses[i]
    return timed_out


def paginate_words(
    timed_words: list[tuple[float, float, str]],
    *,
    max_chars_per_line: int,
    max_lines_per_page: int,
) -> list[list[list[tuple[float, float, str]]]]:
    pages: list[list[list[tuple[float, float, str]]]] = []
    page: list[list[tuple[float, float, str]]] = []
    line_words: list[tuple[float, float, str]] = []
    line_len = 0

    for item in timed_words:
        word = item[2].strip()
        if not word:
            continue
        add_len = len(word) if not line_words else (1 + len(word))
        if line_words and line_len + add_len > max_chars_per_line:
            page.append(line_words)
            line_words = []
            line_len = 0
        if not line_words and len(page) >= max_lines_per_page:
            pages.append(page)
            page = []
        line_words.append((item[0], item[1], word))
        line_len += add_len if line_len else len(word)

    if line_words:
        page.append(line_words)
    if page:
        pages.append(page)
    return pages


def write_progressive_srt_from_timed_words(
    timed_words: list[tuple[float, float, str]],
    out_path: Path,
    *,
    total_duration: float,
    max_chars_per_line: int = 52,
    max_lines_per_page: int = 5,
) -> None:
    if not timed_words:
        out_path.write_text(f"1\n00:00:00,000 --> {srt_time(max(0.5, total_duration))}\n\n", encoding="utf-8")
        return

    pages = paginate_words(
        timed_words,
        max_chars_per_line=max_chars_per_line,
        max_lines_per_page=max_lines_per_page,
    )
    flat = [w for page in pages for line in page for w in line]
    next_start_by_idx: list[float] = []
    for i, (_s, _e, _t) in enumerate(flat):
        next_start_by_idx.append(flat[i + 1][0] if i + 1 < len(flat) else total_duration)

    entries: list[str] = []
    idx = 1
    global_i = 0
    for page in pages:
        page_text = [[w[2] for w in line] for line in page]
        revealed = [0] * len(page)
        for line_idx, line in enumerate(page):
            for local_idx, (start, end, _word) in enumerate(line):
                revealed[line_idx] = local_idx + 1
                parts: list[str] = []
                for li, words in enumerate(page_text):
                    visible_n = revealed[li]
                    if visible_n <= 0:
                        continue
                    parts.append(" ".join(words[:visible_n]))
                caption = "\n".join(parts).strip()
                next_start = next_start_by_idx[global_i]
                entry_end = max(end, next_start)
                if entry_end > start and caption:
                    entries.append(f"{idx}\n{srt_time(start)} --> {srt_time(entry_end)}\n{caption}\n")
                    idx += 1
                global_i += 1

    out_path.write_text("\n".join(entries), encoding="utf-8")


def _pillow_install_hint() -> str:
    vendor_dir = _SCRIPT_DIR / f".vendor-{_PY_TAG}"
    return f"{sys.executable} -m pip install pillow -t {vendor_dir}"


def ffmpeg_standardize_audio_piece(
    input_audio: Path,
    output_audio: Path,
    *,
    soft_edge_fade: bool = True,
) -> None:
    ffmpeg = require_cmd("ffmpeg")
    ensure_dir(output_audio.parent)
    af_parts = []
    if soft_edge_fade:
        # Fade in/out without probing duration first.
        af_parts.append("afade=t=in:st=0:d=0.006")
        af_parts.append("areverse")
        af_parts.append("afade=t=in:st=0:d=0.006")
        af_parts.append("areverse")
    af = ",".join(af_parts) if af_parts else None
    cmd = [
        ffmpeg,
        "-y",
        "-i",
        str(input_audio),
    ]
    if af:
        cmd += ["-af", af]
    cmd += [
        "-ar",
        "48000",
        "-ac",
        "1",
        "-c:a",
        "pcm_s16le",
        str(output_audio),
    ]
    cp = run(cmd)
    if cp.returncode != 0:
        raise RuntimeError(f"ffmpeg standardize audio piece failed:\n{cp.stderr}")


def ffmpeg_concat_audio_files(files: list[Path], output_audio: Path) -> None:
    if not files:
        raise RuntimeError("No audio files to concat")
    ffmpeg = require_cmd("ffmpeg")
    ensure_dir(output_audio.parent)
    with tempfile.TemporaryDirectory(prefix="a2v2_concat_") as td:
        concat_txt = Path(td) / "concat.txt"
        lines = []
        for p in files:
            safe = str(p).replace("'", r"'\''")
            lines.append(f"file '{safe}'")
        concat_txt.write_text("\n".join(lines) + "\n", encoding="utf-8")
        cmd = [
            ffmpeg,
            "-y",
            "-f",
            "concat",
            "-safe",
            "0",
            "-i",
            str(concat_txt),
            "-c:a",
            "pcm_s16le",
            "-ar",
            "48000",
            "-ac",
            "1",
            str(output_audio),
        ]
        cp = run(cmd)
        if cp.returncode != 0:
            raise RuntimeError(f"ffmpeg concat audio files failed:\n{cp.stderr}")


def ffmpeg_make_silence(output_audio: Path, duration: float) -> None:
    ffmpeg = require_cmd("ffmpeg")
    dur = max(0.01, float(duration))
    cmd = [
        ffmpeg,
        "-y",
        "-f",
        "lavfi",
        "-i",
        "anullsrc=r=48000:cl=mono",
        "-t",
        f"{dur:.6f}",
        "-ar",
        "48000",
        "-ac",
        "1",
        "-c:a",
        "pcm_s16le",
        str(output_audio),
    ]
    cp = run(cmd)
    if cp.returncode != 0:
        raise RuntimeError(f"ffmpeg make silence failed:\n{cp.stderr}")


def prepare_voice_embedding_for_hybrid(
    *,
    enhanced_audio: Path,
    segments: list[Segment],
    artifacts_dir: Path,
    voice_ref_seconds: int,
    voice_embedding_path: Path | None,
    refresh_voice_embedding: bool,
    strict_voice_clone: bool,
) -> tuple[Path | None, dict[str, Any]]:
    voice_ref_wav = artifacts_dir / "hybrid_voice_reference.wav"
    voice_embedding = voice_embedding_path or (artifacts_dir / "hybrid_voice_reference.safetensors")

    embedding_reused = bool(voice_embedding.exists() and not refresh_voice_embedding)
    if embedding_reused:
        return (
            voice_embedding,
            {"embedding_reused": True, "voice_reference_audio": None, "voice_reference_embedding": str(voice_embedding)},
        )

    ref_start, ref_end, ref_meta = select_best_voice_reference_window(segments, window_seconds=max(5, voice_ref_seconds))
    make_voice_reference_sample_at(
        enhanced_audio,
        voice_ref_wav,
        start_seconds=ref_start,
        max_seconds=max(5, voice_ref_seconds),
    )
    try:
        export_pocket_tts_voice(voice_ref_wav, voice_embedding)
        return (
            voice_embedding,
            {
                "embedding_reused": False,
                "voice_reference_audio": str(voice_ref_wav),
                "voice_reference_embedding": str(voice_embedding),
                "voice_reference_window": {
                    "start_seconds": round(ref_start, 3),
                    "end_seconds": round(ref_end, 3),
                    "selected_duration_seconds": round(ref_end - ref_start, 3),
                    "selection_metrics": {k: round(float(v), 4) for k, v in ref_meta.items()},
                },
            },
        )
    except RuntimeError:
        if strict_voice_clone:
            raise
        return (
            None,
            {
                "embedding_reused": False,
                "voice_reference_audio": str(voice_ref_wav) if voice_ref_wav.exists() else None,
                "voice_reference_embedding": str(voice_embedding),
                "voice_clone_unavailable": True,
            },
        )


def render_original_audio_clip_output(
    *,
    clip_num: int,
    clip: ClipSelection,
    keep_ranges: list[tuple[int, int]],
    original_tokens: list[TimedToken],
    enhanced_audio: Path,
    stem_dir: Path,
    temp_dir: Path,
    total_source_dur: float,
    args: argparse.Namespace,
) -> dict[str, Any]:
    kept_tokens, kept_indices = apply_keep_ranges_to_tokens(original_tokens, keep_ranges)
    safe_title = sanitize_filename(clip.title).strip("_") or f"Clip_{clip_num:02d}"
    base_name = f"{clip_num:02d}_{safe_title}"

    final_audio = stem_dir / "clips" / f"{base_name}.wav"
    final_srt = stem_dir / "clips" / f"{base_name}.srt"
    final_video = stem_dir / "videos" / f"{base_name}.mp4"
    clip_artifacts_dir = stem_dir / "artifacts" / f"clip_{clip_num:02d}"
    ensure_dir(clip_artifacts_dir)

    raw_audio = temp_dir / f"clip_{clip_num:02d}_raw.wav"
    chunks = build_chunks_from_kept_words(
        kept_tokens,
        total_source_dur,
        pad_before=args.pad_before,
        pad_after=args.pad_after,
        min_word_dur=args.min_word_dur,
        merge_gap=args.merge_gap,
    )
    if not chunks:
        raise RuntimeError(f"Clip {clip_num} produced no source chunks after timing merge")
    pauses = compute_inter_chunk_pauses(chunks, min_pause=args.min_pause, max_pause=args.max_pause)
    ffmpeg_concat_chunks_with_pauses(enhanced_audio, raw_audio, chunks, pauses)
    ffmpeg_standardize_audio_piece(raw_audio, final_audio, soft_edge_fade=False)
    final_dur = ffprobe_duration(final_audio)

    timed_words_out = remap_kept_words_to_output(kept_tokens, chunks, pauses)
    timed_words_payload = {
        "words": [
            {"index": i, "start": s, "end": e, "text": t}
            for i, (s, e, t) in enumerate(timed_words_out)
        ]
    }
    (clip_artifacts_dir / "timed_words.json").write_text(
        json.dumps(timed_words_payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    (clip_artifacts_dir / "selection.json").write_text(
        json.dumps(
            {
                "clip_num": clip_num,
                "title": clip.title,
                "rationale": clip.rationale,
                "word_ranges": [{"start": s, "end": e} for s, e in keep_ranges],
                "selected_word_count": len(kept_indices),
                "source_word_indices_preview": kept_indices[:200],
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    (clip_artifacts_dir / "selected_transcript.txt").write_text(
        " ".join(tok.text for tok in kept_tokens) + "\n",
        encoding="utf-8",
    )

    write_progressive_srt_from_timed_words(
        timed_words_out,
        final_srt,
        total_duration=final_dur,
        max_chars_per_line=30,
        max_lines_per_page=4,
    )
    try:
        make_subtitle_video(
            final_audio,
            final_srt,
            final_video,
            width=args.video_width,
            height=args.video_height,
        )
    except ImportError as e:
        if "PIL" in str(e) or "_imaging" in str(e):
            raise RuntimeError(
                "Video subtitle rendering failed because Pillow is installed for a different Python version.\n"
                f"Current interpreter: {sys.executable}\n"
                f"Install Pillow for this interpreter into a version-specific local vendor dir:\n  {_pillow_install_hint()}\n"
                "Then rerun audio_to_video2.py.\n"
                f"Original import error: {e}"
            ) from e
        raise

    source_start = min(original_tokens[i].start for i in kept_indices)
    source_end = max(original_tokens[i].end for i in kept_indices)
    return {
        "clip_num": clip_num,
        "title": clip.title,
        "rationale": clip.rationale,
        "word_ranges": [{"start": s, "end": e} for s, e in keep_ranges],
        "range_count": len(keep_ranges),
        "selected_word_count": len(kept_indices),
        "source_span_seconds": round(max(0.0, source_end - source_start), 3),
        "source_start_seconds": round(source_start, 3),
        "source_end_seconds": round(source_end, 3),
        "output_duration_seconds": round(final_dur, 3),
        "chunk_count": len(chunks),
        "audio_file": str(final_audio),
        "subtitle_file": str(final_srt),
        "video_file": str(final_video),
        "artifacts_dir": str(clip_artifacts_dir),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audio to Video v2: minimal Gemini edit + hybrid original-audio/TTS stitching with timed subtitles."
    )
    parser.add_argument("input_audio", type=Path, help="Path to .m4a/.mp3/.wav/.mp4 input")
    parser.add_argument("--out-dir", type=Path, default=Path("outputs"), help="Output directory root")
    parser.add_argument("--whisper-model", default="base", help="Local Whisper model name/path")
    parser.add_argument("--gemini-model", default="gemini-3-flash-preview", help="Gemini model for minimal transcript edit")
    parser.add_argument(
        "--gemini-select-clips",
        action="store_true",
        help="Use Gemini to select multiple interesting clips (grouped word ranges) and render multiple outputs (original-audio-only mode).",
    )
    parser.add_argument("--clip-count", type=int, default=3, help="Target number of clips when --gemini-select-clips is enabled")
    parser.add_argument("--clip-min-words", type=int, default=120, help="Approx minimum selected words per clip")
    parser.add_argument("--clip-max-words", type=int, default=420, help="Approx maximum selected words per clip")
    parser.add_argument("--clip-max-ranges", type=int, default=8, help="Max grouped word ranges per clip returned by Gemini")
    parser.add_argument("--language", default=None, help="Whisper language code (optional)")
    parser.add_argument("--whisper-python", default=sys.executable, help="Python executable for Whisper backends")
    parser.add_argument("--max-input-seconds", type=int, default=None, help="Trim input for faster test runs")
    parser.add_argument("--video-width", type=int, default=1920)
    parser.add_argument("--video-height", type=int, default=1080)
    parser.add_argument("--pad-before", type=float, default=0.04, help="Seconds kept before each retained word")
    parser.add_argument("--pad-after", type=float, default=0.06, help="Seconds kept after each retained word")
    parser.add_argument("--merge-gap", type=float, default=0.09, help="Merge kept words into one chunk when source gap <= this")
    parser.add_argument("--min-pause", type=float, default=0.05, help="Minimum inserted pause between distant chunks")
    parser.add_argument("--max-pause", type=float, default=0.16, help="Maximum inserted pause between distant chunks")
    parser.add_argument("--min-word-dur", type=float, default=0.04, help="Minimum kept duration for any word segment")
    parser.add_argument("--hybrid-transition-pause", type=float, default=0.08, help="Pause inserted between hybrid runs")
    parser.add_argument("--voice-ref-seconds", type=int, default=30, help="Seconds from input to use as Pocket TTS voice reference")
    parser.add_argument("--voice-embedding-path", type=Path, default=None, help="Reusable Pocket TTS voice embedding (.safetensors)")
    parser.add_argument("--refresh-voice-embedding", action="store_true", help="Regenerate voice embedding even if file exists")
    parser.add_argument("--pocket-tts-fallback-voice", default="alba", help="Fallback Pocket TTS voice if cloning unavailable")
    parser.add_argument("--strict-voice-clone", action="store_true", help="Fail if Pocket TTS voice cloning is unavailable")
    parser.add_argument("--tts-word-gap", type=float, default=0.03, help="Small silence inserted between synthesized unmatched words")
    parser.add_argument(
        "--original-audio-only",
        action="store_true",
        help="Strict mode: Gemini may only delete content (no rewrites). Disables TTS and requires exact word alignment.",
    )
    parser.add_argument(
        "--resume-from-artifacts",
        action="store_true",
        help="Reuse existing transcript_words.json and edited transcript from the output folder (skip Whisper + Gemini)",
    )
    parser.add_argument("--keep-temp", action="store_true")
    args = parser.parse_args()

    if args.clip_count < 1:
        raise SystemExit("--clip-count must be >= 1")
    if args.clip_min_words < 1 or args.clip_max_words < 1:
        raise SystemExit("--clip-min-words and --clip-max-words must be >= 1")
    if args.clip_min_words > args.clip_max_words:
        raise SystemExit("--clip-min-words must be <= --clip-max-words")
    if args.clip_max_ranges < 1:
        raise SystemExit("--clip-max-ranges must be >= 1")
    if args.gemini_select_clips and not args.original_audio_only:
        raise SystemExit("--gemini-select-clips currently requires --original-audio-only")

    input_audio = args.input_audio.resolve()
    if not input_audio.exists():
        raise SystemExit(f"Input file not found: {input_audio}")
    if input_audio.suffix.lower() not in {".m4a", ".mp3", ".wav", ".mp4"}:
        raise SystemExit("Input must be .m4a, .mp3, .wav, or .mp4")

    require_cmd("ffmpeg")
    require_cmd("ffprobe")
    require_cmd("gemini")
    require_cmd("pocket-tts")

    out_root = args.out_dir.resolve()
    ensure_dir(out_root)
    stem_dir = out_root / f"{sanitize_filename(input_audio.stem)}_v2"
    ensure_dir(stem_dir)
    ensure_dir(stem_dir / "artifacts")
    ensure_dir(stem_dir / "clips")
    ensure_dir(stem_dir / "videos")

    temp_dir = Path(tempfile.mkdtemp(prefix="audio_to_video2_", dir=str(stem_dir / "artifacts")))
    try:
        enhanced_audio = temp_dir / "01_enhanced.wav"
        tx_dir = temp_dir / "whisper"
        transcript_plain_txt = stem_dir / "artifacts" / "transcript_plain.txt"
        transcript_words_json = stem_dir / "artifacts" / "transcript_words.json"
        edited_transcript_txt = stem_dir / "artifacts" / "edited_transcript_minimal_edit.txt"
        kept_chunks_json = stem_dir / "artifacts" / "assembly_runs.json"
        edited_timed_words_json = stem_dir / "artifacts" / "edited_timed_words.json"

        enhance_audio(input_audio, enhanced_audio, max_input_seconds=args.max_input_seconds)

        segments: list[Segment] = []
        if args.resume_from_artifacts:
            if not transcript_words_json.exists():
                raise RuntimeError(
                    f"--resume-from-artifacts requested, but timing file not found: {transcript_words_json}"
                )
            original_tokens = load_word_timing_json(transcript_words_json)
            transcript_plain = transcript_plain_txt.read_text(encoding="utf-8").strip() if transcript_plain_txt.exists() else ""
            if args.original_audio_only:
                if args.gemini_select_clips:
                    edited_transcript = ""
                else:
                    delete_ranges = call_gemini_delete_word_ranges(original_tokens, gemini_model=args.gemini_model)
                    kept_tokens, kept_indices = apply_delete_ranges_to_tokens(original_tokens, delete_ranges)
                    edited_transcript = " ".join(tok.text for tok in kept_tokens)
                    edited_transcript_txt.write_text(edited_transcript + "\n", encoding="utf-8")
            else:
                edited_candidates = [
                    edited_transcript_txt,
                    stem_dir / "artifacts" / "edited_transcript_deletion_only.txt",
                ]
                edited_existing = next((p for p in edited_candidates if p.exists()), None)
                if edited_existing is None:
                    raise RuntimeError(
                        "--resume-from-artifacts requested, but no edited transcript file found. "
                        f"Tried: {', '.join(str(p) for p in edited_candidates)}"
                    )
                edited_transcript = edited_existing.read_text(encoding="utf-8").strip()
                if not edited_transcript:
                    raise RuntimeError(f"Edited transcript file is empty: {edited_existing}")
                if edited_existing != edited_transcript_txt:
                    edited_transcript_txt.write_text(edited_transcript + "\n", encoding="utf-8")
            if args.gemini_select_clips:
                print("Resuming from existing transcript artifacts (skipping Whisper; Gemini clip selection will still run).", file=sys.stderr)
            else:
                print("Resuming from existing transcript artifacts (skipping Whisper + Gemini).", file=sys.stderr)
        else:
            segments = transcribe_with_whisper(enhanced_audio, args.whisper_model, args.language, tx_dir, args.whisper_python)
            if not segments:
                raise RuntimeError("Whisper produced no segments")

            transcript_plain = transcript_plain_text_from_segments(segments)
            transcript_plain_txt.write_text(transcript_plain + "\n", encoding="utf-8")

            original_tokens = collect_timed_tokens(segments)
            if not original_tokens:
                raise RuntimeError("No timed words were produced by Whisper")
            write_word_timing_json(original_tokens, transcript_words_json)

            if args.original_audio_only:
                if args.gemini_select_clips:
                    edited_transcript = ""
                else:
                    delete_ranges = call_gemini_delete_word_ranges(original_tokens, gemini_model=args.gemini_model)
                    kept_tokens, kept_indices = apply_delete_ranges_to_tokens(original_tokens, delete_ranges)
                    edited_transcript = " ".join(tok.text for tok in kept_tokens)
            else:
                edited_transcript = call_gemini_deletion_only(transcript_plain, gemini_model=args.gemini_model)
            if not args.gemini_select_clips:
                edited_transcript_txt.write_text(edited_transcript + "\n", encoding="utf-8")
        if args.gemini_select_clips:
            total_source_dur = ffprobe_duration(enhanced_audio)
            clip_selections = call_gemini_select_clip_word_ranges(
                original_tokens,
                gemini_model=args.gemini_model,
                clip_count=args.clip_count,
                clip_min_words=args.clip_min_words,
                clip_max_words=args.clip_max_words,
                clip_max_ranges=args.clip_max_ranges,
            )
            selected_clips_payload = {
                "mode": "gemini_select_clips_word_ranges",
                "clip_count_requested": args.clip_count,
                "clip_count_returned": len(clip_selections),
                "clip_min_words": args.clip_min_words,
                "clip_max_words": args.clip_max_words,
                "clip_max_ranges": args.clip_max_ranges,
                "clips": [
                    {
                        "clip_num": i + 1,
                        "title": clip.title,
                        "rationale": clip.rationale,
                        "word_ranges": [{"start": s, "end": e} for s, e in clip.word_ranges],
                        "selected_word_count": _selected_word_count(clip.word_ranges),
                    }
                    for i, clip in enumerate(clip_selections)
                ],
            }
            selected_clips_json = stem_dir / "artifacts" / "selected_clips.json"
            selected_clips_json.write_text(json.dumps(selected_clips_payload, ensure_ascii=False, indent=2), encoding="utf-8")

            clip_outputs: list[dict[str, Any]] = []
            for clip_num, clip in enumerate(clip_selections, start=1):
                clip_outputs.append(
                    render_original_audio_clip_output(
                        clip_num=clip_num,
                        clip=clip,
                        keep_ranges=clip.word_ranges,
                        original_tokens=original_tokens,
                        enhanced_audio=enhanced_audio,
                        stem_dir=stem_dir,
                        temp_dir=temp_dir,
                        total_source_dur=total_source_dur,
                        args=args,
                    )
                )

            manifest = {
                "workflow": "audio_to_video_v2_gemini_multi_clip_original_audio_only",
                "input_audio": str(input_audio),
                "enhanced_audio_for_editing": str(enhanced_audio),
                "max_input_seconds": args.max_input_seconds,
                "transcript_plain_file": str(transcript_plain_txt),
                "transcript_words_file": str(transcript_words_json),
                "selected_clips_file": str(selected_clips_json),
                "outputs": {"clips": clip_outputs},
                "timing_controls": {
                    "pad_before": args.pad_before,
                    "pad_after": args.pad_after,
                    "merge_gap": args.merge_gap,
                    "min_pause": args.min_pause,
                    "max_pause": args.max_pause,
                },
                "original_audio_only_mode": True,
            }
            (stem_dir / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")

            print(f"Done. Output directory: {stem_dir}")
            print(f"Generated clips: {len(clip_outputs)}")
            for c in clip_outputs:
                print(
                    f"Clip {c['clip_num']:02d}: {c['title']} | {c['output_duration_seconds']}s | {c['video_file']}"
                )
            print(f"Clip selections: {selected_clips_json}")
            print(f"Word timings (source): {transcript_words_json}")
            return 0
        edited_tokens = tokenize_edited_lexemes(edited_transcript)
        if not edited_tokens:
            raise RuntimeError("Gemini edited transcript has no lexeme tokens")
        if args.original_audio_only:
            if "kept_indices" not in locals():
                token_matches, alignment_metrics = strict_subsequence_align(original_tokens, edited_tokens)
            else:
                token_matches = kept_indices[:]  # exact local deletion; no TTS needed
                alignment_metrics = {
                    "original_word_count": len(original_tokens),
                    "edited_word_count": len(edited_tokens),
                    "matched_word_count": len(kept_indices),
                    "tts_word_count": 0,
                    "match_ratio": 1.0 if edited_tokens else 0.0,
                    "compression_ratio": round(len(edited_tokens) / max(1, len(original_tokens)), 4),
                    "alignment_method": "gemini_delete_ranges_json_exact",
                    "deleted_word_count": len(original_tokens) - len(kept_indices),
                }
        else:
            token_matches, alignment_metrics = align_edited_to_original_greedy(original_tokens, edited_tokens)
        runs = build_alignment_runs(edited_tokens, token_matches)

        final_audio = stem_dir / "clips" / "01_Condensed_OriginalVoice.wav"
        final_srt = stem_dir / "clips" / "01_Condensed_OriginalVoice.srt"
        final_video = stem_dir / "videos" / "01_Condensed_OriginalVoice.mp4"
        run_audio_dir = temp_dir / "hybrid_runs"
        ensure_dir(run_audio_dir)
        total_source_dur = ffprobe_duration(enhanced_audio)

        needs_tts = any(r.kind == "tts" for r in runs)
        if args.original_audio_only and needs_tts:
            raise RuntimeError("Strict original-audio-only mode found unmatched words, which would require TTS. Re-run or tighten edit.")
        voice_embedding_path = args.voice_embedding_path.resolve() if args.voice_embedding_path else None
        hybrid_voice_meta: dict[str, Any] = {"used_tts": needs_tts}
        voice_embedding_for_tts: Path | None = None
        if needs_tts:
            inferred_embedding_path = (
                voice_embedding_path
                if voice_embedding_path is not None
                else (stem_dir / "artifacts" / "hybrid_voice_reference.safetensors")
            )
            if not segments and not (inferred_embedding_path.exists() and not args.refresh_voice_embedding):
                # Resume mode skipped transcription. Re-run only if we need a better voice reference window.
                # This is still much cheaper than rerunning Gemini after a long edit.
                segments = transcribe_with_whisper(enhanced_audio, args.whisper_model, args.language, tx_dir, args.whisper_python)
            voice_embedding_for_tts, hybrid_voice_meta = prepare_voice_embedding_for_hybrid(
                enhanced_audio=enhanced_audio,
                segments=segments,
                artifacts_dir=stem_dir / "artifacts",
                voice_ref_seconds=args.voice_ref_seconds,
                voice_embedding_path=voice_embedding_path,
                refresh_voice_embedding=args.refresh_voice_embedding,
                strict_voice_clone=args.strict_voice_clone,
            )

        final_piece_files: list[Path] = []
        timed_words_out: list[tuple[float, float, str]] = []
        run_summaries: list[dict[str, Any]] = []
        cursor = 0.0
        tts_voice_modes: list[str] = []
        tts_inserted_words: list[str] = []

        for run_idx, run_item in enumerate(runs):
            piece_path = run_audio_dir / f"run_{run_idx:03d}_{run_item.kind}.wav"
            if run_item.kind == "original":
                raw_piece_path = run_audio_dir / f"run_{run_idx:03d}_{run_item.kind}_raw.wav"
                run_words = [original_tokens[i] for i in run_item.original_indices]
                chunks = build_chunks_from_kept_words(
                    run_words,
                    total_source_dur,
                    pad_before=args.pad_before,
                    pad_after=args.pad_after,
                    min_word_dur=args.min_word_dur,
                    merge_gap=args.merge_gap,
                )
                if not chunks:
                    continue
                pauses = compute_inter_chunk_pauses(chunks, min_pause=args.min_pause, max_pause=args.max_pause)
                ffmpeg_concat_chunks_with_pauses(enhanced_audio, raw_piece_path, chunks, pauses)
                ffmpeg_standardize_audio_piece(raw_piece_path, piece_path, soft_edge_fade=False)
                piece_dur = ffprobe_duration(piece_path)
                local_timed = remap_kept_words_to_output(run_words, chunks, pauses)
                if len(local_timed) != len(run_item.edited_tokens):
                    # Defensive fallback: approximate within this piece if counts drift.
                    step = max(0.02, piece_dur / max(1, len(run_item.edited_tokens)))
                    local_timed = [
                        (i * step, min(piece_dur, (i + 1) * step), tok.text)
                        for i, tok in enumerate(run_item.edited_tokens)
                    ]
                else:
                    local_timed = [
                        (s, e, run_item.edited_tokens[i].text) for i, (s, e, _t) in enumerate(local_timed)
                    ]
                final_piece_files.append(piece_path)
                timed_words_out.extend([(cursor + s, cursor + e, t) for s, e, t in local_timed])
                cursor += piece_dur
                run_summaries.append(
                    {
                        "run_index": run_idx,
                        "kind": "original",
                        "edited_word_count": len(run_item.edited_tokens),
                        "source_word_count": len(run_item.original_indices),
                        "audio_file": str(piece_path),
                        "duration_seconds": round(piece_dur, 3),
                        "chunks": [
                            {
                                "source_start": c.source_start,
                                "source_end": c.source_end,
                                "kept_word_start_index": c.kept_start_idx,
                                "kept_word_end_index": c.kept_end_idx,
                            }
                            for c in chunks
                        ],
                    }
                )
            else:
                if not run_item.edited_tokens:
                    continue
                tts_subpieces: list[Path] = []
                local_timed: list[tuple[float, float, str]] = []
                local_cursor = 0.0
                word_modes: list[str] = []
                for t_idx, tok in enumerate(run_item.edited_tokens):
                    raw_word_path = run_audio_dir / f"run_{run_idx:03d}_tts_word_{t_idx:03d}_raw.wav"
                    norm_word_path = run_audio_dir / f"run_{run_idx:03d}_tts_word_{t_idx:03d}.wav"
                    voice_mode = generate_pocket_tts_audio(
                        tok.text,
                        voice_embedding_for_tts,
                        raw_word_path,
                        fallback_voice=args.pocket_tts_fallback_voice,
                        strict_voice_clone=args.strict_voice_clone,
                    )
                    ffmpeg_standardize_audio_piece(raw_word_path, norm_word_path, soft_edge_fade=True)
                    word_modes.append(voice_mode)
                    tts_voice_modes.append(voice_mode)
                    tts_inserted_words.append(tok.text)
                    word_dur = ffprobe_duration(norm_word_path)
                    tts_subpieces.append(norm_word_path)
                    local_timed.append((local_cursor, local_cursor + word_dur, tok.text))
                    local_cursor += word_dur
                    if t_idx < len(run_item.edited_tokens) - 1 and args.tts_word_gap > 0:
                        gap_path = run_audio_dir / f"run_{run_idx:03d}_tts_gap_{t_idx:03d}.wav"
                        ffmpeg_make_silence(gap_path, args.tts_word_gap)
                        tts_subpieces.append(gap_path)
                        local_cursor += args.tts_word_gap
                ffmpeg_concat_audio_files(tts_subpieces, piece_path)
                piece_dur = ffprobe_duration(piece_path)
                final_piece_files.append(piece_path)
                timed_words_out.extend([(cursor + s, cursor + e, t) for s, e, t in local_timed])
                cursor += piece_dur
                run_summaries.append(
                    {
                        "run_index": run_idx,
                        "kind": "tts",
                        "edited_word_count": len(run_item.edited_tokens),
                        "audio_file": str(piece_path),
                        "duration_seconds": round(piece_dur, 3),
                        "tts_voice_modes": sorted(dict.fromkeys(word_modes)),
                        "text": " ".join(tok.text for tok in run_item.edited_tokens),
                        "word_audio_count": len(run_item.edited_tokens),
                    }
                )

            if run_idx < len(runs) - 1 and args.hybrid_transition_pause > 0:
                silence_path = run_audio_dir / f"run_{run_idx:03d}_pause.wav"
                ffmpeg_make_silence(silence_path, args.hybrid_transition_pause)
                final_piece_files.append(silence_path)
                cursor += args.hybrid_transition_pause

        if not final_piece_files:
            raise RuntimeError("Hybrid assembly produced no audio pieces")

        ffmpeg_concat_audio_files(final_piece_files, final_audio)
        final_dur = ffprobe_duration(final_audio)

        timed_words_payload = {
            "words": [
                {"index": i, "start": s, "end": e, "text": t}
                for i, (s, e, t) in enumerate(timed_words_out)
            ]
        }
        edited_timed_words_json.write_text(json.dumps(timed_words_payload, ensure_ascii=False, indent=2), encoding="utf-8")

        write_progressive_srt_from_timed_words(
            timed_words_out,
            final_srt,
            total_duration=final_dur,
            # Cinematic quote-card style (similar to the user's screenshot).
            max_chars_per_line=30,
            max_lines_per_page=4,
        )
        try:
            make_subtitle_video(
                final_audio,
                final_srt,
                final_video,
                width=args.video_width,
                height=args.video_height,
            )
        except ImportError as e:
            if "PIL" in str(e) or "_imaging" in str(e):
                raise RuntimeError(
                    "Video subtitle rendering failed because Pillow is installed for a different Python version.\n"
                    f"Current interpreter: {sys.executable}\n"
                    f"Install Pillow for this interpreter into a version-specific local vendor dir:\n  {_pillow_install_hint()}\n"
                    "Then rerun audio_to_video2.py.\n"
                    f"Original import error: {e}"
                ) from e
            raise

        kept_chunks_payload = {
            "alignment_metrics": alignment_metrics,
            "hybrid_transition_pause": args.hybrid_transition_pause,
            "tts_word_gap": args.tts_word_gap,
            "run_count": len(runs),
            "tts_run_count": len([r for r in run_summaries if r.get("kind") == "tts"]),
            "tts_inserted_word_count": len(tts_inserted_words),
            "tts_inserted_words_preview": tts_inserted_words[:100],
            "runs": run_summaries,
        }
        kept_chunks_json.write_text(json.dumps(kept_chunks_payload, ensure_ascii=False, indent=2), encoding="utf-8")

        manifest = {
            "workflow": "audio_to_video_v2_hybrid_original_audio_plus_tts",
            "input_audio": str(input_audio),
            "enhanced_audio_for_editing": str(enhanced_audio),
            "max_input_seconds": args.max_input_seconds,
            "transcript_plain_file": str(transcript_plain_txt),
            "transcript_words_file": str(transcript_words_json),
            "edited_transcript_file": str(edited_transcript_txt),
            "kept_chunks_file": str(kept_chunks_json),
            "edited_timed_words_file": str(edited_timed_words_json),
            "outputs": {
                "audio_file": str(final_audio),
                "subtitle_file": str(final_srt),
                "video_file": str(final_video),
                "final_duration_seconds": round(final_dur, 3),
                "subtitle_timing_source": "hybrid_whisper_matched_plus_tts_approx_unmatched",
            },
            "timing_controls": {
                "pad_before": args.pad_before,
                "pad_after": args.pad_after,
                "merge_gap": args.merge_gap,
                "min_pause": args.min_pause,
                "max_pause": args.max_pause,
                "hybrid_transition_pause": args.hybrid_transition_pause,
                "tts_word_gap": args.tts_word_gap,
            },
            "alignment_metrics": alignment_metrics,
            "hybrid_voice": hybrid_voice_meta,
            "tts_voice_modes_used": sorted(dict.fromkeys(tts_voice_modes)),
            "tts_inserted_word_count": len(tts_inserted_words),
            "original_audio_only_mode": bool(args.original_audio_only),
        }
        (stem_dir / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")

        print(f"Done. Output directory: {stem_dir}")
        print(f"Condensed audio: {final_audio}")
        print(f"Subtitles: {final_srt}")
        print(f"Video: {final_video}")
        print(f"Edited transcript: {edited_transcript_txt}")
        print(f"Word timings (source): {transcript_words_json}")
        print(f"Word timings (edited/remapped): {edited_timed_words_json}")
        print(f"Hybrid alignment match ratio: {alignment_metrics.get('match_ratio')}")
        print(f"TTS inserted words: {len(tts_inserted_words)}")
    finally:
        if args.keep_temp:
            print(f"Kept temp dir: {temp_dir}", file=sys.stderr)
        else:
            shutil.rmtree(temp_dir, ignore_errors=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
