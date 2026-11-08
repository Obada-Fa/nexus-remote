"""Admin CLI + enforced revocation integration test against the real companion binary.

Usage: python3 admin_integration.py PATH_TO_nexus-remote-companion
Runs with DISPLAY unset (no X11 input), a scratch data dir and a free port.
"""
import base64, hashlib, http.client, json, os, shutil, socket, ssl, subprocess, sys, tempfile, time

binary = sys.argv[1]
data = tempfile.mkdtemp(prefix="nexus-remote-admin-")
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
env = {k: v for k, v in os.environ.items() if k not in ("DISPLAY", "WAYLAND_DISPLAY")}
env.update(NEXUS_REMOTE_DATA_DIR=data, NEXUS_REMOTE_PORT=str(port))


def admin(*args, ok=True):
    r = subprocess.run([binary, "admin", *args, "--json"], env=env, capture_output=True, text=True, timeout=5)
    lines = r.stdout.strip().splitlines()
    assert len(lines) == 1, r
    out = json.loads(lines[0])
    assert out["contract"] == 1
    assert (r.returncode == 0) == ok, (r, out)
    return out


ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE


def conn(fp):
    c = http.client.HTTPSConnection("127.0.0.1", port, context=ctx, timeout=10)
    c.connect()
    assert hashlib.sha256(c.sock.getpeercert(binary_form=True)).hexdigest().upper() == fp
    return c


def request(fp, method, path, body=None, headers=None):
    c = conn(fp)
    c.request(method, path, json.dumps(body) if body is not None else None, {"Content-Type": "application/json", **(headers or {})})
    r = c.getresponse()
    raw = r.read()
    return r.status, (json.loads(raw) if raw[:1] == b"{" else raw)


server = None
try:
    # status works with no server, creates identity
    st = admin("status")
    assert st["utility"] == "remote" and st["devices"] == 0 and len(st["fingerprint"]) == 64 and st["fingerprint"] == st["fingerprint"].upper(), st
    assert admin("status", "--bogus", ok=False)["error"]["code"] == "BAD_ARGS"
    assert admin("invite", "--ttl", "5", "--label", "x", ok=False)["error"]["code"] == "BAD_ARGS"
    assert admin("revoke", "nope", ok=False)["error"]["code"] == "NOT_FOUND"
    fp = st["fingerprint"]

    server = subprocess.Popen([binary, "--service"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    for _ in range(50):
        try:
            if request(fp, "GET", "/health")[0] == 200:
                break
        except OSError:
            time.sleep(0.2)
    else:
        raise SystemExit("server did not start")
    # --service prints no pairing code
    server.stdout.flush()

    inv = admin("invite", "--ttl", "120", "--label", "Test phone")
    assert len(inv["secret"]) == 8 and inv["fingerprint"] == fp and inv["hostId"] == st["hostId"]
    assert abs(inv["expiresAt"] - (time.time() + 120) * 1000) < 5000

    # wrong codes count attempts; 4 wrong is still fine
    for _ in range(4):
        assert request(fp, "POST", "/pair", {"code": "00000000" if inv["secret"] != "00000000" else "11111111", "device_name": "p"})[0] == 403
    status, paired = request(fp, "POST", "/pair", {"code": inv["secret"], "device_name": "Pixel Test"})
    assert status == 200 and paired["host_id"] == st["hostId"], (status, paired)
    token = paired["token"]
    # single use
    assert request(fp, "POST", "/pair", {"code": inv["secret"], "device_name": "again"})[0] == 403

    devs = admin("devices")["devices"]
    assert len(devs) == 1 and devs[0]["name"] == "Pixel Test" and devs[0]["inviteId"] == inv["inviteId"], devs
    assert devs[0]["createdAt"] > 0
    assert admin("status")["devices"] == 1
    dev_id = devs[0]["id"]

    # 5 wrong attempts kill the invite even for the right code
    inv2 = admin("invite", "--ttl", "120", "--label", "x")
    assert inv2["inviteId"] != inv["inviteId"]
    for _ in range(5):
        request(fp, "POST", "/pair", {"code": "x", "device_name": "p"})
    assert request(fp, "POST", "/pair", {"code": inv2["secret"], "device_name": "late"})[0] == 403

    auth = {"Authorization": f"Bearer {token}"}
    assert request(fp, "POST", "/transcribe", {}, auth)[0] != 401  # authenticated (fails later on checksum)

    # websocket
    sock = ctx.wrap_socket(socket.create_connection(("127.0.0.1", port)), server_hostname="127.0.0.1")
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall((f"GET /ws HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                  f"Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\nAuthorization: Bearer {token}\r\n\r\n").encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        buf += sock.recv(4096)
    assert b"101" in buf.split(b"\r\n")[0], buf

    assert admin("revoke", dev_id)["revoked"] is True
    t0 = time.time()
    sock.settimeout(6)
    closed = False
    try:
        while True:
            d = sock.recv(4096)
            if not d or (d[0] & 0x0F) == 8:
                closed = True
                break
    except (ConnectionError, ssl.SSLError):
        closed = True
    elapsed = time.time() - t0
    assert closed and elapsed < 5, (closed, elapsed)
    assert request(fp, "POST", "/transcribe", {}, auth)[0] == 401
    c = conn(fp)
    c.request("GET", "/ws", headers={"Authorization": f"Bearer {token}", "Connection": "Upgrade", "Upgrade": "websocket", "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": key})
    assert c.getresponse().status == 401
    assert admin("devices")["devices"] == [] and admin("status")["devices"] == 0
    assert admin("revoke", dev_id, ok=False)["error"]["code"] == "NOT_FOUND"
    print(f"OK (ws closed {elapsed:.1f}s after revoke)")
finally:
    if server:
        server.terminate()
        try:
            server.wait(5)
        except subprocess.TimeoutExpired:
            server.kill()
    shutil.rmtree(data, ignore_errors=True)
