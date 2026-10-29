---
title: 公开更新源修复实施计划
status: cancelled
last_updated: 2026-10-28
related_spec: ../specs/2026-10-28-public-updates-design.md
---

# 公开更新源修复 Implementation Plan

> 历史方案已取消：用户于 2026-10-28 决定沿用当前私有仓库 lliony/fastbudo，并已完成 0.0.6 本地安装。以下公开源地址与步骤不再适用。当前状态见[验证记录](../../validation/2026-10-28-public-update-source.md)。

> **For agentic workers:** 使用 executing-plans 在当前会话顺序实施；用户选择委派时才使用 subagent-driven-development。

**Goal:** 修复匿名客户端访问私有更新源导致的 404，保留源码私有并恢复可验证的公开安装包更新。

**Architecture:** 将 URL 常量集中在现有 UpdateChecker 文件的 ReleaseSource 中，检查器和安装器复用；错误分类与发布可用性分开验收。

**Tech Stack:** Swift 6、Foundation URLSession、GitHub Releases；Apple Silicon / macOS 27，无新增依赖。

**Spec:** [公开安装包设计](../specs/2026-10-28-public-updates-design.md)。

## Global Constraints

- 不嵌入令牌；不改变私有源码仓库可见性。
- 失败不显示已是最新，保留下载信任边界及回滚。
- 本轮已授权实施；不默认提交、推送或上传。
- 公开发布须双架构完整产物，首次修复版手动安装。

## Task 1：统一来源并修正失败分类

**Files:** App/UpdateChecker.swift、App/UpdateInstaller.swift、AppTests/UpdateCheckerTests.swift、AppTests/UpdateInstallerTests.swift。

**Interfaces:** 新增 ReleaseSource.repository、apiLatest、webLatest、feed、tagPrefix、releaseURL(tag:)、downloadBase(tag:)；现有 check/current/session 和 prepare 签名不变。

- [x] **1. 先增加失败测试。** UpdateCheckerTests 中新增：

~~~swift
@Test func website404IsUnavailableRatherThanGenericServerError() throws {
    let response = try #require(HTTPURLResponse(
        url: URL(string: "https://github.com/lliony/fastbudo-releases/releases/latest")!,
        statusCode: 404, httpVersion: nil, headerFields: nil))
    do {
        _ = try UpdateChecker.newerRelease(pageResponse: response, current: "0.0.5")
        Issue.record("404 不能返回已是最新")
    } catch {
        guard case UpdateChecker.CheckError.noRelease = error else {
            Issue.record("404 应归类为更新源不可访问"); return
        }
    }
}
~~~

在现有 UpdateRateLimitProtocol 中读取新增 X-Test-Web-Status，官网分支使用该值（默认 200）。新增用例设置 API=403、网页=404，调用 check 后断言 noRelease；原 403/429 成功回退测试保留。具体 fixture 改动：

~~~swift
let status = api
    ? Int(request.value(forHTTPHeaderField: "X-Test-Status") ?? "403")!
    : Int(request.value(forHTTPHeaderField: "X-Test-Web-Status") ?? "200")!
~~~

测试 session 使用独立 ephemeral configuration，设置 httpAdditionalHeaders 为上述两键；禁止使用进程共享可变 fixture。

- [x] **2. 运行红灯。**

~~~bash
bash scripts/build-engine.sh
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -only-testing:FastBudoTests/UpdateCheckerTests
~~~

- [x] **3. 添加唯一来源。** 建议名称先用下列值；创建前确认，若改名只改 repository 和对应测试预期。

~~~swift
enum ReleaseSource {
    static let repository = "lliony/fastbudo-releases"
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
~~~

逐一替换 Release.url、check 的 API/HEAD 地址、withFeedNotes URL、FeedNotes 的目标链接、newerRelease(pageResponse:) 的路径前缀、UpdateInstaller.prepare 的下载 base。不要替换 README 的源码链接或下载重定向主机白名单。

- [x] **4. 修正 404 文案及分支。**

~~~swift
// CheckError.noRelease 的 errorDescription：
"更新源不可访问或暂无正式版本，请稍后重试。"
// newerRelease(pageResponse:) 的 status == 200 guard 前：
if pageResponse.statusCode == 404 { throw CheckError.noRelease }
~~~

API 已有 404 分类，保留；500、超时和 TLS 错误不可吞掉。新源网站返回旧私有仓库 tag 路径时仍拒绝。

- [x] **5. 更新测试 URL，并添加来源一致性断言。**

~~~swift
@Test func publicReleaseLinksUseOneRepository() {
    #expect(ReleaseSource.apiLatest.path == "/repos/lliony/fastbudo-releases/releases/latest")
    #expect(ReleaseSource.releaseURL(tag: "v0.0.6").path == "/lliony/fastbudo-releases/releases/tag/v0.0.6")
    #expect(ReleaseSource.downloadBase(tag: "v0.0.6").appendingPathComponent("SHA256SUMS.txt").path ==
            "/lliony/fastbudo-releases/releases/download/v0.0.6/SHA256SUMS.txt")
}
~~~

v0.0.6 在测试中仅作样本，不等于获准发布的版本。UpdateCheckerTests fixture 的官网/tag/Atom 链接统一迁移；拒绝外域、错误路径和预发布版本测试保留。运行 UpdateCheckerTests + UpdateInstallerTests 至通过。

## Task 2：准备发布与恢复真实更新

**Files:** README.md、CHANGELOG.md、docs/guides/local-signing.md、docs/README.md；新增 docs/validation/2026-10-28-public-update-source.md，需 frontmatter 并引用本设计/计划。

- [x] **1. 只读确认目标与版本。**

~~~bash
gh repo view lliony/fastbudo --json nameWithOwner,isPrivate,url
gh repo view lliony/fastbudo-releases --json nameWithOwner,isPrivate,url
gh release list --repo lliony/fastbudo --limit 5
~~~

目标不存在是可创建条件，不代表其他网络或权限错误都能当不存在。选择高于现有 0.0.5 的新版本，遵循项目现有版本配置；在公开前列出确切版本、文件名、大小和校验和。

- [x] **2. 完成自动测试和两个架构 Release 产物。**

~~~bash
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode
xcodebuild -scheme FastBudo -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build
xcodebuild -scheme FastBudo -configuration Release -destination 'platform=macOS,arch=x86_64' -derivedDataPath .build/xcode-intel build
~~~

使用仓库既有发布脚本打包，先读脚本参数，不另写一套发布工具。逐包解压运行 check-private-paths.py --artifact，核验三种二进制架构、版本、签名、许可证；生成 SHA256SUMS。脚本不具备对应架构能力时修复后再打包，不跳过双架构约束。

- [ ] **3. 提供可审阅发布清单后请求外发授权。** 公开仓库建议 lliony/fastbudo-releases；文件仅两个 ZIP、校验和、版本说明及许可必需材料。授权前不执行 gh repo create、gh release create、upload 或推送。不得把整个源码工作区上传到发行仓库。

- [ ] **4. 授权发布后匿名验收。** 用不带 Authorization 的请求读取 apiLatest、webLatest、feed、两种 ZIP 和 SHA256SUMS；按字节验证校验和。API 限流时验证官网可用。手动安装修复版后用已发布更高测试版本验证检查→下载→校验→替换→重启，并保留可恢复备份；若没有更高正式版本，仅声明更新源和产物可访问，不虚称端到端升级通过。

- [x] **5. 同步文档与门禁。** 说明首次手动升级、源码仍私有、公开产物位置及未测 Intel 范围；验证记录保留匿名 HTTP 结果但不包含令牌或用户目录。

~~~bash
python3 "$HOME/.codex/skills/ai-project-standards/scripts/validate-project-standards.py" --root .
python3 scripts/check-private-paths.py
git diff --check
~~~


## 执行记录（2026-10-28）

代码与本地构建完成；全量 120 项测试及最终相关回归 50 项通过。完成范围、探针限制、双架构包及外发状态以[验证记录](../../validation/2026-10-28-public-update-source.md)为准。未完成复选框保留，不能将合成图探针视为真实抓图验收；尚未提交、推送、安装或公开发布。


## 用户决定变更

2026-10-28：用户明确继续使用当前 `lliony/fastbudo` 仓库并重新安装本地应用。独立公开仓库方案取消，保留下文作为历史方案；没有创建或上传。来源统一与错误分类保留，私有仓库匿名访问限制仍存在。此前双架构公开候选包使用旧目标地址，已失效，不得发布。
