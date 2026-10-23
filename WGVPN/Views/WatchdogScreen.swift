// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS — port of the Android ServerWatchdogScreen ("Giám sát máy chủ")

import SwiftUI
import UIKit
import UserNotifications

struct WatchdogScreen: View {
    @EnvironmentObject private var watchdog: WatchdogController
    @EnvironmentObject private var tunnels: TunnelsManager

    @State private var editingSource: TunnelItem?
    @State private var sourceText = ""
    @State private var showPortPrompt = false
    @State private var portText = ""
    @State private var notificationsDenied = false

    private var s: XtSettings { watchdog.settings }

    var body: some View {
        Form {
            statusSection
            ipWatchSection
            sourcesSection
            outageSection
            historySection
        }
        .navigationTitle("Giám sát máy chủ")
        .refreshable { watchdog.reloadFromStore() }
        .task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationsDenied = settings.authorizationStatus == .denied
        }
        .alert("Nguồn IP cho \(editingSource?.name ?? "")", isPresented: Binding(get: { editingSource != nil }, set: { if !$0 { editingSource = nil } })) {
            TextField("nhacuatoi.duckdns.org", text: $sourceText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Hủy", role: .cancel) {}
            Button("Lưu") {
                if let item = editingSource { watchdog.setIpSource(item, source: sourceText) }
            }
        } message: {
            Text("Dùng khi Endpoint của tunnel là địa chỉ IP. Nhập tên miền DDNS của máy chủ (vd: nhacuatoi.duckdns.org) hoặc một URL http(s) trả về IP hiện tại của máy chủ. Khi nguồn này trỏ tới IP mới, WG VPN sẽ sửa lại Endpoint trong cấu hình. Để trống để tắt.")
        }
        .alert("Cổng TCP để kiểm tra", isPresented: $showPortPrompt) {
            TextField("443", text: $portText).keyboardType(.numberPad)
            Button("Hủy", role: .cancel) {}
            Button("Lưu") {
                let port = Int(portText.trimmingCharacters(in: .whitespaces)) ?? 0
                watchdog.update { $0.probeTcpPort = port.clamped(0, 65_535) }
            }
        } message: {
            Text("Không bắt buộc. Một cổng TCP luôn mở trên máy chủ hoặc router khi đang chạy (vd: 443 hoặc 8443). Để trống để dùng ping ICMP.")
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            if let pause = watchdog.pause {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Đã tạm ngắt VPN “\(pause.tunnelName)”: máy chủ không phản hồi", systemImage: "bolt.slash.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline.weight(.semibold))
                    Text("Từ \(XtFormat.time(pause.pausedAt)) • đã kiểm tra: \(pause.probeCount) lần")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let next = watchdog.runtime?.nextProbeAt, !pause.tunnelStopped {
                        Text("Lần kiểm tra tiếp theo lúc \(XtFormat.time(next))").font(.footnote).foregroundStyle(.secondary)
                    }
                    if pause.tunnelStopped {
                        Text("Kill switch đang bật nên VPN đã được tắt hẳn. WG VPN kiểm tra lại máy chủ khi bạn mở ứng dụng, khi iOS cho chạy nền, hoặc khi bạn bấm “Kết nối lại ngay”.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Kết nối lại ngay") { Task { await watchdog.resumeNow() } }
                        .buttonStyle(.borderedProminent)
                        .tint(.wgAccent)
                    Button("Hủy chờ", role: .destructive) { Task { await watchdog.cancelPause() } }
                        .buttonStyle(.bordered)
                }
            } else if let since = watchdog.runtime?.failingSince {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Máy chủ của “\(watchdog.runtime?.failingTunnelName ?? "")” không phản hồi từ \(XtFormat.time(since))", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.subheadline.weight(.semibold))
                    if s.autoPauseEnabled {
                        Text("VPN sẽ được tạm ngắt nếu không phục hồi trong \(XtFormat.duration(s.pauseAfterSec))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } else {
                Label(s.ipWatchEnabled || s.autoPauseEnabled ? "Đang giám sát máy chủ" : "Đã tắt giám sát",
                      systemImage: s.ipWatchEnabled || s.autoPauseEnabled ? "checkmark.shield.fill" : "shield.slash")
                    .foregroundStyle(s.ipWatchEnabled || s.autoPauseEnabled ? Color.green : Color.secondary)
            }
            if let last = watchdog.runtime?.lastIpCheckAt {
                Text("Kiểm tra IP gần nhất: \(XtFormat.time(last))").font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                Task { await watchdog.checkNow() }
            } label: {
                HStack {
                    Label("Kiểm tra ngay", systemImage: "arrow.clockwise")
                    if watchdog.checking || watchdog.runtime?.checking == true {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            if notificationsDenied {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    DescriptionRow(title: "Thông báo đang bị tắt", description: "Bật thông báo để biết khi VPN tạm ngắt hoặc kết nối lại. Chạm để mở Cài đặt.")
                        .foregroundStyle(.red)
                }
            }
            if !AppGroup.isShared {
                Text("Bản cài đặt này không có App Group: ứng dụng và tunnel không chia sẻ được cài đặt giám sát. Hãy ký lại ứng dụng kèm quyền App Groups.")
                    .font(.footnote).foregroundStyle(.red)
            }
        }
    }

    // MARK: - IP watch

    private var ipWatchSection: some View {
        Section {
            ToggleRow(
                title: "Tự cập nhật IP máy chủ",
                description: "Định kỳ tra cứu địa chỉ máy chủ (DDNS) bên ngoài tunnel. Khi máy chủ khởi động lại và nhận IP mới, tunnel sẽ tự chuyển sang IP mới.",
                isOn: binding(\.ipWatchEnabled)
            )
            Picker("Kiểm tra mỗi", selection: binding(\.ipWatchIntervalSec)) {
                ForEach(XtSettings.ipWatchIntervalOptions, id: \.self) { Text(XtFormat.duration($0)).tag($0) }
            }
            .disabled(!s.ipWatchEnabled)
            ToggleRow(
                title: "Kiểm tra thêm qua DNS-over-HTTPS",
                description: "Khi không liên lạc được máy chủ, hỏi thêm trực tiếp Cloudflare/Google để bộ nhớ đệm DNS cũ trên máy không giữ tunnel ở IP cũ",
                isOn: binding(\.useDoh)
            )
        } header: {
            Text("IP máy chủ")
        }
    }

    private var sourcesSection: some View {
        Section {
            if tunnels.tunnels.isEmpty {
                Text("Chưa có tunnel nào").foregroundStyle(.secondary)
            }
            ForEach(tunnels.tunnels) { item in
                sourceRow(item)
            }
        } header: {
            Text("Nguồn IP theo từng tunnel")
        }
    }

    @ViewBuilder
    private func sourceRow(_ item: TunnelItem) -> some View {
        let config = item.configuration
        let endpoint = config?.peers.compactMap { $0.endpoint }.first
        let statuses = (watchdog.runtime?.endpoints ?? []) + watchdog.appEndpoints
        let status = statuses.last { $0.tunnelId == item.tunnelId }
        let source = s.ipSources[item.tunnelId]
        Button {
            guard endpoint?.hasHostAsIPAddress() == true else { return }
            sourceText = source ?? ""
            editingSource = item
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).foregroundStyle(.primary)
                Group {
                    if let endpoint = endpoint {
                        if endpoint.hasHostAsIPAddress() {
                            if let source = source {
                                Text("IP cố định, cập nhật theo: \(source)")
                            } else {
                                Text("IP cố định \(endpoint.hostString). Chạm để thêm tên miền DDNS hoặc URL để có thể tự cập nhật IP")
                            }
                        } else {
                            Text("Đang theo dõi tên miền: \(endpoint.hostString)")
                        }
                    } else {
                        Text("Cấu hình này không có Endpoint")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                if let status = status {
                    if let error = status.error {
                        Text("Tra cứu thất bại: \(error)").font(.caption).foregroundStyle(.red)
                    } else if status.changed {
                        Text("IP đã đổi: \(status.currentIps.joined(separator: ", ")) → \(status.resolvedIps.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.orange)
                    } else if !status.resolvedIps.isEmpty {
                        Text("Phân giải: \(status.resolvedIps.joined(separator: ", ")) (đang dùng: \(status.currentIps.isEmpty ? "?" : status.currentIps.joined(separator: ", ")))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Outage

    private var outageSection: some View {
        Section {
            ToggleRow(
                title: "Tạm ngắt VPN khi máy chủ không phản hồi",
                description: "Nếu máy chủ ngừng phản hồi (vd: cúp điện) trong khi Internet của máy vẫn tốt, VPN sẽ tạm ngừng định tuyến để bạn không mất Internet, và tự kết nối lại khi máy chủ hoạt động trở lại.",
                isOn: binding(\.autoPauseEnabled)
            )
            Group {
                Picker(selection: binding(\.pauseAfterSec)) {
                    ForEach(XtSettings.pauseAfterOptions, id: \.self) { Text(XtFormat.duration($0)).tag($0) }
                } label: {
                    DescriptionRow(title: "Tạm ngắt sau", description: "Thời gian bắt tay thất bại liên tục trước khi tạm ngắt")
                }
                Picker(selection: binding(\.probeIntervalSec)) {
                    ForEach(XtSettings.probeIntervalOptions, id: \.self) { Text(XtFormat.duration($0)).tag($0) }
                } label: {
                    DescriptionRow(title: "Kiểm tra lại máy chủ mỗi", description: "Khi đang tạm ngắt, bao lâu kiểm tra máy chủ một lần")
                }
                Picker(selection: binding(\.probeMethod)) {
                    Text("Thử bắt tay VPN").tag(ProbeMethod.handshake)
                    Text("Ping máy chủ").tag(ProbeMethod.ping)
                } label: {
                    DescriptionRow(title: "Cách kiểm tra", description: s.probeMethod == .handshake
                        ? "Gửi gói bắt tay WireGuard và chờ máy chủ trả lời. Chính xác nhất; trên iOS không làm gián đoạn Internet (trừ khi bật Kill switch)."
                        : "Ping máy chủ (hoặc kết nối tới một cổng TCP) trước, chỉ thử bắt tay khi máy chủ trả lời. Máy chủ/router phải trả lời ping hoặc mở cổng đó.")
                }
                if s.probeMethod == .ping {
                    Button {
                        portText = s.probeTcpPort > 0 ? "\(s.probeTcpPort)" : ""
                        showPortPrompt = true
                    } label: {
                        LabeledContent("Cổng TCP để kiểm tra", value: s.probeTcpPort > 0 ? "Cổng \(s.probeTcpPort)" : "Chưa đặt, dùng ping ICMP")
                    }
                    .foregroundStyle(.primary)
                }
                Picker(selection: binding(\.trialTimeoutSec)) {
                    ForEach(XtSettings.trialTimeoutOptions, id: \.self) { Text(XtFormat.duration($0)).tag($0) }
                } label: {
                    DescriptionRow(title: "Thời gian chờ bắt tay", description: "Mỗi lần thử kết nối sẽ chờ máy chủ trong bao lâu")
                }
                ToggleRow(
                    title: "Tạm bỏ Kill switch khi đang ngắt",
                    description: "Chỉ với tunnel bật Kill switch: tắt hẳn VPN khi máy chủ mất kết nối để vẫn truy cập được Internet. Kill switch có hiệu lực lại khi VPN kết nối lại.",
                    isOn: binding(\.suspendKillSwitch)
                )
            }
            .disabled(!s.autoPauseEnabled)
            ToggleRow(
                title: "Thông báo khi có thay đổi",
                description: "Hiện thông báo khi IP được cập nhật hoặc VPN kết nối lại",
                isOn: binding(\.notifyEvents)
            )
        } header: {
            Text("Khi máy chủ mất kết nối")
        } footer: {
            Text("Trên iOS, khi tạm ngắt, biểu tượng VPN vẫn hiện nhưng tunnel không định tuyến gì: mọi kết nối đi thẳng ra Internet trong lúc WG VPN tiếp tục kiểm tra máy chủ. Không tạm ngắt khi máy mất mạng, đang ngủ hoặc bị cổng đăng nhập Wi-Fi chặn.")
        }
    }

    // MARK: - History

    private var historySection: some View {
        Section {
            if watchdog.events.isEmpty {
                Text("Chưa có sự kiện nào").foregroundStyle(.secondary)
            }
            ForEach(watchdog.events) { event in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: Self.icon(event.type))
                        .foregroundStyle(Self.color(event.type))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.message).font(.footnote)
                        Text(XtFormat.time(event.at)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            HStack {
                Text("Nhật ký")
                Spacer()
                if !watchdog.events.isEmpty {
                    Button("Xóa") { watchdog.clearHistory() }
                        .font(.footnote)
                }
            }
        }
    }

    static func icon(_ type: XtEventType) -> String {
        switch type {
        case .ipChanged: return "arrow.triangle.swap"
        case .ipUpdated: return "checkmark.circle"
        case .ipCheckFailed: return "questionmark.circle"
        case .paused: return "bolt.slash"
        case .resumed: return "bolt.fill"
        case .pauseCancelled: return "xmark.circle"
        case .info: return "info.circle"
        }
    }

    static func color(_ type: XtEventType) -> Color {
        switch type {
        case .paused: return .orange
        case .resumed, .ipUpdated: return .green
        case .ipCheckFailed: return .red
        default: return .wgAccent
        }
    }

    private func binding<T: Equatable>(_ keyPath: WritableKeyPath<XtSettings, T>) -> Binding<T> {
        Binding(
            get: { watchdog.settings[keyPath: keyPath] },
            set: { value in watchdog.update { $0[keyPath: keyPath] = value } }
        )
    }
}
