import Foundation

/// bridge /voice_status 的运行时状态（2026-10-26）。
///
/// 用途：
/// - App 在 bridge 启动后的登录稳定门禁（默认 60s）内显示倒计时，并且**不发语音**；
/// - 开启语音回复时检查文本/语音发送句柄是否已捕获；
/// - 语音回复决策把 `voiceReady` 作为必要条件，未就绪时安全降级文字。
struct VoiceRuntimeStatus: Sendable, Equatable {
    /// bridge 是否返回了可用诊断（false 时其余字段无意义）。
    var available: Bool
    /// App/版本配置是否启用了语音发送（R3 原生发送 + r3VoiceSend）。
    var configured: Bool
    /// Hook 是否具备语音发送配置（任务类/vtable 等）。
    var voiceSend: Bool
    /// 文本发送句柄（newsendmsg 闭包）是否已捕获。
    var textSeed: Bool
    /// 语音发送句柄（uploadvoice 闭包）是否已捕获。
    var voiceSeed: Bool
    /// CdnManager 是否已解析（上传/下载共用）。
    var cdnReady: Bool
    /// 登录稳定门禁是否已过。
    var loginSettled: Bool
    /// 距离门禁结束的毫秒数（0 表示已过）。
    var warmupRemainingMs: Int
    /// Hook 综合判定：配置 + 语音句柄 + 登录稳定。
    var voiceReady: Bool
    /// 失败原因（bridge 未连接/版本不支持等）。
    var error: String?
    /// 该状态在本机收到的时间，用于 UI 本地倒计时。
    var receivedAt: Date

    /// 本地倒计时：基于收到状态的时间扣减，避免 UI 每秒请求 bridge。
    func remainingWarmupSeconds(now: Date = Date()) -> Int {
        guard warmupRemainingMs > 0 else { return 0 }
        let elapsedMs = max(0, Int(now.timeIntervalSince(receivedAt) * 1000))
        return max(0, (warmupRemainingMs - elapsedMs + 999) / 1000)
    }

    /// 语音发送当前是否可用（含倒计时门禁）。
    func canSendVoice(now: Date = Date()) -> Bool {
        available && configured && voiceSend && textSeed && voiceSeed
            && voiceReady && loginSettled && remainingWarmupSeconds(now: now) == 0
    }

    /// UI 展示用的简短状态。
    func summary(now: Date = Date()) -> String {
        if !available {
            return error ?? "bridge 未连接"
        }
        let remaining = remainingWarmupSeconds(now: now)
        if remaining > 0 {
            return "预热中：约 \(remaining) 秒后可发送语音"
        }
        if !configured {
            return "未启用 R3 原生发送（语音会降级文字）"
        }
        if !voiceSend {
            return "当前微信版本不支持语音发送"
        }
        if !textSeed && !voiceSeed {
            return "缺少发送句柄：请手动发一条文字和一条语音"
        }
        if !textSeed {
            return "缺少文本句柄：请手动发一条文字"
        }
        if !voiceSeed {
            return "缺少语音句柄：请手动发一条语音"
        }
        if !loginSettled {
            return "等待登录稳定"
        }
        return "可发送语音"
    }

    static let unavailable = VoiceRuntimeStatus(
        available: false,
        configured: false,
        voiceSend: false,
        textSeed: false,
        voiceSeed: false,
        cdnReady: false,
        loginSettled: false,
        warmupRemainingMs: 0,
        voiceReady: false,
        error: nil,
        receivedAt: Date()
    )
}
