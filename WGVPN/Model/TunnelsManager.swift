// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS

import Foundation
import NetworkExtension
import SwiftUI

/// One VPN configuration saved in iOS (NETunnelProviderManager) plus WG VPN metadata.
@MainActor
final class TunnelItem: ObservableObject, Identifiable {
    let manager: NETunnelProviderManager
    @Published private(set) var status: NEVPNStatus
    @Published private(set) var revision = 0

    /// Stable WG VPN id of the tunnel (assigned before the item is created, never changed).
    nonisolated let id: String

    init(manager: NETunnelProviderManager) {
        self.manager = manager
        self.status = manager.connection.status
        self.id = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?[WGVPNKeys.tunnelId] as? String
            ?? manager.localizedDescription ?? "?"
    }

    var proto: NETunnelProviderProtocol? { manager.protocolConfiguration as? NETunnelProviderProtocol }

    var tunnelId: String { id }
    var name: String { manager.localizedDescription ?? "Tunnel" }
    var configText: String { proto?.providerConfiguration?[WGVPNKeys.wgQuickConfig] as? String ?? "" }
    var configuration: TunnelConfiguration? { try? TunnelConfiguration(fromWgQuickConfig: configText, called: name) }

    var onDemand: OnDemandOptions {
        guard let data = proto?.providerConfiguration?[WGVPNKeys.onDemand] as? Data,
              var options = try? JSONDecoder().decode(OnDemandOptions.self, from: data) else {
            var options = OnDemandOptions()
            options.enabled = manager.isOnDemandEnabled
            return options
        }
        options.enabled = manager.isOnDemandEnabled || onDemandSuspended
        return options
    }

    var onDemandSuspended: Bool { proto?.providerConfiguration?[WGVPNKeys.onDemandSuspended] as? Bool ?? false }
    var killSwitch: Bool { proto?.includeAllNetworks ?? false }
    var allowLAN: Bool { proto?.excludeLocalNetworks ?? false }

    var encryptedDNS: EncryptedDNSSettings? {
        guard let data = proto?.providerConfiguration?[WGVPNKeys.encryptedDNS] as? Data else { return nil }
        return try? JSONDecoder().decode(EncryptedDNSSettings.self, from: data)
    }

    var isActive: Bool { status != .disconnected && status != .invalid }

    var session: NETunnelProviderSession? { manager.connection as? NETunnelProviderSession }

    fileprivate func refreshStatus() {
        if status != manager.connection.status { status = manager.connection.status }
    }

    fileprivate func bump() {
        revision += 1
        refreshStatus()
    }

    // MARK: - Talking to the extension

    func runtimePeers() async -> [PeerRuntime]? {
        guard let session = session, status == .connected || status == .reasserting else { return nil }
        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(Data([0])) { data in
                    continuation.resume(returning: data.map { UAPIParser.parse(String(decoding: $0, as: UTF8.self)) })
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    @discardableResult
    func send(_ command: XtCommand) async -> WatchdogRuntime? {
        guard let session = session, isActive else { return nil }
        guard let data = try? JSONEncoder().encode(XtCommandMessage(command: command)) else { return nil }
        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(data) { reply in
                    continuation.resume(returning: reply.flatMap { try? JSONDecoder().decode(WatchdogRuntime.self, from: $0) })
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}

enum TunnelsError: LocalizedError {
    case parse(String)
    case duplicateName
    case system(String)

    var errorDescription: String? {
        switch self {
        case .parse(let text): return text
        case .duplicateName: return "Đã có tunnel trùng tên"
        case .system(let text): return text
        }
    }
}

@MainActor
final class TunnelsManager: ObservableObject {
    @Published private(set) var tunnels: [TunnelItem] = []
    @Published private(set) var loaded = false
    @Published var errorMessage: String?

    private var observers = [NSObjectProtocol]()

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] note in
            guard let connection = note.object as? NEVPNConnection else { return }
            Task { @MainActor in self?.statusChanged(connection) }
        })
        observers.append(center.addObserver(forName: .NEVPNConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        })
    }

    var activeTunnel: TunnelItem? { tunnels.first { $0.isActive } }

    func tunnel(id: String) -> TunnelItem? { tunnels.first { $0.tunnelId == id } }

    func reload() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            var items = [TunnelItem]()
            for manager in managers {
                if let existing = tunnels.first(where: { $0.manager === manager }) {
                    existing.bump()
                    items.append(existing)
                } else {
                    await assignIdIfNeeded(manager)
                    items.append(TunnelItem(manager: manager))
                }
            }
            tunnels = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            loaded = true
        } catch {
            errorMessage = "Không tải được danh sách VPN: \(error.localizedDescription)"
            loaded = true
        }
    }

    private func statusChanged(_ connection: NEVPNConnection) {
        for item in tunnels where item.manager.connection === connection {
            item.refreshStatus()
        }
        objectWillChange.send()
    }

    private func assignIdIfNeeded(_ manager: NETunnelProviderManager) async {
        guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else { return }
        var configuration = proto.providerConfiguration ?? [:]
        guard configuration[WGVPNKeys.tunnelId] == nil else { return }
        configuration[WGVPNKeys.tunnelId] = UUID().uuidString
        configuration[WGVPNKeys.tunnelName] = manager.localizedDescription ?? "Tunnel"
        proto.providerConfiguration = configuration
        try? await manager.saveToPreferences()
    }

    // MARK: - Names

    func uniqueName(_ base: String, excluding item: TunnelItem? = nil) -> String {
        let clean = Self.sanitize(base)
        let taken = Set(tunnels.filter { $0 !== item }.map { $0.name })
        if !taken.contains(clean) { return clean }
        var index = 2
        while taken.contains("\(clean) (\(index))") { index += 1 }
        return "\(clean) (\(index))"
    }

    static func sanitize(_ name: String) -> String {
        var value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasSuffix(".conf") { value = String(value.dropLast(5)) }
        return value.isEmpty ? "Tunnel" : String(value.prefix(60))
    }

    static func parse(_ text: String, name: String) throws -> TunnelConfiguration {
        do {
            return try TunnelConfiguration(fromWgQuickConfig: text, called: name)
        } catch let error as TunnelConfiguration.ParseError {
            throw TunnelsError.parse(ParseErrorText.describe(error))
        }
    }

    // MARK: - CRUD

    @discardableResult
    func add(name: String, configText: String) async throws -> TunnelItem {
        let finalName = uniqueName(name)
        let config = try Self.parse(configText, name: finalName)
        let manager = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.extensionBundleId
        proto.providerConfiguration = [
            WGVPNKeys.wgQuickConfig: config.asWgQuickConfig(),
            WGVPNKeys.tunnelId: UUID().uuidString,
            WGVPNKeys.tunnelName: finalName,
        ]
        proto.serverAddress = Self.serverAddress(of: config)
        manager.protocolConfiguration = proto
        manager.localizedDescription = finalName
        manager.isEnabled = true
        do {
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        } catch {
            throw TunnelsError.system(Self.describeSaveError(error))
        }
        let item = TunnelItem(manager: manager)
        tunnels.append(item)
        tunnels.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        XtLog.info("Added tunnel \(finalName)")
        return item
    }

    func update(_ item: TunnelItem, name: String, configText: String) async throws {
        let finalName = uniqueName(name, excluding: item)
        let config = try Self.parse(configText, name: finalName)
        try await modify(item) { manager, proto, configuration in
            configuration[WGVPNKeys.wgQuickConfig] = config.asWgQuickConfig()
            configuration[WGVPNKeys.tunnelName] = finalName
            proto.serverAddress = Self.serverAddress(of: config)
            manager.localizedDescription = finalName
        }
        // The user edited the configuration: forget endpoint rewrites that no longer apply
        let pendingKeys = XtStore.shared.rewrites()[item.tunnelId].map { Array($0.keys) } ?? []
        XtStore.shared.removeRewrites(tunnelId: item.tunnelId, peerKeys: pendingKeys)
    }

    func remove(_ item: TunnelItem) async throws {
        if item.isActive { item.manager.connection.stopVPNTunnel() }
        do {
            try await item.manager.removeFromPreferences()
        } catch {
            throw TunnelsError.system(error.localizedDescription)
        }
        tunnels.removeAll { $0 === item }
        XtStore.shared.setIpSource(tunnelId: item.tunnelId, source: nil)
        if XtStore.shared.pause()?.tunnelId == item.tunnelId {
            XtStore.shared.setPause(nil)
            XtNotifier.removePaused()
        }
    }

    func setOnDemand(_ item: TunnelItem, options: OnDemandOptions) async throws {
        try await modify(item) { manager, _, configuration in
            configuration[WGVPNKeys.onDemand] = try? JSONEncoder().encode(options)
            configuration[WGVPNKeys.onDemandSuspended] = nil
            manager.onDemandRules = options.rules
            manager.isOnDemandEnabled = options.enabled
            if options.enabled { manager.isEnabled = true }
        }
    }

    func setKillSwitch(_ item: TunnelItem, enabled: Bool, allowLAN: Bool) async throws {
        try await modify(item) { _, proto, _ in
            proto.includeAllNetworks = enabled
            proto.excludeLocalNetworks = allowLAN
        }
    }

    func setEncryptedDNS(_ item: TunnelItem, settings: EncryptedDNSSettings?) async throws {
        try await modify(item) { _, _, configuration in
            configuration[WGVPNKeys.encryptedDNS] = settings.flatMap { try? JSONEncoder().encode($0) }
        }
    }

    /// Writes endpoint changes the watchdog detected into the saved configuration.
    func applyEndpointRewrites(_ item: TunnelItem, endpoints: [String: String]) async throws {
        guard let config = item.configuration else { return }
        let updated = XtInspector.applying(endpoints, to: config)
        try await modify(item) { _, proto, configuration in
            configuration[WGVPNKeys.wgQuickConfig] = updated.asWgQuickConfig()
            proto.serverAddress = Self.serverAddress(of: updated)
        }
    }

    /// Temporarily turns on-demand off (kill switch pause) or restores it.
    func setOnDemandSuspended(_ item: TunnelItem, suspended: Bool) async throws {
        try await modify(item) { manager, _, configuration in
            if suspended {
                configuration[WGVPNKeys.onDemandSuspended] = true
                manager.isOnDemandEnabled = false
            } else {
                configuration[WGVPNKeys.onDemandSuspended] = nil
                manager.isOnDemandEnabled = true
            }
        }
    }

    private func modify(_ item: TunnelItem, _ change: (NETunnelProviderManager, NETunnelProviderProtocol, inout [String: Any]) throws -> Void) async throws {
        let manager = item.manager
        guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
            throw TunnelsError.system("Cấu hình VPN không hợp lệ")
        }
        var configuration = proto.providerConfiguration ?? [:]
        try change(manager, proto, &configuration)
        proto.providerConfiguration = configuration
        manager.protocolConfiguration = proto
        do {
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        } catch {
            throw TunnelsError.system(Self.describeSaveError(error))
        }
        item.bump()
        tunnels.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        objectWillChange.send()
    }

    // MARK: - Connect / disconnect

    func connect(_ item: TunnelItem, source: StartSource = .app) async throws {
        // Only one VPN can run at a time
        for other in tunnels where other !== item && other.isActive {
            other.manager.connection.stopVPNTunnel()
        }
        let manager = item.manager
        if !manager.isEnabled {
            manager.isEnabled = true
            do {
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
            } catch {
                throw TunnelsError.system(Self.describeSaveError(error))
            }
        }
        do {
            try manager.connection.startVPNTunnel(options: [WGVPNKeys.startSource: source.rawValue as NSString])
            XtLog.info("Requested start of \(item.name) (\(source.rawValue))")
        } catch {
            throw TunnelsError.system("Không bật được VPN: \(error.localizedDescription)")
        }
        item.bump()
    }

    func disconnect(_ item: TunnelItem) async {
        let manager = item.manager
        if manager.isOnDemandEnabled {
            // Otherwise iOS would bring it right back
            manager.isOnDemandEnabled = false
            try? await manager.saveToPreferences()
            try? await manager.loadFromPreferences()
        }
        manager.connection.stopVPNTunnel()
        XtLog.info("Requested stop of \(item.name)")
        item.bump()
    }

    func toggle(_ item: TunnelItem) async throws {
        if item.isActive {
            await disconnect(item)
        } else {
            try await connect(item)
        }
    }

    // MARK: - Helpers

    static var extensionBundleId: String {
        "\(Bundle.main.bundleIdentifier ?? "com.wgvpn.app").network-extension"
    }

    static func serverAddress(of config: TunnelConfiguration) -> String {
        let endpoints = config.peers.compactMap { $0.endpoint }
        switch endpoints.count {
        case 0: return "Không có Endpoint"
        case 1: return endpoints[0].stringRepresentation
        default: return "Nhiều Endpoint"
        }
    }

    private static func describeSaveError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NEVPNErrorDomain, nsError.code == NEVPNError.Code.configurationReadWriteFailed.rawValue {
            return "Bạn cần cho phép WG VPN thêm cấu hình VPN."
        }
        if nsError.domain == NEVPNErrorDomain, nsError.code == NEVPNError.Code.configurationInvalid.rawValue {
            return "iOS từ chối cấu hình VPN. Ứng dụng cần được ký với quyền Network Extension."
        }
        return error.localizedDescription
    }
}

enum ParseErrorText {
    static func describe(_ error: TunnelConfiguration.ParseError) -> String {
        switch error {
        case .invalidLine(let line): return "Dòng không hợp lệ: \(line)"
        case .noInterface: return "Thiếu mục [Interface]"
        case .multipleInterfaces: return "Có nhiều hơn một mục [Interface]"
        case .interfaceHasNoPrivateKey: return "Thiếu PrivateKey trong [Interface]"
        case .interfaceHasInvalidPrivateKey: return "PrivateKey không hợp lệ"
        case .interfaceHasInvalidListenPort(let v): return "ListenPort không hợp lệ: \(v)"
        case .interfaceHasInvalidAddress(let v): return "Address không hợp lệ: \(v)"
        case .interfaceHasInvalidDNS(let v): return "DNS không hợp lệ: \(v)"
        case .interfaceHasInvalidMTU(let v): return "MTU không hợp lệ: \(v)"
        case .interfaceHasUnrecognizedKey(let v): return "Khóa không hỗ trợ trong [Interface]: \(v)"
        case .interfaceHasInvalidCustomParam(let v): return "Tham số AmneziaWG không hợp lệ: \(v)"
        case .interfaceHasInvalidHeaderProtectionKey: return "HeaderProtectionKey không hợp lệ"
        case .peerHasNoPublicKey: return "Thiếu PublicKey trong [Peer]"
        case .peerHasInvalidPublicKey(let v): return "PublicKey không hợp lệ: \(v)"
        case .peerHasInvalidPreSharedKey: return "PresharedKey không hợp lệ"
        case .peerHasInvalidAllowedIP(let v): return "AllowedIPs không hợp lệ: \(v)"
        case .peerHasInvalidEndpoint(let v): return "Endpoint không hợp lệ: \(v)"
        case .peerHasInvalidPersistentKeepAlive(let v): return "PersistentKeepalive không hợp lệ: \(v)"
        case .peerHasInvalidTransferBytes, .peerHasInvalidLastHandshakeTime: return "Dữ liệu peer không hợp lệ"
        case .peerHasUnrecognizedKey(let v): return "Khóa không hỗ trợ trong [Peer]: \(v)"
        case .multiplePeersWithSamePublicKey: return "Hai peer có cùng PublicKey"
        case .multipleEntriesForKey(let v): return "Khóa \(v) xuất hiện nhiều lần"
        }
    }
}
