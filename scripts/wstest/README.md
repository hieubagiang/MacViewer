# WebSocket stream test

Checks whether a long WebSocket carrying UltraViewer-like traffic survives a network that
inspects TLS (the FortiGate case in `docs/relay-drop-investigation.md`). Question it answers:
if a web app streams a remote screen over WebSocket, does the office firewall cut it?

The server sends random bytes (cannot be compressed, like TLS-in-TLS): one 450 KB message at
connect (like the first full frame that gets cut), then 2 KB every 100 ms and a 100 KB burst
every 5 s. It answers `ping:<x>` with `pong:<x>` so the client can measure round trip.

## Files

- `server.py`: asyncio WebSocket server, standard library only, listens on `127.0.0.1:8792`.
- `index.html`: test page, runs 60 s and prints ALIVE or CUT plus a copyable summary.
- `ws_client.py`: same test from a terminal, also prints the TLS issuer.

## Run it

On a server with nginx in front (TLS terminated by nginx):

```
install -D server.py /opt/wstest/server.py
install -D index.html /var/www/wstest/index.html
systemd-run --unit=wstest --property=RuntimeMaxSec=3600 --property=CPUQuota=30% \
  --property=MemoryMax=200M /usr/bin/python3 /opt/wstest/server.py
```

Add to the HTTPS `server` block of some host (back up the file, `nginx -t`, then reload):

```
location = /wstest/ws {
    proxy_pass http://127.0.0.1:8792;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_buffering off;
    proxy_read_timeout 3600s;
}
location /wstest/ { alias /var/www/wstest/; index index.html; }
```

Test from the machine behind the firewall: open `https://<host>/wstest/` in a browser, or
`python3 ws_client.py <host> /wstest/ws 60`.

Remove afterwards: delete the two locations, reload nginx, `systemctl stop wstest`.

## Results so far

- Dev Mac (TLS issuer shown as the FortiGate, `FG121GTK24002248`), host behind Cloudflare's proxy:
  ALIVE 20 s, 1.1 MB in 202 messages, 450 KB burst after 304 ms, ping median 87 ms, p95 304 ms.
- Office Mac that gets its UltraViewer relay cut: **not run yet**. That run decides whether a
  web app is viable on that network.
