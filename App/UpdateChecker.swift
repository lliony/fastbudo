import Foundation

/// 检查与下载共用发行源；客户端匿名访问，不内置仓库凭据。
enum ReleaseSource {
    static let repository = "lliony/fastbudo"
    static let apiLatest = URL(string: "https://api.github.com/repos/" + repository + "/releases/latest")!
    static let webLatest = URL(string: "https://github.com/" + repository + "/releases/latest")!
    static let feed = URL(string: "https://github.com/" + repository + "/releases.atom")!
    static let tagPrefix = "/" + repository + "/releases/tag/"
    static func releaseURL(tag: String) -> URL {
        URL(string: "https://github.com/" + repository + "/releases/tag/")!.appendingPathComponent(tag)
    }
    static func downloadBase(tag: String) -> URL {
        URL(string: "https://github.com/" + repository + "/releases/download/")!.appendingPathComponent(tag)
    }
}

/// 手动查询正式版；下载链接固定在本项目，服务端数据不能指定任意跳转地址。
enum UpdateChecker {
    struct Release: Decodable {
        let tag: String
        let draft: Bool
        let prerelease: Bool
        let body: String?

        enum CodingKeys: String, CodingKey {
            case tag = "tag_name"
            case draft, prerelease, body
        }

        var notes: String? {
            guard let text = body?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }

        var url: URL {
            ReleaseSource.releaseURL(tag: tag)
        }
    }

    enum CheckError: LocalizedError {
        case rateLimited, noRelease, invalidResponse, server(Int)

        var errorDescription: String? {
            switch self {
            case .rateLimited: "GitHub 暂时限制了请求，请稍后重试。"
            case .noRelease: "更新源不可访问或暂无正式版本，请稍后重试。"
            case .invalidResponse: "版本信息无效，请稍后重试。"
            case .server(let status): "更新服务返回错误（\(status)），请稍后重试。"
            }
        }
    }

    static func check(current: String, session: URLSession = .shared) async throws -> Release? {
        var request = URLRequest(url: ReleaseSource.apiLatest,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("FastBudo", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw CheckError.invalidResponse }
        if response.statusCode == 403 || response.statusCode == 429 {
            // 官网 latest 跳转不占 REST API 配额；只接受本仓库的正式版本标签。
            var fallback = URLRequest(url: ReleaseSource.webLatest,
                                      cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            fallback.httpMethod = "HEAD"
            let (_, pageResponse) = try await session.data(for: fallback)
            try Task.checkCancellation()
            guard let pageResponse = pageResponse as? HTTPURLResponse else { throw CheckError.invalidResponse }
            let release = try newerRelease(pageResponse: pageResponse, current: current)
            return try await withFeedNotes(release, session: session)
        }
        let release = try newerRelease(data: data, status: response.statusCode, current: current)
        return try await withFeedNotes(release, session: session)
    }

    // 官网 Atom 正文不占 REST API 配额；按已验证的标签匹配，不能拿其他版本说明代替。
    private static func withFeedNotes(_ release: Release?, session: URLSession) async throws -> Release? {
        guard let release, release.notes == nil else { return release }
        let url = ReleaseSource.feed
        do {
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.url == url, let notes = feedNotes(data: data, tag: release.tag) else { return release }
            return Release(tag: release.tag, draft: release.draft, prerelease: release.prerelease, body: notes)
        } catch {
            try Task.checkCancellation()
            return release
        }
    }

    static func feedNotes(data: Data, tag: String) -> String? {
        guard data.count <= 2 * 1024 * 1024,
              let xml = String(data: data, encoding: .utf8), !xml.contains("<!DOCTYPE") else { return nil }
        let delegate = FeedNotes(target: ReleaseSource.releaseURL(tag: tag).absoluteString)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let html = delegate.result else { return nil }
        var text = html.replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<li(?:\\s[^>]*)?>", with: "- ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</(?:p|h[1-6]|li|div|ul|ol)>|<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&nbsp;": " "]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let range = Range(match.range(at: 1), in: text), let whole = Range(match.range, in: text) else { continue }
                let value = String(text[range])
                let number = value.hasPrefix("x") ? UInt32(value.dropFirst(), radix: 16) : UInt32(value)
                if let number, let scalar = UnicodeScalar(number) { text.replaceSubrange(whole, with: String(scalar)) }
            }
        }
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        let result = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        return result.isEmpty ? nil : result
    }

    private final class FeedNotes: NSObject, XMLParserDelegate {
        let target: String
        var result: String?
        private var inEntry = false
        private var inContent = false
        private var matches = false
        private var content = ""
        init(target: String) { self.target = target }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if elementName == "entry" { inEntry = true; matches = false; content = "" }
            if inEntry && elementName == "link" && attributes["href"] == target { matches = true }
            if inEntry && elementName == "content" { inContent = true }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if inContent { content += string } }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if inContent, let text = String(data: CDATABlock, encoding: .utf8) { content += text }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            if elementName == "content" { inContent = false }
            if elementName == "entry" {
                if matches { result = content }
                inEntry = false
            }
        }
    }

    static func newerRelease(data: Data, status: Int, current: String) throws -> Release? {
        switch status {
        case 200: break
        case 403, 429: throw CheckError.rateLimited
        case 404: throw CheckError.noRelease
        default: throw CheckError.server(status)
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              !release.draft, !release.prerelease else { throw CheckError.invalidResponse }
        return try newerRelease(release, current: current)
    }

    static func newerRelease(pageResponse: HTTPURLResponse, current: String) throws -> Release? {
        if pageResponse.statusCode == 404 { throw CheckError.noRelease }
        guard pageResponse.statusCode == 200 else { throw CheckError.server(pageResponse.statusCode) }
        let prefix = ReleaseSource.tagPrefix
        guard let url = pageResponse.url, url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              url.path.hasPrefix(prefix) else { throw CheckError.invalidResponse }
        let tag = String(url.path.dropFirst(prefix.count))
        return try newerRelease(Release(tag: tag, draft: false, prerelease: false, body: nil), current: current)
    }

    private static func newerRelease(_ release: Release, current: String) throws -> Release? {
        let latest = try version(release.tag)
        let installed = try version(current)
        return installed.lexicographicallyPrecedes(latest) ? release : nil
    }

    private static func version(_ value: String) throws -> [Int] {
        let value = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        // shortcut: 只接受项目现有的三段正式版号；引入预发布渠道时再扩展比较规则。
        guard parts.count == 3 else { throw CheckError.invalidResponse }
        return try parts.map { part in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0", let number = Int(part) else {
                throw CheckError.invalidResponse
            }
            return number
        }
    }
}
