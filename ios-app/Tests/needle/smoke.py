"""Real pinned Needle 3.0.0 embedding ABI smoke test on Linux x86_64.

Usage: python smoke.py /path/to/cactus_needle-3.0.0-py3-none-manylinux2014_x86_64.whl
The wheel is from Hugging Face Cactus-Compute/needle3 at revision
afb64c7f069abd958aa9cadb2cee0b17ca6bf757. No journals or API keys are used.
"""
import ctypes
import hashlib
import json
import math
from pathlib import Path
import platform
import sys
import tempfile
import time
import zipfile

if platform.system() != "Linux" or platform.machine() != "x86_64":
    raise SystemExit("This smoke fixture uses the pinned Linux x86_64 wheel")
wheel = Path(sys.argv[1])
assert hashlib.sha256(wheel.read_bytes()).hexdigest() == "c9533d5a2664a506f6ceaff5ae9c4b5601005cfd67a4600c548d7fdb3891bdd0", "Runtime hash mismatch"
with tempfile.TemporaryDirectory() as folder:
    with zipfile.ZipFile(wheel) as archive:
        path = archive.extract("needle/libneedle3.so", folder)
    lib = ctypes.CDLL(path)
    lib.needle_init.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]
    lib.needle_init.restype = ctypes.c_int
    # This pinned ABI requires a null audio pointer before the output buffer.
    lib.needle_embed.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_float), ctypes.c_int]
    lib.needle_embed.restype = ctypes.c_int
    assert lib.needle_init(b"", b"[]", None) >= 0
    assert lib.needle_embed(b"", None, None, 0) == 3072
    def embed(text):
        out = (ctypes.c_float * 3072)()
        assert lib.needle_embed(text.encode(), None, out, 3072) == 3072
        values = list(out)
        norm = math.sqrt(sum(x*x for x in values))
        assert norm > 0 and math.isfinite(norm)
        return [x / norm for x in values]
    start = time.monotonic()
    a = embed("Local AI on phones and AI agents")
    b = embed("Local AI on phones and AI agents")
    c = embed("Fresh vegetarian cooking recipes")
    assert abs(sum(x*y for x,y in zip(a,b)) - 1) < 1e-6
    assert sum(x*y for x,y in zip(a,c)) < 0.999
    # Longer and non-ASCII input matches the app's bounded text route.
    embed("A local journal about technology. " * 25)
    embed("Meditation und Gemüse. ध्यान और भोजन।")
    print(json.dumps({"passed": True, "dimension": 3072, "embeddings": 5,
                      "seconds": time.monotonic()-start, "host": "Linux x86_64",
                      "iphone_latency_validated": False}))
