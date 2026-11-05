# Prototype tools

The book and Discover were tuned here, on the owner's real journals, with the **same MiniLM model the
iPhone runs** (`minilm.py` mirrors `ios-app/SlowClawApp/MiniLM.swift`; `parity.py` checks it against the
official ONNX export, `export.py` writes the app's weights and the golden vectors its unit test uses).

Journal data never goes into this repository. Export journals to a private file outside it (for
example with a read-only `select id, created_at, title, body from journals` saved as JSON) and pass the
path in.

```bash
python3 -m venv /tmp/proto && /tmp/proto/bin/pip install numpy onnxruntime tokenizers
```

```bash
# model files: config.json, vocab.txt, tokenizer.json, model.safetensors, model.onnx from
# huggingface.co/sentence-transformers/all-MiniLM-L6-v2 into ./minilm
python3 tools/prototype/book_v3.py /private/journals.json ./minilm --cache=/tmp/emb.pkl      # writes book_v3.json
python3 tools/prototype/queries_v3.py book_v3.json /private/journals.json /tmp/emb.pkl      # writes queries_v3.json
python3 tools/prototype/pool_v3.py book_v3.json queries_v3.json ./minilm --source=news --min=0.48
python3 tools/prototype/videos_v3.py book_v3.json ./minilm 0.45
```

Change a rule here first, read the output, then port it. See `docs/book.md` and `docs/discover.md`.
