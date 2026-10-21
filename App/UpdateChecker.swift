import Foundation

/// 手动查询正式版；下载链接固定在本项目，服务端数据不能指定任意跳转地址。
enum UpdateChecker {
    struct Release: Decodable {
        let tag: String
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tag = "tag_name"
            case draft, prerelease
        }

        var url: URL {
            URL(string: "https://github.com/lliony/fastbudo/releases/tag/\(tag)")!
        }
    }

    enum CheckError: LocalizedError {
        case rateLimited, noRelease, invalidResponse, server(Int)

        var errorDescription: String? {
            switch self {
            case .rateLimited: "GitHub 暂时限制了请求，请稍后重试。"
            case .noRelease: "暂未找到可用的正式版本。"
            case .invalidResponse: "版本信息无效，请稍后重试。"
            case .server(let status): "更新服务返回错误（\(status)），请稍后重试。"
            }
        }
    }

    static func check(current: String, session: URLSession = .shared) async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/lliony/fastbudo/releases/latest")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("FastBudo", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw CheckError.invalidResponse }
        if response.statusCode == 403 || response.statusCode == 429 {
            // 官网 latest 跳转不占 REST API 配额；只接受本仓库的正式版本标签。
            var fallback = URLRequest(url: URL(string: "https://github.com/lliony/fastbudo/releases/latest")!,
                                      cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            fallback.httpMethod = "HEAD"
            let (_, pageResponse) = try await session.data(for: fallback)
            try Task.checkCancellation()
            guard let pageResponse = pageResponse as? HTTPURLResponse else { throw CheckError.invalidResponse }
            return try newerRelease(pageResponse: pageResponse, current: current)
        }
        return try newerRelease(data: data, status: response.statusCode, current: current)
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
        guard pageResponse.statusCode == 200 else { throw CheckError.server(pageResponse.statusCode) }
        let prefix = "/lliony/fastbudo/releases/tag/"
        guard let url = pageResponse.url, url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              url.path.hasPrefix(prefix) else { throw CheckError.invalidResponse }
        let tag = String(url.path.dropFirst(prefix.count))
        return try newerRelease(Release(tag: tag, draft: false, prerelease: false), current: current)
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
