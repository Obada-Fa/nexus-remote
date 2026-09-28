"""Manual integration smoke test. Usage: python3 smoke.py WORKER MODEL WAV."""
import json
import struct
import subprocess
import sys
import tempfile
import wave


def exchange(process, message):
    payload = json.dumps(message).encode()
    process.stdin.write(struct.pack("<I", len(payload)) + payload)
    process.stdin.flush()
    header = process.stdout.read(4)
    if len(header) != 4:
        raise RuntimeError("worker exited before replying")
    size = struct.unpack("<I", header)[0]
    if size > 1024 * 1024:
        raise RuntimeError("oversized worker reply")
    return json.loads(process.stdout.read(size))


worker, model, wav = sys.argv[1:]
process = subprocess.Popen(
    [worker], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
)
try:
    loaded = exchange(process, {"id": "load", "method": "load", "path": model})
    assert loaded["result"]["status"] == "loaded", loaded
    result = exchange(
        process, {"id": "speech", "method": "transcribe", "path": wav, "language": "en"}
    )
    assert result["result"]["status"] == "completed", result
    transcript = result["result"]["text"].lower()
    assert "country" in transcript, transcript
    print(transcript)
    repeated = exchange(
        process, {"id": "speech-again", "method": "transcribe", "path": wav, "language": "en"}
    )
    assert "country" in repeated["result"]["text"].lower(), repeated
    with tempfile.NamedTemporaryFile(suffix=".wav") as silence:
        with wave.open(silence.name, "wb") as audio:
            audio.setnchannels(1)
            audio.setsampwidth(2)
            audio.setframerate(16000)
            audio.writeframes(bytes(32000))
        empty = exchange(
            process, {"id": "silence", "method": "transcribe", "path": silence.name}
        )
        assert empty["result"]["status"] == "no_speech", empty
    stopped = exchange(process, {"id": "stop", "method": "shutdown"})
    assert stopped["result"]["status"] == "stopped", stopped
finally:
    process.kill()
