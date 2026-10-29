import AVFoundation
import Foundation
import Observation

/// 语音试听（2026-10-29，随语音引擎收敛为 CosyVoice3 重写）。
///
/// 直接调用本机 CosyVoice3 HTTP 服务合成一句示例文本，再用 `AVAudioPlayer`
/// 在本机播放：不发往微信、不上传音频或文本。
///
/// 全局只保留一个播放器（由 `AppStore` 持有），切换音色/语速/服务地址、
/// 离开页面或再点一次即停止，避免重复试听与跨页面残留播放。
@MainActor
@Observable
final class VoicePreviewController {
    enum Phase: Equatable, Sendable {
        case idle
        case synthesizing
        case playing
    }

    /// 试听文本：短句，服务热态约 1–3 秒可出声。
    static let sampleText = "你好呀，我是你的微信 AI 助手。"

    private(set) var phase: Phase = .idle
    /// 当前正在合成/播放的音色参数（用于按钮状态与行高亮）。
    private(set) var activeVoice: VoiceSelection?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var playerDelegate: PreviewPlayerDelegate?

    init() {}

    /// 指定的音色是否正在合成/播放（用于避免重复点按与行高亮）。
    func isActive(_ voice: VoiceSelection) -> Bool {
        guard phase != .idle else { return false }
        return activeVoice == voice
    }

    /// 点按试听：同一个音色再次点按 → 停止；换音色 → 停止旧的再合成新的。
    func toggle(
        voice: VoiceSelection,
        endpoint: URL,
        onError: (@MainActor (String) -> Void)? = nil
    ) {
        if isActive(voice) {
            stop()
            return
        }
        stop()
        start(voice: voice, endpoint: endpoint, onError: onError)
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
        endpoint: URL,
        onError: (@MainActor (String) -> Void)?
    ) {
        activeVoice = voice
        phase = .synthesizing

        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard voice.hasVoice else {
                    throw VoicePreviewError.voiceNotSelected
                }
                let raw = try await CosyVoiceClient.shared.synthesizeRaw(
                    text: Self.sampleText,
                    voiceID: voice.trimmedVoiceID,
                    speed: voice.effectiveSpeed,
                    timeout: 90,
                    endpoint: endpoint
                )
                try Task.checkCancellation()
                guard self.activeVoice == voice else { return }
                guard let wavURL = raw.sourceWAVURL else {
                    throw VoicePreviewError.cosyVoiceAudioUnavailable
                }
                try self.play(url: wavURL)
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

enum VoicePreviewError: Error, LocalizedError, Equatable {
    case playbackFailed
    case voiceNotSelected
    case cosyVoiceAudioUnavailable

    var errorDescription: String? {
        switch self {
        case .playbackFailed:
            return "试听播放失败"
        case .voiceNotSelected:
            return "试听前请先选择音色"
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
