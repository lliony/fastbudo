import Foundation
import CryptoKit
import ImageIO

struct ClipPolicy: Sendable {
    var count: Int
    var days: Int
    var bytes: Int
    static let standard = ClipPolicy(count: 1000, days: 30, bytes: 200 * 1024 * 1024)
}

enum ClipError: LocalizedError {
    case invalid, tooLarge, full, storage, backupTooLarge
    var errorDescription: String? {
        switch self {
        case .invalid: return "内容格式无效或不受支持。"
        case .tooLarge: return "内容超过单条 20 MiB 或图片尺寸限制。"
        case .full: return "保留内容已达到容量限制，请清理或提高上限。"
        case .backupTooLarge: return "备份超过 2 GiB 或单条记录超过 64 MiB 限制。"
        case .storage: return "剪贴板数据库读写失败，请检查磁盘空间及权限。"
        }
    }
}

enum ClipKind: String, Codable, CaseIterable, Sendable {
    case text, richText, image, files
    var title: String { switch self { case .text: "文本"; case .richText: "富文本"; case .image: "图片"; case .files: "文件" } }
    var symbol: String { switch self { case .text: "text.alignleft"; case .richText: "doc.richtext"; case .image: "photo"; case .files: "doc.on.doc" } }
}

enum ClipMode: String, CaseIterable, Sendable {
    case original, plain, lines, compact
    var title: String { switch self { case .original: "原样"; case .plain: "纯文本"; case .lines: "去换行"; case .compact: "去全部空白" } }
}

struct ClipPayload: Codable, Equatable, Sendable {
    var items: [[String: Data]]
    static let allowed = Set(["public.utf8-plain-text", "public.rtf", "public.html", "public.png", "public.tiff", "public.file-url"])
    static let maximum = 20 * 1024 * 1024
    static func text(_ value: String) -> Self { Self(items: [["public.utf8-plain-text": Data(value.utf8)]]) }
    var plainText: String { items.compactMap { $0["public.utf8-plain-text"].flatMap { String(data: $0, encoding: .utf8) } }.joined(separator: "\n") }
    var fileURLs: [URL] { items.compactMap { $0["public.file-url"].flatMap { String(data: $0, encoding: .utf8) }.flatMap(URL.init(string:)) } }
    var kind: ClipKind {
        let keys = Set(items.flatMap { $0.keys })
        if keys.contains("public.file-url") { return .files }
        if keys.contains("public.png") || keys.contains("public.tiff") { return .image }
        if keys.contains("public.rtf") || keys.contains("public.html") { return .richText }
        return .text
    }
    var searchText: String { plainText + "\n" + fileURLs.map(\.path).joined(separator: "\n") }
    var preview: String {
        if kind == .files { return fileURLs.map(\.lastPathComponent).joined(separator: ", ") }
        if !plainText.isEmpty { return String(plainText.prefix(500)) }
        return kind.title
    }
    /// ImageIO 直接降采样，避免先解码完整的四千万像素图片。
    func thumbnail() throws -> CGImage? {
        guard kind == .image else { return nil }
        guard let data = items.lazy.compactMap({ $0["public.png"] ?? $0["public.tiff"] }).first,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ClipError.invalid }
        return image
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
    func validate() throws {
        guard !items.isEmpty, items.count <= 200, items.allSatisfy({ !$0.isEmpty && Set($0.keys).isSubset(of: Self.allowed) }) else { throw ClipError.invalid }
        guard items.reduce(0, { $0 + $1.values.reduce(0, { $0 + $1.count }) }) <= Self.maximum else { throw ClipError.tooLarge }
        for item in items {
            if let data = item["public.file-url"] {
                guard let text = String(data: data, encoding: .utf8), let url = URL(string: text), url.isFileURL,
                      url.host == nil || url.host == "" || url.host == "localhost" else { throw ClipError.invalid }
            }
            for type in ["public.png", "public.tiff"] {
                if let data = item[type] {
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let w = info[kCGImagePropertyPixelWidth] as? Int, let h = info[kCGImagePropertyPixelHeight] as? Int,
                          w > 0, h > 0, w <= 20000, h <= 20000, w * h <= 40_000_000 else { throw ClipError.tooLarge }
                }
            }
        }
    }
}

struct ClipboardItem: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var kind: ClipKind
    var preview: String
    var title = ""
    var source: String
    var group = ""
    var favorite = false
    var pinned = false
    var reply = false
    var queued = false
    var order = Date().timeIntervalSince1970
    var queueOrder = Date().timeIntervalSince1970
    var created = Date()
    var used = Date()
    var protected: Bool { favorite || pinned || reply || queued }
    var label: String { title.isEmpty ? preview : title }
}
