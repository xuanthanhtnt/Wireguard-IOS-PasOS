// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS

import Foundation

/// Shared container used by the app and the packet tunnel extension.
enum AppGroup {
    static let identifier: String = {
        // Re-signing tools (AltStore / SideStore) rewrite app group names and list them here
        if let groups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String],
           let first = groups.first, !first.isEmpty {
            return first
        }
        if let id = Bundle.main.object(forInfoDictionaryKey: "WGAppGroupID") as? String,
           !id.isEmpty, !id.contains("$(") {
            return id
        }
        return "group.com.wgvpn.app"
    }()

    /// True when the app group container is really available (both processes can share files).
    static var isShared: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) != nil
    }

    static let containerURL: URL = {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return url
        }
        // No app group entitlement (some re-signed builds): fall back to a private directory
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("WGVPN", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}

/// Keys and constants shared by the app and the extension.
enum WGVPNKeys {
    static let wgQuickConfig = "WgQuickConfig"
    static let tunnelId = "WGVPNTunnelID"
    static let tunnelName = "WGVPNTunnelName"
    static let onDemand = "WGVPNOnDemand"
    static let onDemandSuspended = "WGVPNOnDemandSuspended"
    static let encryptedDNS = "WGVPNEncryptedDNS"
    /// Key in the start options dictionary telling the extension who started it.
    static let startSource = "wgvpnSource"

    static let darwinChanged = "com.wgvpn.xt.changed"
    static let backgroundTaskId = "com.wgvpn.app.watchdog"
}

/// Who asked the extension to start.
enum StartSource: String {
    /// The user, from the app UI or a URL.
    case app
    /// The server watchdog testing whether a paused server is back.
    case trial
    /// A Shortcuts / Siri action.
    case intent
}

/// Commands the app sends to the running extension (NETunnelProviderSession.sendProviderMessage).
enum XtCommand: String, Codable {
    case runtime
    case checkNow
    case resumeNow
    case cancelPause
}

struct XtCommandMessage: Codable {
    var command: XtCommand
}

/// Errors the extension reports when it cannot start.
enum TunnelStartError: String, Error, LocalizedError {
    case invalidConfiguration
    case dnsResolutionFailure
    case couldNotStartBackend
    case couldNotDetermineFileDescriptor
    case couldNotSetNetworkSettings

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Cấu hình tunnel không hợp lệ"
        case .dnsResolutionFailure: return "Không phân giải được tên miền máy chủ"
        case .couldNotStartBackend: return "Không khởi động được WireGuard"
        case .couldNotDetermineFileDescriptor: return "Không tìm thấy giao diện tunnel"
        case .couldNotSetNetworkSettings: return "Không áp dụng được cài đặt mạng"
        }
    }
}
