import Foundation
import Testing
@testable import FastBudo

struct UpdateCheckerTests {
    @Test func rateLimitAndMissingWebsiteAreNotUpToDate() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateRateLimitProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Test-Status": "403", "X-Test-Web-Status": "404"]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await UpdateChecker.check(current: "0.0.5", session: session)
            Issue.record("源不可访问不能显示已是最新")
        } catch {
            guard case UpdateChecker.CheckError.noRelease = error else {
                Issue.record("错误分类不正确"); return
            }
        }
    }

    @Test func releaseLinksUseCurrentRepository() {
        #expect(ReleaseSource.apiReleases.path == "/api/v5/repos/llliony/fastbudo/releases")
        #expect(ReleaseSource.releaseURL(tag: "v0.0.6").path == "/llliony/fastbudo/releases/tag/v0.0.6")
        #expect(ReleaseSource.downloadBase(tag: "v0.0.6").appendingPathComponent("SHA256SUMS.txt").path ==
                "/llliony/fastbudo/releases/download/v0.0.6/SHA256SUMS.txt")
    }

    @Test func website404IsUnavailable() throws {
        let response = try #require(HTTPURLResponse(url: URL(string: "https://gitee.com/llliony/fastbudo/releases/latest")!,
            statusCode: 404, httpVersion: nil, headerFields: nil))
        do {
            _ = try UpdateChecker.newerRelease(pageResponse: response, current: "0.0.5")
            Issue.record("404 不能显示已是最新")
        } catch {
            guard case UpdateChecker.CheckError.noRelease = error else {
                Issue.record("404 应归类为源不可访问"); return
            }
        }
    }

    private func release(_ tag: String, draft: Bool = false, prerelease: Bool = false) -> Data {
        Data("""
        {"tag_name":"\(tag)","draft":\(draft),"prerelease":\(prerelease)}
        """.utf8)
    }

    @Test func includesReleaseNotesForNewVersion() throws {
        let data = Data(#"{"tag_name":"v0.2.0","draft":false,"prerelease":false,"body":"  新增更新说明\n修复检查失败  "}"#.utf8)
        let result = try #require(try UpdateChecker.newerRelease(data: data, status: 200, current: "0.0.1"))
        #expect(result.notes == "新增更新说明\n修复检查失败")
    }

    @Test func absentOrBlankNotesDoNotPreventUpdates() throws {
        for body in ["null", "\"\"", "\"  \""] {
            let data = Data("{\"tag_name\":\"v0.2.0\",\"draft\":false,\"prerelease\":false,\"body\":\(body)}".utf8)
            let result = try #require(try UpdateChecker.newerRelease(data: data, status: 200, current: "0.0.1"))
            #expect(result.notes == nil)
        }
        let result = try #require(try UpdateChecker.newerRelease(data: release("v0.2.0"), status: 200, current: "0.0.1"))
        #expect(result.notes == nil)
    }

    @Test func comparesNumericVersions() throws {
        #expect(try UpdateChecker.newerRelease(data: release("v0.0.10"), status: 200, current: "0.0.9")?.tag == "v0.0.10")
        #expect(try UpdateChecker.newerRelease(data: release("v1.0.0"), status: 200, current: "0.99.99") != nil)
        for tag in ["v0.0.1", "0.0.0"] {
            #expect(try UpdateChecker.newerRelease(data: release(tag), status: 200, current: "0.0.1") == nil)
        }
    }

    @Test func rejectsUnusableReleases() {
        for tag in ["", "v1.2", "v1.2.3.4", "v1.2.3-beta", "v1.-2.3", "v1.2.x", "v01.2.3"] {
            #expect(throws: (any Error).self) {
                try UpdateChecker.newerRelease(data: release(tag), status: 200, current: "0.0.1")
            }
        }
        for data in [release("v1.0.0", draft: true), release("v1.0.0", prerelease: true), Data("{}".utf8)] {
            #expect(throws: (any Error).self) {
                try UpdateChecker.newerRelease(data: data, status: 200, current: "0.0.1")
            }
        }
        // 当前版本不可解析（如 beta 预发布、未知版本）不报错，视为已是最新。
        #expect((try? UpdateChecker.newerRelease(data: release("v1.0.0"), status: 200, current: "unknown")) == nil)
        #expect((try? UpdateChecker.newerRelease(data: release("v1.0.0"), status: 200, current: "0.0.11.beta")) == nil)
    }

    @Test func choosesNewestStableIgnoringPrerelease() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateListProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        // 仓库最新是 v0.0.11.beta 预发布，正式最新仍是 v0.0.10。
        let result = try await UpdateChecker.check(current: "0.0.9", session: session)
        #expect(result?.tag == "v0.0.10")
        #expect(try await UpdateChecker.check(current: "0.0.10", session: session) == nil)
    }

    @Test func httpFailuresAreNotReportedAsUpToDate() {
        for status in [403, 404, 429, 500] {
            #expect(throws: (any Error).self) {
                try UpdateChecker.newerRelease(data: release("v0.0.1"), status: status, current: "0.0.1")
            }
        }
    }

    @Test func networkResponseAndTimeout() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let result = try await UpdateChecker.check(current: "0.0.1", session: session)
        #expect(result?.tag == "v0.2.0")

        configuration.protocolClasses = [UpdateTimeoutProtocol.self]
        let timeoutSession = URLSession(configuration: configuration)
        defer { timeoutSession.invalidateAndCancel() }
        do {
            _ = try await UpdateChecker.check(current: "0.0.1", session: timeoutSession)
            Issue.record("网络超时不应被当作已是最新版本")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
    }

    @Test(arguments: [403, 429]) func fallsBackToWebsiteWhenRateLimited(status: Int) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateRateLimitProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Test-Status": String(status)]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let result = try await UpdateChecker.check(current: "0.0.1", session: session)
        #expect(result?.tag == "v0.2.0")
        #expect(result?.notes == nil)
        #expect(try await UpdateChecker.check(current: "0.2.0", session: session) == nil)
    }

    @Test(arguments: [403, 429]) func unavailableWebsiteAfterRateLimitHasActionableError(status: Int) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateRateLimitProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Test-Status": String(status), "X-Test-Web-Status": "404"]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var unavailable = false
        do { _ = try await UpdateChecker.check(current: "0.0.5", session: session) }
        catch UpdateChecker.CheckError.noRelease { unavailable = true }
        #expect(unavailable)
    }

    @Test func rejectsUntrustedOrInvalidWebsiteResponses() {
        for address in ["https://example.com/llliony/fastbudo/releases/tag/v0.2.0",
                        "http://gitee.com/llliony/fastbudo/releases/tag/v0.2.0",
                        "https://gitee.com/other/project/releases/tag/v0.2.0",
                        "https://gitee.com/llliony/fastbudo/releases/latest"] {
            let response = HTTPURLResponse(url: URL(string: address)!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            #expect(throws: (any Error).self) { try UpdateChecker.newerRelease(pageResponse: response, current: "0.0.1") }
        }
        // latest 跳到预发布标签时视为暂无正式版更新，而不是报错。
        let beta = HTTPURLResponse(url: URL(string: "https://gitee.com/llliony/fastbudo/releases/tag/v0.2.0-beta")!,
                                   statusCode: 200, httpVersion: nil, headerFields: nil)!
        #expect((try? UpdateChecker.newerRelease(pageResponse: beta, current: "0.0.1")) == nil)
        let failed = HTTPURLResponse(url: URL(string: "https://gitee.com/llliony/fastbudo/releases/tag/v0.2.0")!,
                                     statusCode: 503, httpVersion: nil, headerFields: nil)!
        #expect(throws: (any Error).self) { try UpdateChecker.newerRelease(pageResponse: failed, current: "0.0.1") }
    }

    @Test func downloadUsesFixedRepository() throws {
        let result = try #require(try UpdateChecker.newerRelease(data: release("v0.1.0"), status: 200, current: "0.0.1"))
        #expect(result.url.absoluteString == "https://gitee.com/llliony/fastbudo/releases/tag/v0.1.0")
    }
}

private final class UpdateResponseProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"[{"tag_name":"v0.2.0","draft":false,"prerelease":false}]"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class UpdateListProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // 仓库最新为 v0.0.11.beta 预发布，正式版最新是 v0.0.10。
        client?.urlProtocol(self, didLoad: Data(#"[{"tag_name":"v0.0.11.beta","draft":false,"prerelease":true},{"tag_name":"v0.0.10","draft":false,"prerelease":false}]"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class UpdateTimeoutProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
    }
    override func stopLoading() {}
}

private final class UpdateRateLimitProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let api = request.url?.path.hasPrefix("/api/v5/") == true
        let status = api ? Int(request.value(forHTTPHeaderField: "X-Test-Status") ?? "403")! : Int(request.value(forHTTPHeaderField: "X-Test-Web-Status") ?? "200")!
        let url = api ? request.url! : URL(string: "https://gitee.com/llliony/fastbudo/releases/tag/v0.2.0")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
