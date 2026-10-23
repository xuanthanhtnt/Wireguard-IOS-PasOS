// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS

import Foundation
import NetworkExtension

/// Auto-tunnel settings of one tunnel, turned into iOS on-demand rules.
struct OnDemandOptions: Codable, Equatable {
    enum WiFiMode: String, Codable, CaseIterable, Identifiable {
        case off
        case always
        case onlyListed
        case exceptListed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: return "Không bật trên Wi-Fi"
            case .always: return "Mọi mạng Wi-Fi"
            case .onlyListed: return "Chỉ các mạng trong danh sách"
            case .exceptListed: return "Trừ các mạng tin cậy"
            }
        }
    }

    var enabled = false
    var wifiMode: WiFiMode = .exceptListed
    /// SSIDs (exact names; iOS does not support wildcards here).
    var ssids: [String] = []
    var cellular = true
    /// Any other network (Ethernet on iPad, ...).
    var otherNetworks = true

    var rules: [NEOnDemandRule] {
        var rules = [NEOnDemandRule]()
        let names = ssids.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        switch wifiMode {
        case .off:
            rules.append(Self.disconnect(.wiFi))
        case .always:
            rules.append(Self.connect(.wiFi))
        case .onlyListed:
            if !names.isEmpty {
                let rule = Self.connect(.wiFi)
                rule.ssidMatch = names
                rules.append(rule)
            }
            rules.append(Self.disconnect(.wiFi))
        case .exceptListed:
            if !names.isEmpty {
                let rule = Self.disconnect(.wiFi)
                rule.ssidMatch = names
                rules.append(rule)
            }
            rules.append(Self.connect(.wiFi))
        }
        rules.append(cellular ? Self.connect(.cellular) : Self.disconnect(.cellular))
        rules.append(otherNetworks ? Self.connect(.any) : Self.disconnect(.any))
        return rules
    }

    var summary: String {
        guard enabled else { return "Tắt" }
        var parts = [String]()
        switch wifiMode {
        case .off: break
        case .always: parts.append("Wi-Fi")
        case .onlyListed: parts.append("Wi-Fi: \(ssids.joined(separator: ", "))")
        case .exceptListed: parts.append(ssids.isEmpty ? "Wi-Fi" : "Wi-Fi trừ \(ssids.joined(separator: ", "))")
        }
        if cellular { parts.append("Di động") }
        if otherNetworks { parts.append("Mạng khác") }
        return parts.isEmpty ? "Bật (không có mạng nào)" : parts.joined(separator: " • ")
    }

    private static func connect(_ type: NEOnDemandRuleInterfaceType) -> NEOnDemandRule {
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = type
        return rule
    }

    private static func disconnect(_ type: NEOnDemandRuleInterfaceType) -> NEOnDemandRule {
        let rule = NEOnDemandRuleDisconnect()
        rule.interfaceTypeMatch = type
        return rule
    }
}
