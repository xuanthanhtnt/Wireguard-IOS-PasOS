// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS

import SwiftUI
import UIKit

struct AboutScreen: View {
    @EnvironmentObject private var updates: UpdateChecker
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        Image("AboutIcon")
                            .resizable()
                            .frame(width: 88, height: 88)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        Text("WG VPN").font(.title2.bold())
                        Text("VPN WireGuard & AmneziaWG tự giám sát máy chủ")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            Clipboard.copy("WG VPN \(AppInfo.version) (\(AppInfo.build)) • \(UIDevice.current.systemName) \(UIDevice.current.systemVersion) • \(UIDevice.current.model)")
                            copied = true
                        } label: {
                            Text(copied ? "Đã sao chép" : "Phiên bản \(AppInfo.version) • \(UIDevice.current.systemName) \(UIDevice.current.systemVersion) • chạm để sao chép")
                                .font(.footnote)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section {
                    Button {
                        Task { await updates.check() }
                    } label: {
                        HStack {
                            Label("Kiểm tra cập nhật", systemImage: "arrow.triangle.2.circlepath")
                            if updates.checking {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    if let latest = updates.latest {
                        if updates.updateAvailable {
                            Button {
                                openURL(latest.ipaURL ?? latest.pageURL)
                            } label: {
                                DescriptionRow(title: "Tải bản \(latest.version)", description: "Có phiên bản mới. Tải file .ipa rồi cài lại bằng công cụ bạn đã dùng (TrollStore, AltStore, Sideloadly…).")
                            }
                        } else {
                            Text("Bạn đang dùng bản mới nhất (\(latest.version))").foregroundStyle(.secondary)
                        }
                    }
                    if let error = updates.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    Link(destination: AppInfo.releasesURL) {
                        DescriptionRow(title: "Các bản phát hành", description: "Nhật ký thay đổi và file IPA trên GitHub")
                    }
                } header: {
                    Text("Cập nhật")
                } footer: {
                    Text("Đang dùng: \(AppInfo.version). Ứng dụng tự tìm phiên bản mới trên GitHub mỗi ngày.")
                }

                Section {
                    Label("WireGuard và AmneziaWG (chống DPI)", systemImage: "lock.shield")
                    Label("Tự cập nhật IP máy chủ (DDNS, DoH, URL)", systemImage: "arrow.triangle.swap")
                    Label("Tạm ngắt khi máy chủ mất điện, tự kết nối lại", systemImage: "bolt.slash")
                    Label("Tự động bật/tắt theo Wi-Fi và di động", systemImage: "wifi")
                    Label("Kill switch, DNS mã hóa, Face ID", systemImage: "hand.raised")
                } header: {
                    Text("Tính năng")
                }

                Section {
                    Link(destination: AppInfo.sourceURL) { Label("Mã nguồn trên GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
                    Link(destination: AppInfo.issuesURL) { Label("Báo lỗi hoặc góp ý", systemImage: "exclamationmark.bubble") }
                    Link(destination: URL(string: "https://github.com/\(AppInfo.androidRepository)")!) { Label("WG VPN cho Android", systemImage: "apps.iphone") }
                } header: {
                    Text("Thông tin")
                } footer: {
                    Text("WG VPN là bản phái sinh của WG Tunnel © Zane Schepke (MIT), dùng WireGuardKit © WireGuard LLC (MIT) và AmneziaWG © Amnezia (MIT). “WireGuard” là nhãn hiệu đã đăng ký của Jason A. Donenfeld. WG VPN không phải sản phẩm chính thức của dự án WireGuard, AmneziaWG hay WG Tunnel.")
                }
            }
            .navigationTitle("Giới thiệu")
        }
    }
}
