"""Manual HTTPS speech integration test.

Usage: python3 end_to_end.py PAIR_CODE TLS_SHA256 WAV
Runs only against a local development companion on port 45679.
"""
import hashlib
import http.client
import json
import pathlib
import base64
import os
import socket
import sys
import ssl
import uuid

code, fingerprint, wav_path = sys.argv[1:]
context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
context.check_hostname = False
context.verify_mode = ssl.CERT_NONE
connection = http.client.HTTPSConnection("127.0.0.1", 45679, context=context, timeout=360)
connection.connect()
actual = hashlib.sha256(connection.sock.getpeercert(binary_form=True)).hexdigest()
assert actual.casefold() == fingerprint.casefold(), "TLS certificate fingerprint mismatch"

connection.request("POST", "/pair", json.dumps({"code": code, "device_name": "Integration test"}),
                   {"Content-Type": "application/json"})
response = connection.getresponse()
pairing = json.loads(response.read())
assert response.status == 200, pairing
token = pairing["token"]


def receive_exact(stream, length):
    data = b""
    while len(data) < length:
        chunk = stream.recv(length - len(data))
        if not chunk:
            raise RuntimeError("WebSocket closed early")
        data += chunk
    return data


def rpc(stream, method, params):
    payload = json.dumps({"version": 1, "id": str(uuid.uuid4()), "method": method, "params": params}).encode()
    mask = os.urandom(4)
    size = len(payload)
    if size < 126:
        header = bytes([0x81, 0x80 | size])
    else:
        header = bytes([0x81, 0x80 | 126]) + size.to_bytes(2, "big")
    stream.sendall(header + mask + bytes(value ^ mask[index % 4] for index, value in enumerate(payload)))
    header = receive_exact(stream, 2)
    size = header[1] & 0x7f
    if size == 126:
        size = int.from_bytes(receive_exact(stream, 2), "big")
    elif size == 127:
        size = int.from_bytes(receive_exact(stream, 8), "big")
    answer = json.loads(receive_exact(stream, size))
    assert "error" not in answer, answer
    return answer["result"]


with context.wrap_socket(socket.create_connection(("127.0.0.1", 45679)), server_hostname="127.0.0.1") as stream:
    actual = hashlib.sha256(stream.getpeercert(binary_form=True)).hexdigest()
    assert actual.casefold() == fingerprint.casefold(), "WebSocket TLS fingerprint mismatch"
    websocket_key = base64.b64encode(os.urandom(16)).decode()
    stream.sendall((
        "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:45679\r\nUpgrade: websocket\r\n"
        "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
        f"Sec-WebSocket-Key: {websocket_key}\r\nAuthorization: Bearer {token}\r\n\r\n"
    ).encode())
    headers = b""
    while b"\r\n\r\n" not in headers:
        headers += stream.recv(4096)
    assert b"101 Switching Protocols" in headers, headers
    info = rpc(stream, "host.info", {})
    assert info["capabilities"]["speech"] == "supported", info
    assert rpc(stream, "controller.acquire", {})["acquired"] is True
    rpc(stream, "controller.heartbeat", {})
    rpc(stream, "controller.release", {})

audio = pathlib.Path(wav_path).read_bytes()
job = str(uuid.uuid4())
headers = {
    "Authorization": f"Bearer {token}",
    "X-Job-ID": job,
    "X-Language": "en",
    "X-Content-SHA256": hashlib.sha256(audio).hexdigest(),
    "Content-Type": "audio/wav",
}
connection.request("POST", "/transcribe", audio, headers)
response = connection.getresponse()
result = json.loads(response.read())
assert response.status == 200, result
assert result["status"] == "completed", result
assert "country" in result["text"].lower(), result

connection.request("POST", "/transcribe", audio, headers)
response = connection.getresponse()
repeated = json.loads(response.read())
assert response.status == 200 and repeated == result, repeated
print(result["text"].strip())
