// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS
//
// Minimal ZIP reader (stored + deflate) and writer (stored), enough for .conf bundles and backups.

import Compression
import Foundation

enum ZipArchive {
    struct Entry {
        var name: String
        var data: Data
    }

    enum ZipError: LocalizedError {
        case invalid
        case unsupportedMethod(UInt16)
        case decompressionFailed

        var errorDescription: String? {
            switch self {
            case .invalid: return "File zip không hợp lệ"
            case .unsupportedMethod(let m): return "Kiểu nén zip không hỗ trợ (\(m))"
            case .decompressionFailed: return "Không giải nén được file zip"
            }
        }
    }

    // MARK: - Reading

    static func read(_ data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw ZipError.invalid }
        // End of central directory: scan backwards for the signature
        var eocd = -1
        var i = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 65_535)
        while i >= lowest {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.invalid }
        let count = Int(u16(bytes, eocd + 10))
        var offset = Int(u32(bytes, eocd + 16))
        var entries = [Entry]()
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, u32(bytes, offset) == 0x0201_4b50 else { throw ZipError.invalid }
            let method = u16(bytes, offset + 10)
            let compressedSize = Int(u32(bytes, offset + 20))
            let uncompressedSize = Int(u32(bytes, offset + 24))
            let nameLength = Int(u16(bytes, offset + 28))
            let extraLength = Int(u16(bytes, offset + 30))
            let commentLength = Int(u16(bytes, offset + 32))
            let localOffset = Int(u32(bytes, offset + 42))
            guard offset + 46 + nameLength <= bytes.count else { throw ZipError.invalid }
            let nameBytes = Array(bytes[(offset + 46)..<(offset + 46 + nameLength)])
            let name = String(bytes: nameBytes, encoding: .utf8) ?? String(decoding: nameBytes, as: UTF8.self)
            offset += 46 + nameLength + extraLength + commentLength

            if name.hasSuffix("/") { continue }
            guard localOffset + 30 <= bytes.count, u32(bytes, localOffset) == 0x0403_4b50 else { throw ZipError.invalid }
            let localName = Int(u16(bytes, localOffset + 26))
            let localExtra = Int(u16(bytes, localOffset + 28))
            let start = localOffset + 30 + localName + localExtra
            guard start + compressedSize <= bytes.count else { throw ZipError.invalid }
            let compressed = Array(bytes[start..<(start + compressedSize)])
            let content: Data
            switch method {
            case 0:
                content = Data(compressed)
            case 8:
                content = try inflate(compressed, expectedSize: uncompressedSize)
            default:
                throw ZipError.unsupportedMethod(method)
            }
            entries.append(Entry(name: name, data: content))
        }
        return entries
    }

    private static func inflate(_ input: [UInt8], expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = [UInt8](repeating: 0, count: expectedSize)
        let written = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(destination.baseAddress!, expectedSize, source.baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw ZipError.decompressionFailed }
        return Data(output)
    }

    // MARK: - Writing (stored, no compression)

    static func write(_ entries: [Entry]) -> Data {
        var output = [UInt8]()
        var central = [UInt8]()
        let (dosTime, dosDate) = dosTimestamp(Date())
        for entry in entries {
            let name = Array(entry.name.utf8)
            let content = [UInt8](entry.data)
            let crc = crc32(content)
            let localOffset = UInt32(output.count)

            output += le32(0x0403_4b50)
            output += le16(20)            // version needed
            output += le16(0x0800)        // UTF-8 names
            output += le16(0)             // stored
            output += le16(dosTime)
            output += le16(dosDate)
            output += le32(crc)
            output += le32(UInt32(content.count))
            output += le32(UInt32(content.count))
            output += le16(UInt16(name.count))
            output += le16(0)
            output += name
            output += content

            central += le32(0x0201_4b50)
            central += le16(20)           // version made by
            central += le16(20)
            central += le16(0x0800)
            central += le16(0)
            central += le16(dosTime)
            central += le16(dosDate)
            central += le32(crc)
            central += le32(UInt32(content.count))
            central += le32(UInt32(content.count))
            central += le16(UInt16(name.count))
            central += le16(0)
            central += le16(0)
            central += le16(0)
            central += le16(0)
            central += le32(0o100644 << 16)
            central += le32(localOffset)
            central += name
        }
        let centralOffset = UInt32(output.count)
        output += central
        output += le32(0x0605_4b50)
        output += le16(0)
        output += le16(0)
        output += le16(UInt16(entries.count))
        output += le16(UInt16(entries.count))
        output += le32(UInt32(central.count))
        output += le32(centralOffset)
        output += le16(0)
        return Data(output)
    }

    // MARK: - Helpers

    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    private static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }

    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)]
    }

    private static func dosTimestamp(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let date = UInt16(max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, date)
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
