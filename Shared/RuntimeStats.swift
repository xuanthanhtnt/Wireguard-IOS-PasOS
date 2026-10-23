// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS

import Foundation

/// Live state of one peer, parsed from the WireGuard UAPI "get" output.
struct PeerRuntime: Equatable {
    /// Base64 public key.
    var publicKey: String
    var endpoint: String?
    var lastHandshake: Date?
    var rxBytes: UInt64 = 0
    var txBytes: UInt64 = 0

    /// IP of the endpoint currently used (no port), normalized.
    var endpointIp: String? {
        guard let endpoint = endpoint, let parts = XtIp.splitEndpoint(endpoint), XtIp.isIPLiteral(parts.host) else { return nil }
        return XtIp.normalize(parts.host)
    }
}

enum UAPIParser {
    static func parse(_ text: String) -> [PeerRuntime] {
        var peers = [PeerRuntime]()
        var current: PeerRuntime?
        var handshakeSec: Int64 = 0
        var handshakeNsec: Int64 = 0

        func flush() {
            guard var peer = current else { return }
            if handshakeSec > 0 {
                peer.lastHandshake = Date(timeIntervalSince1970: Double(handshakeSec) + Double(handshakeNsec) / 1e9)
            }
            peers.append(peer)
            current = nil
            handshakeSec = 0
            handshakeNsec = 0
        }

        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals]
            let value = String(line[line.index(after: equals)...])
            switch key {
            case "public_key":
                flush()
                let base64 = PublicKey(hexKey: value)?.base64Key ?? value
                current = PeerRuntime(publicKey: base64)
            case "endpoint":
                current?.endpoint = value
            case "last_handshake_time_sec":
                handshakeSec = Int64(value) ?? 0
            case "last_handshake_time_nsec":
                handshakeNsec = Int64(value) ?? 0
            case "rx_bytes":
                current?.rxBytes = UInt64(value) ?? 0
            case "tx_bytes":
                current?.txBytes = UInt64(value) ?? 0
            default:
                break
            }
        }
        flush()
        return peers
    }
}

enum ByteFormat {
    static func string(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[unit])
    }
}
