// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS

import SwiftUI

/// Auto-tunnel (the Android "Tự động bật/tắt tunnel") using iOS on-demand rules.
struct OnDemandView: View {
    @ObservedObject var item: TunnelItem
    @EnvironmentObject private var tunnels: TunnelsManager
    @EnvironmentObject private var model: AppModel

    @State private var options = OnDemandOptions()
    @State private var newSSID = ""
    @State private var loaded = false
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                ToggleRow(title: "Tự động bật/tắt tunnel", description: "iOS tự kết nối hoặc ngắt tunnel theo mạng đang dùng, kể cả khi ứng dụng không mở.", isOn: $options.enabled)
            }
            if options.enabled {
                Section {
                    Picker("Wi-Fi", selection: $options.wifiMode) {
                        ForEach(OnDemandOptions.WiFiMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    if options.wifiMode == .onlyListed || options.wifiMode == .exceptListed {
                        ForEach(options.ssids, id: \.self) { ssid in
                            Text(ssid)
                        }
                        .onDelete { options.ssids.remove(atOffsets: $0) }
                        HStack {
                            TextField("Tên mạng (SSID)", text: $newSSID)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button("Thêm") {
                                let value = newSSID.trimmingCharacters(in: .whitespaces)
                                if !value.isEmpty && !options.ssids.contains(value) { options.ssids.append(value) }
                                newSSID = ""
                            }
                            .disabled(newSSID.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                } header: {
                    Text("Wi-Fi")
                } footer: {
                    Text(options.wifiMode == .exceptListed
                         ? "Mạng tin cậy (vd. Wi-Fi ở nhà): tunnel tắt khi kết nối các mạng này và bật trên mọi mạng Wi-Fi khác. Tên mạng phải trùng chính xác (iOS không hỗ trợ ký tự đại diện)."
                         : "Tên mạng phải trùng chính xác (iOS không hỗ trợ ký tự đại diện).")
                }
                Section {
                    ToggleRow(title: "Dữ liệu di động", description: "Bật tunnel khi dùng 4G/5G", isOn: $options.cellular)
                    ToggleRow(title: "Mạng khác", description: "Ethernet (iPad) và các kiểu mạng còn lại", isOn: $options.otherNetworks)
                }
            }
            Section {
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView() } else { Text("Lưu") }
                }
            } footer: {
                Text("Chỉ một tunnel có thể tự động bật tại một thời điểm. Khi bạn tự tắt tunnel, chế độ tự động cũng được tắt để iOS không bật lại ngay.")
            }
        }
        .navigationTitle("Tự động")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            options = item.onDemand
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await tunnels.setOnDemand(item, options: options)
            model.alertMessage = options.enabled ? "Đã bật tự động cho “\(item.name)”." : "Đã tắt tự động cho “\(item.name)”."
        } catch {
            model.alertMessage = error.localizedDescription
        }
    }
}

/// DNS-over-HTTPS / DNS-over-TLS per tunnel (the Android "DNS tuỳ chỉnh (DoH/DoT)").
struct EncryptedDNSView: View {
    @ObservedObject var item: TunnelItem
    @EnvironmentObject private var tunnels: TunnelsManager
    @EnvironmentObject private var model: AppModel

    enum Kind: String, CaseIterable, Identifiable {
        case off, https, tls
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: return "Tắt"
            case .https: return "DNS-over-HTTPS"
            case .tls: return "DNS-over-TLS"
            }
        }
    }

    private struct Preset: Identifiable {
        var name: String
        var doh: String
        var dot: String
        var servers: [String]
        var id: String { name }
    }

    private let presets = [
        Preset(name: "Cloudflare", doh: "https://cloudflare-dns.com/dns-query", dot: "one.one.one.one", servers: ["1.1.1.1", "1.0.0.1"]),
        Preset(name: "Google", doh: "https://dns.google/dns-query", dot: "dns.google", servers: ["8.8.8.8", "8.8.4.4"]),
        Preset(name: "Quad9", doh: "https://dns.quad9.net/dns-query", dot: "dns.quad9.net", servers: ["9.9.9.9", "149.112.112.112"]),
        Preset(name: "AdGuard", doh: "https://dns.adguard-dns.com/dns-query", dot: "dns.adguard-dns.com", servers: ["94.140.14.14", "94.140.15.15"]),
    ]

    @State private var kind = Kind.off
    @State private var value = ""
    @State private var servers = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                Picker("Kiểu", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.title).tag($0) }
                }
                if kind != .off {
                    TextField(kind == .https ? "https://…/dns-query" : "tên máy chủ", text: $value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("IP máy chủ DNS (cách nhau bởi dấu phẩy)", text: $servers)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                }
            } footer: {
                Text("Mã hóa truy vấn DNS bên trong tunnel. Nếu cấu hình đã có dòng DNS, các IP đó được dùng; nếu không, dùng IP nhập ở trên.")
            }
            if kind != .off {
                Section("Mẫu có sẵn") {
                    ForEach(presets) { preset in
                        Button(preset.name) {
                            value = kind == .https ? preset.doh : preset.dot
                            servers = preset.servers.joined(separator: ", ")
                        }
                    }
                }
            }
            Section {
                Button("Lưu") { Task { await save() } }
            }
        }
        .navigationTitle("DNS mã hóa")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let dns = item.encryptedDNS {
                kind = dns.kind == .https ? .https : .tls
                value = dns.value
                servers = dns.bootstrapServers.joined(separator: ", ")
            }
        }
    }

    private func save() async {
        let settings: EncryptedDNSSettings?
        switch kind {
        case .off:
            settings = nil
        case .https, .tls:
            let list = servers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { XtIp.isIPLiteral($0) }
            let candidate = EncryptedDNSSettings(kind: kind == .https ? .https : .tls, value: value.trimmingCharacters(in: .whitespaces), bootstrapServers: list)
            guard candidate.isUsable else {
                model.alertMessage = kind == .https ? "URL DoH phải bắt đầu bằng https://" : "Nhập tên máy chủ DoT"
                return
            }
            settings = candidate
        }
        do {
            try await tunnels.setEncryptedDNS(item, settings: settings)
            model.alertMessage = item.isActive ? "Đã lưu. Kết nối lại tunnel để áp dụng." : "Đã lưu."
        } catch {
            model.alertMessage = error.localizedDescription
        }
    }
}
