// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS
//
// Server watchdog running inside the packet tunnel extension. Port of the Android
// ServerWatchdogCoordinator:
//
// 1. Server IP watch – periodically looks up the server hostname (or the DDNS name / URL attached to
//    a static-IP tunnel) over the physical network. When the server came back with another public IP,
//    the peers are moved to the new address in place, without tearing the tunnel down. For static-IP
//    configs the saved configuration is rewritten with the new IP.
// 2. Outage auto-pause – when the tunnel cannot complete a handshake for a while although the device
//    has working internet (checked around the tunnel), the server is considered down (e.g. power cut).
//    iOS cannot keep monitoring once a VPN is off, so the tunnel stays up in "passthrough": it routes
//    nothing, the device uses its normal internet connection, and the watchdog keeps probing the
//    server. As soon as it answers again, routing is restored. With kill switch (includeAllNetworks)
//    iOS forces all traffic into the tunnel, so the VPN is switched off instead and the app takes over.

import Foundation
import Network
import NetworkExtension

final class ServerWatchdog {
    enum StartMode {
        /// Normal start (may restore a passthrough pause after the extension was restarted).
        case normal
        /// Started to test whether a server paused in kill-switch mode is back.
        case trial
        /// Started by the user while paused: the pause has been cleared.
        case userStart
    }

    struct Prepared {
        var base: TunnelConfiguration
        var overrides: [String: String]
    }

    private enum OutageOutcome {
        case none
        case ipUpdated
        case paused
        case alive
    }

    private static let rejectAfterTime: TimeInterval = 180

    private weak var provider: NEPacketTunnelProvider?
    private let adapter: WireGuardAdapter
    let tunnelId: String
    let tunnelName: String
    private let killSwitch: Bool
    private let baseConfig: TunnelConfiguration
    /// peer public key -> "ip:port" currently forced for that peer.
    private var overrides: [String: String]
    private var mode: StartMode

    private let store = XtStore.shared
    private let network = PhysicalNetworkMonitor()
    private let kicker = Kicker()
    private let lock = NSLock()
    private var loopTask: Task<Void, Never>?

    // Shared with other threads, guarded by `lock`
    private var sharedPause: PauseState?
    private var sharedRuntime = WatchdogRuntime()
    private var manualIpCheck = false
    private var probeRequested = false
    private var forcedTrial = false
    private var cancelRequested = false
    private var resetFailingRequested = false
    private var asleep = false
    private var lastWakeAt = Date.distantPast
    private var lastProbeSignalAt = Date.distantPast

    // Loop only
    private var stopping = false
    private var failingSince: Date?
    private var recheckAfter = Date.distantPast
    private var nextIpCheckAt = Date()
    private var nextProbeAt = Date.distantFuture
    private let startedAt = Date()
    private var lastRxTotal: UInt64 = 0
    private var lastRxChangeAt = Date()
    private var txAtLastRxChange: UInt64 = 0
    private var lastTrialPinnedFromPublicDns = false
    private var reportedLookupErrors = Set<String>()
    private var lastPublished: Data?
    private var lastPublishedAt = Date.distantPast

    // MARK: - Setup

    /// Applies the rewrites and pins the watchdog left behind to a configuration about to start.
    static func prepare(config: TunnelConfiguration, tunnelId: String) -> Prepared {
        let store = XtStore.shared
        var base = config
        if let rewrites = store.rewrites()[tunnelId], !rewrites.isEmpty {
            // Static endpoints the watchdog moved earlier and the app has not saved yet
            base = XtInspector.applying(rewrites, to: config)
        }
        let hostnamePeers = Set(base.peers.compactMap { peer -> String? in
            guard let endpoint = peer.endpoint, !endpoint.hasHostAsIPAddress() else { return nil }
            return peer.publicKey.base64Key
        })
        // DNS caches may still return a server's old address for a while: use the detected one
        let overrides = store.activePins(tunnelId: tunnelId).filter { hostnamePeers.contains($0.key) }
        return Prepared(base: base, overrides: overrides)
    }

    /// Decides how this start relates to a pending pause, clearing it when the user takes over.
    static func startMode(tunnelId: String, source: StartSource?) -> StartMode {
        let store = XtStore.shared
        guard let pause = store.pause() else { return .normal }
        if pause.tunnelId != tunnelId {
            store.setPause(nil)
            store.addEvent(.pauseCancelled, "Tunnel được bật thủ công, kết thúc tạm ngắt")
            XtNotifier.removePaused()
            return .normal
        }
        switch source {
        case .app?, .intent?:
            store.setPause(nil)
            store.addEvent(.pauseCancelled, "Tunnel được bật thủ công, kết thúc tạm ngắt")
            XtNotifier.removePaused()
            return .userStart
        default:
            return pause.tunnelStopped ? .trial : .normal
        }
    }

    init(provider: NEPacketTunnelProvider, adapter: WireGuardAdapter, tunnelId: String, tunnelName: String,
         prepared: Prepared, killSwitch: Bool, mode: StartMode) {
        self.provider = provider
        self.adapter = adapter
        self.tunnelId = tunnelId
        self.tunnelName = tunnelName
        self.baseConfig = prepared.base
        self.overrides = prepared.overrides
        self.killSwitch = killSwitch
        self.mode = mode
        sharedRuntime.tunnelId = tunnelId
        sharedRuntime.tunnelName = tunnelName
    }

    var liveConfig: TunnelConfiguration { XtInspector.applying(overrides, to: baseConfig) }

    func start() {
        network.start { [weak self] _, new in
            guard let self = self, new.satisfied else { return }
            self.lock.lock()
            self.resetFailingRequested = true
            self.lock.unlock()
            self.signalProbe()
        }
        loopTask = Task.detached(priority: .utility) { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        loopTask?.cancel()
        kicker.kick()
        network.stop()
    }

    // MARK: - Commands from the app / system

    func handle(_ command: XtCommand) -> Data? {
        lock.lock()
        switch command {
        case .runtime:
            break
        case .checkNow:
            if sharedPause != nil { probeRequested = true } else { manualIpCheck = true }
        case .resumeNow:
            forcedTrial = true
            probeRequested = true
        case .cancelPause:
            cancelRequested = true
        }
        lock.unlock()
        if command != .runtime { kicker.kick() }
        return try? JSONEncoder().encode(snapshot())
    }

    func deviceWillSleep() {
        lock.lock()
        asleep = true
        lock.unlock()
    }

    func deviceDidWake() {
        lock.lock()
        asleep = false
        lastWakeAt = Date()
        resetFailingRequested = true
        lock.unlock()
        signalProbe()
        kicker.kick()
    }

    /// A new network or the device waking up: good moments to check a paused server.
    private func signalProbe() {
        lock.lock()
        defer { lock.unlock() }
        guard let pause = sharedPause else { return }
        let now = Date()
        guard now.timeIntervalSince(lastProbeSignalAt) > 60 else { return }
        guard now.timeIntervalSince(pause.lastProbeAt ?? .distantPast) > 60 else { return }
        lastProbeSignalAt = now
        probeRequested = true
        kicker.kick()
    }

    // MARK: - Loop

    private func run() async {
        if mode == .normal, let saved = store.pause(), saved.tunnelId == tunnelId, !saved.tunnelStopped {
            // The extension was restarted while waiting for the server: keep waiting
            if await setPassthrough(true) {
                setPause(saved)
                nextProbeAt = Date().addingTimeInterval(10)
                XtLog.info("XT: restored paused state for \(tunnelName)")
            }
        }
        nextIpCheckAt = Date().addingTimeInterval(20)
        publish(force: true)
        while !Task.isCancelled && !stopping {
            let settings = store.settings()
            await step(settings)
            if Task.isCancelled || stopping { break }
            publish()
            let wait: TimeInterval = pause != nil ? min(30, max(1, nextProbeAt.timeIntervalSinceNow)) : 5
            await kicker.wait(seconds: wait)
        }
    }

    private func step(_ s: XtSettings) async {
        if takeFlag(\.cancelRequested) {
            if pause != nil { cancelPauseAndStop() }
            return
        }
        if takeFlag(\.resetFailingRequested) {
            clearFailing()
        }
        if mode == .trial {
            mode = .normal
            await runTrialAfterStop(s)
            return
        }
        if pause != nil {
            let forced = takeFlag(\.forcedTrial)
            let requested = takeFlag(\.probeRequested)
            if forced || requested || Date() >= nextProbeAt {
                await probe(s, forced: forced)
                if pause != nil {
                    nextProbeAt = Date().addingTimeInterval(TimeInterval(s.probeIntervalSec))
                }
                publish(force: true)
            }
            return
        }
        let manual = takeFlag(\.manualIpCheck)
        if manual || (s.ipWatchEnabled && Date() >= nextIpCheckAt) {
            await checkTunnel(s, manual: manual)
            nextIpCheckAt = Date().addingTimeInterval(TimeInterval(max(30, s.ipWatchIntervalSec)))
        }
        await outageTick(s)
    }

    // MARK: - IP watch

    private func checkTunnel(_ s: XtSettings, manual: Bool) async {
        setChecking(true)
        defer { setChecking(false) }
        let path = await currentPath()
        let peers = await runtimePeers()
        let inspection = await inspect(s, peers: peers, failing: failingSince != nil, knownIps: [:], path: path)
        setEndpoints(inspection.statuses)
        reportLookupErrors(inspection.statuses, manual: manual)
        if !inspection.changes.isEmpty {
            await applyChanges(inspection.changes, s)
        } else if manual {
            XtLog.info("XT: manual IP check, no change for \(inspection.statuses.count) endpoint(s)")
        }
    }

    private func inspect(_ s: XtSettings, peers: [PeerRuntime]?, failing: Bool, knownIps: [String: [String]], path: PhysicalPath) async -> Inspection {
        var runtimeByKey = [String: PeerRuntime]()
        for peer in peers ?? [] { runtimeByKey[peer.publicKey] = peer }
        let forced = overrides
        return await XtInspector.inspect(
            config: baseConfig, tunnelId: tunnelId, tunnelName: tunnelName, settings: s,
            currentIps: { peer in
                let key = peer.publicKey.base64Key
                let override = forced[key].flatMap { XtIp.splitEndpoint($0)?.host }.flatMap { XtIp.isIPLiteral($0) ? XtIp.normalize($0) : nil }
                if let endpoint = peer.endpoint, endpoint.hasHostAsIPAddress() {
                    return [override ?? XtIp.normalize(endpoint.hostString)]
                }
                if let live = runtimeByKey[key]?.endpointIp { return [live] }
                if let override = override { return [override] }
                return []
            },
            knownIps: knownIps, failing: failing, path: path
        )
    }

    private func applyChanges(_ changes: [EndpointChange], _ s: XtSettings) async {
        for change in changes {
            let old = change.oldIps.isEmpty ? "?" : change.oldIps.joined(separator: ", ")
            store.addEvent(.ipChanged, "\(tunnelName): \(change.source) đổi IP \(old) → \(change.newIp)")
        }
        let staticChanges = changes.filter { $0.staticEndpoint }
        let dynamicChanges = changes.filter { !$0.staticEndpoint }
        if !staticChanges.isEmpty {
            var endpoints = [String: String]()
            staticChanges.forEach { endpoints[$0.peerKey] = $0.endpointString }
            store.addRewrites(tunnelId: tunnelId, endpoints: endpoints)
            store.addEvent(.ipUpdated, "\(tunnelName): đã lưu IP mới vào cấu hình")
        }
        if !dynamicChanges.isEmpty {
            var endpoints = [String: String]()
            dynamicChanges.forEach { endpoints[$0.peerKey] = $0.endpointString }
            store.putPins(tunnelId: tunnelId, endpoints: endpoints)
        }
        changes.forEach { overrides[$0.peerKey] = $0.endpointString }
        do {
            try await updateAdapterEndpoints()
            resetTrafficCounters()
            if s.notifyEvents, let first = changes.first {
                XtNotifier.showEvent(title: "Đã cập nhật IP máy chủ", body: "\(tunnelName) giờ kết nối tới \(first.newIp)")
            }
        } catch {
            XtLog.error("XT: could not move \(tunnelName) to the new IP: \(error)")
        }
    }

    private func reportLookupErrors(_ statuses: [EndpointStatus], manual: Bool) {
        for status in statuses {
            guard let source = status.source else { continue }
            if status.error == nil && !status.resolvedIps.isEmpty {
                reportedLookupErrors.remove(status.id)
                continue
            }
            if manual || reportedLookupErrors.insert(status.id).inserted {
                store.addEvent(.ipCheckFailed, "\(tunnelName): không tra cứu được \(source) (\(status.error ?? "-"))")
            }
        }
    }

    // MARK: - Outage detection

    private func outageTick(_ s: XtSettings) async {
        if isAsleep { return }
        guard let peers = await runtimePeers(), peers.contains(where: { $0.endpoint != nil }) else {
            clearFailing()
            return
        }
        guard evaluateFailing(peers) else {
            clearFailing()
            return
        }
        let now = Date()
        guard let since = failingSince else {
            failingSince = now
            recheckAfter = .distantPast
            setFailing(now)
            XtLog.info("XT: \(tunnelName) stopped answering")
            // A server that restarted often comes back with a new public IP: look right away
            nextIpCheckAt = now
            return
        }
        guard s.autoPauseEnabled else { return }
        guard now.timeIntervalSince(since) >= TimeInterval(s.pauseAfterSec) else { return }
        guard now >= recheckAfter else { return }
        recheckAfter = now.addingTimeInterval(30)
        // Right after waking up handshakes fail on purpose: not an outage
        guard now.timeIntervalSince(wakeTime) > 30 else { return }
        let path = await currentPath()
        guard path.satisfied else { return }
        // Only blame the server when the internet works fine around the tunnel
        guard await XtNetwork.internetReachable(path: path) else {
            XtLog.info("XT: handshake failing but no internet around the tunnel either; not pausing")
            return
        }
        switch await handleSuspectedOutage(s, path: path) {
        case .ipUpdated:
            failingSince = Date()
        case .paused, .alive:
            clearFailing()
        case .none:
            break
        }
    }

    /// No valid session while traffic is being sent, or nothing received for a while although the
    /// device keeps sending (a live server always answers data within ~10 s).
    private func evaluateFailing(_ peers: [PeerRuntime]) -> Bool {
        let now = Date()
        let rx = peers.reduce(UInt64(0)) { $0 + $1.rxBytes }
        let tx = peers.reduce(UInt64(0)) { $0 + $1.txBytes }
        if rx != lastRxTotal || tx < txAtLastRxChange {
            lastRxTotal = rx
            lastRxChangeAt = now
            txAtLastRxChange = tx
        }
        let sending = tx > txAtLastRxChange
        let newest = peers.compactMap { $0.lastHandshake }.max()
        let noSession: Bool
        if let newest = newest {
            noSession = now.timeIntervalSince(newest) > Self.rejectAfterTime
        } else {
            noSession = now.timeIntervalSince(startedAt) > 25
        }
        let silentWhileSending = now.timeIntervalSince(lastRxChangeAt) >= 30 && tx >= txAtLastRxChange + 250
        return (noSession && sending) || silentWhileSending
    }

    private func handleSuspectedOutage(_ s: XtSettings, path: PhysicalPath) async -> OutageOutcome {
        let peers = await runtimePeers()
        let inspection = await inspect(s, peers: peers, failing: true, knownIps: [:], path: path)
        setEndpoints(inspection.statuses)
        if !inspection.changes.isEmpty {
            await applyChanges(inspection.changes, s)
            return .ipUpdated
        }
        // Last check before blaming the server: an explicit fresh handshake
        if await confirmAlive(timeout: s.trialTimeoutSec) {
            XtLog.info("XT: \(tunnelName) answered a fresh handshake; not an outage")
            return .alive
        }
        return await pauseNow(s, inspection: inspection) ? .paused : .none
    }

    private func pauseNow(_ s: XtSettings, inspection: Inspection) async -> Bool {
        var known = [String: [String]]()
        for status in inspection.statuses {
            let ips = status.currentIps.isEmpty ? status.resolvedIps : status.currentIps
            if !ips.isEmpty { known[status.peerKey] = ips }
        }
        let now = Date()
        if killSwitch {
            guard s.suspendKillSwitch else {
                XtLog.info("XT: kill switch on and may not be suspended; keeping \(tunnelName) up")
                recheckAfter = now.addingTimeInterval(300)
                return false
            }
            let state = PauseState(tunnelId: tunnelId, tunnelName: tunnelName, pausedAt: now, tunnelStopped: true, knownIps: known)
            setPause(state, persist: true)
            store.addEvent(.paused, "\(tunnelName): máy chủ không phản hồi, đã tắt VPN (Kill switch) để giữ Internet")
            XtNotifier.showPaused(tunnelName: tunnelName, killSwitch: true)
            stopping = true
            publish(force: true)
            XtLog.info("XT: stopping \(tunnelName) (kill switch mode)")
            provider?.cancelTunnelWithError(nil)
            return true
        }
        guard await setPassthrough(true) else { return false }
        let state = PauseState(tunnelId: tunnelId, tunnelName: tunnelName, pausedAt: now, tunnelStopped: false, knownIps: known)
        setPause(state, persist: true)
        nextProbeAt = now.addingTimeInterval(TimeInterval(s.probeIntervalSec))
        store.addEvent(.paused, "\(tunnelName): máy chủ không phản hồi, đã tạm ngắt VPN để giữ Internet")
        XtNotifier.showPaused(tunnelName: tunnelName, killSwitch: false)
        publish(force: true)
        return true
    }

    // MARK: - While paused

    private func probe(_ s: XtSettings, forced: Bool) async {
        guard var current = pause else { return }
        let path = await currentPath()
        // The device itself is offline: nothing to learn about the server right now
        guard path.satisfied else { return }
        current.probeCount += 1
        current.lastProbeAt = Date()
        setPause(current, persist: true)
        setChecking(true)
        defer { setChecking(false) }

        // Alternate: when the last test used an address from public DNS and still failed, test with
        // the device's own DNS answer this time (LAN / split-horizon setups)
        let allowPublicDnsOverride = !lastTrialPinnedFromPublicDns
        let inspection = await inspect(s, peers: await runtimePeers(), failing: allowPublicDnsOverride, knownIps: current.knownIps, path: path)
        setEndpoints(inspection.statuses)

        let ipChanged = !inspection.changes.isEmpty
        if ipChanged {
            await applyChanges(inspection.changes, s)
            inspection.changes.forEach { current.knownIps[$0.peerKey] = [$0.newIp] }
            setPause(current, persist: true)
        }

        var shouldTry = forced || ipChanged || s.probeMethod == .handshake
        if !shouldTry {
            shouldTry = await serverAnswers(inspection, current, s, path)
        }
        guard shouldTry else { return }

        if await confirmAlive(timeout: s.trialTimeoutSec) {
            lastTrialPinnedFromPublicDns = false
            await resume(s)
        } else {
            // The pinned address did not answer either: next time test with plain DNS
            let hostnameKeys = Set(baseConfig.peers.compactMap { peer -> String? in
                guard let endpoint = peer.endpoint, !endpoint.hasHostAsIPAddress() else { return nil }
                return peer.publicKey.base64Key
            })
            let hadPin = overrides.keys.contains { hostnameKeys.contains($0) }
            if hadPin {
                hostnameKeys.forEach { overrides.removeValue(forKey: $0) }
                store.clearPins(tunnelId: tunnelId)
                try? await updateAdapterEndpoints()
            }
            lastTrialPinnedFromPublicDns = hadPin
        }
    }

    private func serverAnswers(_ inspection: Inspection, _ pause: PauseState, _ s: XtSettings, _ path: PhysicalPath) async -> Bool {
        let candidates = inspection.statuses.flatMap { $0.resolvedIps.isEmpty ? $0.currentIps : $0.resolvedIps } +
            pause.knownIps.values.flatMap { $0 }
        let targets = XtIp.unique(candidates.map { XtIp.normalize($0) }.filter { XtIp.isIPLiteral($0) })
        for ip in targets {
            let reachable: Bool
            if (1...65_535).contains(s.probeTcpPort) {
                reachable = await XtNetwork.tcpReachable(ip, port: s.probeTcpPort, path: path)
            } else {
                reachable = await XtNetwork.ping(ip, path: path)
            }
            if reachable { return true }
        }
        return false
    }

    private func resume(_ s: XtSettings) async {
        guard let paused = pause else { return }
        _ = await setPassthrough(false)
        setPause(nil, persist: true)
        nextProbeAt = .distantFuture
        XtNotifier.removePaused()
        announceResumed(paused, s)
        clearFailing()
        resetTrafficCounters()
        publish(force: true)
    }

    /// Kill switch mode: the app (or iOS on-demand) started the tunnel to see whether the server is back.
    private func runTrialAfterStop(_ s: XtSettings) async {
        guard var paused = store.pause(), paused.tunnelId == tunnelId, paused.tunnelStopped else { return }
        paused.probeCount += 1
        paused.lastProbeAt = Date()
        setPause(paused, persist: true)
        let path = await currentPath()
        let inspection = await inspect(s, peers: await runtimePeers(), failing: true, knownIps: paused.knownIps, path: path)
        setEndpoints(inspection.statuses)
        if !inspection.changes.isEmpty {
            await applyChanges(inspection.changes, s)
        }
        if await confirmAlive(timeout: s.trialTimeoutSec) {
            setPause(nil, persist: true)
            XtNotifier.removePaused()
            announceResumed(paused, s)
            clearFailing()
            resetTrafficCounters()
            publish(force: true)
        } else {
            XtLog.info("XT: \(tunnelName) still unreachable, switching the VPN off again")
            stopping = true
            setPause(nil)
            publish(force: true)
            provider?.cancelTunnelWithError(nil)
        }
    }

    private func announceResumed(_ paused: PauseState, _ s: XtSettings) {
        let minutes = max(0, Int(Date().timeIntervalSince(paused.pausedAt) / 60))
        let message = "\(tunnelName): máy chủ đã hoạt động lại, VPN đã kết nối lại (tạm ngắt \(minutes) phút)"
        store.addEvent(.resumed, message)
        if s.notifyEvents {
            XtNotifier.showEvent(title: "VPN đã kết nối lại", body: message)
        }
    }

    private func cancelPauseAndStop() {
        setPause(nil, persist: true)
        XtNotifier.removePaused()
        store.addEvent(.pauseCancelled, "Đã hủy chờ máy chủ")
        stopping = true
        publish(force: true)
        provider?.cancelTunnelWithError(nil)
    }

    /// Replaces the peers (dropping old sessions) and forces an immediate handshake.
    private func confirmAlive(timeout: Int) async -> Bool {
        guard await resetPeers() else { return false }
        await keepaliveOverride(25)
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        var alive = false
        while Date() < deadline && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let peers = await runtimePeers(), peers.contains(where: { $0.lastHandshake != nil }) {
                alive = true
                break
            }
        }
        await keepaliveOverride(nil)
        resetTrafficCounters()
        return alive
    }

    // MARK: - Adapter wrappers

    private func runtimePeers() async -> [PeerRuntime]? {
        await withCheckedContinuation { continuation in
            adapter.getRuntimeConfiguration { settings in
                continuation.resume(returning: settings.map { UAPIParser.parse($0) })
            }
        }
    }

    private func updateAdapterEndpoints() async throws {
        let config = liveConfig
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            adapter.updateEndpoints(tunnelConfiguration: config) { error in
                if let error = error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func resetPeers() async -> Bool {
        let config = liveConfig
        return await withCheckedContinuation { continuation in
            adapter.update(tunnelConfiguration: config) { error in
                if let error = error { XtLog.error("XT: peer reset failed: \(error)") }
                continuation.resume(returning: error == nil)
            }
        }
    }

    private func setPassthrough(_ enabled: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            adapter.setPassthrough(enabled) { error in
                if let error = error { XtLog.error("XT: passthrough \(enabled) failed: \(error)") }
                continuation.resume(returning: error == nil)
            }
        }
    }

    private func keepaliveOverride(_ seconds: UInt16?) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            adapter.setKeepaliveOverride(seconds) { continuation.resume() }
        }
    }

    private func currentPath() async -> PhysicalPath {
        let path = network.current
        if path.satisfied { return path }
        return await PhysicalNetworkMonitor.currentPath()
    }

    // MARK: - State helpers

    private var pause: PauseState? {
        lock.lock()
        defer { lock.unlock() }
        return sharedPause
    }

    private var isAsleep: Bool {
        lock.lock()
        defer { lock.unlock() }
        return asleep
    }

    private var wakeTime: Date {
        lock.lock()
        defer { lock.unlock() }
        return lastWakeAt
    }

    private func setPause(_ state: PauseState?, persist: Bool = false) {
        lock.lock()
        sharedPause = state
        lock.unlock()
        if persist { store.setPause(state) }
    }

    private func takeFlag(_ keyPath: ReferenceWritableKeyPath<ServerWatchdog, Bool>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let value = self[keyPath: keyPath]
        self[keyPath: keyPath] = false
        return value
    }

    private func clearFailing() {
        guard failingSince != nil else { return }
        failingSince = nil
        setFailing(nil)
    }

    private func resetTrafficCounters() {
        lastRxChangeAt = Date()
        txAtLastRxChange = 0
        lastRxTotal = 0
    }

    private func setFailing(_ since: Date?) {
        lock.lock()
        sharedRuntime.failingSince = since
        sharedRuntime.failingTunnelName = since == nil ? nil : tunnelName
        lock.unlock()
        publish(force: true)
    }

    private func setChecking(_ checking: Bool) {
        lock.lock()
        sharedRuntime.checking = checking
        lock.unlock()
        publish(force: true)
    }

    private func setEndpoints(_ statuses: [EndpointStatus]) {
        lock.lock()
        sharedRuntime.endpoints = statuses
        sharedRuntime.lastIpCheckAt = Date()
        lock.unlock()
    }

    private func snapshot() -> WatchdogRuntime {
        lock.lock()
        var runtime = sharedRuntime
        let paused = sharedPause != nil
        lock.unlock()
        runtime.passthrough = paused
        runtime.nextProbeAt = paused && nextProbeAt != .distantFuture ? nextProbeAt : nil
        return runtime
    }

    private func publish(force: Bool = false) {
        var runtime = snapshot()
        runtime.updatedAt = Date(timeIntervalSince1970: 0)
        let data = try? JSONEncoder().encode(runtime)
        let now = Date()
        if !force, data == lastPublished, now.timeIntervalSince(lastPublishedAt) < 60 { return }
        lastPublished = data
        lastPublishedAt = now
        runtime.updatedAt = now
        store.setRuntime(runtime)
    }
}

/// Lets the watchdog loop sleep until a timeout or until something asks for attention.
final class Kicker {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var pending = false
    private var generation: UInt64 = 0

    func kick() {
        lock.lock()
        if let waiting = continuation {
            continuation = nil
            lock.unlock()
            waiting.resume()
        } else {
            pending = true
            lock.unlock()
        }
    }

    func wait(seconds: TimeInterval) async {
        await withCheckedContinuation { (waiting: CheckedContinuation<Void, Never>) in
            lock.lock()
            if pending {
                pending = false
                lock.unlock()
                waiting.resume()
                return
            }
            generation += 1
            let mine = generation
            continuation = waiting
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.timeout(mine)
            }
        }
    }

    private func timeout(_ token: UInt64) {
        lock.lock()
        guard token == generation, let waiting = continuation else {
            lock.unlock()
            return
        }
        continuation = nil
        lock.unlock()
        waiting.resume()
    }
}
