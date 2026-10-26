import Foundation

/// 一次「这条回复要不要改成语音」的决策输入（纯值，便于单测）。
///
/// 由运行时在生成文字回复后调用；`modelsReady` 表示 TTS 引擎与所选模型已就绪
/// （由 `VoiceSynthesisService`/`VoiceModelStore` 判定后传入），`rng` 由调用方
/// 注入 `Double.random(in: 0..<1)`，测试里可固定。
struct VoiceReplyContext: Sendable, Equatable {
    var global: VoiceSettings
    var conversation: Conversation
    var incomingWasVoice: Bool
    var replyText: String
    var modelsReady: Bool
    /// bridge/Hook 的语音发送运行时是否就绪（句柄 + 登录稳定倒计时 + 配置）。
    var runtimeReady: Bool = true
    var rng: Double
}

/// 语音回复决策：`voice` 时上层改发语音，`text` 时发文字。
///
/// `reason` 只用于日志（不进入提示词、不影响用户可见文案）。
enum VoiceReplyDecision: Equatable, Sendable {
    case text(reason: String)
    case voice(reason: String)

    var isVoice: Bool {
        if case .voice = self { return true }
        return false
    }

    var reason: String {
        switch self {
        case .text(let reason), .voice(let reason): return reason
        }
    }
}

/// 语音回复决策纯函数（spec §3.2）。
///
/// 判定顺序（命中即返回，保证行为可解释、可单测）：
/// 1. **开关**：会话覆盖 → 全局 `replyEnabled`；关闭时发文字；
/// 2. **模型就绪**：TTS 引擎/模型未就绪时发文字（不阻塞文字回复）；
/// 3. **对等**：`mirrorIncomingVoice` 时只有本轮收到语音才考虑回语音；
/// 4. **短回复**：`shortReplyOnly` 且回复字符数超过阈值时发文字；
/// 5. **概率**：`rng < 生效概率` → 语音，否则文字；
/// 6. 兜底：文字。
func decideVoiceReply(_ ctx: VoiceReplyContext) -> VoiceReplyDecision {
    let settings = ctx.global
    let enabled = ctx.conversation.effectiveVoiceReplyEnabled(global: settings.replyEnabled)
    guard enabled else {
        return .text(reason: "语音回复已关闭（会话/全局开关）")
    }
    guard ctx.modelsReady else {
        return .text(reason: "语音模型未就绪")
    }
    guard ctx.runtimeReady else {
        return .text(reason: "语音发送句柄未就绪或仍在启动倒计时")
    }
    if settings.mirrorIncomingVoice, !ctx.incomingWasVoice {
        return .text(reason: "对等模式：本轮不是语音消息")
    }
    let text = ctx.replyText.trimmingCharacters(in: .whitespacesAndNewlines)
    if settings.shortReplyOnly, text.count > settings.effectiveShortReplyMaxChars {
        return .text(reason: "仅短回复：\(text.count) 字 > \(settings.effectiveShortReplyMaxChars) 字")
    }
    // 概率仍由全局设置控制（会话只覆盖总开关），避免旧库里的概率覆盖让「已开启」
    // 的会话被静默拦住不发语音。
    let probability = settings.effectiveReplyProbability
    guard probability > 0 else {
        return .text(reason: "语音回复概率为 0")
    }
    let rng = ctx.rng.isFinite ? ctx.rng : 1
    if rng < probability {
        return .voice(reason: String(format: "命中语音回复概率（%.2f < %.2f）", rng, probability))
    }
    return .text(reason: String(format: "未命中语音回复概率（%.2f ≥ %.2f）", rng, probability))
}

/// 引用语音时附加到本轮用户消息末尾的说明（与引用图片的 `VisionSupport` 同构）。
///
/// 微信引用只带 `svrid` 与 `[语音]` 摘要，主回复模型看不到语音本体；把被引用语音的
/// 转写作为一条显式说明附加，模型才能知道「引用的是哪条语音」。
/// `transcript` 为空表示原语音未能转写：也要明确告知，避免模型编造内容。
enum VoiceQuoteText {
    static func quotedVoiceNote(transcript: String?) -> String {
        let value = transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "（引用的语音转写暂不可用）" : "（引用语音内容：\(value)）"
    }
}
