// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS

import Foundation

/// JSON files in the app group, shared by the app and the extension.
/// Every write is done under an inter-process file lock and announced with a Darwin notification.
final class XtStore {
    static let shared = XtStore()

    private enum File: String {
        case settings = "xt-settings.json"
        case pause = "xt-pause.json"
        case events = "xt-events.json"
        case runtime = "xt-runtime.json"
        case pins = "xt-pins.json"
        case rewrites = "xt-rewrites.json"
        case lastError = "xt-last-error.json"
    }

    private let directory = AppGroup.containerURL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    private var lockPath: String { directory.appendingPathComponent("xt.lock").path }

    // MARK: - Settings

    func settings() -> XtSettings { read(.settings, as: XtSettings.self) ?? XtSettings() }

    func updateSettings(_ change: (inout XtSettings) -> Void) {
        locked {
            var current = settings()
            change(&current)
            write(.settings, current)
        }
        notifyChanged()
    }

    func setIpSource(tunnelId: String, source: String?) {
        updateSettings { s in
            let clean = source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if clean.isEmpty {
                s.ipSources.removeValue(forKey: tunnelId)
            } else {
                s.ipSources[tunnelId] = clean
            }
        }
    }

    // MARK: - Pause state

    func pause() -> PauseState? { read(.pause, as: PauseState.self) }

    func setPause(_ state: PauseState?) {
        locked { write(.pause, state) }
        notifyChanged()
    }

    func updatePause(_ change: (inout PauseState) -> Void) {
        locked {
            guard var current = pause() else { return }
            change(&current)
            write(.pause, current)
        }
        notifyChanged()
    }

    // MARK: - Events

    func events() -> [XtEvent] { read(.events, as: [XtEvent].self) ?? [] }

    func addEvent(_ type: XtEventType, _ message: String) {
        XtLog.info("XT event \(type.rawValue): \(message)")
        locked {
            let updated = [XtEvent(at: Date(), type: type, message: message)] + events()
            write(.events, Array(updated.prefix(XtEvent.maxEvents)))
        }
        notifyChanged()
    }

    func clearEvents() {
        locked { write(.events, [XtEvent]?.none) }
        notifyChanged()
    }

    // MARK: - Runtime (written by the extension)

    func runtime() -> WatchdogRuntime? { read(.runtime, as: WatchdogRuntime.self) }

    func setRuntime(_ runtime: WatchdogRuntime?) {
        locked { write(.runtime, runtime) }
        notifyChanged()
    }

    // MARK: - Endpoint pins (hostname endpoints, short-lived)

    func activePins(tunnelId: String) -> [String: String] {
        guard let all = read(.pins, as: [String: EndpointPins].self), let entry = all[tunnelId] else { return [:] }
        return entry.expiresAt > Date() ? entry.endpoints : [:]
    }

    func putPins(tunnelId: String, endpoints: [String: String]) {
        guard !endpoints.isEmpty else { return }
        locked {
            var all = read(.pins, as: [String: EndpointPins].self) ?? [:]
            let previous = all[tunnelId].flatMap { $0.expiresAt > Date() ? $0.endpoints : nil } ?? [:]
            all[tunnelId] = EndpointPins(
                endpoints: previous.merging(endpoints) { _, new in new },
                expiresAt: Date().addingTimeInterval(EndpointPins.ttl)
            )
            all = all.filter { $0.value.expiresAt > Date() }
            write(.pins, all)
        }
    }

    func clearPins(tunnelId: String) {
        locked {
            var all = read(.pins, as: [String: EndpointPins].self) ?? [:]
            guard all.removeValue(forKey: tunnelId) != nil else { return }
            write(.pins, all)
        }
    }

    // MARK: - Static endpoint rewrites (applied to the saved configuration by the app)

    /// tunnelId -> (peer public key -> "ip:port")
    func rewrites() -> [String: [String: String]] { read(.rewrites, as: [String: [String: String]].self) ?? [:] }

    func addRewrites(tunnelId: String, endpoints: [String: String]) {
        guard !endpoints.isEmpty else { return }
        locked {
            var all = rewrites()
            all[tunnelId, default: [:]].merge(endpoints) { _, new in new }
            write(.rewrites, all)
        }
        notifyChanged()
    }

    func removeRewrites(tunnelId: String, peerKeys: [String]) {
        locked {
            var all = rewrites()
            guard var entry = all[tunnelId] else { return }
            peerKeys.forEach { entry.removeValue(forKey: $0) }
            all[tunnelId] = entry.isEmpty ? nil : entry
            write(.rewrites, all)
        }
    }

    // MARK: - Last start error (shown by the app)

    struct LastError: Codable {
        var tunnelId: String
        var message: String
        var at: Date
    }

    func lastError() -> LastError? { read(.lastError, as: LastError.self) }

    func setLastError(_ error: LastError?) {
        locked { write(.lastError, error) }
        notifyChanged()
    }

    // MARK: - Plumbing

    private func url(_ file: File) -> URL { directory.appendingPathComponent(file.rawValue) }

    private func read<T: Decodable>(_ file: File, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: url(file)), !data.isEmpty else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ file: File, _ value: T?) {
        let target = url(file)
        guard let value = value else {
            try? FileManager.default.removeItem(at: target)
            return
        }
        guard let data = try? encoder.encode(value) else { return }
        do {
            try data.write(to: target, options: [.atomic])
        } catch {
            XtLog.error("XtStore: cannot write \(file.rawValue): \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func locked<R>(_ body: () throws -> R) rethrows -> R {
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer {
            if fd >= 0 {
                flock(fd, LOCK_UN)
                close(fd)
            }
        }
        return try body()
    }

    func notifyChanged() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(WGVPNKeys.darwinChanged as CFString),
            nil, nil, true
        )
    }
}
