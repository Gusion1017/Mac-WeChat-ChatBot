import AVFoundation
import Foundation
import Observation

/// 语音试听（2026-10-27）。
///
/// 与真实回复共用同一个 `VoiceSynthesisService`（同一引擎、音色、语速与 16k WAV 链路），
/// 合成完成后在本机用 `AVAudioPlayer` 播放，不发往微信、不联网。
///
/// 全局只保留一个播放器（由 `AppStore` 持有），避免「机器人 → 语音」与
/// 「设置 → 语音」两个入口同时出声。切换音色/语速、离开页面或再点一次即停止。
@MainActor
@Observable
final class VoicePreviewController {
    enum Phase: Equatable, Sendable {
        case idle
        case synthesizing
        case playing
    }

    /// 试听文本：短句，Kokoro 首次加载后约 1–3 秒可出声。
    static let sampleText = "你好呀，我是你的微信 AI 助手。"
    /// 试听时长上限（远小于正式语音上限，避免误合成长文本）。
    static let maxSeconds = 15

    private(set) var phase: Phase = .idle
    /// 当前正在合成/播放的音色参数（用于按钮状态与行高亮）。
    private(set) var activeVoice: VoiceSelection?

    @ObservationIgnored private let synthesis: VoiceSynthesisService
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var playerDelegate: PreviewPlayerDelegate?

    init(synthesis: VoiceSynthesisService) {
        self.synthesis = synthesis
    }

    /// 指定的音色是否正在合成/播放（用于避免重复点按与行高亮）。
    func isActive(_ voice: VoiceSelection) -> Bool {
        guard phase != .idle else { return false }
        return activeVoice == voice
    }

    /// 点按试听：同一个音色再次点按 → 停止；换音色 → 停止旧的再合成新的。
    ///
    /// - `cosyVoice`：引擎为 `.cosyVoice` 时必传（HTTP 合成需要地址/音色/语速）；
    ///   Kokoro/ZipVoice 传 nil 走本地合成服务。
    func toggle(
        voice: VoiceSelection,
        cosyVoice: VoicePreviewCosyVoiceOptions? = nil,
        onError: (@MainActor (String) -> Void)? = nil
    ) {
        if isActive(voice) {
            stop()
            return
        }
        stop()
        start(voice: voice, cosyVoice: cosyVoice, onError: onError)
    }

    /// 停止播放并取消尚未完成的合成。
    func stop() {
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        playerDelegate = nil
        phase = .idle
        activeVoice = nil
    }

    // MARK: - Synthesis / playback

    private func start(
        voice: VoiceSelection,
        cosyVoice: VoicePreviewCosyVoiceOptions?,
        onError: (@MainActor (String) -> Void)?
    ) {
        activeVoice = voice
        phase = .synthesizing

        task = Task { [weak self] in
            guard let self else { return }
            do {
                if voice.engine == .cosyVoice {
                    guard let options = cosyVoice, !options.voiceID.isEmpty else {
                        throw VoicePreviewError.cosyVoiceOptionsMissing
                    }
                    // CosyVoice3 直接走 HTTP 合成：拿到 24k 原始 WAV 后本地播放。
                    let raw = try await CosyVoiceClient.shared.synthesizeRaw(
                        text: Self.sampleText,
                        voiceID: options.voiceID,
                        speed: options.speed,
                        timeout: 90,
                        endpoint: options.endpoint
                    )
                    try Task.checkCancellation()
                    guard self.activeVoice == voice else { return }
                    guard let wavURL = raw.sourceWAVURL else {
                        throw VoicePreviewError.cosyVoiceAudioUnavailable
                    }
                    try self.play(url: wavURL)
                    return
                }
                let result = try await self.synthesis.synthesize(
                    text: Self.sampleText,
                    voice: voice,
                    maxSeconds: Self.maxSeconds,
                    allowsTruncation: true
                )
                try Task.checkCancellation()
                guard self.activeVoice == voice else { return }
                try self.play(url: result.wavURL)
            } catch is CancellationError {
                // 用户主动停止/切换：不报错。
            } catch {
                guard !Task.isCancelled else { return }
                self.fail(error, onError: onError)
            }
        }
    }

    private func play(url: URL) throws {
        let player = try AVAudioPlayer(contentsOf: url)
        let delegate = PreviewPlayerDelegate { [weak self] in
            self?.playbackDidFinish()
        }
        player.delegate = delegate
        player.prepareToPlay()
        guard player.play() else {
            throw VoicePreviewError.playbackFailed
        }
        self.player = player
        playerDelegate = delegate
        phase = .playing
    }

    private func playbackDidFinish() {
        guard phase == .playing else { return }
        player?.stop()
        player = nil
        playerDelegate = nil
        phase = .idle
        activeVoice = nil
    }

    private func fail(_ error: Error, onError: (@MainActor (String) -> Void)?) {
        let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        player?.stop()
        player = nil
        playerDelegate = nil
        phase = .idle
        activeVoice = nil
        onError?(message)
    }
}

/// CosyVoice3 试听参数（HTTP 合成不经过 `VoiceSynthesisService` 的 WAV 落盘链路）。
struct VoicePreviewCosyVoiceOptions: Sendable, Equatable {
    var voiceID: String
    var endpoint: URL
    var speed: Double
}

enum VoicePreviewError: Error, LocalizedError, Equatable {
    case playbackFailed
    case cosyVoiceOptionsMissing
    case cosyVoiceAudioUnavailable

    var errorDescription: String? {
        switch self {
        case .playbackFailed:
            return "试听播放失败"
        case .cosyVoiceOptionsMissing:
            return "CosyVoice3 试听缺少服务地址"
        case .cosyVoiceAudioUnavailable:
            return "CosyVoice3 试听音频写入失败"
        }
    }
}

/// AVAudioPlayer 的 delegate 回调可能在非主线程到达，统一切回 MainActor。
private final class PreviewPlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let onFinish: @MainActor () -> Void

    init(onFinish: @escaping @MainActor () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [onFinish] in onFinish() }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [onFinish] in onFinish() }
    }
}
