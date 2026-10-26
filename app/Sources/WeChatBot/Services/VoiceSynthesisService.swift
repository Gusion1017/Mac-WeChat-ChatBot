import Foundation

// MARK: - Engine selection (shared with settings UI; spec §2.4 / §3.1)

/// TTS 引擎类型。
///
/// - `kokoro`：内置多音色（Kokoro multi-lang v1_1），按 `sid` 选音色、`speed` 调语速；
/// - `zipvoiceClone`：零样本克隆（ZipVoice distill int8），需要参考音频 + 参考文本。
enum VoiceEngineKind: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case kokoro
    case zipvoiceClone

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .kokoro: return "Kokoro"
        case .zipvoiceClone: return "ZipVoice 克隆"
        }
    }
}

/// 一次合成要用的音色参数（由 `VoiceSettings`/会话覆盖解析而来）。
struct VoiceSelection: Sendable, Equatable, Hashable {
    var engine: VoiceEngineKind
    var kokoroSpeakerID: Int
    var speed: Double
    /// `engine == .zipvoiceClone` 时必填。
    var cloneID: String?

    init(
        engine: VoiceEngineKind = .kokoro,
        kokoroSpeakerID: Int = 0,
        speed: Double = 1.0,
        cloneID: String? = nil
    ) {
        self.engine = engine
        self.kokoroSpeakerID = kokoroSpeakerID
        self.speed = speed
        self.cloneID = cloneID
    }

    /// 从设置解析（把范围收敛、克隆 ID 归一化）。T2/运行时可直接用。
    init(settings: VoiceSettings, cloneID: String? = nil) {
        self.init(
            engine: settings.engine,
            kokoroSpeakerID: settings.kokoroSpeakerID,
            speed: settings.effectiveKokoroSpeed,
            cloneID: cloneID ?? settings.cloneID
        )
    }

    /// 生效的语速（0.5...2.0）。
    var effectiveSpeed: Double {
        guard speed.isFinite else { return 1.0 }
        return min(max(speed, 0.5), 2.0)
    }

    /// 生效的 Kokoro 音色编号（负数按 0 处理；上限由引擎的音色数兜底）。
    var effectiveSpeakerID: Int {
        max(0, kokoroSpeakerID)
    }
}

/// 一次合成产物：16 kHz 单声道 16-bit WAV。
struct SynthesisResult: Sendable, Equatable {
    var wavURL: URL
    var duration: TimeInterval
    var sampleRate: Int
}

// MARK: - Errors

enum VoiceSynthesisError: Error, LocalizedError, Equatable {
    /// 文本清洗后为空（纯 Markdown/emoji/URL）。
    case emptyText
    /// 引擎或模型未就绪（UI 应引导下载）。
    case engineNotReady(engine: VoiceEngineKind, reason: String)
    /// 克隆档案不存在（被删除或 ID 拼错）。
    case cloneNotFound(String)
    /// 克隆参考音频/参考文本不可用。
    case cloneReferenceUnavailable(String)
    /// 合成超过时长上限且按策略不允许截断。
    case tooLong(actualSeconds: Double, maxSeconds: Int)
    /// 引擎加载失败（模型文件损坏/版本不匹配）。
    case engineLoadFailed(String)
    /// 合成失败（sherpa 返回空音频）。
    case synthesisFailed(String)
    /// 重采样/写 WAV 失败。
    case outputWriteFailed(String)
    /// 任务被取消。
    case cancelled

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "没有可朗读的文本"
        case .engineNotReady(let engine, let reason):
            return "\(engine.displayName) 语音模型未就绪：\(reason)"
        case .cloneNotFound(let id):
            return "克隆音色不存在：\(id)"
        case .cloneReferenceUnavailable(let reason):
            return "克隆参考音频不可用：\(reason)"
        case .tooLong(let actual, let maxSeconds):
            return String(format: "语音时长 %.1f 秒超过上限 %d 秒", actual, maxSeconds)
        case .engineLoadFailed(let reason):
            return "语音引擎加载失败：\(reason)"
        case .synthesisFailed(let reason):
            return "语音合成失败：\(reason)"
        case .outputWriteFailed(let reason):
            return "语音文件写入失败：\(reason)"
        case .cancelled:
            return "语音合成已取消"
        }
    }
}

// MARK: - Service

/// 出站语音合成服务（spec §3.1）。
///
/// 设计边界：
/// - **actor**：合成串行、引擎懒加载并复用（一次加载，多次合成）；
/// - **纯离线**：只依赖本地模型文件（`VoiceModelStore`），不联网；
/// - 输入清洗与超限截断是纯函数（`VoiceTextSanitizer`），可单测；
/// - 输出统一转 16 kHz 单声道 16-bit WAV（微信 SILK 链路需要 16k PCM）。
///
/// 与 `VoiceModelStore` / `VoiceCloneStore` 的分工：本服务只读文件与档案，
/// 下载、删除、CRUD 由那两个存储负责。
actor VoiceSynthesisService {
    static let defaultMaxSeconds = 30
    static let minMaxSeconds = 5
    static let maxMaxSeconds = 60
    /// 输出采样率（微信语音 16k PCM）。
    static let outputSampleRate = 16_000
    /// ZipVoice distill 的默认 flow-matching 步数（官方 example 用 4）。
    static let zipvoiceNumSteps = 4
    /// ZipVoice 切句最小字符数（官方 example 的 extra 参数）。
    static let zipvoiceMinCharInSentence = "10"
    /// TTS 产物保留时长（每次合成前顺手清理更早的文件，避免无限增长）。
    static let outputRetention: TimeInterval = 24 * 60 * 60

    /// TTS 推理线程数。实测（M3 Max / osx-arm64 静态库 / -O）：Kokoro 4 线程
    /// RTF ≈1.3，2 线程 ≈2.2，6–8 线程反而变慢；ZipVoice 4 线程最优（≈6.5）。
    /// 4 线程对 10–14 核的 Apple Silicon 是稳妥值，也避免和 App 主线程抢核。
    static let inferenceThreadCount = 4

    private var kokoroEngine: SherpaTtsEngine?
    private var zipvoiceEngine: SherpaTtsEngine?
    /// 已加载引擎对应的模型路径签名；模型文件被替换（重新下载）后重建引擎。
    private var kokoroSignature: String?
    private var zipvoiceSignature: String?

    init() {}

    // MARK: Readiness

    /// 指定引擎是否可用（模型文件齐全）；只查文件，不加载引擎，可高频调用。
    ///
    /// `nonisolated`：UI（`@MainActor`）可直接同步调用，例如回复决策里的 `modelsReady`。
    nonisolated static func isReady(_ engine: VoiceEngineKind) -> Bool {
        switch engine {
        case .kokoro:
            return VoiceModelStore.kokoroConfig() != nil
        case .zipvoiceClone:
            return VoiceModelStore.zipvoiceConfig() != nil
        }
    }

    nonisolated func isReady(_ engine: VoiceEngineKind) -> Bool {
        Self.isReady(engine)
    }

    /// 已加载的引擎数量（日志/诊断/释放测试用）。
    var loadedEngineCount: Int {
        (kokoroEngine == nil ? 0 : 1) + (zipvoiceEngine == nil ? 0 : 1)
    }

    /// 释放已加载引擎，下次合成重新加载（模型更新/功能关闭时调用）。
    func unloadEngines() {
        kokoroEngine = nil
        zipvoiceEngine = nil
        kokoroSignature = nil
        zipvoiceSignature = nil
    }

    /// TTS 输出目录：`~/Library/Application Support/WeChatAI/media/tts/`。
    nonisolated static var outputDirectory: URL {
        AppPaths.mediaDirectory.appendingPathComponent("tts", isDirectory: true)
    }

    // MARK: Synthesize

    /// 合成一段语音。
    ///
    /// - Parameters:
    ///   - text: 待朗读文本（内部会做口语化清洗；清洗后为空抛 `.emptyText`）。
    ///   - voice: 引擎与音色参数。
    ///   - maxSeconds: 时长上限（5...60；越界自动收敛）。
    ///   - allowsTruncation: `true` = 超限时按句截断后重合成一次（`VoiceOverLimit.truncate`）；
    ///     `false` = 直接抛 `.tooLong`（`VoiceOverLimit.text`，上层改发文字）。
    func synthesize(
        text: String,
        voice: VoiceSelection,
        maxSeconds: Int = VoiceSynthesisService.defaultMaxSeconds,
        allowsTruncation: Bool = true
    ) async throws -> SynthesisResult {
        let limit = min(max(maxSeconds, Self.minMaxSeconds), Self.maxMaxSeconds)
        var spoken = VoiceTextSanitizer.sanitizeForSpeech(text)
        guard !spoken.isEmpty else { throw VoiceSynthesisError.emptyText }

        try Task.checkCancellation()
        let audio = try makeAudio(for: voice, text: spoken)
        var raw = audio
        var duration = audio.duration

        if duration > Double(limit) * 1.02 {
            guard allowsTruncation else {
                throw VoiceSynthesisError.tooLong(
                    actualSeconds: duration, maxSeconds: limit)
            }
            let budget = VoiceTextSanitizer.characterBudget(
                spokenSeconds: duration,
                textLength: spoken.count,
                maxSeconds: limit
            )
            let capped = VoiceTextSanitizer.sentenceCapped(spoken, maxCharacters: budget)
            guard !capped.isEmpty, capped != spoken else {
                throw VoiceSynthesisError.tooLong(
                    actualSeconds: duration, maxSeconds: limit)
            }
            spoken = capped
            try Task.checkCancellation()
            raw = try makeAudio(for: voice, text: capped)
            duration = raw.duration
            if duration > Double(limit) * 1.02 {
                throw VoiceSynthesisError.tooLong(
                    actualSeconds: duration, maxSeconds: limit)
            }
        }

        guard !raw.samples.isEmpty else {
            throw VoiceSynthesisError.synthesisFailed("引擎返回空音频")
        }

        let resampled: [Float]
        do {
            resampled = try VoiceSynthesisAudio.resampleTo16k(
                raw.samples, sampleRate: raw.sampleRate)
        } catch {
            throw VoiceSynthesisError.outputWriteFailed(
                (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }

        try Task.checkCancellation()
        pruneOldOutputs()
        let outputURL = Self.makeOutputURL()
        do {
            try VoiceSynthesisAudio.writePCM16WAV(samples: resampled, to: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw VoiceSynthesisError.outputWriteFailed(
                (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }

        return SynthesisResult(
            wavURL: outputURL,
            duration: Double(resampled.count) / Double(Self.outputSampleRate),
            sampleRate: Self.outputSampleRate
        )
    }

    // MARK: Engine loading

    /// 用指定引擎合成（内部只返回 sherpa 原始 24k 音频）。
    private func makeAudio(for voice: VoiceSelection, text: String) throws -> SherpaGeneratedAudio {
        switch voice.engine {
        case .kokoro:
            let engine = try loadKokoroEngine()
            let speakerCount = max(1, engine.numSpeakers)
            var config = SherpaTtsGenerationConfig(
                speed: Float(voice.effectiveSpeed),
                speakerID: min(voice.effectiveSpeakerID, speakerCount - 1),
                silenceScale: 0.2
            )
            config.numSteps = Self.zipvoiceNumSteps
            do {
                return try engine.generate(text: text, config: config)
            } catch let error as SherpaTtsEngineError {
                throw VoiceSynthesisError.synthesisFailed(
                    error.errorDescription ?? "\(error)")
            }
        case .zipvoiceClone:
            let reference = try resolveCloneReference(voice)
            let engine = try loadZipvoiceEngine()
            var config = SherpaTtsGenerationConfig(
                speed: Float(voice.effectiveSpeed),
                silenceScale: 0.2
            )
            config.referenceAudio = reference.samples
            config.referenceSampleRate = reference.sampleRate
            config.referenceText = reference.text
            config.numSteps = Self.zipvoiceNumSteps
            config.extra = ["min_char_in_sentence": Self.zipvoiceMinCharInSentence]
            do {
                return try engine.generate(text: text, config: config)
            } catch let error as SherpaTtsEngineError {
                throw VoiceSynthesisError.synthesisFailed(
                    error.errorDescription ?? "\(error)")
            }
        }
    }

    private func loadKokoroEngine() throws -> SherpaTtsEngine {
        guard let config = VoiceModelStore.kokoroConfig() else {
            throw VoiceSynthesisError.engineNotReady(
                engine: .kokoro, reason: "模型未下载或文件不完整")
        }
        let signature = "\(config.model)|\(config.voices)|\(config.tokens)|\(config.lexicon)"
        if let engine = kokoroEngine, signature == kokoroSignature { return engine }
        do {
            let engine = try SherpaTtsEngine.makeKokoro(config, numThreads: Self.inferenceThreadCount)
            kokoroEngine = engine
            kokoroSignature = signature
            return engine
        } catch {
            kokoroEngine = nil
            kokoroSignature = nil
            throw VoiceSynthesisError.engineLoadFailed(
                (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    private func loadZipvoiceEngine() throws -> SherpaTtsEngine {
        guard let config = VoiceModelStore.zipvoiceConfig() else {
            throw VoiceSynthesisError.engineNotReady(
                engine: .zipvoiceClone, reason: "模型未下载或文件不完整")
        }
        let signature = "\(config.tokens)|\(config.encoder)|\(config.decoder)|\(config.vocoder)"
            + "|\(config.lexicon)"
        if let engine = zipvoiceEngine, signature == zipvoiceSignature { return engine }
        do {
            let engine = try SherpaTtsEngine.makeZipvoice(config, numThreads: Self.inferenceThreadCount)
            zipvoiceEngine = engine
            zipvoiceSignature = signature
            return engine
        } catch {
            zipvoiceEngine = nil
            zipvoiceSignature = nil
            throw VoiceSynthesisError.engineLoadFailed(
                (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    /// 解析克隆档案的参考音频与参考文本。
    private func resolveCloneReference(
        _ voice: VoiceSelection
    ) throws -> (samples: [Float], sampleRate: Int, text: String) {
        let cloneID = (voice.cloneID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cloneID.isEmpty else {
            throw VoiceSynthesisError.engineNotReady(
                engine: .zipvoiceClone, reason: "未选择克隆音色")
        }
        guard let profile = VoiceCloneStore.profile(id: cloneID) else {
            throw VoiceSynthesisError.cloneNotFound(cloneID)
        }
        guard profile.hasReferenceText else {
            throw VoiceSynthesisError.cloneReferenceUnavailable(
                "参考文本为空，请先转写或手动填写")
        }
        let samples: [Float]
        do {
            samples = try VoiceSynthesisAudio.decodeMono16k(url: profile.audioURL)
        } catch {
            throw VoiceSynthesisError.cloneReferenceUnavailable(
                (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        guard !samples.isEmpty else {
            throw VoiceSynthesisError.cloneReferenceUnavailable("参考音频为空")
        }
        return (samples, VoiceSynthesisAudio.targetSampleRate, profile.referenceText)
    }

    // MARK: Output files

    private static func makeOutputURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let name = "tts-\(stamp)-\(suffix).wav"
        try? FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)
        return outputDirectory.appendingPathComponent(name)
    }

    /// 删除超过保留期的 TTS 产物（best-effort，不影响合成结果）。
    private func pruneOldOutputs() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: Self.outputDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-Self.outputRetention)
        for file in files where file.pathExtension.lowercased() == "wav" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}
