// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS — server watchdog models (port of the Android xt/XtModels.kt)

import Foundation

/// How the watchdog checks whether a paused server has come back.
enum ProbeMethod: String, Codable, CaseIterable, Identifiable {
    /// Start a WireGuard handshake and wait for the answer. Most reliable.
    case handshake = "HANDSHAKE"
    /// ICMP ping (or TCP connect when a port is set) to the server.
    case ping = "PING"

    var id: String { rawValue }
}

/// WG VPN watchdog settings, stored as one JSON document in the app group.
struct XtSettings: Codable, Equatable {
    var ipWatchEnabled = true
    var ipWatchIntervalSec = XtSettings.defaultIpWatchIntervalSec
    var useDoh = true
    var autoPauseEnabled = true
    var pauseAfterSec = XtSettings.defaultPauseAfterSec
    var probeIntervalSec = XtSettings.defaultProbeIntervalSec
    var probeMethod: ProbeMethod = .handshake
    var probeTcpPort = 0
    var trialTimeoutSec = XtSettings.defaultTrialTimeoutSec
    var suspendKillSwitch = true
    var notifyEvents = true
    /// tunnelId -> DDNS hostname or http(s) URL returning the server IP.
    var ipSources: [String: String] = [:]

    static let defaultIpWatchIntervalSec = 120
    static let defaultPauseAfterSec = 90
    static let defaultProbeIntervalSec = 180
    static let defaultTrialTimeoutSec = 20

    static let ipWatchIntervalOptions = [60, 120, 300, 600, 900, 1800]
    static let pauseAfterOptions = [45, 60, 90, 120, 180, 300]
    static let probeIntervalOptions = [60, 120, 180, 300, 600, 900]
    static let trialTimeoutOptions = [10, 15, 20, 30, 45]

    enum CodingKeys: String, CodingKey {
        case ipWatchEnabled, ipWatchIntervalSec, useDoh, autoPauseEnabled, pauseAfterSec
        case probeIntervalSec, probeMethod, probeTcpPort, trialTimeoutSec, suspendKillSwitch
        case notifyEvents, ipSources
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = XtSettings()
        ipWatchEnabled = (try? c.decode(Bool.self, forKey: .ipWatchEnabled)) ?? d.ipWatchEnabled
        ipWatchIntervalSec = ((try? c.decode(Int.self, forKey: .ipWatchIntervalSec)) ?? d.ipWatchIntervalSec).clamped(30, 86_400)
        useDoh = (try? c.decode(Bool.self, forKey: .useDoh)) ?? d.useDoh
        autoPauseEnabled = (try? c.decode(Bool.self, forKey: .autoPauseEnabled)) ?? d.autoPauseEnabled
        pauseAfterSec = ((try? c.decode(Int.self, forKey: .pauseAfterSec)) ?? d.pauseAfterSec).clamped(20, 3_600)
        probeIntervalSec = ((try? c.decode(Int.self, forKey: .probeIntervalSec)) ?? d.probeIntervalSec).clamped(30, 86_400)
        probeMethod = (try? c.decode(ProbeMethod.self, forKey: .probeMethod)) ?? d.probeMethod
        probeTcpPort = ((try? c.decode(Int.self, forKey: .probeTcpPort)) ?? 0).clamped(0, 65_535)
        trialTimeoutSec = ((try? c.decode(Int.self, forKey: .trialTimeoutSec)) ?? d.trialTimeoutSec).clamped(5, 120)
        suspendKillSwitch = (try? c.decode(Bool.self, forKey: .suspendKillSwitch)) ?? d.suspendKillSwitch
        notifyEvents = (try? c.decode(Bool.self, forKey: .notifyEvents)) ?? d.notifyEvents
        let sources = (try? c.decode([String: String].self, forKey: .ipSources)) ?? [:]
        ipSources = sources.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// A tunnel the watchdog has paused because its server stopped answering. Persisted.
struct PauseState: Codable, Equatable {
    var tunnelId: String
    var tunnelName: String
    var pausedAt: Date
    /// Kill switch mode: iOS cannot let traffic bypass the tunnel, so the VPN was switched off.
    /// Otherwise the tunnel stays up in "passthrough" (routes nothing) while it waits.
    var tunnelStopped: Bool
    /// The app turned the tunnel's on-demand rules off while it is stopped (restored on resume).
    var onDemandSuspended: Bool = false
    /// peer public key -> server IPs that were in use when the tunnel was paused.
    var knownIps: [String: [String]] = [:]
    var probeCount: Int = 0
    var lastProbeAt: Date?
}

enum XtEventType: String, Codable {
    case ipChanged = "IP_CHANGED"
    case ipUpdated = "IP_UPDATED"
    case ipCheckFailed = "IP_CHECK_FAILED"
    case paused = "PAUSED"
    case resumed = "RESUMED"
    case pauseCancelled = "PAUSE_CANCELLED"
    case info = "INFO"
}

/// One line of the watchdog history shown in the app.
struct XtEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    var at: Date
    var type: XtEventType
    var message: String

    static let maxEvents = 60
}

/// Result of looking up the server address for one peer.
struct EndpointStatus: Codable, Identifiable, Equatable {
    var tunnelId: String
    var tunnelName: String
    /// Base64 public key of the peer.
    var peerKey: String
    /// Host part of the configured endpoint (hostname or IP literal).
    var endpointHost: String
    /// What was looked up: endpoint hostname, configured DDNS name or URL. nil = nothing to watch.
    var source: String?
    var currentIps: [String]
    var resolvedIps: [String]
    var checkedAt: Date
    var error: String?
    /// The tunnel cannot reach its server and public DoH points elsewhere while local DNS still
    /// returns the old address.
    var staleLocalDns = false

    var id: String { "\(tunnelId)/\(peerKey)" }

    var changed: Bool {
        source != nil && !currentIps.isEmpty && !resolvedIps.isEmpty &&
            (staleLocalDns || currentIps.allSatisfy { !resolvedIps.contains($0) })
    }
}

/// Live state of the watchdog in the extension, published for the app.
struct WatchdogRuntime: Codable, Equatable {
    var tunnelId: String?
    var tunnelName: String?
    var passthrough = false
    var nextProbeAt: Date?
    var lastIpCheckAt: Date?
    var checking = false
    var endpoints: [EndpointStatus] = []
    var failingSince: Date?
    var failingTunnelName: String?
    var updatedAt = Date()
}

/// Short-lived endpoint pins: after an IP change was detected, the next tunnel start uses the new
/// IP directly instead of a DNS answer that may still be cached.
struct EndpointPins: Codable, Equatable {
    /// peer public key -> "ip:port"
    var endpoints: [String: String]
    var expiresAt: Date

    static let ttl: TimeInterval = 15 * 60
}

extension Int {
    func clamped(_ low: Int, _ high: Int) -> Int { Swift.min(Swift.max(self, low), high) }
}

/// Formatting helpers shared by notifications, events and the UI.
enum XtFormat {
    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) giây" }
        return "\(seconds / 60) phút"
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "vi_VN")
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm:ss" : "dd/MM HH:mm"
        return f.string(from: date)
    }
}
