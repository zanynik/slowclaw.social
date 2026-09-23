"""Download one immutable Needle archive; verify before linking. No secrets."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

REVISION = "afb64c7f069abd958aa9cadb2cee0b17ca6bf757"
HASHES = {
    "iphoneos": ("ios-arm64", "716efc8e2cdf345e46d13d3914e6fb856c16704b04d0fddbb045c95fa8f5b4e3"),
    "iphonesimulator": ("ios-sim-arm64", "7ef8de3687103c64551131001d09057403705b0762112ab73b01e3ce3fb029b9"),
}

def prepare(platform, destination):
    folder, expected = HASHES[platform]
    cache = Path(__file__).resolve().parents[2] / "tools" / "needle" / REVISION / folder
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / "libneedle.a"
    def valid(path):
        return path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == expected
    if not valid(archive):
        handle, name = tempfile.mkstemp(dir=cache, prefix="download-")
        os.close(handle)
        tmp = Path(name)
        try:
            url = f"https://huggingface.co/Cactus-Compute/needle3/resolve/{REVISION}/{folder}/libneedle.a"
            subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "3", "--max-time", "180", url, "-o", str(tmp)], check=True)
            if not valid(tmp):
                raise RuntimeError("Needle archive checksum mismatch")
            tmp.replace(archive)
        finally:
            tmp.unlink(missing_ok=True)
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(archive, destination / "libneedle.a")
    print(f"Verified pinned Needle 3.0.0 for {folder}; embedded weights; requires iOS 26.5+")

if __name__ == "__main__":
    prepare(sys.argv[1], sys.argv[2])
