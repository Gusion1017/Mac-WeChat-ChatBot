import AVFoundation
import Foundation
import Speech

// MARK: - Results / errors

/// 一次本地语音转写的结果。
struct VoiceTranscription: Sendable, Equatable {
    /// 清洗后的转写文本；空字符串表示「静音/无声」或门限丢弃。
    var text: String
    /// 全文最高置信度（0...1）；没有置信度属性时，非空文本按 1.0 处理。
    var maxConfidence: Double
    /// 音频时长（秒）。
    var duration: TimeInterval
}

/// 转写链路的可展示错误。
///
/// - `assetUnavailable`：macOS 26 本地语音资源尚未安装（UI 提示去系统设置下载，不自动下载）；
/// - `unreadableAudio`：文件不存在/不是可读音频；
/// - `failed`：识别运行期失败（含超时）。
enum VoiceTranscriptionError: LocalizedError, Equatable {
    case assetUnavailable
    case unreadableAudio
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .assetUnavailable:
            return "系统尚未安装中文语音识别资源（系统设置 → 通用 → 语言与地区 → 语音识别资源）"
        case .unreadableAudio:
            return "无法读取语音音频文件"
        case .failed(let reason):
            return reason.isEmpty ? "语音转写失败" : "语音转写失败：\(reason)"
        }
    }

    /// 是否属于「资源未安装」：UI 据此显示下载引导，而不是重试按钮文案。
    var isAssetUnavailable: Bool {
        if case .assetUnavailable = self { return true }
        return false
    }
}

/// 本地语音资源状态（`SpeechTranscriber` / `AssetInventory` 的 UI 摘要）。
enum VoiceAssetStatus: Sendable, Equatable {
    case installed
    /// 系统支持但资源未安装（需要用户在系统设置中下载）。
    case downloadable
    case unsupported
    case unknown

    var label: String {
        switch self {
        case .installed: return "已安装"
        case .downloadable: return "未安装"
        case .unsupported: return "系统不支持"
        case .unknown: return "未知"
        }
    }
}

// MARK: - Service

/// 入站语音转写（macOS 26 `SpeechAnalyzer` + `SpeechTranscriber`，本地离线）。
///
/// 语义与边界：
/// - **actor**：所有识别状态在 actor 内串行化；调用方 `await`，不阻塞主线程。
/// - **串行**：同一时刻只识别一条语音；后到的请求排队等待前一条结束（单条超时 20s）。
/// - **静音幻觉门限**：`maxConfidence < 0.3 && duration < 1.5` 视为静音/幻觉，返回空文本。
/// - **文本清洗**：折叠空白、去掉中英文标点两侧多余空格（不改变语义）。
/// - **资源未安装**：抛 `.assetUnavailable`，不自动下载；UI 引导用户在系统设置里安装。
/// - 日志不打印转写原文（调用方只记录字数/置信度/时长）。
actor VoiceTranscriptionService {
    /// 默认识别语言：简体中文（微信语音基本为 zh_CN）。
    static let defaultLocale = Locale(identifier: "zh_CN")
    /// 静音门限：最高置信度低于该值 **且** 时长短于 1.5s 时视为静音/幻觉。
    static let silenceConfidenceThreshold: Double = 0.3
    static let silenceDurationThreshold: TimeInterval = 1.5
    /// 低置信度提示门限：提示词里追加「（识别可能不准确）」。
    static let lowConfidenceThreshold: Double = 0.6
    /// 单条语音转写超时（秒）。
    static let timeoutSeconds: TimeInterval = 20

    /// 串行链：后一个请求等待前一个完成，保证同一时刻只有一条识别在跑。
    private var tail: Task<Void, Never>?

    // MARK: Public API

    /// 转写一个本地音频文件（16k WAV / m4a 等 AVFoundation 可读格式）。
    func transcribe(
        fileURL: URL,
        locale: Locale = VoiceTranscriptionService.defaultLocale
    ) async throws -> VoiceTranscription {
        let previous = tail
        let task = Task<VoiceTranscription, Error> { [weak self] in
            if let previous { await previous.value }
            guard let self else { throw VoiceTranscriptionError.failed("转写服务已释放") }
            return try await self.perform(fileURL: fileURL, locale: locale)
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    /// 当前系统是否已安装对应语言的本地语音资源。
    func assetStatus(locale: Locale = VoiceTranscriptionService.defaultLocale) async -> VoiceAssetStatus {
        guard SpeechTranscriber.isAvailable else { return .unsupported }
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return .unsupported
        }
        let transcriber = Self.makeTranscriber(locale: resolved)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: return .installed
        case .supported, .downloading: return .downloadable
        case .unsupported: return .unsupported
        @unknown default: return .unknown
        }
    }

    /// 直接调用系统 AssetInventory 下载当前语言的本地语音资源。
    /// 下载完成后 `AssetInventory.status` 可能仍短暂返回 `.supported`，因此
    /// 转写实现不再把 `.supported` 当成硬失败（见 analyze）。
    func installAssets(locale: Locale = VoiceTranscriptionService.defaultLocale) async throws {
        guard SpeechTranscriber.isAvailable else { throw VoiceTranscriptionError.assetUnavailable }
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw VoiceTranscriptionError.failed("系统不支持该语言（\(locale.identifier)）的本地语音识别")
        }
        let transcriber = Self.makeTranscriber(locale: resolved)
        if await AssetInventory.status(forModules: [transcriber]) == .installed { return }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            throw VoiceTranscriptionError.assetUnavailable
        }
        try await request.downloadAndInstall()
    }

    // MARK: Implementation

    private func perform(fileURL: URL, locale: Locale) async throws -> VoiceTranscription {
        try await withThrowingTaskGroup(of: VoiceTranscription.self) { group in
            group.addTask {
                try await Self.analyze(fileURL: fileURL, locale: locale)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(Self.timeoutSeconds))
                throw VoiceTranscriptionError.failed("转写超时（\(Int(Self.timeoutSeconds))s）")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw VoiceTranscriptionError.failed("转写被取消")
            }
            return first
        }
    }

    /// 真正的 SpeechAnalyzer 调用。单独静态实现，便于并发任务组调用。
    private static func analyze(fileURL: URL, locale: Locale) async throws -> VoiceTranscription {
        guard SpeechTranscriber.isAvailable else { throw VoiceTranscriptionError.assetUnavailable }
        let trimmedPath = fileURL.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty, FileManager.default.fileExists(atPath: trimmedPath) else {
            throw VoiceTranscriptionError.unreadableAudio
        }
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw VoiceTranscriptionError.failed("系统不支持该语言（\(locale.identifier)）的本地语音识别")
        }
        let transcriber = makeTranscriber(locale: resolved)
        let status = await AssetInventory.status(forModules: [transcriber])
        // 真机（2026-10-26）：资源刚下载/按需加载时 status 可能仍是 .supported，
        // 但 SpeechAnalyzer 已能正常转写。只有 .unsupported 才是硬失败。
        guard status != .unsupported else {
            throw VoiceTranscriptionError.failed("该语言不在系统支持列表中")
        }
        guard let file = try? AVAudioFile(forReading: fileURL) else {
            throw VoiceTranscriptionError.unreadableAudio
        }
        let sampleRate = file.processingFormat.sampleRate
        let duration = sampleRate > 0 ? Double(file.length) / sampleRate : 0

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> (text: String, maxConfidence: Double) in
            var parts: [String] = []
            var maxConfidence = 0.0
            var sawConfidence = false
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                parts.append(text)
                for run in result.text.runs {
                    if let value = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] {
                        sawConfidence = true
                        maxConfidence = max(maxConfidence, value)
                    }
                }
            }
            let joined = parts.joined()
            if !sawConfidence, !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                maxConfidence = 1.0
            }
            return (joined, maxConfidence)
        }
        do {
            _ = try await analyzer.analyzeSequence(from: file)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            if error is CancellationError { throw error }
            throw VoiceTranscriptionError.failed(error.localizedDescription)
        }
        let collected = try await collector.value
        let cleaned = cleanTranscript(collected.text)
        if isLikelySilence(text: cleaned, maxConfidence: collected.maxConfidence, duration: duration) {
            return VoiceTranscription(text: "", maxConfidence: collected.maxConfidence, duration: duration)
        }
        return VoiceTranscription(
            text: cleaned,
            maxConfidence: collected.maxConfidence,
            duration: duration
        )
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.transcriptionConfidence]
        )
    }
}

// MARK: - Pure helpers（单测覆盖）

extension VoiceTranscriptionService {
    /// 中文/全角标点：两侧空格都去掉。
    private static let cjkPunctuation: Set<Character> = [
        "，", "。", "！", "？", "；", "：", "、", "…", "—", "～", "·",
        "“", "”", "‘", "’", "「", "」", "『", "』", "【", "】", "《", "》", "〈", "〉", "（", "）"
    ]
    /// 英文标点：只去掉标点前的空格（保留 `, ` 后的词间空格）。
    private static let asciiPunctuation: Set<Character> = [",", ".", "!", "?", ";", ":", ")", "]"]

    /// 文本清洗：折叠空白（含换行）、去掉标点两侧多余空格；句末标点保持原样（不改语义）。
    ///
    /// - `"你 好 ， 世 界"` → `"你 好，世 界"`（中文标点两侧去空格）；
    /// - `"hello , world"` → `"hello, world"`（英文标点只去前空格）；
    /// - `"  第一行\n第二行  "` → `"第一行 第二行"`。
    static func cleanTranscript(_ raw: String) -> String {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var output = String()
        output.reserveCapacity(normalized.count)
        for character in normalized {
            if character.isWhitespace {
                guard let last = output.last else { continue }
                if last.isWhitespace { continue }
                if cjkPunctuation.contains(last) { continue }
                output.append(" ")
                continue
            }
            if cjkPunctuation.contains(character) {
                while let last = output.last, last.isWhitespace { output.removeLast() }
                output.append(character)
                continue
            }
            if asciiPunctuation.contains(character) {
                while let last = output.last, last.isWhitespace { output.removeLast() }
                output.append(character)
                continue
            }
            output.append(character)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 静音/幻觉门限：最高置信度低于 0.3 且音频短于 1.5s。
    ///
    /// 空文本同样视为「无有效内容」；较长的低置信度音频保留（可能是轻声说话）。
    static func isLikelySilence(text: String, maxConfidence: Double, duration: TimeInterval) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return maxConfidence < silenceConfidenceThreshold && duration < silenceDurationThreshold
    }

    /// 低置信度（会追加「识别可能不准确」）；nil/非法值按非低置信度处理。
    static func isLowConfidence(_ confidence: Double?) -> Bool {
        guard let confidence, confidence.isFinite else { return false }
        return confidence < lowConfidenceThreshold
    }

    /// 提示词/气泡里的时长标签：`[语音 5s]`；没有时长时退化为 `[语音]`。
    static func voiceLabel(durationMs: Int?) -> String {
        guard let durationMs, durationMs > 0 else { return "[语音]" }
        let seconds = max(1, Int((Double(durationMs) / 1000).rounded()))
        return "[语音 \(seconds)s]"
    }
}
