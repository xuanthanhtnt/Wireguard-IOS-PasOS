// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS

import Foundation

/// Turns files, zip archives, URLs, QR codes and pasted text into tunnels.
@MainActor
enum ImportService {
    struct Candidate {
        var name: String
        var text: String
    }

    struct Report {
        var added: [String] = []
        var failed: [String] = []

        var message: String {
            var parts = [String]()
            if !added.isEmpty { parts.append("Đã thêm \(added.count) tunnel: \(added.joined(separator: ", "))") }
            if !failed.isEmpty { parts.append("Không nhập được:\n" + failed.joined(separator: "\n")) }
            return parts.isEmpty ? "Không tìm thấy cấu hình nào" : parts.joined(separator: "\n\n")
        }
    }

    static func candidates(fromFile url: URL) throws -> [Candidate] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return try candidates(from: data, suggestedName: url.deletingPathExtension().lastPathComponent)
    }

    static func candidates(from data: Data, suggestedName: String) throws -> [Candidate] {
        if data.starts(with: [0x50, 0x4b, 0x03, 0x04]) {
            return try ZipArchive.read(data).compactMap { entry -> Candidate? in
                let file = (entry.name as NSString).lastPathComponent
                guard file.lowercased().hasSuffix(".conf"), !file.hasPrefix("._") else { return nil }
                return Candidate(name: (file as NSString).deletingPathExtension, text: String(decoding: entry.data, as: UTF8.self))
            }
        }
        let text = String(decoding: data, as: UTF8.self)
        return [Candidate(name: suggestedName, text: text)]
    }

    static func candidates(fromURL string: String) async throws -> [Candidate] {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw TunnelsError.parse("URL không hợp lệ")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("WG VPN", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TunnelsError.parse("Máy chủ trả về HTTP \(http.statusCode)")
        }
        var name = url.deletingPathExtension().lastPathComponent
        if name.isEmpty || name == "/" { name = url.host ?? "Tunnel" }
        return try candidates(from: data, suggestedName: name)
    }

    static func add(_ candidates: [Candidate], to tunnels: TunnelsManager) async -> Report {
        var report = Report()
        for candidate in candidates {
            do {
                let item = try await tunnels.add(name: candidate.name, configText: candidate.text)
                report.added.append(item.name)
            } catch {
                report.failed.append("• \(candidate.name): \(error.localizedDescription)")
            }
        }
        return report
    }

    /// Backup of every tunnel as a zip of .conf files.
    static func backupArchive(_ tunnels: [TunnelItem]) throws -> URL {
        var used = Set<String>()
        let entries = tunnels.map { item -> ZipArchive.Entry in
            var base = item.name.replacingOccurrences(of: "/", with: "-")
            var index = 2
            while used.contains(base.lowercased()) {
                base = "\(item.name) (\(index))"
                index += 1
            }
            used.insert(base.lowercased())
            let text = item.configuration?.asWgQuickConfig() ?? item.configText
            return ZipArchive.Entry(name: "\(base).conf", data: Data(text.utf8))
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wgvpn-backup-\(formatter.string(from: Date())).zip")
        try ZipArchive.write(entries).write(to: url, options: .atomic)
        return url
    }

    static func exportFile(_ item: TunnelItem) throws -> URL {
        let name = item.name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).conf")
        let text = item.configuration?.asWgQuickConfig() ?? item.configText
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    /// Template for a new tunnel with a fresh key pair.
    static func newTunnelTemplate() -> String {
        let key = PrivateKey()
        return """
        [Interface]
        PrivateKey = \(key.base64Key)
        Address = 10.0.0.2/32
        DNS = 1.1.1.1

        [Peer]
        PublicKey =
        AllowedIPs = 0.0.0.0/0, ::/0
        Endpoint = vpn.example.com:51820
        PersistentKeepalive = 25
        """
    }
}
