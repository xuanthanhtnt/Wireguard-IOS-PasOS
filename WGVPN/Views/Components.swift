// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS

import NetworkExtension
import SwiftUI
import UIKit

extension Color {
    static let wgAccent = Color(red: 30 / 255, green: 187 / 255, blue: 188 / 255)
    static let wgNavy = Color(red: 15 / 255, green: 32 / 255, blue: 54 / 255)
}

/// What a tunnel row / detail shows as its state, including the watchdog pause.
struct TunnelState {
    var text: String
    var color: Color
    var busy: Bool

    @MainActor
    init(item: TunnelItem, pause: PauseState?) {
        if let pause = pause, pause.tunnelId == item.tunnelId {
            if pause.tunnelStopped {
                text = "Đã tắt – chờ máy chủ có điện trở lại"
            } else {
                text = "Tạm ngắt – máy chủ không phản hồi"
            }
            color = .orange
            busy = false
            return
        }
        busy = false
        switch item.status {
        case .connected:
            text = "Đã kết nối"
            color = .green
        case .connecting:
            text = "Đang kết nối…"
            color = .yellow
            busy = true
        case .reasserting:
            text = "Đang kết nối lại…"
            color = .yellow
            busy = true
        case .disconnecting:
            text = "Đang ngắt…"
            color = .secondary
            busy = true
        case .invalid:
            text = "Cấu hình không hợp lệ"
            color = .red
        case .disconnected:
            text = "Đã ngắt"
            color = .secondary
        @unknown default:
            text = "Không rõ"
            color = .secondary
        }
        if item.onDemand.enabled { text += " • Tự động" }
    }
}

struct StatusDot: View {
    var color: Color

    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9)
    }
}

/// UIActivityViewController for sharing files.
struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// A row with a title and a secondary description, like the Android settings rows.
struct DescriptionRow: View {
    var title: String
    var description: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            if let description = description, !description.isEmpty {
                Text(description).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct ToggleRow: View {
    var title: String
    var description: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            DescriptionRow(title: title, description: description)
        }
        .tint(.wgAccent)
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }
}

extension Date {
    var relativeVietnamese: String {
        let seconds = Int(Date().timeIntervalSince(self))
        if seconds < 5 { return "vừa xong" }
        if seconds < 60 { return "\(seconds) giây trước" }
        if seconds < 3600 { return "\(seconds / 60) phút trước" }
        if seconds < 86_400 { return "\(seconds / 3600) giờ trước" }
        return "\(seconds / 86_400) ngày trước"
    }
}
