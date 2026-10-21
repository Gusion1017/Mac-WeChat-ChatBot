import Foundation

/// Interface language preference. `system` follows the macOS preferred language.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    /// Bilingual label so the picker is understandable in either language.
    var displayName: String {
        switch self {
        case .system: "跟随系统 / System"
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }

    var locale: Locale {
        switch self {
        case .system:
            let code = Locale.current.language.languageCode?.identifier ?? "zh"
            return Locale(identifier: code == "zh" ? "zh-Hans" : "en")
        case .simplifiedChinese:
            return Locale(identifier: "zh-Hans")
        case .english:
            return Locale(identifier: "en")
        }
    }
}

/// Runtime UI string lookup. Chinese is the source language; English strings live in
/// `en.lproj/Localizable.strings` inside the app bundle.
///
/// SwiftUI localizes `Text("中文")` automatically through the environment locale.
/// This helper covers labels built as `String` values (enum labels, custom components)
/// and dynamic strings that would otherwise stay in Chinese.
enum L10n {
    private(set) nonisolated(unsafe) static var language: String = "zh-Hans"
    private nonisolated(unsafe) static var englishBundle: Bundle?

    static func resolvedLanguage(_ raw: String) -> String {
        switch AppLanguage(rawValue: raw) ?? .system {
        case .simplifiedChinese:
            return "zh-Hans"
        case .english:
            return "en"
        case .system:
            let code = Locale.current.language.languageCode?.identifier ?? "zh"
            return code == "zh" ? "zh-Hans" : "en"
        }
    }

    static func apply(_ raw: String) {
        let resolved = resolvedLanguage(raw)
        guard resolved != language || englishBundle == nil else { return }
        language = resolved
        if resolved == "en" {
            if let path = Bundle.main.path(forResource: "en", ofType: "lproj") {
                englishBundle = Bundle(path: path)
            }
        } else {
            englishBundle = nil
        }
    }

    static func text(_ key: String) -> String {
        guard language == "en" else { return key }
        if let bundle = englishBundle {
            let translated = bundle.localizedString(forKey: key, value: key, table: nil)
            if translated != key { return translated }
        }
        return patternTranslate(key)
    }

    /// Fallback for composed strings (counts, status suffixes, error prefixes) that
    /// cannot be keyed byte-for-byte. Keeps the source code free of format plumbing
    /// for every small label.
    private static let patterns: [(String, String)] = [
        // Specific composed sentences first.
        ("^(.*) 连接正常$", "$1 connected"),
        ("^(.*) 连接失败$", "$1 connection failed"),
        ("^已重命名为「(.*)」$", "Renamed to “$1”"),
        ("^已恢复自动名称「(.*)」$", "Restored automatic name “$1”"),
        ("^已从 Keychain 删除 (.*) 的密钥$", "Deleted the key for $1 from Keychain"),
        ("^已删除通道 (.*)$", "Deleted channel $1"),
        ("^已将 (.*) 设为默认人格$", "Set $1 as the default persona"),
        ("^日志已导出到 (.*)$", "Logs exported to $1"),
        ("^安装失败：(.*)$", "Installation failed: $1"),
        ("^还原失败：(.*)$", "Restore failed: $1"),
        ("^导出失败：(.*)$", "Export failed: $1"),
        ("^保存 API Key 失败：(.*)$", "Failed to save API key: $1"),
        ("^删除密钥失败：(.*)$", "Failed to delete key: $1"),
        ("^通道已保存，但密钥写入失败：(.*)$", "Channel saved, but failed to write API key: $1"),
        ("^AI 连接失败：(.*)$", "AI connection failed: $1"),
        ("^工作时间：当前处于工作时段，(.*)$", "Working hours: active; $1"),
        ("^工作时间：当前不在工作时段，(.*)$", "Working hours: inactive; $1"),
        ("^(.*)，规则引擎不会因时间拦截自动回复。$", "$1; the rule engine will not block replies based on time."),
        ("^(.*)–次日 (.*)$", "$1–next day $2"),
        ("^(.*) · 本地$", "$1 · local"),
        ("^(.*) · 尚未保存密钥$", "$1 · API key not saved"),
        ("^已检测到微信 (.*)$", "Detected WeChat $1"),
        ("^微信 (.*)$", "WeChat $1"),
        ("^版本 (.*)$", "Version $1"),
        ("^最近更新 (.*)$", "Last updated $1"),
        ("^最近召回 (.*)$", "Last recalled $1"),
        ("^最近 (.*)$", "Recent $1"),
        ("^启动于 (.*)$", "Started $1"),
        ("^更新 (.*)$", "Updated $1"),
        ("^合并 (\\d+) 条$", "Merged $1"),
        ("^召回 (\\d+) 次$", "Recalled $1×"),
        ("^核心 (\\d+) 条$", "Core: $1"),
        ("^★ 核心 (\\d+)$", "★ Core $1"),
        ("^权重 (.*)$", "Weight $1"),
        ("^基础 ×(.*)$", "Base ×$1"),
        ("^第 (\\d+)/(\\d+) 段$", "Part $1/$2"),
        ("^R3 队列 (\\d+) 条$", "R3 queue: $1"),
        ("^已等待 (.*)$", "Waiting $1"),
        ("^回执 (.*)$", "Receipt $1"),
        ("^总用时 (.*)$", "Total $1"),
        ("^生成 (\\d+)s$", "Generated in $1s"),
        ("^(\\d+)s 后发送$", "Sending in $1s"),
        ("^每分钟最多 (\\d+) 条回复$", "Up to $1 replies per minute"),
        ("^临时记忆最多 (\\d+) 条 · 累计 (\\d+) 条旧消息后批量总结$", "Short-term memory: up to $1 · batch summary after $2 old messages"),
        ("^最多 (\\d+) 段$", "Up to $1 segments"),
        ("^(\\d+) 个任务 · (\\d+) 个启用$", "$1 schedules · $2 enabled"),
        ("^(\\d+) 个会话 · (\\d+) 条消息 · 本地 SQLite$", "$1 conversations · $2 messages · local SQLite"),
        ("^(\\d+) 个通道 · 默认 (.*) · (.*)$", "$1 channels · default $2 · $3"),
        ("^(\\d+) 个人格 · 默认「(.*)」$", "$1 personas · default “$2”"),
        ("^(\\d+) 个人格$", "$1 personas"),
        ("^(\\d+) 个任务$", "$1 schedules"),
        ("^(\\d+) 个会话文件夹$", "$1 conversation folders"),
        ("^(\\d+) 条长期记忆 · 核心 (\\d+) · 短期窗口 (\\d+) 条 · 每 (\\d+) 条批量总结 · 本地 SQLite$",
         "$1 long-term memories · core $2 · short-term window $3 · batch summary every $4 · local SQLite"),
        ("^(\\d+) 条未读$", "$1 unread"),
        ("^(\\d+) 条消息$", "$1 messages"),
        ("^(\\d+) 条记忆$", "$1 memories"),
        ("^(\\d+) 条匹配$", "$1 matches"),
        ("^(\\d+) 条回复$", "$1 replies"),
        ("^(\\d+) 条缓冲 · 上限 (\\d+) 条 · (.*)$", "$1 buffered · limit $2 · $3"),
        ("^(\\d+) / (\\d+) 条$", "$1 / $2 items"),
        ("^(\\d+) 条$", "$1 items"),
        ("^(\\d+) 次$", "$1 times"),
        ("^(\\d+) 秒$", "$1 s"),
        ("^(\\d+) 分钟前$", "$1 min ago"),
        ("^(\\d+) 分 (\\d+) 秒$", "$1 min $2 s"),
        ("^(\\d+) 段$", "$1 segments"),
        ("^(\\d+) 个启用$", "$1 enabled"),
        ("全局时段", "global hours"),
        ("会话时段", "conversation hours"),
        ("不限时段", "unrestricted"),
        ("非工作时段", "outside working hours"),
        ("工作时段", "working hours"),
        ("全局未启用工作时间限制", "working hours are not enabled globally"),
        ("未选择任何星期", "no weekdays selected"),
        ("已安装 · 版本已匹配", "Installed · version matched"),
        ("已安装 · 待匹配版本", "Installed · version not matched"),
        ("尚未安装（可稍后在设置中安装）", "Not installed (you can install later in Settings)"),
        ("所有会话", "all conversations"),
        ("尚未安装", "Not installed"),
        ("未检测到版本", "Version not detected"),
        ("^上次 (.*)$", "Last $1"),
        ("^下次 (.*)$", "Next $1"),
        ("^(\\d+) 条 · (.*)$", "$1 items · $2"),
        ("无未读", "No unread"),
        ("群聊", "Group chat"),
        ("私聊", "Direct message"),
        ("公众号", "Official account"),
        ("AI 自动回复已关闭", "AI auto-reply off"),
        ("^AI 生成中 · (.*)$", "AI generating · $1"),
        ("^当前处于工作时段，规则引擎不会因时间拦截自动回复。$", "Currently within working hours; the rule engine will not block replies based on time."),
        ("^当前不在工作时段，规则引擎会拦截自动回复（手动发送不受影响）。$", "Outside working hours; the rule engine blocks automatic replies (manual sending is unaffected)."),
        ("^此会话已取消工作时间限制$", "Working hours disabled for this conversation"),
        ("^全局未启用工作时间限制$", "Working hours are not enabled globally"),
        ("^工作时间：不限时段$", "Working hours: unrestricted"),
        // Service error prefixes.
        ("^写入消息失败：(.*)$", "Failed to write message: $1"),
        ("^读取长期记忆失败：(.*)$", "Failed to read long-term memory: $1"),
        ("^数据库打开失败：(.*)$", "Failed to open database: $1"),
        ("^生成回复失败：(.*)$", "Failed to generate reply: $1"),
        ("^AI 服务返回错误：(.*)$", "AI service error: $1"),
        ("^命令执行失败：(.*)$", "Command failed: $1"),
        ("^手动发送失败：(.*)$", "Manual send failed: $1"),
        // Status words inside composed subtitles/tooltips.
        ("机器人运行中", "Bot running"),
        ("机器人已停止", "Bot stopped"),
        ("OneBot 已连接", "OneBot connected"),
        ("OneBot 未连接", "OneBot not connected"),
        ("昨天", "Yesterday"),
        ("今天", "Today"),
        ("明天", "Tomorrow"),
        ("工作日", "Weekdays"),
        ("每天", "Every day"),
        ("已启用「关键词」触发", "Keyword trigger enabled"),
        ("勾选「关键词」后生效", "Enable Keyword above to apply"),
        ("演练模式", "Dry run"),
        ("真实发送", "Live sending"),
        ("运行中", "Running"),
        ("已停止", "Stopped"),
        ("未运行", "Not running"),
        ("未检测", "Not detected"),
        ("已连接", "Connected"),
        ("未连接", "Not connected"),
        ("已安装", "Installed"),
        ("未安装", "Not installed"),
        ("已配置", "Configured"),
        ("未配置", "Not configured"),
        ("已停用", "Disabled"),
        ("缺少密钥", "Missing key"),
        ("已暂停", "Paused"),
        ("实时", "Live"),
    ]

    private static func patternTranslate(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else {
            return text
        }
        var result = text
        // Two passes handle nested fragments such as "最近 5 分钟前".
        for _ in 0..<2 {
            for (pattern, replacement) in patterns {
                result = result.replacingOccurrences(
                    of: pattern,
                    with: replacement,
                    options: .regularExpression
                )
            }
        }
        result = result
            .replacingOccurrences(of: "(\\d+(?:\\.\\d+)?) 秒", with: "$1 s", options: .regularExpression)
            .replacingOccurrences(of: "(\\d+) 分钟前", with: "$1 min ago", options: .regularExpression)
            .replacingOccurrences(of: "(\\d+) 分 (\\d+) 秒", with: "$1 min $2 s", options: .regularExpression)
            .replacingOccurrences(of: "(\\d+) 条", with: "$1 items", options: .regularExpression)
            .replacingOccurrences(of: "(\\d+) 次", with: "$1 times", options: .regularExpression)
            .replacingOccurrences(of: "(\\d+) 段", with: "$1 segments", options: .regularExpression)
            .replacingOccurrences(of: "(\\d+) 个", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "，", with: ", ")
            .replacingOccurrences(of: "、", with: ", ")
            .replacingOccurrences(of: "；", with: "; ")
            .replacingOccurrences(of: "：", with: ": ")
        return result
    }
}

/// Translate a Chinese UI string at runtime. Unknown keys fall back to the source string.
func L(_ key: String) -> String { L10n.text(key) }

/// Translate a Chinese format string and apply `String(format:)` arguments.
func Lf(_ key: String, _ args: CVarArg...) -> String {
    String(format: L10n.text(key), arguments: args)
}
