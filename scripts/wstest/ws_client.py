#!/usr/bin/env python3
"""Command-line twin of index.html: opens the test WebSocket over HTTP/1.1 and
reports whether it stays up while the server streams a 450 KB burst and a steady flow.

Usage: python3 ws_client.py <host> [path=/wstest/ws] [seconds=60]
Prints the TLS issuer too, so a FortiGate re-signing the connection is visible.
"""
import base64, os, socket, ssl, struct, sys, time

host = sys.argv[1]
path = sys.argv[2] if len(sys.argv) > 2 else "/wstest/ws"
duration = float(sys.argv[3]) if len(sys.argv) > 3 else 60.0

ctx = ssl.create_default_context()
ctx.set_alpn_protocols(["http/1.1"])  # WebSocket over HTTP/1.1 only
sock = ctx.wrap_socket(socket.create_connection((host, 443), timeout=10), server_hostname=host)
key = base64.b64encode(os.urandom(16)).decode()
sock.sendall((f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
              f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())

buf = b""


def fill(deadline):
    """Reads more bytes. False on timeout; raises EOFError when the peer closed."""
    global buf
    sock.settimeout(max(0.05, min(0.2, deadline - time.time())))
    try:
        data = sock.recv(65536)
    except socket.timeout:
        return False
    if not data:
        raise EOFError
    buf += data
    return True


def masked_frame(opcode, payload):
    mask = os.urandom(4)
    assert len(payload) < 126
    return bytes([0x80 | opcode, 0x80 | len(payload)]) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))


start = time.time()
deadline = start + duration
while b"\r\n\r\n" not in buf:
    fill(start + 10)
head, buf = buf.split(b"\r\n\r\n", 1)
issuer = dict(x[0] for x in sock.getpeercert()["issuer"]).get("commonName")
print(head.split(b"\r\n")[0].decode(), "| TLS issuer:", issuer)

received = messages = biggest = 0
first_burst_ms = None
rtts = []
close_code = None
last_ping = 0.0
try:
    while time.time() < deadline:
        if time.time() - last_ping >= 1:
            sock.settimeout(5)
            sock.sendall(masked_frame(1, f"ping:{time.time() * 1000}".encode()))
            last_ping = time.time()
        if len(buf) < 2 and not fill(deadline):
            continue
        if len(buf) < 2:
            continue
        opcode, length, offset = buf[0] & 15, buf[1] & 127, 2
        if length == 126:
            while len(buf) < 4 and time.time() < deadline:
                fill(deadline)
            if len(buf) < 4:
                break
            length, offset = struct.unpack("!H", buf[2:4])[0], 4
        elif length == 127:
            while len(buf) < 10 and time.time() < deadline:
                fill(deadline)
            if len(buf) < 10:
                break
            length, offset = struct.unpack("!Q", buf[2:10])[0], 10
        while len(buf) < offset + length and time.time() < deadline:
            fill(deadline)
        if len(buf) < offset + length:
            break
        payload, buf = buf[offset:offset + length], buf[offset + length:]
        if opcode == 2:
            messages += 1
            received += length
            biggest = max(biggest, length)
            if first_burst_ms is None and length >= 400_000:
                first_burst_ms = (time.time() - start) * 1000
        elif opcode == 1 and payload.startswith(b"pong:"):
            rtts.append(time.time() * 1000 - float(payload[5:]))
        elif opcode == 8:
            close_code = struct.unpack("!H", payload[:2])[0] if payload else 0
            break
    alive = time.time() - start
    verdict = "ALIVE" if close_code is None and alive >= duration - 0.5 else "CUT"
    print(f"result: {verdict} after {alive:.1f}s, close code={close_code}")
except (EOFError, ConnectionError, ssl.SSLError, OSError) as error:
    print(f"result: CUT after {time.time() - start:.1f}s ({type(error).__name__}), received {received} bytes")

rtts.sort()
median = round(rtts[len(rtts) // 2]) if rtts else "-"
p95 = round(rtts[int(len(rtts) * 0.95)]) if rtts else "-"
print(f"received {received // 1024} KB in {messages} messages, biggest {biggest} bytes, "
      f"first burst {round(first_burst_ms) if first_burst_ms else 'never'} ms, "
      f"ping median {median} ms, p95 {p95} ms ({len(rtts)} pongs)")
