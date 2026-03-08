Place bundled Whisper ggml model files in this directory before building iOS archives.

Recommended starter model for TestFlight:
- `ggml-base.en.bin`

The mobile runtime resolves transcription models from:
1. `workspace/models/`
2. bundled app resources under `resources/models/`

Set `transcription.model` to either a filename in one of those directories or an absolute path during local development.
