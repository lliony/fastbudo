import Foundation

/// 检查与下载共用发行源；客户端匿名访问，不内置仓库凭据。
enum ReleaseSource {
    static let repository = "llliony/fastbudo"
    /// 拉取发行列表，从中挑选最新的正式版；不再依赖 /latest（它不排除预发布版本）。
    static let apiReleases = URL(string: "https://gitee.com/api/v5/repos/" + repository + "/releases?per_page=100&page=1")!
    static let webLatest = URL(string: "https://gitee.com/" + repository + "/releases/latest")!
    static let tagPrefix = "/" + repository + "/releases/tag/"
    static func releaseURL(tag: String) -> URL {
        URL(string: "https://gitee.com/" + repository + "/releases/tag/")!.appendingPathComponent(tag)
    }
    static func downloadBase(tag: String) -> URL {
        URL(string: "https://gitee.com/" + repository + "/releases/download/")!.appendingPathComponent(tag)
    }
}

/// 更新偏好的共享存储键；设置页与应用启动读取同一值，避免字面量分散。
enum UpdatePreferences {
    static let autoDownloadKey = "autoDownloadUpdates"
}

/// 手动查询正式版；下载链接固定在本项目，服务端数据不能指定任意跳转地址。
enum UpdateChecker {
    struct Release: Decodable {
        let tag: String
        let draft: Bool?
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
            case .rateLimited: "Gitee 暂时限制了请求，请稍后重试。"
            case .noRelease: "无法访问更新源：仓库可能为私有或尚无正式版本，请联系发布者确认。"
            case .invalidResponse: "版本信息无效，请稍后重试。"
            case .server(let status): "更新服务返回错误（\(status)），请稍后重试。"
            }
        }
    }

    static func check(current: String, session: URLSession = .shared) async throws -> Release? {
        var request = URLRequest(url: ReleaseSource.apiReleases,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
            return try newerRelease(pageResponse: pageResponse, current: current)
        }
        guard response.statusCode == 200 else {
            throw response.statusCode == 404 ? CheckError.noRelease : CheckError.server(response.statusCode)
        }
        let releases: [Release]
        do {
            releases = try JSONDecoder().decode([Release].self, from: data)
        } catch {
            throw CheckError.invalidResponse
        }
        // 只认最新正式版：跳过草稿、预发布及不可解析的三段版号标签。
        guard let latest = try latestStable(in: releases) else { throw CheckError.noRelease }
        return try newerRelease(latest, current: current)
    }

    /// 单个候选发行对象的判定入口（测试/内部用）：候选必须是正式版。
    static func newerRelease(data: Data, status: Int, current: String) throws -> Release? {
        switch status {
        case 200: break
        case 403, 429: throw CheckError.rateLimited
        case 404: throw CheckError.noRelease
        default: throw CheckError.server(status)
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              release.draft != true, !release.prerelease else { throw CheckError.invalidResponse }
        return try newerRelease(release, current: current)
    }

    static func newerRelease(pageResponse: HTTPURLResponse, current: String) throws -> Release? {
        if pageResponse.statusCode == 404 { throw CheckError.noRelease }
        guard pageResponse.statusCode == 200 else { throw CheckError.server(pageResponse.statusCode) }
        let prefix = ReleaseSource.tagPrefix
        guard let url = pageResponse.url, url.scheme == "https", url.host == "gitee.com",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              url.path.hasPrefix(prefix) else { throw CheckError.invalidResponse }
        let tag = String(url.path.dropFirst(prefix.count))
        // latest 跳到预发布等非正式标签时，视为该源暂无正式版可更新，而不是报错。
        guard (try? stableVersion(tag)) != nil else { return nil }
        return try newerRelease(Release(tag: tag, draft: false, prerelease: false, body: nil), current: current)
    }

    private static func latestStable(in releases: [Release]) throws -> Release? {
        var latest: Release?
        var latestVersion: [Int]?
        for release in releases where release.draft != true && release.prerelease == false {
            guard let version = try? stableVersion(release.tag) else { continue }
            if latestVersion == nil || latestVersion!.lexicographicallyPrecedes(version) {
                latest = release
                latestVersion = version
            }
        }
        return latest
    }

    private static func newerRelease(_ release: Release, current: String) throws -> Release? {
        // 当前安装版本为预发布/不可解析时不做比较（beta 经站点分发，不进入应用内更新）。
        guard let installed = try? stableVersion(current) else { return nil }
        let latest = try stableVersion(release.tag)
        return installed.lexicographicallyPrecedes(latest) ? release : nil
    }

    private static func stableVersion(_ value: String) throws -> [Int] {
        let value = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        // 只接受三段正式版号；预发布标签（如 0.0.11.beta）在此按不可解析处理。
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