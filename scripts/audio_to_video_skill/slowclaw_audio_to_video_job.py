#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
AUDIO_TO_VIDEO2 = SCRIPT_DIR / "audio_to_video2.py"
DEFAULT_PIPELINE_DIR = "journals/pipeline/audio_to_video"
DEFAULT_PUBLISH_DIR = "journals/processed"


def pb_url() -> str:
    value = os.environ.get("ZEROCLAW_POCKETBASE_URL") or os.environ.get("POCKETBASE_URL")
    if value and value.strip():
        return value.rstrip("/")
    # Gateway sidecar default for local single-machine deployments.
    return "http://127.0.0.1:8090"


def pb_token() -> str | None:
    value = os.environ.get("ZEROCLAW_POCKETBASE_TOKEN") or os.environ.get("POCKETBASE_TOKEN")
    return value.strip() if value and value.strip() else None


def pb_request(method: str, path: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
    url = f"{pb_url()}{path}"
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(url, method=method, data=data)
    req.add_header("Content-Type", "application/json")
    token = pb_token()
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = resp.read().decode("utf-8", "replace")
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        raise RuntimeError(f"PocketBase {method} {path} failed ({e.code}): {body}") from e


def pb_create(collection: str, payload: dict[str, Any]) -> dict[str, Any]:
    return pb_request("POST", f"/api/collections/{collection}/records", payload)


def pb_patch(collection: str, record_id: str, payload: dict[str, Any]) -> dict[str, Any]:
    return pb_request("PATCH", f"/api/collections/{collection}/records/{record_id}", payload)


def newest_manifest(out_dir: Path) -> Path:
    manifests = sorted(out_dir.glob("*_v2/manifest.json"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not manifests:
        raise RuntimeError(f"No manifest.json found under {out_dir}")
    return manifests[0]


def rel_to_workspace(path_str: str, workspace_dir: Path) -> str:
    p = Path(path_str)
    if not p.is_absolute():
        return str(p)
    try:
        return str(p.relative_to(workspace_dir))
    except ValueError:
        return str(p)


def artifact_rows_from_manifest(
    manifest: dict[str, Any],
    manifest_path: Path,
    workspace_dir: Path,
    asset_id: str | None,
    entry_id: str | None,
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    created_at = __import__("datetime").datetime.utcnow().isoformat() + "Z"
    outputs = manifest.get("outputs") or {}

    def push(artifact_type: str, path_val: str | None, title: str | None = None, mime: str | None = None, preview: str | None = None, metadata: dict[str, Any] | None = None) -> None:
        if not path_val:
            return
        rows.append(
            {
                "parentAssetId": asset_id or "",
                "parentEntryId": entry_id or "",
                "artifactType": artifact_type,
                "title": title or artifact_type,
                "status": "ready",
                "mimeType": mime or "",
                "workspacePath": rel_to_workspace(path_val, workspace_dir),
                "previewText": preview or "",
                "metadataJson": json.dumps(metadata or {}, ensure_ascii=False),
                "createdAtClient": created_at,
            }
        )

    if isinstance(outputs.get("clips"), list):
        for clip in outputs["clips"]:
            push(
                "video_clip",
                clip.get("video_file"),
                title=clip.get("title") or f"Clip {clip.get('clip_num', '')}".strip(),
                mime="video/mp4",
                preview=clip.get("rationale"),
                metadata=clip,
            )
            push("audio_clip", clip.get("audio_file"), title=(clip.get("title") or "Clip") + " audio", mime="audio/wav", metadata=clip)
            push("subtitle_clip", clip.get("subtitle_file"), title=(clip.get("title") or "Clip") + " subtitles", mime="text/plain", metadata=clip)
    else:
        push("video", outputs.get("video_file"), title="Generated video", mime="video/mp4", metadata=outputs)
        push("audio", outputs.get("audio_file"), title="Generated audio", mime="audio/wav", metadata=outputs)
        push("subtitle", outputs.get("subtitle_file"), title="Generated subtitles", mime="text/plain", metadata=outputs)

    push("manifest", str(manifest_path), title="Processing manifest", mime="application/json", metadata={"workflow": manifest.get("workflow")})
    rows = [r for r in rows if r.get("workspacePath")]
    return rows


def safe_name(raw: str, fallback: str) -> str:
    normalized = re.sub(r"[^A-Za-z0-9._-]+", "_", (raw or "").strip())
    normalized = normalized.strip("._")
    return normalized or fallback


def write_sidecar_caption(path_no_caption: Path, title: str, rationale: str | None) -> Path:
    caption_path = Path(f"{path_no_caption}.caption.txt")
    lines = [title.strip() or "Untitled clip"]
    if rationale and rationale.strip():
        lines += ["", rationale.strip()]
    caption_path.write_text("\n".join(lines).strip() + "\n", encoding="utf-8")
    return caption_path


def copy_if_exists(src: str | None, dest_dir: Path, dest_name: str) -> Path | None:
    if not src:
        return None
    src_path = Path(src)
    if not src_path.exists() or not src_path.is_file():
        return None
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest_path = dest_dir / dest_name
    shutil.copy2(src_path, dest_path)
    return dest_path


def publish_outputs_from_manifest(
    manifest: dict[str, Any],
    manifest_path: Path,
    workspace_dir: Path,
    publish_root: Path,
) -> list[dict[str, str]]:
    run_dir = publish_root / safe_name(manifest_path.parent.name, "run")
    outputs = manifest.get("outputs") or {}
    published: list[dict[str, str]] = []

    clips = outputs.get("clips")
    if isinstance(clips, list) and clips:
        for index, clip in enumerate(clips, start=1):
            if not isinstance(clip, dict):
                continue
            title = str(clip.get("title") or f"Clip {index}").strip()
            base = f"{index:02d}_{safe_name(title, f'clip_{index:02d}')}"
            video_src = clip.get("video_file")
            audio_src = clip.get("audio_file")
            rationale = str(clip.get("rationale") or "").strip()

            video_dest = copy_if_exists(video_src, run_dir, f"{base}.mp4")
            if video_dest:
                caption = write_sidecar_caption(video_dest, title, rationale)
                published.append({"type": "video", "path": rel_to_workspace(str(video_dest), workspace_dir), "title": title})
                published.append({"type": "caption", "path": rel_to_workspace(str(caption), workspace_dir), "title": f"{title} caption"})

            audio_dest = copy_if_exists(audio_src, run_dir, f"{base}.wav")
            if audio_dest:
                audio_caption = write_sidecar_caption(audio_dest, title, rationale)
                published.append({"type": "audio", "path": rel_to_workspace(str(audio_dest), workspace_dir), "title": f"{title} audio"})
                published.append({"type": "caption", "path": rel_to_workspace(str(audio_caption), workspace_dir), "title": f"{title} audio caption"})
        return published

    title = str(manifest.get("workflow") or "Generated output")
    rationale = "Generated from uploaded journal media."
    video_dest = copy_if_exists(outputs.get("video_file"), run_dir, "01_generated.mp4")
    if video_dest:
        caption = write_sidecar_caption(video_dest, title, rationale)
        published.append({"type": "video", "path": rel_to_workspace(str(video_dest), workspace_dir), "title": "Generated video"})
        published.append({"type": "caption", "path": rel_to_workspace(str(caption), workspace_dir), "title": "Generated video caption"})
    audio_dest = copy_if_exists(outputs.get("audio_file"), run_dir, "01_generated.wav")
    if audio_dest:
        audio_caption = write_sidecar_caption(audio_dest, title, rationale)
        published.append({"type": "audio", "path": rel_to_workspace(str(audio_dest), workspace_dir), "title": "Generated audio"})
        published.append({"type": "caption", "path": rel_to_workspace(str(audio_caption), workspace_dir), "title": "Generated audio caption"})

    return published


def main() -> int:
    parser = argparse.ArgumentParser(description="Run audio_to_video2.py and publish artifact metadata to PocketBase")
    parser.add_argument("input_path", help="Input media path relative to workspace (or absolute)")
    parser.add_argument("--asset-id", default=None, help="PocketBase media_assets record id to patch after processing")
    parser.add_argument("--entry-id", default=None, help="Optional PocketBase journal_entries record id to link artifacts")
    parser.add_argument(
        "--out-dir",
        default=DEFAULT_PIPELINE_DIR,
        help="Pipeline output directory for full run artifacts (relative to workspace)",
    )
    parser.add_argument(
        "--publish-dir",
        default=DEFAULT_PUBLISH_DIR,
        help="Feed-visible publish directory for curated final media (relative to workspace)",
    )
    parser.add_argument("--python", dest="python_bin", default=sys.executable, help="Python interpreter to run audio_to_video2.py")
    parser.add_argument("--gemini-model", default=None, help="Override audio_to_video2.py --gemini-model")
    args, extra = parser.parse_known_args()

    if not AUDIO_TO_VIDEO2.exists():
        raise SystemExit(f"Missing processor script: {AUDIO_TO_VIDEO2}")

    workspace_dir = Path.cwd().resolve()
    input_path = Path(args.input_path)
    if not input_path.is_absolute():
        input_path = (workspace_dir / input_path).resolve()
    if not input_path.exists():
        raise SystemExit(f"Input file not found: {input_path}")
    if not str(input_path).startswith(str(workspace_dir)):
        raise SystemExit("Input path must be inside the current workspace")

    out_dir = Path(args.out_dir)
    if not out_dir.is_absolute():
        out_dir = (workspace_dir / out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    publish_dir = Path(args.publish_dir)
    if not publish_dir.is_absolute():
        publish_dir = (workspace_dir / publish_dir).resolve()
    publish_dir.mkdir(parents=True, exist_ok=True)

    cmd = [args.python_bin, str(AUDIO_TO_VIDEO2), str(input_path), "--out-dir", str(out_dir)]
    if args.gemini_model:
        cmd += ["--gemini-model", args.gemini_model]
    passthrough = [x for x in extra if x != "--"]
    cmd += passthrough

    if args.asset_id:
        try:
            pb_patch("media_assets", args.asset_id, {"status": "processing"})
        except Exception as e:  # noqa: BLE001
            print(f"[warn] failed to mark media_assets processing: {e}", file=sys.stderr)

    cp = subprocess.run(cmd, cwd=str(SCRIPT_DIR), capture_output=True, text=True)
    sys.stdout.write(cp.stdout)
    sys.stderr.write(cp.stderr)

    if cp.returncode != 0:
        if args.asset_id:
            try:
                pb_patch("media_assets", args.asset_id, {"status": "error", "previewText": (cp.stderr or cp.stdout)[-500:]})
            except Exception as e:  # noqa: BLE001
                print(f"[warn] failed to mark media_assets error: {e}", file=sys.stderr)
        return cp.returncode

    manifest_path = newest_manifest(out_dir)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    published_items = publish_outputs_from_manifest(manifest, manifest_path, workspace_dir, publish_dir)
    rows = artifact_rows_from_manifest(manifest, manifest_path, workspace_dir, args.asset_id, args.entry_id)
    now = __import__("datetime").datetime.utcnow().isoformat() + "Z"
    for item in published_items:
        rows.append(
            {
                "parentAssetId": args.asset_id or "",
                "parentEntryId": args.entry_id or "",
                "artifactType": f"published_{item['type']}",
                "title": item.get("title") or item["type"],
                "status": "ready",
                "mimeType": "",
                "workspacePath": item["path"],
                "previewText": "",
                "metadataJson": json.dumps({"publishDir": rel_to_workspace(str(publish_dir), workspace_dir)}, ensure_ascii=False),
                "createdAtClient": now,
            }
        )
    created_artifacts = []
    for row in rows:
        try:
            created_artifacts.append(pb_create("artifacts", row))
        except Exception as e:  # noqa: BLE001
            print(f"[warn] failed to create artifact row for {row.get('workspacePath')}: {e}", file=sys.stderr)

    if args.asset_id:
        patch_payload = {
            "status": "processed",
            "previewText": (
                f"Processed via audio_to_video2 ({manifest.get('workflow', 'unknown workflow')}); "
                f"published {len([p for p in published_items if p['type'] in ('video', 'audio')])} media files"
            ),
        }
        patch_payload["workspacePath"] = rel_to_workspace(str(input_path), workspace_dir)
        try:
            pb_patch("media_assets", args.asset_id, patch_payload)
        except Exception as e:  # noqa: BLE001
            print(f"[warn] failed to patch media_assets processed status: {e}", file=sys.stderr)

    print(json.dumps({
        "ok": True,
        "manifest": rel_to_workspace(str(manifest_path), workspace_dir),
        "published": published_items,
        "artifacts_created": len(created_artifacts),
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
