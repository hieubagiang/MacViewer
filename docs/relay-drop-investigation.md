# Relay session drops right after the first frame

Status: **root cause found (2026-11-05): TLS inspection by a Fortinet FortiGate on the office network, see "Root cause" below**. Earlier text kept for history. Written 2026-11-05 as a hand-off so the investigation can continue on another machine.

## Symptom

Connecting to some Windows UltraViewer hosts over the **relay** path shows the first full-screen frame, then the session ends with
"The relay connection to the Windows computer closed." (`Failure.relayClosed`) or "The remote computer disconnected." (`Failure.closed`).
The same hosts can work over **LAN direct** (`TCPDirectPeerTransport`). The drop is intermittent per host/path.

## Evidence (about 10 relay sessions)

- 3+ different hosts (6.6.108, 6.6.129, 6.6.133), 5+ different relay IPs, two different networks (office and another network).
- Every failing session ends the same way: the relay stream gets a clean remote FIN (`relay stream ended without error`), at most ~1–2 ms after the first full frame (220–450 KB) has been received and decoded.
- No end command (27/41/54), no relay system message, `ignoredSources=0`.
- `aliveMs` varies (219–2961), so it is not a fixed timer.
- Decode speed is not the cause (13–18 ms in an optimized build still drops).
- The FIN is processed before our ACK `18` could have reached the relay, so the ACK did not cause it.
- Outgoing traffic is not the cause: a session that sent only `login`, `17`, `28|||1`, `18` (exactly what `LinuxViewer/src/client.rs` sends) still dropped.
- The receive loop (`FramedTCPTransport.receiveLoop`) treats `isComplete` correctly; the FIN is real.

Not known: whether the relay or the host closes the stream.

### Update 2026-11-05 (later): Rust client reproduces the drop

- `LinuxViewer` (`linuxviewer snapshot 112293508 ... --frames 3 --no-lan`, with `LINUXVIEWER_INSECURE_RELAY=1` because its TLS roots do not trust the relay) logged in, received 1 frame, saved it, then "The UltraViewer network connection closed." Same host (6.6.108) that drops the Swift client.
- The Swift client without any experiment flag, via relay `149.28.14.225`, dropped the same way (frame 245 KB, FIN about 1 ms after ACK 18).
- `MACVIEWER_FIRST_QUALITY=10` earlier did not shrink the first frame (300-317 KB), so it never tested a small frame. Hypothesis 1 (first frame too large for the relay path) is **untested**, not ruled out.
- Follow-up (2026-11-05): sent `32|||2` + `31|||10` **before** `17` (host echoes 32, so it processed it), and also `23|||0` (hide wallpaper). Frame #1 stayed 304-326 KB and the session still dropped, so the first full frame size cannot be reduced from the viewer. Hypothesis 1 therefore cannot be tested this way. Env: `MACVIEWER_FIRST_QUALITY`, `MACVIEWER_FIRST_WALLPAPER=0`, `MACVIEWER_FIRST_ORDER=after`.
- Earlier log (host 135774296, 6.6.133, before the tx logging existed) shows the stream cut **mid-frame** (`truncatedFrame`, 55 ms after init, before any ACK). So the cut is not a logical reaction to our ACK or to a complete frame; it happens while the first large burst is in transit. This fits "host-to-relay or relay-to-us path aborts during the first big burst" better than a protocol-level rejection.
- Commands 3/4/28 received right before the FIN are cursor messages (benign).
- Two independent clients failing identically points away from a Swift-only bug. Still open: host/relay fault vs. a step both clients omit that the official viewer performs.
- Next: run the official UltraViewer against the same host; if it survives, capture it with `tcpdump` and diff.

## Root cause (found 2026-11-05)

- The same host (112293508, 6.6.108), same relay hostname and same Rust client, run from a datacenter server with no firewall in between (Ubuntu, VN IP, `tcpdump` running): **4/4 sessions survive**, 2 frames received, no FIN. On the office Mac the same client drops after the first frame.
- Certificate seen for `*.ultraviewer.net`: on the Mac the issuer is `Fortinet ... CN=FG121GTK24002248` (a FortiGate re-signing TLS); on the server it is the real `Sectigo RSA Domain Validation Secure Server CA`. This is also why the Rust client reports `UnknownIssuer` on the Mac while the Swift app works (macOS trusts the corporate CA).
- So the office firewall does TLS deep inspection and ends the proxied session right after the first large burst (250-490 KB), sometimes mid-frame (`truncatedFrame`). That explains the clean FIN, the lack of any command, and why LAN direct (no firewall) works.
- Fix is outside the app: ask network admins to exempt `*.ultraviewer.net` (port 443) from SSL deep inspection / IPS, or use a network without it (VPN, hotspot). The "other network" in the evidence list should be checked for a similar middlebox.
- Cross-check planned: `hieu.pd1`'s machine/network does **not** disconnect (reported by the team). Compare against it: run the Swift app there (`MACVIEWER_AUTOCONNECT=<id>:<password>`), then check the relay certificate issuer on both networks with `echo | openssl s_client -connect functions3.ultraviewer.net:443 -servername ultraviewer 2>/dev/null | openssl x509 -noout -issuer`. A Sectigo issuer there and a Fortinet issuer on the office network confirms the cause.
- Test server used: `ssh hieuit-cf` (Cloudflare Access, `cloudflared`), Ubuntu 24.04. `/root/LinuxViewer` holds a Rust build (`cargo build --release --no-default-features --features desktop`; Wayland feature needs PipeWire dev packages), `/root/relay.pcap` holds the capture of a surviving session.
- App-side improvement worth doing: detect a non-Sectigo issuer on the relay certificate and show "A firewall on your network is inspecting the connection; ask IT to exempt *.ultraviewer.net".

## Workaround: relay through a SOCKS5 proxy (2026-11-06)

When IT cannot exempt `*.ultraviewer.net`, send the connection through a server whose path is not inspected.

1. Open a SOCKS5 proxy over a path the firewall allows, for example `ssh -N -D 1080 <server>` (works through a Cloudflare Tunnel too).
2. In MacViewer: Settings > General > Network > "SOCKS5 proxy (host:port)" = `127.0.0.1:1080`, or launch with `MACVIEWER_SOCKS5=127.0.0.1:1080`. Empty means direct.
3. Reconnect. In debug builds the log shows `via SOCKS5 proxy ... -> relayIP:443` for the ID-server and relay connections.

Proxy kinds (Settings > General > Network, or `MACVIEWER_PROXY`): `host:1080` / `socks5://` (SOCKS5), `socks5s://` (SOCKS5 inside TLS), `http://` (HTTP CONNECT, e.g. Squid), `https://` (HTTP CONNECT inside TLS, default port 443). Optional `user:pass@` (SOCKS5 RFC 1929, HTTP Basic) or the separate user/password settings. Many corporate networks only allow outbound 443 to unknown hosts, so use the TLS kinds on port 443 there. The TLS leg to the proxy is verified against the proxy's host name with the system trust store; it has only been unit-tested without TLS so far.

How it works: `ProxyBridge` listens once on 127.0.0.1, does the SOCKS5 or HTTP CONNECT handshake to the real relay, and copies bytes. The app's TLS handshake still runs end to end with the relay, so certificates are verified as before and the proxy only carries encrypted bytes. Works on every supported macOS (no `ProxyConfiguration`, which needs macOS 14). LAN direct does not use the proxy.

Verified here (no firewall on this network, so this proves the bridge, not the firewall bypass): unit tests (`ProxyBridgeTests`, 200 KB round trip, refused CONNECT, unreachable proxy) and a live session through a local SOCKS5 proxy, relay opened, frames decoded, session alive 13 s+. Verified on the office network behind the FortiGate (2026-11-06, same Mac, same host): without the proxy the relay certificate issuer is `FG121GTK24002248` and the session is cut after the first frame (`relayCutByFirewall`); through `ssh -D` the issuer is Sectigo and the session stayed up 15 s (23 frames, 94 commands, relay ping answered) until the user closed it.

This is a way around a corporate control. Prefer asking IT for the exemption when possible.

### Server side used for the HTTPS proxy (2026-11-06)

Many corporate networks only allow outbound 443 to unknown hosts, so a plain proxy port (3128, 1080) is unreachable. Setup that works from the office network:

- DNS-only A record `px.<domain>` (not proxied: Cloudflare's proxy does not carry CONNECT) pointing to the server.
- Let's Encrypt certificate for that name (`certbot --webroot`), plus an HTTP :80 vhost that serves `/.well-known/acme-challenge/` so renewal keeps working.
- nginx `stream` on 443 already routes by SNI (`ssl_preread`). Add `px.<domain> 127.0.0.1:8446;` to the map and a stream `server { listen 127.0.0.1:8446 ssl; ...cert...; proxy_timeout 1h; proxy_pass 127.0.0.1:3128; }`. Other SNIs are unchanged.
- Squid with Basic auth (`basic_ncsa_auth`, `htpasswd`-style file) bound to `127.0.0.1:3128` only.
- App setting: `https://user:password@px.<domain>` (or the separate user/password fields).

Verified: `curl --proxy https://px.<domain>:443 --proxy-user user:pass https://api.ipify.org` returns the server's IP, a wrong password gets 407, and the app's ID-server lookup went through it. A full relay session through this HTTPS proxy was not re-run because the test host rotated its password.

## Status 2026-11-06 (latest): HTTPS proxy is still cut on the office network

Behind the FortiGate, with Proxy = `https://user:pass@px.<domain>` (HTTP CONNECT inside TLS on 443):

- The proxy works: ID lookup and relay open go through it (`via proxy https://***@px.<domain>:443 -> relayIP:443`).
- But `relay opened certIssuer=FG121GTK24002248`, i.e. the relay's own TLS certificate was re-signed by the FortiGate **inside** the tunnel (through `ssh -D` the issuer was Sectigo). The session is cut after frame #1 (94-96 KB) with `relayCutByFirewall`, as without a proxy.
- Working theory (unconfirmed): the FortiGate decrypts the outer TLS to the proxy host, sees the plaintext `CONNECT host:443` line, treats it as a proxy tunnel and inspects the tunneled TLS again. `ssh -D` over a Cloudflare tunnel is not parsed that way.
- Confirm on the office Mac: `echo | openssl s_client -connect px.<domain>:443 -servername px.<domain> 2>/dev/null | openssl x509 -noout -issuer`. `Fortinet...` means the outer layer is intercepted (theory holds); `Let's Encrypt` means it is not and the theory is wrong.

What works today on that network: `ssh -N -D 1080 <server>` through a Cloudflare tunnel, with Proxy = `127.0.0.1:1080` (15 s+ session, 23 frames, relay ping answered).

**Confirmed (2026-11-06, office Mac):** `openssl s_client -connect px.<domain>:443 -servername px.<domain>` shows issuer `Fortinet ... CN=FG121GTK24002248`. The FortiGate decrypts every TLS session to an unknown host on 443, including our proxy host. So any proxy protocol whose bytes are readable inside the outer TLS (HTTP CONNECT, and probably SOCKS5) is visible to it. Only a payload it cannot read gets through (SSH worked).

### Next steps (for the next session)

1. ~~Run the confirm command above and record the issuer here.~~ Done, see above.
2. If the outer layer is intercepted, try a payload that is not an HTTP CONNECT: SOCKS5 inside TLS (`socks5s://`). Server side needs a SOCKS5 server (for example a separate xray instance with a `socks` inbound and auth, or dante) behind the same nginx `stream` TLS terminator on a second SNI. Client side already supports `socks5s://` and user/password; the TLS leg has only been exercised against the HTTP variant. Risk: the FortiGate may recognize SOCKS and block it.
3. If that fails too, the payload must be opaque to the FortiGate: add an app-level encrypted layer (for example Shadowsocks-style AEAD to the server) or a built-in "SSH tunnel" option that runs `ssh -N -D` through the Cloudflare tunnel (the one thing proven to work); until then keep using `ssh -D` manually.
4. Best long-term fix remains asking IT to exempt `*.ultraviewer.net` TCP 443 from SSL inspection / IPS; give them the issuer `FG121GTK24002248`.

## Status 2026-11-06 (latest): built-in SSH tunnel works behind the FortiGate

Proxy = `ssh://hieuit-cf` (any `~/.ssh/config` alias or `ssh://[user@]host[:port]`; key/agent login only, `BatchMode`). The app runs `/usr/bin/ssh -N -T -D 127.0.0.1:<free port>` itself (`SSHTunnel.swift`), waits for the port, then uses it as a local SOCKS5 proxy. `~/.ssh/config` applies, so the cloudflared `ProxyCommand` works.

Tested on the office network with a real session: tunnel up in 1.3 s, `relay opened certIssuer=Sectigo...` (not FortiGate), frame #1 (95 KB) decoded and the session stayed up 38 s+ with relay pings answered. A leftover ssh from a force-quit app is killed on the next start (pid file in the temp dir).

Not done: the `socks5s://` experiment (low value now that this works). `swift test` cannot run here (no Xcode, no `Testing` module); `Tests/UltraViewerProtocolTests/SSHTunnelTests.swift` is written but unrun.

## Status 2026-11-06 (later): `socks5s://` works behind the FortiGate

Proxy = `socks5s://macviewer:<password>@px.<domain>` (user/password can also go in the Settings fields). Tested on the office network: relay issuer Sectigo, frames #1 (97 KB) and #2 decoded, session alive 75 s with relay pings answered, no cut. The outer TLS to the proxy host is still re-signed by the FortiGate (issuer `FG121GTK24002248`), so the old theory holds: it is the plaintext HTTP `CONNECT` inside that triggers the second inspection; SOCKS5 inside the TLS is not re-inspected.

Server side (no secrets here): a separate `xray-s5.service` (own config in `/etc/xray-s5/`, user `nobody`) with one `socks` inbound on `127.0.0.1:1081`, password auth. The existing xray/VPN is untouched. In `/etc/nginx/nginx.conf` the stream server on `127.0.0.1:8446` (SNI `px.<domain>`) now proxies to `127.0.0.1:1081` instead of Squid `3128` (backup: `nginx.conf.bak-s5-*`), so `https://` HTTP-CONNECT proxy no longer works on that host. Squid is still running on 3128 but unreachable from outside; remove it if not needed. The password is in `/etc/xray-s5/config.json` on the server only.

## Web app idea: WebSocket stream test (2026-11-06)

If the UltraViewer protocol never crosses the office network (a server speaks it and streams the screen to a browser over HTTPS/WebSocket), the FortiGate has nothing it recognizes. `scripts/wstest/` (see its README) checks that cheaply: a WebSocket that sends a 450 KB burst plus a steady stream for 60 s.

- Dev Mac, host behind Cloudflare's proxy, TLS re-signed by the FortiGate: ALIVE, 1.1 MB in 20 s, ping median 87 ms.
- Office Mac (the one that gets cut): run `https://<host>/wstest/` in a browser and record ALIVE/CUT here. Not run yet.
- Server measured: 2 vCPU Xeon 2.6 GHz, 3.9 GB RAM, ~220 Mbps up / ~280 Mbps down, 20 ms to the UltraViewer ID server. Estimated (not measured): server-side decode plus re-encode costs about 50-70% of a core per heavy session, under 5% per light session, so CPU is the limit (2-3 heavy or 20-30 light sessions). A WebSocket-to-TCP gateway with the client in WASM would need almost no server CPU.

## Hypotheses (superseded by the root cause above)

1. The first frame is too large for the relay path (frames of 250–450 KB). Test: `MACVIEWER_FIRST_QUALITY=10` sends `32|||2` and `31|||10` right after `17`; check whether `frame #1 payload=` shrinks and the session survives.
2. Our `login` parameters make the host behave differently from the official viewer. Compare against a capture of the official UltraViewer.
3. The host or relay is simply broken for third-party viewers on this path. Test: run the official UltraViewer on the same machine against the same host. If it also drops, the app is not at fault.

## Tools added for debugging

- `ConnectLog` (debug builds): in-memory ring plus `~/Library/Logs/MacViewer/connect.log`. Logs state, command ids and sizes, never passwords or payload contents.
- In-app log window (⌥⌘L, debug builds), with Copy all / Clear / Reveal file.
- `MACVIEWER_DEBUG_LOG=1 scripts/package_app.sh release` compiles the logging into an optimized build (debug builds decode a 3840x1080 frame in ~800 ms, which distorts timings).
- `MACVIEWER_DISABLE_LAN_DIRECT=1` forces relay only.
- `MACVIEWER_FIRST_QUALITY=<n>` experiment described above.
- `MACVIEWER_AUTOCONNECT=<id>:<password>` (debug builds) connects at launch and turns off remember-password (avoids a Keychain prompt that blocks unsigned builds).

## Next steps

1. Run hypothesis 1 and 3 on the same Mac against one failing host, 3–4 attempts each, and compare.
2. If the app is at fault, build the Rust client in `LinuxViewer/` (`cargo run`) against the same host. If Rust survives, diff the bytes it sends and receives against the Swift client.
3. A packet capture (`tcpdump` on port 443) would show who sends the first FIN or RST. It needs admin rights.

## Unrelated fix included in the same branch

`AppLocalization` touched SwiftPM's `Bundle.module` in a packaged `.app`, which is a `fatalError` on any Mac other than the build machine. It now only uses `Bundle.module` when not running from an `.app`.
