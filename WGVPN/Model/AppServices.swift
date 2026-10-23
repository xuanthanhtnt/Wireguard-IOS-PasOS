// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS

import Foundation
import LocalAuthentication
import SwiftUI

enum AppInfo {
    static let repository = "xuanthanhtnt/Wireguard-IOS-PasOS"
    static let androidRepository = "xuanthanhtnt/Wireguard"
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }
    static var releasesURL: URL { URL(string: "https://github.com/\(repository)/releases")! }
    static var sourceURL: URL { URL(string: "https://github.com/\(repository)")! }
    static var issuesURL: URL { URL(string: "https://github.com/\(repository)/issues")! }
}

/// Looks for a newer release on GitHub (same scheme as the Android app: v1.0.<build>).
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Equatable {
        var version: String
        var pageURL: URL
        var ipaURL: URL?
        var notes: String
    }

    @Published private(set) var latest: Release?
    @Published private(set) var checking = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastCheck: Date?

    private let lastCheckKey = "update.lastCheck"
    private let notifiedKey = "update.notifiedVersion"

    var updateAvailable: Bool {
        guard let latest = latest else { return false }
        return Self.compare(latest.version, AppInfo.version) == .orderedDescending
    }

    func checkIfDue() async {
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        await check()
        if updateAvailable, let version = latest?.version,
           UserDefaults.standard.string(forKey: notifiedKey) != version {
            UserDefaults.standard.set(version, forKey: notifiedKey)
            XtNotifier.showUpdate(version: version)
        }
    }

    func check() async {
        checking = true
        lastError = nil
        defer { checking = false }
        do {
            let url = URL(string: "https://api.github.com/repos/\(AppInfo.repository)/releases/latest")!
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("WG VPN iOS", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 404 {
                lastError = "Chưa có bản phát hành nào"
                return
            }
            guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.cannotParseResponse) }
            let tag = (json["tag_name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? AppInfo.releasesURL
            let assets = json["assets"] as? [[String: Any]] ?? []
            let ipa = assets.compactMap { asset -> URL? in
                guard let name = asset["name"] as? String, name.lowercased().hasSuffix(".ipa") else { return nil }
                return (asset["browser_download_url"] as? String).flatMap(URL.init(string:))
            }.first
            latest = Release(version: tag, pageURL: page, ipaURL: ipa, notes: json["body"] as? String ?? "")
            lastCheck = Date()
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        } catch {
            lastError = "Không kiểm tra được: \(error.localizedDescription)"
        }
    }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }
        let right = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(left.count, right.count) {
            let l = i < left.count ? left[i] : 0
            let r = i < right.count ? right[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

/// Face ID / Touch ID / passcode lock (the Android PIN lock).
@MainActor
final class AppLock: ObservableObject {
    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "appLock.enabled") }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "appLock.enabled")
        }
    }
    @Published private(set) var locked = false
    private var backgroundedAt: Date?

    init() {
        locked = enabled
    }

    var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "mật mã"
        }
    }

    var canUse: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func didEnterBackground() {
        backgroundedAt = Date()
    }

    func willEnterForeground() {
        guard enabled else { return }
        if let at = backgroundedAt, Date().timeIntervalSince(at) > 30 { locked = true }
    }

    func unlock() async {
        guard locked else { return }
        let context = LAContext()
        context.localizedCancelTitle = "Hủy"
        do {
            if try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Mở khóa WG VPN") {
                locked = false
            }
        } catch {
            XtLog.debug("Unlock failed: \(error.localizedDescription)")
        }
    }

    func setEnabled(_ value: Bool) async -> Bool {
        if value {
            let context = LAContext()
            do {
                guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Bật khóa ứng dụng") else { return false }
            } catch {
                return false
            }
        }
        enabled = value
        if !value { locked = false }
        return true
    }
}
