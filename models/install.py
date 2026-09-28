"""Download a pinned model, verify length and SHA-256, and install atomically."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument("model", choices=("quality", "test-tiny"))
parser.add_argument("--directory", type=Path)
args = parser.parse_args()
manifest = json.loads((Path(__file__).parent / "manifest.json").read_text())
entry = manifest["models"][args.model]
directory = args.directory or Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "nexus-remote/models"
directory.mkdir(parents=True, exist_ok=True)
target = directory / entry["filename"]


def verified(path):
    if not path.is_file() or path.stat().st_size != entry["bytes"]:
        return False
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest() == entry["sha256"]


if not verified(target):
    temporary = target.with_suffix(".download")
    if temporary.exists():
        temporary.unlink()
    try:
        request = urllib.request.Request(entry["url"], headers={"User-Agent": "NexusRemote/0.1"})
        with urllib.request.urlopen(request, timeout=30) as source, temporary.open("wb") as output:
            while block := source.read(1024 * 1024):
                output.write(block)
        if not verified(temporary):
            raise RuntimeError("Model length or checksum did not match the pinned manifest")
        os.replace(temporary, target)
    finally:
        if temporary.exists():
            temporary.unlink()
print(target)
