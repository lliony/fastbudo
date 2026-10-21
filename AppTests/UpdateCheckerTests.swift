import Foundation
import Testing
@testable import FastBudo

struct UpdateCheckerTests {
    private func release(_ tag: String, draft: Bool = false, prerelease: Bool = false) -> Data {
        Data("""
        {"tag_name":"\(tag)","draft":\(draft),"prerelease":\(prerelease)}
        """.utf8)
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
        #expect(throws: (any Error).self) {
            try UpdateChecker.newerRelease(data: release("v1.0.0"), status: 200, current: "unknown")
        }
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
        #expect(try await UpdateChecker.check(current: "0.0.1", session: session)?.tag == "v0.2.0")
        #expect(try await UpdateChecker.check(current: "0.2.0", session: session) == nil)
    }

    @Test func rejectsUntrustedOrInvalidWebsiteResponses() {
        for address in ["https://example.com/lliony/fastbudo/releases/tag/v0.2.0",
                        "http://github.com/lliony/fastbudo/releases/tag/v0.2.0",
                        "https://github.com/other/project/releases/tag/v0.2.0",
                        "https://github.com/lliony/fastbudo/releases/latest",
                        "https://github.com/lliony/fastbudo/releases/tag/v0.2.0-beta"] {
            let response = HTTPURLResponse(url: URL(string: address)!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            #expect(throws: (any Error).self) { try UpdateChecker.newerRelease(pageResponse: response, current: "0.0.1") }
        }
        let failed = HTTPURLResponse(url: URL(string: "https://github.com/lliony/fastbudo/releases/tag/v0.2.0")!,
                                     statusCode: 503, httpVersion: nil, headerFields: nil)!
        #expect(throws: (any Error).self) { try UpdateChecker.newerRelease(pageResponse: failed, current: "0.0.1") }
    }

    @Test func downloadUsesFixedRepository() throws {
        let result = try #require(try UpdateChecker.newerRelease(data: release("v0.1.0"), status: 200, current: "0.0.1"))
        #expect(result.url.absoluteString == "https://github.com/lliony/fastbudo/releases/tag/v0.1.0")
    }
}

private final class UpdateResponseProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"tag_name":"v0.2.0","draft":false,"prerelease":false}"#.utf8))
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
        let api = request.url?.host == "api.github.com"
        let status = api ? Int(request.value(forHTTPHeaderField: "X-Test-Status") ?? "403")! : 200
        let url = api ? request.url! : URL(string: "https://github.com/lliony/fastbudo/releases/tag/v0.2.0")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
