// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS

import NetworkExtension
import SwiftUI

struct TunnelDetailView: View {
    @ObservedObject var item: TunnelItem
    @EnvironmentObject private var tunnels: TunnelsManager
    @EnvironmentObject private var watchdog: WatchdogController
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var peers: [PeerRuntime] = []
    @State private var showEditor = false
    @State private var showQR = false
    @State private var sharedFile: SharedFile?
    @State private var confirmDelete = false
    @State private var showSourcePrompt = false
    @State private var sourceText = ""

    private var config: TunnelConfiguration? { item.configuration }

    var body: some View {
        let state = TunnelState(item: item, pause: watchdog.pause)
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { item.isActive },
                    set: { on in
                        Task {
                            do {
                                if on { try await tunnels.connect(item) } else { await tunnels.disconnect(item) }
                            } catch {
                                model.alertMessage = error.localizedDescription
                            }
                        }
                    }
                )) {
                    HStack(spacing: 10) {
                        StatusDot(color: state.color)
                        Text(state.text)
                    }
                }
                .tint(.wgAccent)
                if let pause = watchdog.pause, pause.tunnelId == item.tunnelId {
                    PauseBanner(pause: pause)
                }
                if let error = watchdog.lastError, error.tunnelId == item.tunnelId, !item.isActive {
                    Label("Lần bật gần nhất thất bại: \(error.message)", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Trạng thái")
            }

            if let config = config {
                interfaceSection(config)
                ForEach(Array(config.peers.enumerated()), id: \.offset) { index, peer in
                    peerSection(peer, index: index, total: config.peers.count)
                }
            } else {
                Section {
                    Text("Không đọc được cấu hình").foregroundStyle(.red)
                }
            }

            Section {
                NavigationLink {
                    OnDemandView(item: item)
                } label: {
                    LabeledContent("Tự động bật/tắt", value: item.onDemand.summary)
                }
                Toggle(isOn: Binding(
                    get: { item.killSwitch },
                    set: { value in Task { await setKillSwitch(value, allowLAN: item.allowLAN) } }
                )) {
                    DescriptionRow(title: "Kill switch", description: "Chặn mọi kết nối không đi qua VPN (kể cả lúc đang kết nối lại)")
                }
                .tint(.wgAccent)
                if item.killSwitch {
                    Toggle(isOn: Binding(
                        get: { item.allowLAN },
                        set: { value in Task { await setKillSwitch(true, allowLAN: value) } }
                    )) {
                        DescriptionRow(title: "Cho phép mạng nội bộ (LAN)", description: "Máy in, AirPlay… trong mạng Wi-Fi vẫn truy cập được")
                    }
                    .tint(.wgAccent)
                }
                NavigationLink {
                    EncryptedDNSView(item: item)
                } label: {
                    LabeledContent("DNS mã hóa", value: encryptedDNSSummary)
                }
            } header: {
                Text("Kết nối")
            }

            watchdogSection

            Section {
                Button { showEditor = true } label: { Label("Sửa cấu hình", systemImage: "square.and.pencil") }
                Button { exportFile() } label: { Label("Xuất file .conf", systemImage: "square.and.arrow.up") }
                Button { showQR = true } label: { Label("Hiện mã QR", systemImage: "qrcode") }
                Button { Clipboard.copy(config?.asWgQuickConfig() ?? item.configText) } label: {
                    Label("Sao chép cấu hình", systemImage: "doc.on.doc")
                }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Xóa tunnel", systemImage: "trash") }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: item.status) { await pollRuntime() }
        .sheet(isPresented: $showEditor) {
            NavigationStack {
                TunnelEditorView(mode: .edit(item))
            }
        }
        .sheet(isPresented: $showQR) {
            NavigationStack {
                QRCodeView(title: item.name, text: config?.asWgQuickConfig() ?? item.configText)
            }
        }
        .sheet(item: $sharedFile) { file in
            ShareSheet(items: [file.url])
        }
        .confirmationDialog("Xóa tunnel “\(item.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Xóa", role: .destructive) {
                Task {
                    do {
                        try await tunnels.remove(item)
                        model.selectedTunnelId = nil
                        dismiss()
                    } catch {
                        model.alertMessage = error.localizedDescription
                    }
                }
            }
        }
        .alert("Nguồn IP cho \(item.name)", isPresented: $showSourcePrompt) {
            TextField("nhacuatoi.duckdns.org", text: $sourceText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Hủy", role: .cancel) {}
            Button("Lưu") { watchdog.setIpSource(item, source: sourceText) }
        } message: {
            Text("Dùng khi Endpoint của tunnel là địa chỉ IP. Nhập tên miền DDNS của máy chủ (vd: nhacuatoi.duckdns.org) hoặc một URL http(s) trả về IP hiện tại của máy chủ. Khi nguồn này trỏ tới IP mới, WG VPN sẽ sửa lại Endpoint trong cấu hình. Để trống để tắt.")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func interfaceSection(_ config: TunnelConfiguration) -> some View {
        let interface = config.interface
        Section {
            CopyRow(title: "Khóa công khai", value: interface.privateKey.publicKey.base64Key)
            if !interface.addresses.isEmpty {
                LabeledContent("Địa chỉ", value: interface.addresses.map { $0.stringRepresentation }.joined(separator: ", "))
            }
            if !interface.dns.isEmpty || !interface.dnsSearch.isEmpty {
                LabeledContent("DNS", value: (interface.dns.map { $0.stringRepresentation } + interface.dnsSearch).joined(separator: ", "))
            }
            if let mtu = interface.mtu { LabeledContent("MTU", value: "\(mtu)") }
            if let port = interface.listenPort { LabeledContent("Cổng nghe", value: "\(port)") }
            if Self.isAmnezia(interface) {
                LabeledContent("Giao thức", value: "AmneziaWG (chống DPI)")
            } else {
                LabeledContent("Giao thức", value: "WireGuard")
            }
        } header: {
            Text("Giao diện")
        }
    }

    @ViewBuilder
    private func peerSection(_ peer: PeerConfiguration, index: Int, total: Int) -> some View {
        let key = peer.publicKey.base64Key
        let live = peers.first { $0.publicKey == key }
        Section {
            CopyRow(title: "Khóa công khai", value: key)
            if let endpoint = peer.endpoint {
                LabeledContent("Endpoint", value: endpoint.stringRepresentation)
            }
            if let current = live?.endpoint, current != peer.endpoint?.stringRepresentation {
                LabeledContent("Đang dùng", value: current)
            }
            if !peer.allowedIPs.isEmpty {
                LabeledContent("AllowedIPs", value: peer.allowedIPs.map { $0.stringRepresentation }.joined(separator: ", "))
            }
            if let keepalive = peer.persistentKeepAlive {
                LabeledContent("Giữ kết nối", value: "\(keepalive) giây")
            }
            if peer.preSharedKey != nil {
                LabeledContent("Khóa chia sẻ trước", value: "Có")
            }
            if let live = live {
                LabeledContent("Bắt tay gần nhất", value: live.lastHandshake?.relativeVietnamese ?? "Chưa có")
                LabeledContent("Đã nhận / gửi", value: "\(ByteFormat.string(live.rxBytes)) / \(ByteFormat.string(live.txBytes))")
            }
        } header: {
            Text(total > 1 ? "Peer \(index + 1)" : "Peer")
        }
    }

    @ViewBuilder
    private var watchdogSection: some View {
        let statuses = (watchdog.runtime?.endpoints ?? []) .filter { $0.tunnelId == item.tunnelId } +
            watchdog.appEndpoints.filter { $0.tunnelId == item.tunnelId }
        let isStatic = config?.peers.contains { $0.endpoint?.hasHostAsIPAddress() ?? false } ?? false
        let source = watchdog.settings.ipSources[item.tunnelId]
        Section {
            if isStatic {
                Button {
                    sourceText = source ?? ""
                    showSourcePrompt = true
                } label: {
                    DescriptionRow(
                        title: "Nguồn IP (DDNS hoặc URL)",
                        description: source.map { "IP cố định, cập nhật theo: \($0)" } ?? "Chưa đặt. Chạm để thêm tên miền DDNS hoặc URL để có thể tự cập nhật IP"
                    )
                }
                .foregroundStyle(.primary)
            } else if let host = config?.peers.compactMap({ $0.endpoint?.hostname() }).first {
                DescriptionRow(title: "Đang theo dõi tên miền", description: host)
            }
            if let status = statuses.first {
                if let error = status.error {
                    Text("Tra cứu thất bại: \(error)").font(.footnote).foregroundStyle(.red)
                } else if !status.resolvedIps.isEmpty {
                    Text("Phân giải: \(status.resolvedIps.joined(separator: ", ")) (đang dùng: \(status.currentIps.isEmpty ? "?" : status.currentIps.joined(separator: ", ")))")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Giám sát máy chủ")
        }
    }

    private var encryptedDNSSummary: String {
        guard let dns = item.encryptedDNS, dns.isUsable else { return "Tắt" }
        return dns.kind == .https ? "DoH" : "DoT"
    }

    // MARK: - Actions

    private func setKillSwitch(_ enabled: Bool, allowLAN: Bool) async {
        do {
            try await tunnels.setKillSwitch(item, enabled: enabled, allowLAN: allowLAN)
            if item.isActive {
                model.alertMessage = "Thay đổi sẽ có hiệu lực ở lần kết nối tiếp theo."
            }
        } catch {
            model.alertMessage = error.localizedDescription
        }
    }

    private func exportFile() {
        do {
            sharedFile = SharedFile(url: try ImportService.exportFile(item))
        } catch {
            model.alertMessage = error.localizedDescription
        }
    }

    private func pollRuntime() async {
        while !Task.isCancelled {
            if item.status == .connected || item.status == .reasserting {
                peers = await item.runtimePeers() ?? []
            } else {
                peers = []
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    static func isAmnezia(_ interface: InterfaceConfiguration) -> Bool {
        interface.junkPacketCount != nil || interface.initPacketMagicHeader != nil || interface.specialJunk1 != nil ||
            interface.initPacketJunkSize != nil || interface.headerProtectionKey != nil
    }
}

struct CopyRow: View {
    var title: String
    var value: String
    @State private var copied = false

    var body: some View {
        Button {
            Clipboard.copy(value)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                copied = false
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(copied ? "Đã sao chép" : value)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
