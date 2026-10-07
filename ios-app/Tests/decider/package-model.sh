#!/bin/bash
# One model asset job in the existing TestFlight workflow, never another app publisher.
set -euo pipefail
DECIDER_RELEASE_DIR="$(mktemp -d)"
trap 'rm -rf "$DECIDER_RELEASE_DIR"' EXIT
DECIDER_TAG="strands-decider-model-v21"
if gh release view "$DECIDER_TAG" >/dev/null 2>&1; then
    gh release download "$DECIDER_TAG" --pattern slowclaw-decider-q6.gguf --dir "$DECIDER_RELEASE_DIR"
else
    python3 -m venv "$DECIDER_RELEASE_DIR/venv"
    source "$DECIDER_RELEASE_DIR/venv/bin/activate"
    python3 -m pip install torch==2.14.0 --index-url https://download.pytorch.org/whl/cpu
    python3 -m pip install -r ios-app/Tests/decider/requirements.txt
    git clone --depth 1 --branch b10201 https://github.com/ggml-org/llama.cpp.git "$DECIDER_RELEASE_DIR/converter"
    HF_HUB_DISABLE_XET=1 python3 ios-app/Tests/decider/export.py --converter "$DECIDER_RELEASE_DIR/converter" \
        --work "$DECIDER_RELEASE_DIR/merged" --output "$DECIDER_RELEASE_DIR/decider-f16.gguf" --precision f16
    cmake -S "$DECIDER_RELEASE_DIR/converter" -B "$DECIDER_RELEASE_DIR/build" \
        -DGGML_NATIVE=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_CURL=OFF
    cmake --build "$DECIDER_RELEASE_DIR/build" --target llama-quantize -j2
    "$DECIDER_RELEASE_DIR/build/bin/llama-quantize" "$DECIDER_RELEASE_DIR/decider-f16.gguf" \
        "$DECIDER_RELEASE_DIR/slowclaw-decider-q6.gguf" Q6_K
fi
python3 - "$DECIDER_RELEASE_DIR/slowclaw-decider-q6.gguf" <<'PY'
import hashlib,json,sys
manifest=json.load(open('ios-app/Tests/decider/model-manifest.json'));h=hashlib.sha256()
with open(sys.argv[1],'rb') as f:
    while chunk:=f.read(1048576):h.update(chunk)
assert h.hexdigest()==manifest['sha256'], 'Artifact differs from the validated model; do not publish.'
PY
if ! gh release view "$DECIDER_TAG" >/dev/null 2>&1; then
    gh release create "$DECIDER_TAG" --prerelease --target "$GITHUB_SHA" \
        --title "Strands Decider v21 · on-device model" --notes-file ios-app/Tests/decider/release-notes.md \
        "$DECIDER_RELEASE_DIR/slowclaw-decider-q6.gguf" ios-app/Tests/decider/model-manifest.json LICENSE-APACHE
fi
