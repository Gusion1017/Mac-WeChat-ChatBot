import Foundation

// MARK: - Voice selection

/// 一次合成要用的音色参数（由全局 `VoiceSettings` 解析而来）。
///
/// CosyVoice3 是 App 唯一的 TTS 引擎：音色来自本机 `voices.json` / 服务端
/// `/voices`，语速 0.5–2.0（默认 1.0）。App 不内置任何音色，空音色表示
/// 「未选择音色」，合成前会明确报错而不是回退到某个内置音色。
struct VoiceSelection: Sendable, Equatable, Hashable {
    /// CosyVoice3 音色 ID；空字符串表示「未选择音色」。
    var cosyVoiceVoiceID: String
    /// 语速（0.5...2.0）。
    var speed: Double

    init(cosyVoiceVoiceID: String = "", speed: Double = 1.0) {
        self.cosyVoiceVoiceID = cosyVoiceVoiceID
        self.speed = speed
    }

    /// 从设置解析（语速与音色都会做范围收敛/去空白）。
    init(settings: VoiceSettings) {
        self.init(
            cosyVoiceVoiceID: settings.effectiveCosyVoiceVoiceID,
            speed: settings.effectiveCosyVoiceSpeed
        )
    }

    /// 生效的语速（0.5...2.0，默认 1.0）。
    var effectiveSpeed: Double {
        guard speed.isFinite else { return 1.0 }
        return min(max(speed, 0.5), 2.0)
    }

    /// 去掉首尾空白的音色 ID。
    var trimmedVoiceID: String {
        cosyVoiceVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 是否已选择可用的音色 ID。
    var hasVoice: Bool { !trimmedVoiceID.isEmpty }
}

/// 一次合成产物：引擎原生采样率（CosyVoice3 为 24 kHz）的单声道 16-bit WAV。
struct SynthesisResult: Sendable, Equatable {
    var wavURL: URL
    var duration: TimeInterval
    var sampleRate: Int
}

// MARK: - Errors

enum VoiceSynthesisError: Error, LocalizedError, Equatable {
    /// 文本清洗后为空（纯 Markdown/emoji/URL）。
    case emptyText
    /// CosyVoice3 未安装、本地服务未运行/加载中，或未选择音色（UI 应引导安装/启动/选音色）。
    case engineNotReady(reason: String)
    /// 合成超过时长上限且按策略不允许截断。
    case tooLong(actualSeconds: Double, maxSeconds: Int)
    /// 合成失败（服务返回错误/空音频）。
    case synthesisFailed(String)
    /// 重采样/写 WAV 失败。
    case outputWriteFailed(String)
    /// 任务被取消。
    case cancelled

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "没有可朗读的文本"
        case .engineNotReady(let reason):
            return "CosyVoice3 语音未就绪：\(reason)"
        case .tooLong(let actual, let maxSeconds):
            return String(format: "语音时长 %.1f 秒超过上限 %d 秒", actual, maxSeconds)
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

/// 出站语音合成服务（CosyVoice3 本地 HTTP 旁路）。
///
/// 设计边界：
/// - **actor**：合成串行，写 WAV/清理输出串行化；
/// - **本地**：只请求本机回环地址上的 CosyVoice3 sidecar，不联网、不上传音频/文本；
/// - 输入清洗与超限截断是纯函数（`VoiceTextSanitizer`），可单测；
/// - 输出沿用引擎原生采样率（CosyVoice3 为 24 kHz）的单声道 16-bit WAV；
///   微信 SILK 链路由 bridge 负责重采样/编码。
///
/// 与 `CosyVoiceClient` 的分工：本服务负责文本清洗、时长上限/截断与最终 WAV 落盘；
/// 客户端只负责「文本 → 本机服务 → PCM 采样」。
actor VoiceSynthesisService {
    static let defaultMaxSeconds = 30
    static let minMaxSeconds = 5
    static let maxMaxSeconds = 60
    /// 微信现有链路支持的采样率；引擎原生 24k 直接落盘，不再二次重采样。
    static let supportedOutputSampleRates: Set<Int> = [16_000, 24_000]
    /// TTS 产物保留时长（每次合成前顺手清理更早的文件，避免无限增长）。
    static let outputRetention: TimeInterval = 24 * 60 * 60

    init() {}

    // MARK: Readiness

    /// CosyVoice3 是否可用：已安装 + 最近一次健康检查通过。
    ///
    /// 只读缓存快照（真正的健康检查在 `CosyVoiceRuntime` 后台推进），
    /// `nonisolated`：UI 与回复决策可在 `@MainActor` 同步调用。
    nonisolated static var isReady: Bool {
        CosyVoiceRuntime.shared.isServiceReadySnapshot
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
    ///   - voice: 音色与语速。
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
        let audio = try await makeAudio(for: voice, text: spoken)
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
            raw = try await makeAudio(for: voice, text: capped)
            duration = raw.duration
            if duration > Double(limit) * 1.02 {
                throw VoiceSynthesisError.tooLong(
                    actualSeconds: duration, maxSeconds: limit)
            }
        }

        guard !raw.samples.isEmpty else {
            throw VoiceSynthesisError.synthesisFailed("服务返回空音频")
        }

        let outputRate = raw.sampleRate
        guard Self.supportedOutputSampleRates.contains(outputRate) else {
            throw VoiceSynthesisError.outputWriteFailed(
                "引擎输出采样率 \(outputRate) Hz 不在支持范围（16k/24k）")
        }
        var outputSamples = raw.samples
        Self.applyEdgeFade(&outputSamples, sampleRate: outputRate)

        try Task.checkCancellation()
        pruneOldOutputs()
        let outputURL = Self.makeOutputURL()
        do {
            try VoiceSynthesisAudio.writePCM16WAV(
                samples: outputSamples, sampleRate: outputRate, to: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw VoiceSynthesisError.outputWriteFailed(
                (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }

        return SynthesisResult(
            wavURL: outputURL,
            duration: Double(outputSamples.count) / Double(outputRate),
            sampleRate: outputRate
        )
    }

    /// 首尾 5 ms 淡入淡出，避免 WAV 边界爆音（SILK 编码后尤其明显）。
    static func applyEdgeFade(_ samples: inout [Float], sampleRate: Int) {
        guard sampleRate > 0, samples.count > 2 else { return }
        let fade = min(max(1, sampleRate / 200), samples.count / 2)
        for index in 0..<fade {
            let gain = Float(index) / Float(fade)
            samples[index] *= gain
            samples[samples.count - 1 - index] *= gain
        }
    }

    // MARK: Synthesis backend

    /// 调用 CosyVoice3 本地服务合成（只返回原始 PCM；时长/截断/落盘由本 actor 统一处理）。
    private func makeAudio(
        for voice: VoiceSelection,
        text: String
    ) async throws -> CosyVoiceRawSynthesis {
        guard voice.hasVoice else {
            throw VoiceSynthesisError.engineNotReady(reason: "未选择 CosyVoice3 音色")
        }
        do {
            return try await CosyVoiceClient.shared.synthesizeRaw(
                text: text,
                voiceID: voice.trimmedVoiceID,
                speed: voice.effectiveSpeed
            )
        } catch let error as CosyVoiceError {
            switch error {
            case .notInstalled, .serviceNotRunning, .serviceLoading, .serviceUnavailable:
                throw VoiceSynthesisError.engineNotReady(
                    reason: error.errorDescription ?? "本地服务不可用")
            default:
                throw VoiceSynthesisError.synthesisFailed(
                    error.errorDescription ?? "CosyVoice3 合成失败")
            }
        } catch {
            throw VoiceSynthesisError.synthesisFailed(
                (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
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
