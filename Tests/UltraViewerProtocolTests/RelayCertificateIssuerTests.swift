import XCTest
@testable import UltraViewerProtocol

final class RelayCertificateIssuerTests: XCTestCase {
    func testFlagsKnownInspectingFirewalls() {
        XCTAssertTrue(RelayCertificateIssuer.looksLikeInspectingFirewall("FG121GTK24002248 Fortinet"))
        XCTAssertTrue(RelayCertificateIssuer.looksLikeInspectingFirewall("Zscaler Intermediate Root CA"))
    }

    func testRealPublicAuthoritiesAreNotFlagged() {
        XCTAssertFalse(RelayCertificateIssuer.looksLikeInspectingFirewall("Sectigo RSA Domain Validation Secure Server CA"))
        XCTAssertFalse(RelayCertificateIssuer.looksLikeInspectingFirewall("DigiCert TLS RSA SHA256 2020 CA1"))
        XCTAssertFalse(RelayCertificateIssuer.looksLikeInspectingFirewall(nil))
        XCTAssertFalse(RelayCertificateIssuer.looksLikeInspectingFirewall(""))
    }

    func testFirewallFailureMessageNamesTheFixAndIssuer() {
        let text = UltraViewerRelaySession.Failure.relayCutByFirewall(issuer: "Fortinet").errorDescription ?? ""
        XCTAssertTrue(text.contains("*.ultraviewer.net"))
        XCTAssertTrue(text.contains("Fortinet"))
    }
}
