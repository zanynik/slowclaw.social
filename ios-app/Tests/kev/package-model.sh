#!/bin/bash
# Called only by the existing TestFlight workflow on the Kev experiment branch.
set -euo pipefail
KEV_RELEASE_DIR="$(mktemp -d)"
trap 'rm -rf "$KEV_RELEASE_DIR"' EXIT
KEV_TAG="kev-lite-model-v1"
if gh release view "$KEV_TAG" >/dev/null 2>&1; then
    gh release download "$KEV_TAG" --pattern slowclaw-kev-q8.gguf --dir "$KEV_RELEASE_DIR"
else
    python3 -m venv "$KEV_RELEASE_DIR/venv"
    source "$KEV_RELEASE_DIR/venv/bin/activate"
    python3 -m pip install torch==2.14.0 --index-url https://download.pytorch.org/whl/cpu
    python3 -m pip install -r ios-app/Tests/kev/requirements.txt
    git clone --depth 1 --branch b10201 https://github.com/ggml-org/llama.cpp.git /tmp/slowclaw-llama-convert
    HF_HUB_DISABLE_XET=1 python3 ios-app/Tests/kev/export.py --converter /tmp/slowclaw-llama-convert \
        --work /tmp/slowclaw-kev-merged --output "$KEV_RELEASE_DIR/slowclaw-kev-q8.gguf"
fi
python3 - "$KEV_RELEASE_DIR/slowclaw-kev-q8.gguf" <<'PY'
import hashlib,json,sys
manifest=json.load(open('ios-app/Tests/kev/model-manifest.json'))
h=hashlib.sha256()
with open(sys.argv[1],'rb') as f:
    while chunk:=f.read(1048576):h.update(chunk)
assert h.hexdigest()==manifest['sha256'], 'Generated/downloaded artifact differs from the tested model. Do not publish.'
PY
if ! gh release view "$KEV_TAG" >/dev/null 2>&1; then
    gh release create "$KEV_TAG" --prerelease --target "$GITHUB_SHA" \
        --title "Kev-0.5B · SlowClaw Lite experiment" --notes-file ios-app/Tests/kev/release-notes.md \
        "$KEV_RELEASE_DIR/slowclaw-kev-q8.gguf" ios-app/Tests/kev/model-manifest.json LICENSE-APACHE
fi
