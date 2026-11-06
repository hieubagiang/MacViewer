import Foundation
import Testing
@testable import UltraViewerProtocol

struct SSHTunnelTests {
    @Test func parsesSSHForms() {
        #expect(RelayProxy.parse("ssh://hieuit-cf") == .init(host: "hieuit-cf", port: 0, kind: .ssh))
        #expect(RelayProxy.parse("ssh://root@example.com:2222")
                == .init(host: "example.com", port: 2222, kind: .ssh, username: "root"))
        #expect(RelayProxy.parse("ssh://root@example.com:2222")?.summary == "ssh://root@example.com:2222")
        #expect(RelayProxy.parse("ssh://") == nil)
        #expect(RelayProxy.parse("ssh://-oProxyCommand=x") == nil)
        #expect(RelayProxy.parse("ssh://a b") == nil)
    }

    @Test func buildsArgumentsThatCannotInjectOptions() {
        let args = SSHTunnel.arguments(for: .init(host: "h", port: 22, kind: .ssh, username: "u"), localPort: 5555)
        #expect(args.contains("127.0.0.1:5555"))
        #expect(args.suffix(2) == ["--", "h"])
        #expect(args.contains("BatchMode=yes"))
    }

    @Test func reportsSSHFailure() async {
        // Port 1 on loopback refuses at once, so ssh exits and the reason surfaces.
        let address = RelayProxy.Address(host: "127.0.0.1", port: 1, kind: .ssh, username: "nobody")
        do {
            _ = try await SSHTunnel.shared.localPort(for: address, timeout: 20)
            Issue.record("expected failure")
        } catch let error as SSHTunnel.Failure {
            #expect(error.reason.contains("ended"))
        } catch { Issue.record("wrong error \(error)") }
    }
}
