import AppKit
import SwiftUI

struct ArchiveJob: Identifiable, Sendable {
    enum Operation: Sendable {
        case create(CreateRequest)
        case extract(URL, URL)
    }
    let id = UUID()
    let operation: Operation
    var password = ""
    var approved = false
}

@MainActor @Observable final class ArchiveModel {
    var files: [URL] = []
    var outputDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    var name = "归档"
    var format = ArchiveFormat.zip
    var password = ""
    var excludeDSStore = UserDefaults.standard.object(forKey: "excludeDSStore") as? Bool ?? true
    var preserveAttributes = UserDefaults.standard.bool(forKey: "preserveAttributes")
    var busy = false
    var pending: [ArchiveJob] = []
    var failed: ArchiveJob?
    var requiresExpansionConfirmation = false
    var residualWorkspaces = (UserDefaults.standard.stringArray(forKey: "unfinishedWorkspaces") ?? []).filter {
        URL(fileURLWithPath: $0).lastPathComponent.hasPrefix(".fastbudo-") && FileManager.default.fileExists(atPath: $0)
    }
    var message = "暂无任务。从 Finder 右键服务发起压缩。"
    var results: [URL] = []
    private var engine: ArchiveEngine?

    func enqueue(_ job: ArchiveJob) { pending.append(job); startNext() }
    func startNext() {
        guard !busy, failed == nil, !pending.isEmpty else { return }
        let job = pending.removeFirst()
        busy = true
        message = "正在处理…"
        let runner = ArchiveEngine { [weak self] phase in
            Task { @MainActor in self?.message = phase }
        }
        engine = runner
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    switch job.operation {
                    case .create(let request): return try runner.create(request, password: job.password)
                    case .extract(let input, let directory):
                        return try runner.extract(input, to: directory, password: job.password, approved: job.approved)
                    }
                }.value
                results.insert(result, at: 0)
                message = "已完成：\(result.lastPathComponent)"

            } catch is CancellationError { message = "已取消，原始文件保留。" }
            catch {
                failed = job
                requiresExpansionConfirmation = (error as? ArchiveFailure)?.message == "expansion_confirmation"
                message = explain(error)
            }
            engine = nil
            busy = false
            startNext()
        }
    }
    func cancel() { engine?.cancel() }
    func retry() {
        guard var job = failed else { return }
        job.password = password
        failed = nil
        password = ""
        pending.insert(job, at: 0)
        startNext()
    }
    func approveExpansion() {
        guard var job = failed else { return }
        job.approved = true
        failed = nil
        pending.insert(job, at: 0)
        startNext()
    }
    func skip() { failed = nil; password = ""; startNext() }
    func select(_ urls: [URL], quick: Bool) {
        files = urls
        guard let first = urls.first else { return }
        outputDirectory = first.deletingLastPathComponent()
        name = urls.count == 1 ? first.lastPathComponent : "归档"
        password = ""
        format = quick ? .zip : (ArchiveFormat(rawValue: UserDefaults.standard.string(forKey: "defaultFormat") ?? "zip") ?? .zip)
        excludeDSStore = UserDefaults.standard.object(forKey: "excludeDSStore") as? Bool ?? true
        preserveAttributes = UserDefaults.standard.bool(forKey: "preserveAttributes")
        if quick { submit() }
    }
    func submit() {
        let request = CreateRequest(inputs: files, outputDirectory: outputDirectory, name: name, format: format,
                                    excludeDSStore: excludeDSStore, preserveAttributes: preserveAttributes && format == .zip && password.isEmpty)
        enqueue(ArchiveJob(operation: .create(request), password: password))
        password = ""
    }
    func open(_ urls: [URL]) {
        for url in urls { enqueue(ArchiveJob(operation: .extract(url, url.deletingLastPathComponent()))) }
    }
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { select(panel.urls, quick: false) }
    }
    func chooseArchives() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { open(panel.urls) }
    }
    func chooseOutput() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
            if let job = failed {
                let operation: ArchiveJob.Operation
                switch job.operation {
                case .extract(let input, _): operation = .extract(input, url)
                case .create(var request): request.outputDirectory = url; operation = .create(request)
                }
                failed = ArchiveJob(operation: operation, password: job.password, approved: job.approved)
            }
        }
    }
    private func explain(_ error: Error) -> String {
        switch (error as? ArchiveFailure)?.message {
        case "expansion_confirmation": return "解压内容超过体积、文件数或压缩比阈值，或无法预估。请确认是否继续。"
        case "unsafe_path", "path_collision": return "压缩包包含不安全路径或冲突文件名，已停止。"
        case "unsupported_entry": return "首版暂不解压符号链接、硬链接或特殊设备条目。"
        case "select_first_volume": return "请选择首卷（.001、part1.rar 或 .rar）；ZIP 分卷请打开 .zip 文件。"
        case "password_or_archive_invalid": return "需要正确密码，或压缩包已损坏。请输入密码后重试。"
        case "extraction_failed": return "解压失败：可能是密码错误、缺失分卷、损坏、空间不足或权限限制。"
        case "unsupported_or_damaged_archive", "missing_or_damaged_volume": return "无法读取归档：请检查格式、文件完整性和同目录分卷。"
        default: return error.localizedDescription
        }
    }
}
