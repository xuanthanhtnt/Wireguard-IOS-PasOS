// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS

import SwiftUI

struct TunnelEditorView: View {
    enum Mode {
        case create(template: String)
        case edit(TunnelItem)
    }

    let mode: Mode
    @EnvironmentObject private var tunnels: TunnelsManager
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var text = ""
    @State private var error: String?
    @State private var saving = false
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                TextField("Tên tunnel", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Tên")
            }
            Section {
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: 320)
            } header: {
                Text("Cấu hình (wg-quick / AmneziaWG)")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let publicKey = publicKey {
                        Text("Khóa công khai: \(publicKey)").textSelection(.enabled)
                    }
                    if let error = error {
                        Text(error).foregroundStyle(.red)
                    }
                    Text("Các khóa iOS không dùng được (PostUp, Table, IncludedApplications…) sẽ được bỏ qua.")
                }
                .font(.footnote)
            }
            Section {
                Button {
                    regenerateKey()
                } label: {
                    Label("Tạo cặp khóa mới", systemImage: "key")
                }
            }
        }
        .navigationTitle(isCreate ? "Tunnel mới" : "Sửa tunnel")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Hủy") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button("Lưu") { Task { await save() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: text) { _ in error = nil }
    }

    private var isCreate: Bool {
        if case .create = mode { return true }
        return false
    }

    private var publicKey: String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0].lowercased() == "privatekey", let key = PrivateKey(base64Key: parts[1]) {
                return key.publicKey.base64Key
            }
        }
        return nil
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch mode {
        case .create(let template):
            name = tunnels.uniqueName("Tunnel")
            text = template
        case .edit(let item):
            name = item.name
            text = item.configuration?.asWgQuickConfig() ?? item.configText
        }
    }

    private func regenerateKey() {
        let key = PrivateKey()
        var lines = text.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("privatekey") }) {
            lines[index] = "PrivateKey = \(key.base64Key)"
        } else if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "[interface]" }) {
            lines.insert("PrivateKey = \(key.base64Key)", at: index + 1)
        } else {
            lines.insert(contentsOf: ["[Interface]", "PrivateKey = \(key.base64Key)"], at: 0)
        }
        text = lines.joined(separator: "\n")
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            switch mode {
            case .create:
                let item = try await tunnels.add(name: name, configText: text)
                model.selectedTunnelId = item.tunnelId
            case .edit(let item):
                try await tunnels.update(item, name: name, configText: text)
                if item.isActive {
                    model.alertMessage = "Đã lưu. Kết nối lại tunnel để áp dụng cấu hình mới."
                }
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
