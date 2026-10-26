import Foundation

// MARK: - Text preparation for TTS

/// 口语化文本清洗与超限截断（纯函数，便于单测；spec §3.1）。
///
/// 清洗目标（按顺序）：
/// 1. 去掉代码块/行内代码/Markdown 链接/裸 URL/HTML 标签——这些朗读出来没有意义；
/// 2. 去掉 Markdown 标记（标题、列表、引用、粗体/斜体/删除线、表格竖线）；
/// 3. 去掉 emoji 与零宽字符；
/// 4. 折叠多余空白；
/// 5. 英文缩写按小词典做「保留式」替换（默认保留 PR/Slack/AI 等，数字读法交给模型）；
/// 6. 截断到安全上限，避免异常长文本拖垮合成。
///
/// 不做的事：不改写语义、不翻译、不把数字转成中文读法（交给模型/词典）。
enum VoiceTextSanitizer {
    /// 输入字符上限（超出直接截断；正常回复远小于此值）。
    static let maxInputCharacters = 1000

    /// 默认保留的英文缩略词/产品名（值为读音写法；当前都是「原样保留」）。
    /// 需要时可由调用方传入自己的词典覆盖（见 `sanitizeForSpeech(_:abbreviations:)`）。
    static let defaultAbbreviations: [String: String] = [
        "PR": "PR",
        "Slack": "Slack",
        "AI": "AI",
        "API": "API",
        "TTS": "TTS",
        "STT": "STT",
    ]

    // MARK: Sanitize

    static func sanitizeForSpeech(
        _ raw: String,
        abbreviations: [String: String]? = nil
    ) -> String {
        var text = raw

        // 1. 代码块（含未闭合的情况）与行内代码。
        text = replacing(text, #"```[\s\S]*?(```|$)"#, with: " ")
        text = replacing(text, #"`[^`\n]*`"#, with: " ")

        // 2. 图片/链接（保留可见文字）、裸 URL、自动链接。
        text = replacing(text, #"!\[[^\]]*\]\([^)]*\)"#, with: " ")
        text = replacing(text, #"\[([^\]]*)\]\([^)]*\)"#, with: "$1")
        text = replacing(text, #"(?i)\b(?:https?://|www\.)\S+"#, with: " ")
        text = replacing(text, #"<https?://[^>\s]+>"#, with: " ")

        // 3. HTML/XML 标签（微信消息里偶尔出现的残留）。
        text = replacing(text, #"<[^>\n]{1,80}>"#, with: " ")

        // 4. Markdown 结构标记（行首标题/引用/列表/任务框，表格竖线）。
        text = replacing(text, #"(?m)^\s{0,3}#{1,6}\s*"#, with: "")
        text = replacing(text, #"(?m)^\s{0,3}>\s?"#, with: "")
        text = replacing(text, #"(?m)^\s*[-*+]\s+"#, with: "")
        text = replacing(text, #"(?m)^\s*\d+[.)]\s+"#, with: "")
        text = replacing(text, #"(?m)^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$"#, with: " ")
        text = replacing(text, #"\|"#, with: "，")

        // 5. 强调/删除线标记（保留文字）。
        text = replacing(text, #"(?<!\w)[*_~]{1,3}(?=\S)"#, with: "")
        text = replacing(text, #"(?<=\S)[*_~]{1,3}(?!\w)"#, with: "")

        // 6. emoji、零宽/控制字符。
        text = removeEmojiAndInvisibles(text)

        // 7. 空白折叠。
        text = replacing(text, "[ \t\u{00A0}\u{3000}]+", with: " ")
        text = replacing(text, #"\n{3,}"#, with: "\n\n")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 8. 缩略词小词典（词边界匹配，避免替换到单词内部）。
        let dictionary = abbreviations ?? defaultAbbreviations
        text = applyAbbreviations(text, dictionary: dictionary)

        // 9. 长度上限。
        if text.count > maxInputCharacters {
            text = String(text.prefix(maxInputCharacters))
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把词典里的词替换成读音写法（默认是恒等映射，仅表达「保留」语义）。
    static func applyAbbreviations(_ text: String, dictionary: [String: String]) -> String {
        guard !dictionary.isEmpty else { return text }
        var result = text
        for key in dictionary.keys.sorted(by: { $0.count > $1.count }) {
            guard let value = dictionary[key], !key.isEmpty else { continue }
            let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: key)
                + "(?![A-Za-z0-9])"
            result = replacing(result, pattern, with: value)
        }
        return result
    }

    // MARK: Truncation

    /// 按完整句子截取不超过 `maxCharacters` 的前缀（句号/问号/感叹号/分号/换行优先，
    /// 单句过长时退化到逗号/顿号/空格，最后才硬截断）。
    ///
    /// `maxCharacters <= 0` 返回空串；文本本来就短时原样返回。
    static func sentenceCapped(_ text: String, maxCharacters: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxCharacters > 0 else { return "" }
        guard trimmed.count > maxCharacters else { return trimmed }

        let strong = CharacterSet(charactersIn: "。！？!?；;\n")
        let weak = CharacterSet(charactersIn: "，,、：:—…")

        func split(_ value: String, on set: CharacterSet) -> [String] {
            var chunks: [String] = []
            var current = ""
            for character in value {
                current.append(character)
                if character.unicodeScalars.contains(where: { set.contains($0) }) {
                    chunks.append(current)
                    current = ""
                }
            }
            if !current.isEmpty { chunks.append(current) }
            return chunks
        }

        // 1. 句级：累加完整句子，尽量保留最后一个完整句。
        var result = ""
        for chunk in split(trimmed, on: strong) {
            if (result + chunk).count > maxCharacters { break }
            result += chunk
        }
        if !result.isEmpty { return result.trimmingCharacters(in: .whitespacesAndNewlines) }

        // 2. 第一句就超长：从句内逗号处截。
        let firstSentence = split(trimmed, on: strong).first ?? trimmed
        var partial = ""
        for chunk in split(firstSentence, on: weak) {
            if (partial + chunk).count > maxCharacters { break }
            partial += chunk
        }
        if !partial.isEmpty { return partial.trimmingCharacters(in: .whitespacesAndNewlines) }

        // 3. 硬截断（按 Character，不会切坏字素）。
        return String(trimmed.prefix(maxCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 根据首次合成的实测时长，估算「不超过 `maxSeconds` 秒」的字符预算。
    ///
    /// - Parameters:
    ///   - spokenSeconds: 整段文本实际合成的语音时长（秒）。
    ///   - textLength: 整段文本的字符数。
    ///   - maxSeconds: 目标时长上限。
    ///   - safety: 安全系数（默认 0.9，抵消句间静音/重采样误差）。
    static func characterBudget(
        spokenSeconds: Double,
        textLength: Int,
        maxSeconds: Int,
        safety: Double = 0.9
    ) -> Int {
        guard spokenSeconds > 0, textLength > 0, maxSeconds > 0, safety > 0 else { return 0 }
        let secondsPerCharacter = spokenSeconds / Double(textLength)
        guard secondsPerCharacter > 0 else { return textLength }
        let budget = Double(maxSeconds) * safety / secondsPerCharacter
        return max(1, min(textLength - 1, Int(budget)))
    }

    // MARK: Helpers

    /// 正则替换（失败时原样返回，避免清洗层抛错影响主链路）。
    private static func replacing(_ text: String, _ pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: template)
    }

    /// 去掉 emoji 与不可见字符（零宽、方向控制、替换符）。
    private static func removeEmojiAndInvisibles(_ text: String) -> String {
        var result = String()
        result.reserveCapacity(text.count)
        let variationSelector = Unicode.Scalar(0xFE0F)
        let zeroWidthJoiner = Unicode.Scalar(0x200D)
        for character in text {
            // 单个 emoji 往往由「基础符号 + 变体选择符 + ZWJ 序列」组成；
            // 只要任一标量落在 emoji 区就整体丢弃。
            let scalars = character.unicodeScalars
            if scalars.contains(where: { isEmojiScalar($0) }) { continue }
            if let first = scalars.first,
               first == variationSelector || first == zeroWidthJoiner {
                continue
            }
            if scalars.contains(where: { isInvisible($0) }) { continue }
            result.append(character)
        }
        return result
    }

    private static func isEmojiScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1F000...0x1FAFF,   // 各类 emoji（含肤色/旗帜/符号）
             0x2600...0x27BF,     // 杂项符号 + Dingbats（☀️✅✈️…）
             0x2B00...0x2BFF,     // ⭐ 等
             0x2190...0x21FF,     // 箭头（回复里常作装饰）
             0x2300...0x23FF,     // ⌚⏰ 等技术符号
             0xFE00...0xFE0F,     // 变体选择符
             0x1F1E6...0x1F1FF,   // 区域指示符（国旗）
             0xE0020...0xE007F:   // tag 字符
            return true
        default:
            return false
        }
    }

    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00AD,              // soft hyphen
             0x200B...0x200F,     // 零宽空格/方向控制
             0x202A...0x202E,     // 方向嵌入
             0x2060...0x2064,     // 词连接符
             0xFEFF,              // BOM
             0xFFFD:              // 替换符
            return true
        default:
            return false
        }
    }
}
