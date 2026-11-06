import Foundation
@preconcurrency import Network
import Testing
@testable import UltraViewerProtocol

/// Minimal SOCKS5 proxy (no auth, IPv4 CONNECT) on loopback. No external servers.
private final class FakeSOCKS5Proxy: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "MacViewer.tests.socks5")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var storedRequest: (host: String, port: UInt16)?
    private let replyCode: UInt8

    init(replyCode: UInt8 = 0) throws {
        self.replyCode = replyCode
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] client in self?.handle(client) }
    }

    var request: (host: String, port: UInt16)? { lock.lock(); defer { lock.unlock() }; return storedRequest }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        lock.lock(); let all = connections; connections = []; lock.unlock()
        all.forEach { $0.cancel() }
        listener.cancel()
    }

    private func track(_ connection: NWConnection) { lock.lock(); connections.append(connection); lock.unlock() }

    private func read(_ connection: NWConnection, _ count: Int, _ then: @escaping @Sendable (Data) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, _ in
            if let data, data.count == count { then(data) } else { connection.cancel() }
        }
    }

    private func handle(_ client: NWConnection) {
        track(client)
        client.start(queue: queue)
        read(client, 3) { [self] greeting in
            #expect(Array(greeting) == [5, 1, 0])
            client.send(content: Data([5, 0]), completion: .contentProcessed { _ in })
            read(client, 10) { [self] connect in
                let bytes = Array(connect)
                let host = bytes[4...7].map(String.init).joined(separator: ".")
                let port = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
                lock.lock(); storedRequest = (host, port); lock.unlock()
                guard replyCode == 0 else {
                    client.send(content: Data([5, replyCode, 0, 1, 0, 0, 0, 0, 0, 0]),
                                completion: .contentProcessed { _ in client.cancel() })
                    return
                }
                let target = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
                track(target)
                target.stateUpdateHandler = { [self] state in
                    guard case .ready = state else { return }
                    target.stateUpdateHandler = nil
                    client.send(content: Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]), completion: .contentProcessed { _ in })
                    pipe(client, target); pipe(target, client)
                }
                target.start(queue: queue)
            }
        }
    }

    private func pipe(_ from: NWConnection, _ to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
            if let data, !data.isEmpty { to.send(content: data, completion: .contentProcessed { _ in }) }
            if complete || error != nil { to.cancel() } else { pipe(from, to) }
        }
    }
}

private final class EchoServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "MacViewer.tests.echo")
    private let lock = NSLock()
    private var clients: [NWConnection] = []

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] client in
            guard let self else { client.cancel(); return }
            lock.lock(); clients.append(client); lock.unlock()
            client.start(queue: queue)
            Self.echo(client)
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        lock.lock(); let all = clients; clients = []; lock.unlock()
        all.forEach { $0.cancel() }
        listener.cancel()
    }

    private static func echo(_ client: NWConnection) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            if let data { client.send(content: data, completion: .contentProcessed { _ in }) }
            if !complete && error == nil { echo(client) }
        }
    }
}

private func roundTrip(through port: UInt16, payload: Data) async -> Data? {
    let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    let queue = DispatchQueue(label: "MacViewer.tests.client")
    return await withCheckedContinuation { continuation in
        let once = OnceBox()
        client.stateUpdateHandler = { state in
            switch state {
            case .ready:
                client.send(content: payload, completion: .contentProcessed { _ in })
                client.receive(minimumIncompleteLength: payload.count, maximumLength: payload.count) { data, _, _, _ in
                    if once.take() { client.cancel(); continuation.resume(returning: data) }
                }
            case .failed, .cancelled:
                if once.take() { continuation.resume(returning: nil) }
            default: break
            }
        }
        client.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) {
            if once.take() { client.cancel(); continuation.resume(returning: nil) }
        }
    }
}

private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}

struct SOCKS5BridgeTests {
    @Test func bridgeCarriesBytesBothWaysThroughTheProxy() async throws {
        let echo = try EchoServer(), proxy = try FakeSOCKS5Proxy()
        defer { echo.stop(); proxy.stop() }
        let echoPort = try await echo.start()
        let proxyPort = try await proxy.start()
        let bridge = SOCKS5Bridge(proxy: .init(host: "127.0.0.1", port: proxyPort),
                                  targetHost: "127.0.0.1", targetPort: echoPort)
        defer { bridge.cancel() }
        let local = try await bridge.start()
        let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let reply = await roundTrip(through: local, payload: payload)
        #expect(reply == payload)
        #expect(proxy.request?.host == "127.0.0.1")
        #expect(proxy.request?.port == echoPort)
        #expect(bridge.failureReason == nil)
    }

    @Test func refusedConnectIsReportedAndDropsTheClient() async throws {
        let proxy = try FakeSOCKS5Proxy(replyCode: 5)
        defer { proxy.stop() }
        let proxyPort = try await proxy.start()
        let bridge = SOCKS5Bridge(proxy: .init(host: "127.0.0.1", port: proxyPort),
                                  targetHost: "127.0.0.1", targetPort: 9)
        defer { bridge.cancel() }
        let local = try await bridge.start()
        let reply = await roundTrip(through: local, payload: Data([1, 2, 3]))
        #expect(reply == nil)
        #expect(bridge.failureReason == "the relay refused the connection")
    }

    @Test func unreachableProxyIsReported() async throws {
        let bridge = SOCKS5Bridge(proxy: .init(host: "127.0.0.1", port: 1),
                                  targetHost: "127.0.0.1", targetPort: 9)
        defer { bridge.cancel() }
        let local = try await bridge.start()
        let reply = await roundTrip(through: local, payload: Data([1]))
        #expect(reply == nil)
        #expect(bridge.failureReason?.contains("cannot reach the proxy") == true)
    }

    @Test func proxyAddressParsing() {
        #expect(RelayProxy.parse("127.0.0.1:1080") == .init(host: "127.0.0.1", port: 1080))
        #expect(RelayProxy.parse(" 1080 ") == .init(host: "127.0.0.1", port: 1080))
        #expect(RelayProxy.parse("[::1]:9050") == .init(host: "::1", port: 9050))
        #expect(RelayProxy.parse("proxy.local:8") == .init(host: "proxy.local", port: 8))
        #expect(RelayProxy.parse("") == nil)
        #expect(RelayProxy.parse("host:") == nil)
        #expect(RelayProxy.parse("host:70000") == nil)
        #expect(RelayProxy.parse("nonsense") == nil)
    }
}
