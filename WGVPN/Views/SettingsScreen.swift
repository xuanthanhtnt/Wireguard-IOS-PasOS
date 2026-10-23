// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tunnels: TunnelsManager
    @EnvironmentObject private var watchdog: WatchdogController
    @EnvironmentObject private var lock: AppLock

    @State private var sharedFile: SharedFile?
    @State private var showRestore = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        WatchdogScreen()
                    } label: {
                        DescriptionRow(title: "Giám sát máy chủ", description: "Tự cập nhật IP máy chủ và tạm ngắt VPN khi máy chủ mất điện")
                    }
                } header: {
                    Text("WG VPN")
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { lock.enabled },
                        set: { value in Task { _ = await lock.setEnabled(value) } }
                    )) {
                        DescriptionRow(title: "Khóa ứng dụng", description: "Yêu cầu \(lock.biometryName) khi mở WG VPN")
                    }
                    .tint(.wgAccent)
                    .disabled(!lock.canUse && !lock.enabled)
                } header: {
                    Text("Bảo mật")
                }

                Section {
                    Button {
                        backup()
                    } label: {
                        Label("Sao lưu tất cả tunnel (.zip)", systemImage: "archivebox")
                    }
                    .disabled(tunnels.tunnels.isEmpty)
                    Button {
                        showRestore = true
                    } label: {
                        Label("Khôi phục từ file sao lưu", systemImage: "arrow.down.doc")
                    }
                } header: {
                    Text("Sao lưu")
                } footer: {
                    Text("File sao lưu chứa khóa bí mật của các tunnel. Hãy cất giữ cẩn thận.")
                }

                Section {
                    DescriptionRow(title: "Phím tắt (Shortcuts) & Siri", description: "Dùng các thao tác “Bật tunnel”, “Tắt tunnel”, “Bật/tắt tunnel” của WG VPN trong ứng dụng Phím tắt (tự động hóa theo thời gian, vị trí, NFC…).")
                    DescriptionRow(title: "Liên kết điều khiển", description: "wgvpn://connect?name=Tên  •  wgvpn://disconnect  •  wgvpn://toggle?name=Tên  •  wgvpn://check")
                } header: {
                    Text("Điều khiển từ xa")
                }

                Section {
                    NavigationLink {
                        LogView()
                    } label: {
                        Label("Nhật ký", systemImage: "doc.text.magnifyingglass")
                    }
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } label: {
                        Label("Quyền của ứng dụng (thông báo, camera)", systemImage: "gear")
                    }
                } header: {
                    Text("Khác")
                }
            }
            .navigationTitle("Cài đặt")
        }
        .sheet(item: $sharedFile) { file in
            ShareSheet(items: [file.url])
        }
        .fileImporter(isPresented: $showRestore, allowedContentTypes: TunnelsScreen.importTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                var candidates = [ImportService.Candidate]()
                for url in urls {
                    if let found = try? ImportService.candidates(fromFile: url) { candidates += found }
                }
                model.alertMessage = await ImportService.add(candidates, to: tunnels).message
            }
        }
    }

    private func backup() {
        do {
            sharedFile = SharedFile(url: try ImportService.backupArchive(tunnels.tunnels))
        } catch {
            model.alertMessage = error.localizedDescription
        }
    }
}

struct LogView: View {
    @State private var text = ""
    @State private var sharedFile: SharedFile?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "Chưa có nhật ký" : text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                Color.clear.frame(height: 1).id("bottom")
            }
            .onAppear {
                reload()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { proxy.scrollTo("bottom") }
            }
        }
        .navigationTitle("Nhật ký")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                Button { share() } label: { Image(systemName: "square.and.arrow.up") }
                Button(role: .destructive) {
                    XtLog.clear()
                    reload()
                } label: { Image(systemName: "trash") }
            }
        }
        .sheet(item: $sharedFile) { file in
            ShareSheet(items: [file.url])
        }
    }

    private func reload() {
        let lines = XtLog.readAll().split(separator: "\n", omittingEmptySubsequences: true)
        text = lines.suffix(3000).joined(separator: "\n")
    }

    private func share() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wgvpn-log.txt")
        try? XtLog.readAll().write(to: url, atomically: true, encoding: .utf8)
        sharedFile = SharedFile(url: url)
    }
}
