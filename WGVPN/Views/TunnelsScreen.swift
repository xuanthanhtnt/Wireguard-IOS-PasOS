// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct TunnelsScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tunnels: TunnelsManager
    @EnvironmentObject private var watchdog: WatchdogController

    @State private var showFileImporter = false
    @State private var showScanner = false
    @State private var showURLPrompt = false
    @State private var urlText = ""
    @State private var newTunnelTemplate: String?
    @State private var importing = false

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedTunnelId) {
                if let pause = watchdog.pause {
                    Section {
                        PauseBanner(pause: pause)
                    }
                }
                Section {
                    ForEach(tunnels.tunnels) { item in
                        TunnelRow(item: item)
                            .tag(item.tunnelId)
                    }
                    .onDelete { offsets in
                        let items = offsets.map { tunnels.tunnels[$0] }
                        Task {
                            for item in items {
                                do { try await tunnels.remove(item) } catch { model.alertMessage = error.localizedDescription }
                            }
                        }
                    }
                } footer: {
                    if tunnels.loaded && tunnels.tunnels.isEmpty {
                        EmptyTunnelsHint()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("WG VPN")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    addMenu
                }
            }
            .refreshable { await tunnels.reload() }
            .overlay {
                if importing { ProgressView().controlSize(.large) }
            }
        } detail: {
            if let id = model.selectedTunnelId, let item = tunnels.tunnel(id: id) {
                TunnelDetailView(item: item)
                    .id(item.tunnelId)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.system(size: 54))
                        .foregroundStyle(Color.wgAccent)
                    Text("Chọn một tunnel").foregroundStyle(.secondary)
                }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task { await importFiles(urls) }
            case .failure(let error):
                model.alertMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showScanner) {
            QRScannerScreen { text in
                showScanner = false
                Task {
                    let report = await ImportService.add([ImportService.Candidate(name: "QR", text: text)], to: tunnels)
                    model.alertMessage = report.message
                }
            }
        }
        .sheet(item: Binding(get: { newTunnelTemplate.map { TemplateBox(text: $0) } }, set: { newTunnelTemplate = $0?.text })) { box in
            NavigationStack {
                TunnelEditorView(mode: .create(template: box.text))
            }
        }
        .alert("Nhập từ URL", isPresented: $showURLPrompt) {
            TextField("https://…/tunnel.conf", text: $urlText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Hủy", role: .cancel) {}
            Button("Tải về") {
                let link = urlText
                Task { await importURL(link) }
            }
        } message: {
            Text("Địa chỉ một file .conf hoặc .zip")
        }
    }

    private var addMenu: some View {
        Menu {
            Button { showFileImporter = true } label: { Label("Nhập từ file (.conf, .zip)", systemImage: "doc") }
            Button { showScanner = true } label: { Label("Quét mã QR", systemImage: "qrcode.viewfinder") }
            Button { urlText = ""; showURLPrompt = true } label: { Label("Nhập từ URL", systemImage: "link") }
            Button { pasteFromClipboard() } label: { Label("Dán từ bộ nhớ tạm", systemImage: "doc.on.clipboard") }
            Button { newTunnelTemplate = ImportService.newTunnelTemplate() } label: { Label("Tạo thủ công", systemImage: "square.and.pencil") }
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("Thêm tunnel")
    }

    static var importTypes: [UTType] {
        var types: [UTType] = [.zip, .plainText, .data]
        if let conf = UTType(filenameExtension: "conf") { types.insert(conf, at: 0) }
        return types
    }

    private func importFiles(_ urls: [URL]) async {
        importing = true
        defer { importing = false }
        var candidates = [ImportService.Candidate]()
        var errors = [String]()
        for url in urls {
            do {
                candidates += try ImportService.candidates(fromFile: url)
            } catch {
                errors.append("• \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        var report = await ImportService.add(candidates, to: tunnels)
        report.failed += errors
        model.alertMessage = report.message
        if let first = report.added.first, let item = tunnels.tunnels.first(where: { $0.name == first }) {
            model.selectedTunnelId = item.tunnelId
        }
    }

    private func importURL(_ link: String) async {
        importing = true
        defer { importing = false }
        do {
            let candidates = try await ImportService.candidates(fromURL: link)
            model.alertMessage = await ImportService.add(candidates, to: tunnels).message
        } catch {
            model.alertMessage = "Không tải được: \(error.localizedDescription)"
        }
    }

    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string, text.lowercased().contains("[interface]") else {
            model.alertMessage = "Bộ nhớ tạm không chứa cấu hình WireGuard"
            return
        }
        Task {
            model.alertMessage = await ImportService.add([ImportService.Candidate(name: "Tunnel", text: text)], to: tunnels).message
        }
    }
}

private struct TemplateBox: Identifiable {
    let text: String
    var id: String { text }
}

struct TunnelRow: View {
    @ObservedObject var item: TunnelItem
    @EnvironmentObject private var tunnels: TunnelsManager
    @EnvironmentObject private var watchdog: WatchdogController
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let state = TunnelState(item: item, pause: watchdog.pause)
        HStack(spacing: 12) {
            StatusDot(color: state.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.body.weight(.medium)).lineLimit(1)
                Text(state.text).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if state.busy {
                ProgressView()
            }
            Toggle("", isOn: Binding(
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
            ))
            .labelsHidden()
            .tint(.wgAccent)
        }
        .padding(.vertical, 4)
    }
}

struct PauseBanner: View {
    var pause: PauseState
    @EnvironmentObject private var watchdog: WatchdogController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Đã tạm ngắt VPN “\(pause.tunnelName)”: máy chủ không phản hồi", systemImage: "bolt.slash.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Từ \(XtFormat.time(pause.pausedAt)) • đã kiểm tra: \(pause.probeCount) lần")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Button("Kết nối lại ngay") { Task { await watchdog.resumeNow() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.wgAccent)
                Button("Hủy chờ", role: .destructive) { Task { await watchdog.cancelPause() } }
                    .buttonStyle(.bordered)
            }
            .font(.footnote)
        }
        .padding(.vertical, 4)
    }
}

private struct EmptyTunnelsHint: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Chưa có tunnel nào")
                .font(.headline)
            Text("Bấm + để nhập file .conf/.zip, quét mã QR, tải từ URL hoặc tạo cấu hình mới.")
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
    }
}
