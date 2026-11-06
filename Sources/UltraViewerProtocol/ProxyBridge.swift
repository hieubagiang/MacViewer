import Foundation
@preconcurrency import Network

/// Proxy that relay connections go through: SOCKS5 or HTTP CONNECT, optionally
/// over TLS, optionally with a user name and password.
///
/// Text forms (Settings, or MACVIEWER_PROXY / MACVIEWER_SOCKS5):
///   `1080`, `host:1080`            SOCKS5 (plain), e.g. `ssh -N -D 1080 server`
///   `socks5://[user:pass@]host:1080`
///   `socks5s://[user:pass@]host[:443]`   SOCKS5 inside TLS
///   `http://[user:pass@]host:3128`       HTTP CONNECT (e.g. Squid)
///   `https://[user:pass@]host[:443]`     HTTP CONNECT inside TLS
///   `ssh://[user@]host[:port]`           the app runs `ssh -N -D` to that host (an
///                                        ~/.ssh/config alias works, key login only) and
///                                        uses the local SOCKS5 port it opens
public enum RelayProxy {
    public static let defaultsKey = "MacViewer.relaySOCKS5Proxy"
    public static let userKey = "MacViewer.relayProxyUser"
    public static let passwordKey = "MacViewer.relayProxyPassword"

    public struct Address: Equatable, Sendable {
        public enum Kind: String, Sendable { case socks5, http, ssh }
        public var kind: Kind
        public var host: String
        public var port: UInt16
        public var useTLS: Bool
        public var username: String?
        public var password: String?

        public init(host: String, port: UInt16, kind: Kind = .socks5, useTLS: Bool = false,
                    username: String? = nil, password: String? = nil) {
            self.kind = kind; self.host = host; self.port = port; self.useTLS = useTLS
            self.username = username; self.password = password
        }

        /// Never includes the password.
        public var summary: String {
            if kind == .ssh {
                return "ssh://\(username.map { "\($0)@" } ?? "")\(host)\(port == 0 ? "" : ":\(port)")"
            }
            let scheme = switch (kind, useTLS) {
            case (.ssh, _): "ssh"
            case (.socks5, false): "socks5"
            case (.socks5, true): "socks5s"
            case (.http, false): "http"
            case (.http, true): "https"
            }
            return "\(scheme)://\(username.map { _ in "***@" } ?? "")\(host):\(port)"
        }
    }

    /// Returns nil for empty or invalid text.
    public static func parse(_ text: String) -> Address? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        var kind = Address.Kind.socks5, tls = false, defaultPort: UInt16?
        var rest = Substring(value)
        if let range = value.range(of: "://") {
            switch value[..<range.lowerBound].lowercased() {
            case "socks5", "socks5h": break
            case "socks5s", "socks5+tls": tls = true; defaultPort = 443
            case "ssh": return parseSSH(value[range.upperBound...])
            case "http": kind = .http
            case "https": kind = .http; tls = true; defaultPort = 443
            default: return nil
            }
            rest = value[range.upperBound...]
        }
        while rest.hasSuffix("/") { rest = rest.dropLast() }
        var user: String?, pass: String?
        if let at = rest.lastIndex(of: "@") {
            let info = rest[..<at]
            rest = rest[rest.index(after: at)...]
            if let colon = info.firstIndex(of: ":") {
                user = String(info[..<colon]).removingPercentEncoding
                pass = String(info[info.index(after: colon)...]).removingPercentEncoding
            } else { user = String(info).removingPercentEncoding }
            if user?.isEmpty == true { user = nil }
        }
        if let port = UInt16(rest), port > 0, rest.count <= 5, !value.contains("://") {
            return Address(host: "127.0.0.1", port: port)
        }
        var host: String, port: UInt16
        if let colon = rest.lastIndex(of: ":"), !rest.hasSuffix("]") {
            host = String(rest[..<colon])
            guard let parsed = UInt16(rest[rest.index(after: colon)...]), parsed > 0 else { return nil }
            port = parsed
        } else {
            guard let defaultPort else { return nil }
            host = String(rest); port = defaultPort
        }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty else { return nil }
        return Address(host: host, port: port, kind: kind, useTLS: tls, username: user, password: pass)
    }

    /// `[user@]host[:port]`; the host may be an ~/.ssh/config alias.
    private static func parseSSH(_ text: Substring) -> Address? {
        var rest = text
        while rest.hasSuffix("/") { rest = rest.dropLast() }
        var user: String?
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at]).removingPercentEncoding
            rest = rest[rest.index(after: at)...]
            if user?.isEmpty == true { user = nil }
        }
        var port: UInt16 = 0
        if let colon = rest.lastIndex(of: ":"), !rest.hasSuffix("]") {
            guard let parsed = UInt16(rest[rest.index(after: colon)...]), parsed > 0 else { return nil }
            port = parsed
            rest = rest[..<colon]
        }
        var host = String(rest)
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        // The host goes to ssh as an argument: refuse anything that could be read as an option.
        guard !host.isEmpty, !host.hasPrefix("-"), !host.contains(where: { $0.isWhitespace }) else { return nil }
        if let user, user.hasPrefix("-") || user.contains(where: { $0.isWhitespace }) { return nil }
        return Address(host: host, port: port, kind: .ssh, username: user)
    }

    /// Environment first, then Settings. Separate user/password settings apply
    /// only when the address text carries none.
    public static var configured: Address? {
        let env = ProcessInfo.processInfo.environment
        if let text = env["MACVIEWER_PROXY"] ?? env["MACVIEWER_SOCKS5"], let address = parse(text) {
            return address
        }
        let defaults = UserDefaults.standard
        guard var address = parse(defaults.string(forKey: defaultsKey) ?? "") else { return nil }
        if address.username == nil {
            let user = defaults.string(forKey: userKey) ?? ""
            if !user.isEmpty {
                address.username = user
                address.password = defaults.string(forKey: passwordKey) ?? ""
            }
        }
        return address
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    /// True only for the first caller.
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}

/// One-shot loopback bridge: the app's own TLS connection dials 127.0.0.1:port,
/// and the bridge connects to the target through the proxy (SOCKS5 or HTTP
/// CONNECT) and copies bytes both ways. TLS stays end to end between the app and the relay;
/// the proxy only sees encrypted bytes.
final class ProxyBridge: @unchecked Sendable {
    private let proxy: RelayProxy.Address
    private let targetHost: String
    private let targetPort: UInt16
    private let queue = DispatchQueue(label: "MacViewer.proxybridge")
    private let lock = NSLock()
    private var listener: NWListener?
    private var inbound: NWConnection?
    private var outbound: NWConnection?
    private var finished = false
    private var storedFailure: String?

    init(proxy: RelayProxy.Address, targetHost: String, targetPort: UInt16) {
        self.proxy = proxy
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    /// Why the proxy leg failed, for the connection error message.
    var failureReason: String? { lock.lock(); defer { lock.unlock() }; return storedFailure }

    /// Starts listening on loopback and returns the local port to dial.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard once.take() else { return }
                    if let port = listener.port?.rawValue { continuation.resume(returning: port) }
                    else { continuation.resume(throwing: NWError.posix(.EADDRNOTAVAIL)) }
                case let .failed(error):
                    guard once.take() else { return }
                    self?.fail("local bridge: \(error)")
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func cancel() {
        lock.lock()
        let wasFinished = finished
        finished = true
        let items = (listener, inbound, outbound)
        listener = nil; inbound = nil; outbound = nil
        lock.unlock()
        guard !wasFinished else { return }
        items.0?.cancel(); items.1?.cancel(); items.2?.cancel()
    }

    private func fail(_ reason: String) {
        lock.lock()
        if storedFailure == nil { storedFailure = reason }
        lock.unlock()
        cancel()
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        let alreadyHaveOne = inbound != nil || finished
        if !alreadyHaveOne { inbound = connection }
        lock.unlock()
        guard !alreadyHaveOne else { connection.cancel(); return }
        listener?.cancel() // only one connection is expected
        connection.start(queue: queue)
        connectToProxy()
    }

    private func connectToProxy() {
        guard let port = NWEndpoint.Port(rawValue: proxy.port) else { fail("invalid proxy port"); return }
        // A TLS leg is verified against the proxy's own host name with the system trust store.
        let parameters = proxy.useTLS ? NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options()) : .tcp
        let connection = NWConnection(host: NWEndpoint.Host(proxy.host), port: port, using: parameters)
        lock.lock(); outbound = connection; lock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                connection.stateUpdateHandler = { [weak self] state in
                    if case .failed = state { self?.cancel() }
                }
                self.handshake(connection)
            case let .failed(error), let .waiting(error):
                let kind = self.proxy.useTLS ? "cannot open a secure connection to the proxy" : "cannot reach the proxy"
                self.fail("\(kind) \(self.proxy.host):\(self.proxy.port) (\(error))")
            default: break
            }
        }
        connection.start(queue: queue)
    }

    // MARK: Handshakes

    private func handshake(_ proxyConnection: NWConnection) {
        switch proxy.kind {
        case .socks5: socksHandshake(proxyConnection)
        case .http: httpConnect(proxyConnection)
        case .ssh: fail("an ssh:// proxy must be resolved to a local SOCKS5 port first")
        }
    }

    /// RFC 1928 greeting; user/password (RFC 1929) is offered only when configured.
    private func socksHandshake(_ proxyConnection: NWConnection) {
        let hasCredentials = proxy.username != nil
        let greeting = hasCredentials ? Data([5, 2, 0, 2]) : Data([5, 1, 0])
        proxyConnection.send(content: greeting, completion: .contentProcessed { [weak self] error in
            if let error { self?.fail("proxy send failed (\(error))"); return }
            self?.receive(proxyConnection, count: 2) { reply in
                guard reply.count == 2, reply[0] == 5 else { self?.fail("not a SOCKS5 proxy"); return }
                switch reply[1] {
                case 0: self?.sendConnect(proxyConnection)
                case 2: self?.socksLogin(proxyConnection)
                default: self?.fail(hasCredentials ? "the proxy accepts none of the offered login methods"
                                                   : "the proxy requires a user name and password")
                }
            }
        })
    }

    private func socksLogin(_ proxyConnection: NWConnection) {
        let user = Array((proxy.username ?? "").utf8), pass = Array((proxy.password ?? "").utf8)
        guard !user.isEmpty, user.count <= 255, pass.count <= 255 else {
            fail("the proxy requires a user name and password (1 to 255 bytes each)"); return
        }
        var request = Data([1, UInt8(user.count)]); request.append(contentsOf: user)
        request.append(UInt8(pass.count)); request.append(contentsOf: pass)
        proxyConnection.send(content: request, completion: .contentProcessed { [weak self] error in
            if let error { self?.fail("proxy send failed (\(error))"); return }
            self?.receive(proxyConnection, count: 2) { reply in
                guard reply.count == 2, reply[1] == 0 else {
                    self?.fail("the proxy rejected the user name or password"); return
                }
                self?.sendConnect(proxyConnection)
            }
        })
    }

    /// HTTP CONNECT with optional Basic authentication. Any bytes the proxy
    /// sends after the header are forwarded to the app.
    private func httpConnect(_ proxyConnection: NWConnection) {
        let authority = targetHost.contains(":") ? "[\(targetHost)]:\(targetPort)" : "\(targetHost):\(targetPort)"
        var lines = ["CONNECT \(authority) HTTP/1.1", "Host: \(authority)", "Proxy-Connection: Keep-Alive"]
        if let user = proxy.username {
            let token = Data("\(user):\(proxy.password ?? "")".utf8).base64EncodedString()
            lines.append("Proxy-Authorization: Basic \(token)")
        }
        let request = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        proxyConnection.send(content: request, completion: .contentProcessed { [weak self] error in
            if let error { self?.fail("proxy send failed (\(error))"); return }
            self?.readHTTPHeader(proxyConnection, collected: Data())
        })
    }

    private func readHTTPHeader(_ connection: NWConnection, collected: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let error { self.fail("proxy read failed (\(error))"); return }
            var buffer = collected
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data([13, 10, 13, 10])) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let status = head.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
                let code = status.split(separator: " ").dropFirst().first.flatMap { Int($0) }
                switch code {
                case 200?: break
                case 407?: self.fail("the proxy rejected the user name or password"); return
                case 403?: self.fail("the proxy refused the connection (403)"); return
                default: self.fail("the proxy answered \"\(status.prefix(80))\""); return
                }
                let extra = Data(buffer[end.upperBound...])
                self.startPiping(initialToApp: extra)
            } else if complete || buffer.count > 16 * 1024 {
                self.fail("the proxy sent an invalid reply")
            } else {
                self.readHTTPHeader(connection, collected: buffer)
            }
        }
    }

    private func sendConnect(_ proxyConnection: NWConnection) {
        var request = Data([5, 1, 0])
        let octets = targetHost.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        if octets.count == 4, targetHost.split(separator: ".").count == 4 {
            request.append(1); request.append(contentsOf: octets)
        } else {
            let name = Array(targetHost.utf8)
            guard name.count <= 255 else { fail("target name too long"); return }
            request.append(3); request.append(UInt8(name.count)); request.append(contentsOf: name)
        }
        request.append(UInt8(targetPort >> 8)); request.append(UInt8(targetPort & 0xFF))
        proxyConnection.send(content: request, completion: .contentProcessed { [weak self] error in
            if let error { self?.fail("proxy send failed (\(error))"); return }
            self?.receive(proxyConnection, count: 4) { header in
                guard header.count == 4, header[0] == 5 else { self?.fail("bad SOCKS5 reply"); return }
                guard header[1] == 0 else { self?.fail(Self.replyText(header[1])); return }
                let remaining: Int
                switch header[3] {
                case 1: remaining = 4 + 2
                case 4: remaining = 16 + 2
                case 3:
                    self?.receive(proxyConnection, count: 1) { length in
                        guard let first = length.first else { self?.fail("bad SOCKS5 reply"); return }
                        self?.receive(proxyConnection, count: Int(first) + 2) { _ in self?.startPiping() }
                    }
                    return
                default: self?.fail("bad SOCKS5 address type"); return
                }
                self?.receive(proxyConnection, count: remaining) { _ in self?.startPiping() }
            }
        })
    }

    private static func replyText(_ code: UInt8) -> String {
        switch code {
        case 1: "the proxy reported a general failure"
        case 2: "the proxy ruleset refused the connection"
        case 3: "the proxy has no route to the network"
        case 4: "the proxy could not reach the relay host"
        case 5: "the relay refused the connection"
        case 6: "TTL expired at the proxy"
        case 7: "the proxy does not support CONNECT"
        case 8: "the proxy does not support this address type"
        default: "the proxy returned error \(code)"
        }
    }

    private func receive(_ connection: NWConnection, count: Int, then handler: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
            if let error { self?.fail("proxy read failed (\(error))"); return }
            guard let data, data.count == count else { self?.fail("the proxy closed the connection"); return }
            handler(data)
        }
    }

    // MARK: Byte pipe

    private func startPiping(initialToApp: Data = Data()) {
        lock.lock()
        let pair = (inbound, outbound)
        lock.unlock()
        guard let inbound = pair.0, let outbound = pair.1 else { return }
        pipe(from: inbound, to: outbound)
        if initialToApp.isEmpty { pipe(from: outbound, to: inbound) }
        else {
            inbound.send(content: initialToApp, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.cancel() } else { self?.pipe(from: outbound, to: inbound) }
            })
        }
    }

    private func pipe(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    if sendError != nil { self?.cancel(); return }
                    if error == nil, !complete { self?.pipe(from: source, to: destination) }
                    else { self?.cancel() }
                })
            } else if error != nil || complete {
                self?.cancel()
            } else {
                self?.pipe(from: source, to: destination)
            }
        }
    }
}
