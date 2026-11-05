import Foundation

/// Tells a real relay certificate apart from one re-signed by a network
/// firewall that decrypts TLS. Such a firewall can cut the relay session right
/// after the first large frame, which looks like a host or app fault.
public enum RelayCertificateIssuer {
    /// Vendors whose appliances re-sign TLS with their own CA (FortiGate shows
    /// up as "Fortinet" or "FG…" serial names).
    static let inspectingVendors = [
        "fortinet", "fortigate", "palo alto", "zscaler", "sophos", "check point",
        "checkpoint", "sonicwall", "watchguard", "netskope", "forcepoint",
        "blue coat", "bluecoat", "websense", "mcafee web", "cisco umbrella",
        "iboss", "barracuda"
    ]

    /// True when `issuer` names a known TLS-inspecting firewall. Unknown
    /// issuers are not flagged, so a legitimate CA change cannot raise a false alarm.
    public static func looksLikeInspectingFirewall(_ issuer: String?) -> Bool {
        guard let issuer, !issuer.isEmpty else { return false }
        let lowered = issuer.lowercased()
        return inspectingVendors.contains { lowered.contains($0) } || looksLikeFortiGateSerial(issuer)
    }

    /// A FortiGate signs with its serial number as the CA name (for example
    /// "FG121GTK24002248"), with no vendor word in the certificate summary.
    static func looksLikeFortiGateSerial(_ name: String) -> Bool {
        let value = name.trimmingCharacters(in: .whitespaces)
        guard value.count >= 12, value.hasPrefix("FG") else { return false }
        return value.unicodeScalars.allSatisfy { ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90) }
    }

    public static func firewallAdvice(issuer: String) -> String {
        "A firewall on this network (certificate issuer: \(issuer)) is inspecting the connection to UltraViewer and cut it. Ask your IT team to exempt *.ultraviewer.net (TCP 443) from SSL inspection, or use another network."
    }
}
