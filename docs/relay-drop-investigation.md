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

How it works: `SOCKS5Bridge` listens once on 127.0.0.1, does the SOCKS5 no-auth CONNECT to the real relay, and copies bytes. The app's TLS handshake still runs end to end with the relay, so certificates are verified as before and the proxy only carries encrypted bytes. Works on every supported macOS (no `ProxyConfiguration`, which needs macOS 14). LAN direct does not use the proxy.

Verified here (no firewall on this network, so this proves the bridge, not the firewall bypass): unit tests (`SOCKS5BridgeTests`, 200 KB round trip, refused CONNECT, unreachable proxy) and a live session through a local SOCKS5 proxy, relay opened, frames decoded, session alive 13 s+. Not yet verified: on the office network behind the FortiGate.

This is a way around a corporate control. Prefer asking IT for the exemption when possible.

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
