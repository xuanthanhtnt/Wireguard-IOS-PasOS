// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS — Shortcuts / Siri actions (the Android remote-control intents)

import AppIntents
import Foundation
import NetworkExtension

struct TunnelEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Tunnel"
    static var defaultQuery = TunnelEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct TunnelEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [TunnelEntity] {
        try await Self.all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [TunnelEntity] {
        try await Self.all()
    }

    static func all() async throws -> [TunnelEntity] {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        return managers.compactMap { manager in
            let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
            let name = manager.localizedDescription ?? "Tunnel"
            let id = proto?.providerConfiguration?[WGVPNKeys.tunnelId] as? String ?? name
            return TunnelEntity(id: id, name: name)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

@MainActor
enum TunnelControl {
    static func item(_ id: String?) async throws -> TunnelItem {
        let tunnels = AppModel.shared.tunnels
        await tunnels.reload()
        if let id = id, let item = tunnels.tunnel(id: id) { return item }
        if let item = tunnels.activeTunnel ?? tunnels.tunnels.first { return item }
        throw TunnelsError.system("Chưa có tunnel nào")
    }
}

struct ConnectTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Bật tunnel"
    static var description = IntentDescription("Kết nối một tunnel WG VPN.")
    static var openAppWhenRun = false

    @Parameter(title: "Tunnel")
    var tunnel: TunnelEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let item = try await TunnelControl.item(tunnel.id)
        try await AppModel.shared.tunnels.connect(item, source: .intent)
        return .result(dialog: "Đang bật \(item.name)")
    }
}

struct DisconnectTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Tắt tunnel"
    static var description = IntentDescription("Ngắt tunnel WG VPN đang chạy.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let tunnels = AppModel.shared.tunnels
        await tunnels.reload()
        guard let item = tunnels.activeTunnel else { return .result(dialog: "Không có tunnel nào đang bật") }
        await tunnels.disconnect(item)
        return .result(dialog: "Đã tắt \(item.name)")
    }
}

struct ToggleTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Bật/tắt tunnel"
    static var description = IntentDescription("Bật tunnel nếu đang tắt, tắt nếu đang bật.")
    static var openAppWhenRun = false

    @Parameter(title: "Tunnel")
    var tunnel: TunnelEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let item = try await TunnelControl.item(tunnel?.id)
        let tunnels = AppModel.shared.tunnels
        if item.isActive {
            await tunnels.disconnect(item)
            return .result(dialog: "Đã tắt \(item.name)")
        }
        try await tunnels.connect(item, source: .intent)
        return .result(dialog: "Đang bật \(item.name)")
    }
}

struct CheckServerIntent: AppIntent {
    static var title: LocalizedStringResource = "Kiểm tra máy chủ"
    static var description = IntentDescription("Kiểm tra ngay IP máy chủ (hoặc máy chủ đang tạm ngắt).")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await AppModel.shared.tunnels.reload()
        AppModel.shared.watchdog.attach(AppModel.shared.tunnels)
        await AppModel.shared.watchdog.checkNow()
        return .result()
    }
}

struct WGVPNShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleTunnelIntent(), phrases: [
            "Bật tắt \(.applicationName)",
            "Toggle \(.applicationName)",
        ], shortTitle: "Bật/tắt VPN", systemImageName: "network")
        AppShortcut(intent: DisconnectTunnelIntent(), phrases: [
            "Tắt \(.applicationName)",
            "Disconnect \(.applicationName)",
        ], shortTitle: "Tắt VPN", systemImageName: "network.slash")
        AppShortcut(intent: CheckServerIntent(), phrases: [
            "Kiểm tra máy chủ \(.applicationName)",
        ], shortTitle: "Kiểm tra máy chủ", systemImageName: "waveform.path.ecg")
    }
}
