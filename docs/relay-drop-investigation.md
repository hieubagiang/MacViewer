# Relay session drops right after the first frame

Status: **unresolved**. Written 2026-11-05 as a hand-off so the investigation can continue on another machine.

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
- `MACVIEWER_FIRST_QUALITY=10` earlier did not shrink the first frame (300-317 KB) and still dropped, so hypothesis 1 is effectively ruled out.
- Two independent clients failing identically points away from a Swift-only bug. Still open: host/relay fault vs. a step both clients omit that the official viewer performs.
- Next: run the official UltraViewer against the same host; if it survives, capture it with `tcpdump` and diff.

## Hypotheses still open

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
