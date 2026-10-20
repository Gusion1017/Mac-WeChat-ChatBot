import Foundation

/// 群聊 @ 的文本辅助。
///
/// 微信「从列表点选」的 @ 通常带 `<atuserlist>`（hook 会转成 `at` 段 / `mentions`），
/// 但实测存在两种情况需要文本兜底：
/// 1. 部分客户端/版本把目标写在 `msgsource` 之外，事件里没有 `at` 段；
/// 2. 用户手动输入 `@群昵称`，微信不会生成结构化 mention。
///
/// 文本里的昵称可以从带 `at` 段的成功事件中学习（见 `displayName(in:selfID:mentions:)`），
/// 之后规则层即可用昵称匹配文本 @。
enum MentionText {
    /// 微信在点选 @ 昵称后插入 U+2005（四分之一 em 空格）。
    private static let mentionSeparator = "\u{2005}"

    /// 提取文本中所有「@昵称」的昵称，按出现顺序返回。
    static func names(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        // 昵称后必须是空白 / U+2005 / 结尾，避免把 "@机器人2" 学成 "@机器人"。
        let pattern = "@([^@\\s\\u2005]+)(?=[\\s\\u2005]|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        return regex.matches(in: text, range: fullRange).compactMap { match in
            guard match.numberOfRanges >= 2 else { return nil }
            let value = nsText.substring(with: match.range(at: 1))
            return value.isEmpty ? nil : value
        }
    }

    /// 当 `mentions` 中包含机器人 wxid 时，返回文本里对应的 @ 展示昵称。
    ///
    /// 仅在数量/顺序能对齐时返回，避免把别人的昵称学成机器人的；
    /// `mentions` 与文本中的 @ 顺序都按微信正文出现顺序排列。
    static func displayName(in text: String, selfID: String, mentions: [String]) -> String? {
        guard !selfID.isEmpty,
              let index = mentions.firstIndex(of: selfID) else { return nil }
        let names = names(in: text)
        guard !names.isEmpty else { return nil }

        let name: String
        if names.count == mentions.count {
            name = names[index]
        } else if names.count == 1, mentions.count == 1 {
            name = names[0]
        } else {
            return nil
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.lowercased().hasPrefix("wxid_") else { return nil }
        return trimmed
    }

    /// 判断文本是否 @ 了指定昵称（大小写不敏感，允许昵称后跟分隔符/标点/结尾）。
    static func containsMention(of name: String, in text: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, text.contains("@") else { return false }
        let needle = "@" + trimmed
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: needle, options: [.caseInsensitive], range: searchStart..<text.endIndex) {
            let beforeOK: Bool = {
                guard range.lowerBound > text.startIndex else { return true }
                let previous = text[text.index(before: range.lowerBound)]
                return previous.isWhitespace || previous.isNewline || previous.isPunctuation
                    || previous == ":" || previous == Character(mentionSeparator)
            }()
            let afterOK: Bool = {
                guard range.upperBound < text.endIndex else { return true }
                let next = text[range.upperBound]
                return next.isWhitespace || next.isNewline || next.isPunctuation
                    || next == Character(mentionSeparator)
            }()
            if beforeOK && afterOK { return true }
            searchStart = range.upperBound
        }
        return false
    }
}
