// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS
//
// App side of the server watchdog: settings, history, and the parts iOS does not let the extension
// do itself (saving rewritten configurations, probing a server while the VPN is switched off in
// kill switch mode).

import BackgroundTasks
import Foundation
import SwiftUI

@MainActor
final class WatchdogController: ObservableObject {
    @Published private(set) var settings = XtSettings()
    @Published private(set) var events: [XtEvent] = []
    @Published private(set) var pause: PauseState?
    @Published private(set) var runtime: WatchdogRuntime?
    @Published private(set) var appEndpoints: [EndpointStatus] = []
    @Published private(set) var checking = false
    @Published var lastError: XtStore.LastError?

    private let store = XtStore.shared
    private weak var tunnels: TunnelsManager?
    private var reconciling = false

    init() {
        reloadFromStore()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), observer,
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let controller = Unmanaged<WatchdogController>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in controller.storeChanged() }
            },
            WGVPNKeys.darwinChanged as CFString, nil, .deliverImmediately
        )
    }

    func attach(_ tunnels: TunnelsManager) {
        self.tunnels = tunnels
    }

    private func storeChanged() {
        reloadFromStore()
        Task { await reconcile() }
    }

    func reloadFromStore() {
        let newSettings = store.settings()
        if newSettings != settings { settings = newSettings }
        let newEvents = store.events()
        if newEvents != events { events = newEvents }
        let newPause = store.pause()
        if newPause != pause { pause = newPause }
        let newRuntime = store.runtime()
        if newRuntime != runtime { runtime = newRuntime }
        lastError = store.lastError()
    }

    // MARK: - Settings

    func update(_ change: (inout XtSettings) -> Void) {
        var copy = settings
        change(&copy)
        guard copy != settings else { return }
        settings = copy
        store.updateSettings(change)
    }

    func setIpSource(_ tunnel: TunnelItem, source: String?) {
        store.setIpSource(tunnelId: tunnel.tunnelId, source: source)
        reloadFromStore()
    }

    func clearHistory() {
        store.clearEvents()
        reloadFromStore()
    }

    // MARK: - Actions

    /// "Kiểm tra ngay": IP check (or a server probe while paused).
    func checkNow() async {
        guard let tunnels = tunnels else { return }
        if let pause = pause, pause.tunnelStopped {
            await probeStoppedPause(force: true)
            return
        }
        if let active = tunnels.activeTunnel, active.status == .connected || active.status == .reasserting {
            checking = true
            _ = await active.send(.checkNow)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            checking = false
            reloadFromStore()
            return
        }
        // Nothing connected: look every tunnel up from here and fix static ones
        checking = true
        defer { checking = false }
        let path = await PhysicalNetworkMonitor.currentPath()
        var statuses = [EndpointStatus]()
        for item in tunnels.tunnels {
            guard let config = item.configuration else { continue }
            let pins = store.activePins(tunnelId: item.tunnelId)
            let inspection = await XtInspector.inspect(
                config: config, tunnelId: item.tunnelId, tunnelName: item.name, settings: settings,
                currentIps: { peer in
                    if let endpoint = peer.endpoint, endpoint.hasHostAsIPAddress() { return [XtIp.normalize(endpoint.hostString)] }
                    if let pinned = pins[peer.publicKey.base64Key], let host = XtIp.splitEndpoint(pinned)?.host { return [XtIp.normalize(host)] }
                    return []
                },
                failing: false, path: path
            )
            statuses += inspection.statuses
            for status in inspection.statuses where status.source != nil && status.error != nil {
                store.addEvent(.ipCheckFailed, "\(item.name): không tra cứu được \(status.source ?? "") (\(status.error ?? "-"))")
            }
            let staticChanges = inspection.changes.filter { $0.staticEndpoint }
            if !staticChanges.isEmpty {
                var endpoints = [String: String]()
                for change in staticChanges {
                    endpoints[change.peerKey] = change.endpointString
                    store.addEvent(.ipChanged, "\(item.name): \(change.source) đổi IP \(change.oldIps.joined(separator: ", ")) → \(change.newIp)")
                }
                do {
                    try await tunnels.applyEndpointRewrites(item, endpoints: endpoints)
                    store.addEvent(.ipUpdated, "\(item.name): đã lưu IP mới vào cấu hình")
                } catch {
                    XtLog.error("Could not save new endpoint for \(item.name): \(error.localizedDescription)")
                }
            }
            let dynamic = inspection.changes.filter { !$0.staticEndpoint }
            if !dynamic.isEmpty {
                var endpoints = [String: String]()
                dynamic.forEach { endpoints[$0.peerKey] = $0.endpointString }
                store.putPins(tunnelId: item.tunnelId, endpoints: endpoints)
            }
        }
        appEndpoints = statuses
        reloadFromStore()
    }

    /// "Kết nối lại ngay" while paused.
    func resumeNow() async {
        guard let pause = pause, let tunnels = tunnels else { return }
        if pause.tunnelStopped {
            await startTrial(pause)
        } else if let item = tunnels.tunnel(id: pause.tunnelId) {
            _ = await item.send(.resumeNow)
        }
    }

    /// "Hủy chờ": stop waiting for the server and leave the VPN off.
    func cancelPause() async {
        guard let pause = pause, let tunnels = tunnels else { return }
        if pause.tunnelStopped {
            store.setPause(nil)
            XtNotifier.removePaused()
            store.addEvent(.pauseCancelled, "Đã hủy chờ máy chủ")
            reloadFromStore()
            await restoreOnDemandIfNeeded()
        } else if let item = tunnels.tunnel(id: pause.tunnelId), item.isActive {
            _ = await item.send(.cancelPause)
        } else {
            store.setPause(nil)
            XtNotifier.removePaused()
            reloadFromStore()
        }
    }

    // MARK: - Reconcile (called on launch, foreground and store changes)

    func reconcile() async {
        guard let tunnels = tunnels, !reconciling else { return }
        reconciling = true
        defer { reconciling = false }

        // 1. Static endpoints the extension moved: write them into the saved configuration when the
        //    tunnel is not running (saving a running configuration would restart it).
        for (tunnelId, endpoints) in store.rewrites() {
            guard let item = tunnels.tunnel(id: tunnelId) else {
                store.removeRewrites(tunnelId: tunnelId, peerKeys: Array(endpoints.keys))
                continue
            }
            guard !item.isActive else { continue }
            do {
                try await tunnels.applyEndpointRewrites(item, endpoints: endpoints)
                store.removeRewrites(tunnelId: tunnelId, peerKeys: Array(endpoints.keys))
                XtLog.info("Saved new endpoint(s) into \(item.name)")
            } catch {
                XtLog.error("Could not save endpoint rewrite for \(item.name): \(error.localizedDescription)")
            }
        }

        // 2. Kill switch pause: keep iOS on-demand from bringing a dead tunnel back in a loop
        if let pause = store.pause(), pause.tunnelStopped, let item = tunnels.tunnel(id: pause.tunnelId) {
            if item.manager.isOnDemandEnabled && !item.isActive {
                do {
                    try await tunnels.setOnDemandSuspended(item, suspended: true)
                    store.updatePause { $0.onDemandSuspended = true }
                    XtLog.info("Suspended on-demand of \(item.name) while its server is down")
                } catch {
                    XtLog.error("Could not suspend on-demand: \(error.localizedDescription)")
                }
            }
        } else {
            await restoreOnDemandIfNeeded()
        }
        reloadFromStore()
    }

    private func restoreOnDemandIfNeeded() async {
        guard let tunnels = tunnels, store.pause() == nil else { return }
        for item in tunnels.tunnels where item.onDemandSuspended {
            do {
                try await tunnels.setOnDemandSuspended(item, suspended: false)
                XtLog.info("Restored on-demand of \(item.name)")
            } catch {
                XtLog.error("Could not restore on-demand: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Kill switch pause: probing from the app

    /// Checks a server whose VPN was switched off (kill switch mode) and starts a trial when it may be back.
    func probeStoppedPause(force: Bool) async {
        guard var pause = store.pause(), pause.tunnelStopped, let tunnels = tunnels,
              let item = tunnels.tunnel(id: pause.tunnelId) else { return }
        guard !item.isActive else { return }
        let s = store.settings()
        if !force, let last = pause.lastProbeAt, Date().timeIntervalSince(last) < TimeInterval(s.probeIntervalSec) { return }
        let path = await PhysicalNetworkMonitor.currentPath()
        guard path.satisfied else { return }
        checking = true
        defer { checking = false }

        pause.probeCount += 1
        pause.lastProbeAt = Date()
        store.setPause(pause)

        var shouldTry = force || s.probeMethod == .handshake
        if let config = item.configuration {
            let inspection = await XtInspector.inspect(
                config: config, tunnelId: item.tunnelId, tunnelName: item.name, settings: s,
                currentIps: { peer in
                    if let endpoint = peer.endpoint, endpoint.hasHostAsIPAddress() { return [XtIp.normalize(endpoint.hostString)] }
                    return []
                },
                knownIps: pause.knownIps, failing: true, path: path
            )
            appEndpoints = inspection.statuses
            if !inspection.changes.isEmpty {
                shouldTry = true
                var rewrites = [String: String]()
                var pins = [String: String]()
                for change in inspection.changes {
                    store.addEvent(.ipChanged, "\(item.name): \(change.source) đổi IP \(change.oldIps.joined(separator: ", ")) → \(change.newIp)")
                    if change.staticEndpoint { rewrites[change.peerKey] = change.endpointString } else { pins[change.peerKey] = change.endpointString }
                }
                if !rewrites.isEmpty {
                    try? await tunnels.applyEndpointRewrites(item, endpoints: rewrites)
                    store.addEvent(.ipUpdated, "\(item.name): đã lưu IP mới vào cấu hình")
                }
                store.putPins(tunnelId: item.tunnelId, endpoints: pins)
            }
            if !shouldTry {
                let targets = XtIp.unique((inspection.statuses.flatMap { $0.resolvedIps.isEmpty ? $0.currentIps : $0.resolvedIps } +
                    pause.knownIps.values.flatMap { $0 }).filter { XtIp.isIPLiteral($0) })
                for ip in targets {
                    let reachable: Bool
                    if (1...65_535).contains(s.probeTcpPort) {
                        reachable = await XtNetwork.tcpReachable(ip, port: s.probeTcpPort, path: path)
                    } else {
                        reachable = await XtNetwork.ping(ip, path: path)
                    }
                    if reachable {
                        shouldTry = true
                        break
                    }
                }
            }
        }
        reloadFromStore()
        guard shouldTry else { return }
        await startTrial(pause)
    }

    private func startTrial(_ pause: PauseState) async {
        guard let tunnels = tunnels, let item = tunnels.tunnel(id: pause.tunnelId) else { return }
        do {
            try await tunnels.connect(item, source: .trial)
        } catch {
            XtLog.error("Trial start failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Background refresh (kill switch pause only)

    static func registerBackgroundTask(tunnels: TunnelsManager, controller: WatchdogController) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: WGVPNKeys.backgroundTaskId, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let work = Task { @MainActor in
                await tunnels.reload()
                await controller.probeStoppedPause(force: false)
                await controller.reconcile()
                controller.scheduleBackgroundRefresh()
                refresh.setTaskCompleted(success: true)
            }
            refresh.expirationHandler = { work.cancel() }
        }
    }

    func scheduleBackgroundRefresh() {
        guard let pause = store.pause(), pause.tunnelStopped else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: WGVPNKeys.backgroundTaskId)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: WGVPNKeys.backgroundTaskId)
        request.earliestBeginDate = Date().addingTimeInterval(TimeInterval(max(300, store.settings().probeIntervalSec)))
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            XtLog.debug("Background refresh not scheduled: \(error.localizedDescription)")
        }
    }
}
