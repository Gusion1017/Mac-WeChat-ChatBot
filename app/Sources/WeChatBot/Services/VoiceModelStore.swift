import CryptoKit
import Foundation
import Observation

// MARK: - Model catalog

/// 需要按需下载的 TTS 模型文件（spec §3.1）。
enum VoiceModelKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Kokoro multi-lang v1_1（内置音色，tar.bz2）。
    case kokoro
    /// ZipVoice distill int8 zh-en（零样本克隆，tar.bz2）。
    case zipvoice
    /// ZipVoice 的声码器 vocos_24khz.onnx（单文件）。
    case vocoder

    var id: String { rawValue }
}

/// 一个模型的下载/校验/解包元数据。
struct VoiceModelSpec: Sendable, Equatable {
    let kind: VoiceModelKind
    let displayName: String
    let downloadURL: URL
    /// 下载产物的 SHA256（GitHub release 资产固定，写死以避免中间人/半包）。
    let sha256: String
    let approximateBytes: Int64
    /// 本地临时文件名。
    let archiveName: String
    /// tar.bz2 解包后的目录名（相对 `models/`）；`nil` 表示单文件模型。
    let extractedDirectory: String?
    /// 单文件模型的落盘文件名；`nil` 表示 tar 包。
    let plainFileName: String?

    var isArchive: Bool { extractedDirectory != nil }
    var sizeText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: approximateBytes)
    }
}

// MARK: - State

/// 单个模型的本地状态（UI 直接展示）。
enum VoiceModelState: Equatable, Sendable {
    case notDownloaded
    /// `progress` 为 0...1；`nil` 表示服务器未给总大小（未知进度）。
    case downloading(progress: Double?)
    case verifying
    case extracting
    case ready
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .downloading, .verifying, .extracting: return true
        case .notDownloaded, .ready, .failed: return false
        }
    }

    /// 0...1；非下载中返回 0/1。
    var fraction: Double {
        switch self {
        case .notDownloaded: return 0
        case .downloading(let progress): return progress ?? 0
        case .verifying, .extracting: return 1
        case .ready: return 1
        case .failed: return 0
        }
    }

    var displayText: String {
        switch self {
        case .notDownloaded: return "未下载"
        case .downloading(let progress):
            if let progress {
                return String(format: "下载中 %.0f%%", progress * 100)
            }
            return "下载中"
        case .verifying: return "校验中"
        case .extracting: return "解包中"
        case .ready: return "已就绪"
        case .failed(let reason): return "失败：\(reason)"
        }
    }
}

// MARK: - Errors

enum VoiceModelError: Error, LocalizedError, Equatable {
    /// 用户未同意按需下载（`modelDownloadConsent == false`）。
    case consentRequired
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case cancelled
    case diskWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .consentRequired:
            return "需要先同意按需下载语音模型"
        case .downloadFailed(let reason):
            return "模型下载失败：\(reason)"
        case .checksumMismatch(let expected, let actual):
            return "模型校验失败（SHA256 不匹配，期望 \(expected.prefix(12))…，实际 \(actual.prefix(12))…）"
        case .extractionFailed(let reason):
            return "模型解包失败：\(reason)"
        case .cancelled:
            return "模型下载已取消"
        case .diskWriteFailed(let reason):
            return "模型写入失败：\(reason)"
        }
    }
}

// MARK: - Store

/// 语音模型的本地目录、下载、校验与删除（spec §3.1）。
///
/// - 目录：`~/Library/Application Support/WeChatAI/models/`（不入库、不打包）；
/// - 下载前必须显式同意（`modelDownloadConsent`），由 UI 传入 `consent: true`；
/// - 下载 → SHA256 校验 → `/usr/bin/tar -xjf` 解包 → 删临时包；
/// - `states` 是 `@Observable` 状态，供设置页展示进度/失败原因；
/// - 文件路径解析函数是 `nonisolated static`，合成服务/单测无需 MainActor。
@MainActor
@Observable
final class VoiceModelStore {
    static let shared = VoiceModelStore()

    /// GitHub release 资产（spec §3.1）；SHA256 在首次下载后固定写死。
    static let catalog: [VoiceModelSpec] = [
        VoiceModelSpec(
            kind: .kokoro,
            displayName: "Kokoro multi-lang v1_1",
            downloadURL: URL(string:
                "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-multi-lang-v1_1.tar.bz2")!,
            sha256: "a3f4c73d043860e3fd2e5b06f36795eb81de0fc8e8de6df703245edddd87dbad",
            approximateBytes: 365 * 1024 * 1024,
            archiveName: "kokoro-multi-lang-v1_1.tar.bz2",
            extractedDirectory: "kokoro-multi-lang-v1_1",
            plainFileName: nil
        ),
        VoiceModelSpec(
            kind: .zipvoice,
            displayName: "ZipVoice distill int8 zh-en",
            downloadURL: URL(string:
                "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/sherpa-onnx-zipvoice-distill-int8-zh-en-emilia.tar.bz2")!,
            sha256: "77219c8b40f4ee8d73a7f902305ff6c1128ef9b54461c41b4ca6ed890b6c2803",
            approximateBytes: 109 * 1024 * 1024,
            archiveName: "sherpa-onnx-zipvoice-distill-int8-zh-en-emilia.tar.bz2",
            extractedDirectory: "sherpa-onnx-zipvoice-distill-int8-zh-en-emilia",
            plainFileName: nil
        ),
        VoiceModelSpec(
            kind: .vocoder,
            displayName: "Vocos 24 kHz",
            downloadURL: URL(string:
                "https://github.com/k2-fsa/sherpa-onnx/releases/download/vocoder-models/vocos_24khz.onnx")!,
            sha256: "bcb3b970e384161c4d634f0bb9e999ff1c471b34c9bc0b1049a5014065ed3cc0",
            approximateBytes: 54 * 1024 * 1024,
            archiveName: "vocos_24khz.onnx",
            extractedDirectory: nil,
            plainFileName: "vocos_24khz.onnx"
        ),
    ]

    /// 本地模型根目录：`~/Library/Application Support/WeChatAI/models/`。
    nonisolated static var modelsDirectory: URL {
        AppPaths.supportDirectory.appendingPathComponent("models", isDirectory: true)
    }

    /// 下载过程中的临时目录（解包成功后清理）。
    nonisolated static var downloadsDirectory: URL {
        modelsDirectory.appendingPathComponent(".downloads", isDirectory: true)
    }

    /// 各模型状态（UI 观察）。
    private(set) var states: [VoiceModelKind: VoiceModelState] = [:]
    /// 最近一次失败原因（UI 用；状态里也有）。
    private(set) var lastError: String?
    /// 当前下载任务（取消用）。
    @ObservationIgnored private var activeTask: Task<Void, any Error>?
    /// 正在进行的下载（重入保护）。
    private(set) var isDownloading = false

    init() {
        refresh()
    }

    // MARK: Queries

    func state(for kind: VoiceModelKind) -> VoiceModelState {
        states[kind] ?? (Self.isModelReady(kind) ? .ready : .notDownloaded)
    }

    /// 指定引擎的模型是否齐全（只查文件系统）。
    nonisolated static func isReady(_ engine: VoiceEngineKind) -> Bool {
        switch engine {
        case .kokoro: return kokoroConfig() != nil
        case .zipvoiceClone: return zipvoiceConfig() != nil
        }
    }

    /// 某个模型文件是否已落盘（tar 解包目录/单文件存在）。
    nonisolated static func isModelReady(_ kind: VoiceModelKind) -> Bool {
        guard let spec = catalog.first(where: { $0.kind == kind }) else { return false }
        let fileManager = FileManager.default
        if let directory = spec.extractedDirectory {
            let url = modelsDirectory.appendingPathComponent(directory, isDirectory: true)
            return fileManager.fileExists(atPath: url.path)
        }
        if let name = spec.plainFileName {
            let url = modelsDirectory.appendingPathComponent(name)
            return fileManager.fileExists(atPath: url.path)
        }
        return false
    }

    /// 全部模型是否就绪。
    nonisolated static var allModelsReady: Bool {
        catalog.allSatisfy { isModelReady($0.kind) }
    }

    /// 从文件系统重新推导状态（启动、删除后调用）。
    func refresh() {
        for spec in Self.catalog where !(states[spec.kind]?.isBusy ?? false) {
            states[spec.kind] = Self.isModelReady(spec.kind) ? .ready : .notDownloaded
        }
        lastError = nil
    }

    // MARK: Configuration resolution

    /// Kokoro 模型路径；缺文件时返回 `nil`。
    nonisolated static func kokoroConfig() -> SherpaTtsKokoroConfig? {
        let directory = modelsDirectory.appendingPathComponent(
            "kokoro-multi-lang-v1_1", isDirectory: true)
        let fileManager = FileManager.default
        guard let model = firstMatching("model", extension: "onnx", in: directory),
              let voices = existing("voices.bin", in: directory),
              let tokens = existing("tokens.txt", in: directory) else {
            return nil
        }
        let lexicons = lexicons(in: directory)
        return SherpaTtsKokoroConfig(
            model: model.path,
            voices: voices.path,
            tokens: tokens.path,
            lexicon: lexicons.map(\.path).joined(separator: ","),
            lang: ""
        )
    }

    /// ZipVoice 模型路径；缺文件时返回 `nil`。
    nonisolated static func zipvoiceConfig() -> SherpaTtsZipvoiceConfig? {
        let directory = modelsDirectory.appendingPathComponent(
            "sherpa-onnx-zipvoice-distill-int8-zh-en-emilia", isDirectory: true)
        guard let tokens = existing("tokens.txt", in: directory),
              let encoder = firstMatching("encoder", extension: "onnx", in: directory),
              let decoder = firstMatching("decoder", extension: "onnx", in: directory),
              let vocoder = existing("vocos_24khz.onnx", in: modelsDirectory) else {
            return nil
        }
        let lexicons = lexicons(in: directory, includeEnglish: true)
        return SherpaTtsZipvoiceConfig(
            tokens: tokens.path,
            encoder: encoder.path,
            decoder: decoder.path,
            vocoder: vocoder.path,
            lexicon: lexicons.map(\.path).joined(separator: ",")
        )
    }

    /// Kokoro 内置音色数（从 voices.bin 大小推导：向量维度固定 256，每音色 511 字节）。
    /// 解析失败时返回 0，由调用方按 1 处理。
    nonisolated static func kokoroSpeakerCount() -> Int {
        let voices = modelsDirectory
            .appendingPathComponent("kokoro-multi-lang-v1_1/voices.bin")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: voices.path),
              let size = attributes[.size] as? Int, size > 0 else {
            return 0
        }
        // Kokoro v1_1: 每音色 512 字节（256 float16 × 2）。
        let count = size / 512
        return count > 0 ? count : 0
    }

    // MARK: Download / verify / extract

    /// 依次下载缺少的模型。`consent` 必须为 `true`（对应 `modelDownloadConsent`）。
    ///
    /// 失败时抛 `VoiceModelError`，并把该模型状态置为 `.failed`；
    /// 取消抛 `.cancelled`。已完成（`.ready`）的模型会跳过。
    func download(_ kinds: [VoiceModelKind]? = nil, consent: Bool) async throws {
        guard consent else { throw VoiceModelError.consentRequired }
        guard !isDownloading else { return }

        let targets = (kinds ?? Self.catalog.map(\.kind)).filter { !Self.isModelReady($0) }
        guard !targets.isEmpty else {
            refresh()
            return
        }

        isDownloading = true
        lastError = nil
        defer { isDownloading = false }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            for kind in targets {
                try Task.checkCancellation()
                do {
                    try await self.install(kind)
                } catch is CancellationError {
                    self.states[kind] = .notDownloaded
                    throw VoiceModelError.cancelled
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    self.states[kind] = .failed(message)
                    self.lastError = message
                    throw error
                }
            }
        }
        activeTask = task
        defer { activeTask = nil }
        try await task.value
    }

    /// 取消正在进行的下载/解包。
    func cancel() {
        activeTask?.cancel()
        activeTask = nil
    }

    /// 删除某个模型的本地文件。
    func delete(_ kind: VoiceModelKind) throws {
        guard let spec = Self.catalog.first(where: { $0.kind == kind }) else { return }
        let url: URL
        if let directory = spec.extractedDirectory {
            url = Self.modelsDirectory.appendingPathComponent(directory, isDirectory: true)
        } else if let name = spec.plainFileName {
            url = Self.modelsDirectory.appendingPathComponent(name)
        } else {
            return
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        // 临时包可能残留。
        let archive = Self.downloadsDirectory.appendingPathComponent(spec.archiveName)
        try? FileManager.default.removeItem(at: archive)
        states[kind] = .notDownloaded
    }

    // MARK: Install pipeline

    private func install(_ kind: VoiceModelKind) async throws {
        guard let spec = Self.catalog.first(where: { $0.kind == kind }) else { return }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: Self.modelsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: Self.downloadsDirectory, withIntermediateDirectories: true)

        let destination = Self.downloadsDirectory.appendingPathComponent(spec.archiveName)
        try? fileManager.removeItem(at: destination)

        states[kind] = .downloading(progress: 0)
        let delegate = DownloadProgressDelegate { [weak self] received, expected in
            let fraction: Double? = expected > 0 ? Double(received) / Double(expected) : nil
            Task { @MainActor [weak self] in
                guard let self, self.states[kind]?.isBusy == true else { return }
                self.states[kind] = .downloading(progress: fraction)
            }
        }
        let (temporaryURL, response) = try await URLSession.shared.download(
            for: URLRequest(url: spec.downloadURL), delegate: delegate)
        try Task.checkCancellation()

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw VoiceModelError.downloadFailed("HTTP \(http.statusCode)")
        }
        do {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        } catch {
            throw VoiceModelError.diskWriteFailed(error.localizedDescription)
        }

        states[kind] = .verifying
        let digest = try Self.sha256Hex(of: destination)
        guard digest == spec.sha256 else {
            try? fileManager.removeItem(at: destination)
            states[kind] = .notDownloaded
            throw VoiceModelError.checksumMismatch(expected: spec.sha256, actual: digest)
        }

        if spec.isArchive {
            states[kind] = .extracting
            try extractArchive(destination, kind: kind)
        } else if let name = spec.plainFileName {
            let target = Self.modelsDirectory.appendingPathComponent(name)
            try? fileManager.removeItem(at: target)
            do {
                try fileManager.moveItem(at: destination, to: target)
            } catch {
                throw VoiceModelError.diskWriteFailed(error.localizedDescription)
            }
        }

        try? fileManager.removeItem(at: destination)
        guard Self.isModelReady(kind) else {
            throw VoiceModelError.extractionFailed("落盘后缺少预期文件：\(spec.displayName)")
        }
        states[kind] = .ready
    }

    /// `/usr/bin/tar -xjf <archive> -C <models>`（不依赖 app bundle 的资源）。
    private func extractArchive(_ archive: URL, kind: VoiceModelKind) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archive.path, "-C", Self.modelsDirectory.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            throw VoiceModelError.extractionFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw VoiceModelError.extractionFailed(
                message.isEmpty ? "tar 退出码 \(process.terminationStatus)" : message)
        }
        _ = kind
    }

    /// 流式计算 SHA256（365MB 模型不整读进内存）。
    nonisolated static func sha256Hex(of url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw VoiceModelError.diskWriteFailed("无法读取 \(url.lastPathComponent)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Helpers

    /// 在目录里找文件（非隔离，供后台线程/服务调用）。
    nonisolated private static func existing(_ name: String, in directory: URL) -> URL? {
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 找第一个文件名包含 `keyword` 且扩展名匹配的文件（模型有 `model.int8.onnx` 等变体）。
    nonisolated private static func firstMatching(
        _ keyword: String, extension ext: String, in directory: URL
    ) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        return contents
            .filter { $0.pathExtension.lowercased() == ext && $0.lastPathComponent.contains(keyword) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    /// 目录内 `lexicon-*.txt`；ZipVoice 还可以借用 English 词典。
    nonisolated private static func lexicons(in directory: URL, includeEnglish: Bool = false) -> [URL] {
        var found: [URL] = []
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) {
            found = contents
                .filter { $0.lastPathComponent.hasPrefix("lexicon") && $0.pathExtension == "txt" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        if includeEnglish, found.isEmpty,
           let english = existing("lexicon-us-en.txt", in: directory) {
            found.append(english)
        }
        return found
    }
}

// MARK: - Progress delegate

/// 把 URLSession 下载进度转成回调（`@unchecked Sendable`：只在 URLSession 队列使用）。
private final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64, Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }
}
