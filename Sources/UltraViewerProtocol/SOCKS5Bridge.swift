import Foundation
@preconcurrency import Network

/// Where relay connections go through a SOCKS5 proxy, e.g. `ssh -N -D 1080 server`.
/// Set in Settings (`MacViewer.relaySOCKS5Proxy`) or with MACVIEWER_SOCKS5=host:port.
public enum RelayProxy {
    public static let defaultsKey = "MacViewer.relaySOCKS5Proxy"

    public struct Address: Equatable, Sendable {
        public let host: String
        public let port: UInt16
    }

    /// Parses "host:port", "[::1]:port" or a bare port. Returns nil for empty or invalid text.
    public static func parse(_ text: String) -> Address? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let port = UInt16(value), port > 0 { return Address(host: "127.0.0.1", port: port) }
        guard let colon = value.lastIndex(of: ":") else { return nil }
        var host = String(value[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty, let port = UInt16(value[value.index(after: colon)...]), port > 0 else { return nil }
        return Address(host: host, port: port)
    }

    public static var configured: Address? {
        if let env = ProcessInfo.processInfo.environment["MACVIEWER_SOCKS5"], let address = parse(env) {
            return address
        }
        return parse(UserDefaults.standard.string(forKey: defaultsKey) ?? "")
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    /// True only for the first caller.
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}

/// One-shot loopback bridge: the app's own TLS connection dials 127.0.0.1:port,
/// and the bridge connects to the target through a SOCKS5 proxy (no auth) and
/// copies bytes both ways. TLS stays end to end between the app and the relay;
/// the proxy only sees encrypted bytes.
final class SOCKS5Bridge: @unchecked Sendable {
    private let proxy: RelayProxy.Address
    private let targetHost: String
    private let targetPort: UInt16
    private let queue = DispatchQueue(label: "MacViewer.socks5bridge")
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
        let connection = NWConnection(host: NWEndpoint.Host(proxy.host), port: port, using: .tcp)
        lock.lock(); outbound = connection; lock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                connection.stateUpdateHandler = { [weak self] state in
                    if case .failed = state { self?.cancel() }
                }
                self.handshake(connection)
            case let .failed(error): self.fail("cannot reach the proxy \(self.proxy.host):\(self.proxy.port) (\(error))")
            case let .waiting(error): self.fail("cannot reach the proxy \(self.proxy.host):\(self.proxy.port) (\(error))")
            default: break
            }
        }
        connection.start(queue: queue)
    }

    // MARK: SOCKS5 handshake (RFC 1928, no authentication)

    private func handshake(_ proxyConnection: NWConnection) {
        proxyConnection.send(content: Data([5, 1, 0]), completion: .contentProcessed { [weak self] error in
            if let error { self?.fail("proxy send failed (\(error))"); return }
            self?.receive(proxyConnection, count: 2) { reply in
                guard reply.count == 2, reply[0] == 5 else { self?.fail("not a SOCKS5 proxy"); return }
                guard reply[1] == 0 else { self?.fail("the proxy requires authentication, which is not supported"); return }
                self?.sendConnect(proxyConnection)
            }
        })
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

    private func startPiping() {
        lock.lock()
        let pair = (inbound, outbound)
        lock.unlock()
        guard let inbound = pair.0, let outbound = pair.1 else { return }
        pipe(from: inbound, to: outbound)
        pipe(from: outbound, to: inbound)
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
