import Foundation
import Darwin

/// Runs `ssh -N -D 127.0.0.1:<port> <host>` for the `ssh://` proxy form and
/// hands back the local SOCKS5 port. One tunnel per destination is kept alive
/// and reused; a dead one is replaced on the next call.
///
/// Login must be non-interactive (key or agent, `BatchMode`). Everything in
/// ~/.ssh/config applies, including `ProxyCommand` (for example cloudflared).
public final class SSHTunnel: @unchecked Sendable {
    public static let shared = SSHTunnel()

    public struct Failure: Error, LocalizedError {
        public let reason: String
        public var errorDescription: String? { reason }
    }

    private struct Running {
        let key: String
        let process: Process
        let port: UInt16
    }

    private let lock = NSLock()
    private var running: Running?
    private let stderrBox = StderrBox()

    private init() {
        atexit { SSHTunnel.shared.stop() }
    }

    /// Local SOCKS5 port of a live tunnel to `address`, starting ssh if needed.
    public func localPort(for address: RelayProxy.Address, timeout: TimeInterval = 25) async throws -> UInt16 {
        let key = address.summary
        let (reusable, stale): (UInt16?, Running?) = lock.withLock {
            if let current = running, current.key == key, current.process.isRunning { return (current.port, nil) }
            let old = running
            running = nil
            return (nil, old)
        }
        if let reusable { return reusable }
        stale?.process.terminate()

        let port = try Self.freePort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.arguments(for: address, localPort: port)
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        stderrBox.reset()
        errors.fileHandleForReading.readabilityHandler = { [stderrBox] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { stderrBox.append(data) }
        }
        Self.killLeftover()
        ConnectLog.write("ssh tunnel: starting \(address.summary) on 127.0.0.1:\(port)")
        do { try process.run() } catch {
            throw Failure(reason: "cannot start /usr/bin/ssh (\(error.localizedDescription))")
        }

        try? String(process.processIdentifier).write(to: Self.pidFile, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if !process.isRunning {
                let detail = stderrBox.text
                throw Failure(reason: "ssh to \(address.host) ended (status \(process.terminationStatus))"
                              + (detail.isEmpty ? "" : ": \(detail)"))
            }
            if Self.accepts(port: port) {
                lock.withLock { running = Running(key: key, process: process, port: port) }
                ConnectLog.write("ssh tunnel: up on 127.0.0.1:\(port)")
                return port
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        process.terminate()
        let detail = stderrBox.text
        throw Failure(reason: "ssh to \(address.host) did not open the tunnel in \(Int(timeout)) s"
                      + (detail.isEmpty ? "" : ": \(detail)"))
    }

    public func stop() {
        let current = lock.withLock { () -> Running? in let old = running; running = nil; return old }
        current?.process.terminate()
        try? FileManager.default.removeItem(at: Self.pidFile)
    }

    private static let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("MacViewer-ssh-tunnel.pid")

    /// An app that was force-quit leaves its ssh behind; end it before starting a new one.
    private static func killLeftover() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text), pid > 1 else { return }
        var info = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var proc = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&info, 4, &proc, &size, nil, 0) == 0, size > 0 else { return }
        let name = withUnsafeBytes(of: proc.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        if name == "ssh" { kill(pid, SIGTERM) }
    }

    static func arguments(for address: RelayProxy.Address, localPort: UInt16) -> [String] {
        var args = ["-N", "-T",
                    "-D", "127.0.0.1:\(localPort)",
                    "-o", "BatchMode=yes",
                    "-o", "ExitOnForwardFailure=yes",
                    "-o", "ConnectTimeout=15",
                    "-o", "ServerAliveInterval=15",
                    "-o", "ServerAliveCountMax=3",
                    "-o", "ControlPath=none"]
        if address.port != 0 { args += ["-p", String(address.port)] }
        if let user = address.username { args += ["-l", user] }
        // "--" so a host can never be taken as an option.
        args += ["--", address.host]
        return args
    }

    private static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(reason: "no free local port") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw Failure(reason: "no free local port") }
        var out = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard got == 0 else { throw Failure(reason: "no free local port") }
        return UInt16(bigEndian: out.sin_port)
    }

    private static func accepts(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = port.bigEndian
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }
}

private final class StderrBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func reset() { lock.lock(); data = Data(); lock.unlock() }
    func append(_ more: Data) { lock.lock(); if data.count < 4096 { data.append(more) }; lock.unlock() }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
    }
}
