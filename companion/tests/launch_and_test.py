"""Launch a local packaged companion and test pairing before its invitation expires."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

bundle, model, wav = sys.argv[1:]
env = os.environ.copy()
env["XDG_DATA_HOME"] = tempfile.mkdtemp(prefix="nexus-remote-e2e-")
env["NEXUS_REMOTE_MODEL"] = str(Path(model).resolve())
process = subprocess.Popen(
    [str(Path(bundle).resolve() / "run.sh")],
    env=env,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)
try:
    lines = [process.stdout.readline().strip() for _ in range(4)]
    fingerprint = next(line.split(": ", 1)[1] for line in lines if line.startswith("TLS SHA-256"))
    code = next(line.rsplit(": ", 1)[1] for line in lines if line.startswith("Pairing code"))
    subprocess.run(
        [sys.executable, str(Path(__file__).with_name("end_to_end.py")), code, fingerprint, wav],
        check=True,
    )
finally:
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
