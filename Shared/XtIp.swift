// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS — port of the Android xt/XtIp.kt

import Foundation

/// Helpers for IP literals and WireGuard endpoint strings. Never performs DNS.
enum XtIp {
    static func stripBrackets(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("[") { value.removeFirst() }
        if value.hasSuffix("]") { value.removeLast() }
        return value
    }

    private static func withoutZone(_ value: String) -> String {
        if let index = value.firstIndex(of: "%") { return String(value[..<index]) }
        return value
    }

    static func isIPv4(_ value: String) -> Bool {
        var address = in_addr()
        return stripBrackets(value).withCString { inet_pton(AF_INET, $0, &address) } == 1
    }

    static func isIPv6(_ value: String) -> Bool {
        let v = withoutZone(stripBrackets(value))
        guard v.contains(":") else { return false }
        var address = in6_addr()
        return v.withCString { inet_pton(AF_INET6, $0, &address) } == 1
    }

    static func isIPLiteral(_ value: String?) -> Bool {
        guard let value = value, !value.isEmpty else { return false }
        return isIPv4(value) || isIPv6(value)
    }

    /// Canonical form used for comparisons: no brackets, no zone, lower case, compressed IPv6.
    static func normalize(_ value: String) -> String {
        let v = withoutZone(stripBrackets(value)).lowercased()
        if isIPv4(v) { return v }
        guard isIPv6(v) else { return v }
        var address = in6_addr()
        guard v.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return v }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { return v }
        return String(cString: buffer).lowercased()
    }

    static func formatEndpoint(ip: String, port: Int) -> String {
        let clean = stripBrackets(ip)
        return clean.contains(":") ? "[\(clean)]:\(port)" : "\(clean):\(port)"
    }

    /// Splits "host:port" / "[v6]:port" (as printed by WireGuard) into its parts.
    static func splitEndpoint(_ endpoint: String) -> (host: String, port: Int)? {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = value.lastIndex(of: ":") else { return nil }
        let host = String(value[..<colon])
        guard let port = Int(value[value.index(after: colon)...]) else { return nil }
        return (stripBrackets(host), port)
    }

    private static let ipv4InText = try! NSRegularExpression(
        pattern: "(?<![\\d.])(25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)(\\.(25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)){3}(?![\\d.])"
    )
    private static let ipv6InText = try! NSRegularExpression(
        pattern: "(?<![0-9a-fA-F:])[0-9a-fA-F]{0,4}(:[0-9a-fA-F]{0,4}){2,7}(?![0-9a-fA-F:])"
    )

    /// Pulls every IP literal out of a text body (e.g. a "what is my IP" page).
    static func extractIps(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        func matches(_ regex: NSRegularExpression) -> [String] {
            regex.matches(in: text, range: range).compactMap { match in
                Range(match.range, in: text).map { String(text[$0]) }
            }
        }
        let v4 = matches(ipv4InText)
        let v6 = matches(ipv6InText).filter { isIPv6($0) }
        return unique((v4 + v6).map { normalize($0) })
    }

    /// Picks the best new address, keeping the IP family the tunnel already uses when possible.
    static func pickPreferred(_ candidates: [String], current: [String]) -> String? {
        guard let first = candidates.first else { return nil }
        let wantV6 = !current.isEmpty && current.allSatisfy { $0.contains(":") }
        return candidates.first { $0.contains(":") == wantV6 } ?? first
    }

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
