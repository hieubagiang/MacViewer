#!/usr/bin/env python3
"""Throw-away WebSocket traffic generator for the MacViewer firewall test.

Mimics an UltraViewer-like stream over one WebSocket: a large first message,
then a steady small stream with occasional large bursts. Random bytes, so it
cannot be compressed (like TLS-in-TLS payload). Echoes "ping:<x>" as "pong:<x>".
Listens on loopback only; nginx terminates TLS in front of it.
"""
import asyncio, base64, hashlib, os, struct, time

HOST, PORT = "127.0.0.1", 8792
FIRST_BURST = 450_000
TICK_SECONDS, TICK_BYTES = 0.1, 2_048
BURST_EVERY, BURST_BYTES = 5.0, 100_000
MAX_SECONDS, MAX_CONNECTIONS = 600, 10
GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
active = 0


def frame(opcode: int, payload: bytes) -> bytes:
    n = len(payload)
    if n < 126:
        head = struct.pack("!BB", 0x80 | opcode, n)
    elif n < 65536:
        head = struct.pack("!BBH", 0x80 | opcode, 126, n)
    else:
        head = struct.pack("!BBQ", 0x80 | opcode, 127, n)
    return head + payload


async def read_frame(reader):
    b1, b2 = await reader.readexactly(2)
    opcode, masked, n = b1 & 0x0F, b2 & 0x80, b2 & 0x7F
    if n == 126:
        n = struct.unpack("!H", await reader.readexactly(2))[0]
    elif n == 127:
        n = struct.unpack("!Q", await reader.readexactly(8))[0]
    if n > 1_000_000:
        raise ValueError("frame too large")
    key = await reader.readexactly(4) if masked else b""
    data = await reader.readexactly(n)
    if masked:
        data = bytes(c ^ key[i % 4] for i, c in enumerate(data))
    return opcode, data


async def handle(reader, writer):
    global active
    lock = asyncio.Lock()

    async def send(opcode, payload):
        async with lock:
            writer.write(frame(opcode, payload))
            await writer.drain()

    try:
        raw = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 10)
        headers = {}
        for line in raw.decode("latin1").split("\r\n")[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        key = headers.get("sec-websocket-key")
        if headers.get("upgrade", "").lower() != "websocket" or not key or active >= MAX_CONNECTIONS:
            writer.write(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
            await writer.drain()
            return
        accept = base64.b64encode(hashlib.sha1(key.encode() + GUID).digest())
        writer.write(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                     b"Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
        await writer.drain()
        active += 1
        started = time.monotonic()

        async def stream():
            await send(2, os.urandom(FIRST_BURST))
            next_burst = time.monotonic() + BURST_EVERY
            while time.monotonic() - started < MAX_SECONDS:
                await asyncio.sleep(TICK_SECONDS)
                await send(2, os.urandom(TICK_BYTES))
                if time.monotonic() >= next_burst:
                    next_burst += BURST_EVERY
                    await send(2, os.urandom(BURST_BYTES))
            await send(8, struct.pack("!H", 1000))

        task = asyncio.create_task(stream())
        try:
            while True:
                opcode, data = await read_frame(reader)
                if opcode == 8:
                    break
                if opcode == 9:
                    await send(10, data)
                elif opcode == 1 and data.startswith(b"ping:"):
                    await send(1, b"pong:" + data[5:])
        finally:
            task.cancel()
            active -= 1
    except (asyncio.IncompleteReadError, ConnectionError, asyncio.TimeoutError, ValueError):
        pass
    finally:
        writer.close()


async def main():
    server = await asyncio.start_server(handle, HOST, PORT)
    async with server:
        await server.serve_forever()


asyncio.run(main())
