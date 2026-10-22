import Foundation

// MARK: - Pat event

/// 微信「拍一拍」的结构化事件。
///
/// 新版 hook 会额外上报 `pat_target_wxid` / `pat_from_wxid` / `pat_chat_wxid` /
/// `pat_suffix` / `pat_template`；旧 bridge 没有这些字段时，从 `raw_message` 的
/// appmsg `<patinfo>` 或旧版 `<sysmsg type="pat">` / `<patmsg>` XML 里解析。
///
/// 解析不到被拍人时 `targetID` 为空字符串——规则层不得根据「拍了拍我」里的「我」硬猜，
/// 否则用户随口说一句「我刚才拍了拍他」也会被当成拍一拍。
struct PatEvent: Equatable, Sendable {
    /// 拍的人 wxid。
    var fromID: String
    /// 群 ID；私聊为空。
    var chatID: String
    /// 被拍的人 wxid；解析不到时为空字符串。
    var targetID: String
    /// 拍一拍后缀（如「的肩膀」）。
    var suffix: String?
    /// 原始模板（如 `"小明" 拍了拍 "测试机器人"`）。
    var template: String?
}

/// 拍一拍回复的 @ 目标（仅群聊）。
///
/// `userID` 交给 bridge 的 `at` 段解析群昵称并写入 `<atuserlist>`；
/// `displayName` 只用于本地消息记录/预览，未知时不伪造 `@昵称` 文本。
struct PatMention: Equatable, Sendable {
    /// 拍的人 wxid。
    var userID: String
    /// 可读的拍的人昵称；未知时为 nil。
    var displayName: String?

    /// 本地记录与微信正文对齐的展示文本：`@昵称\u{2005}正文`。
    /// 微信在点选 @ 后插入 U+2005（四分之一 em 空格），见 `MentionText`。
    func localText(_ text: String) -> String {
        guard let displayName, !displayName.isEmpty else { return text }
        return "@\(displayName)\u{2005}\(text)"
    }
}

// MARK: - Pat message helpers

enum PatMessage {
    // MARK: Public API

    /// 从 App 保存的事件 `rawJSON` 中解析拍一拍结构；不是拍一拍返回 `nil`。
    ///
    /// 支持三种形态：
    /// 1. hook 新增的结构化字段（事件同层或 `data` 包装层）；
    /// 2. JSON 事件里的 `raw_message` XML（含被二次转义的 `\u003c` 形态）；
    /// 3. `rawJSON` 本身就是 XML。
    static func event(from rawJSON: String?) -> PatEvent? {
        guard let rawJSON else { return nil }
        let trimmed = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            if let object = json as? [String: Any] {
                return event(fromEventObject: object)
            }
            if let text = json as? String {
                return event(fromXML: WeChatXML.decodeEscapes(text))
            }
        }
        return event(fromXML: WeChatXML.decodeEscapes(trimmed))
    }

    /// 规则层判定：这条拍一拍是否拍的是机器人。
    ///
    /// - 有结构化目标：只有目标等于 `selfID`（大小写不敏感）才命中；
    /// - 没有结构化目标：只有确认是拍一拍事件后，才允许文本兜底——
    ///   私聊认「拍了拍我 / patted me」，群聊必须出现 `selfID` 或已学到的机器人群昵称。
    static func isDirectedAtBot(_ message: ChatMessage, conversation: Conversation,
                                selfID: String, selfMentionName: String?) -> Bool {
        // 纯文本消息（rawJSON 里没有 patinfo / type 62 / sysmsg type=pat）不是拍一拍。
        guard let event = event(from: message.rawJSON) else { return false }

        let target = event.targetID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !target.isEmpty {
            guard !selfID.isEmpty else { return false }
            return target.caseInsensitiveCompare(selfID) == .orderedSame
        }

        // 4.1.12 的部分 sysmsg 只带模板、不带 pattedusername；私聊里「拍了拍我」
        // 可以确定被拍的是机器人，群聊里则必须能对上 selfID / 群昵称。
        let texts = [message.text, event.template ?? ""].filter { !$0.isEmpty }
        if conversation.kind == .direct, texts.contains(where: isPatMeTemplate) {
            return true
        }
        return texts.contains(where: {
            containsSelfReference($0, selfID: selfID, mentionName: selfMentionName)
        })
    }

    /// 群聊拍一拍回复的 @ 目标；不满足条件返回 `nil`。
    ///
    /// 只在群聊、开关开启、能确定拍的人 wxid 且不是机器人自己时返回。
    /// 优先用消息发送者（入站拍一拍事件里就是拍的人），缺失时回退 `pat_from_wxid`。
    static func replyMention(
        _ message: ChatMessage,
        conversation: Conversation,
        selfID: String,
        enabled: Bool
    ) -> PatMention? {
        guard enabled, conversation.kind == .group else { return nil }

        var userID = message.senderID.trimmingCharacters(in: .whitespacesAndNewlines)
        if userID.isEmpty {
            userID = event(from: message.rawJSON)?.fromID
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard !userID.isEmpty else { return nil }
        if !selfID.isEmpty, userID.caseInsensitiveCompare(selfID) == .orderedSame {
            return nil
        }
        // 群 ID / 占位账号不是可 @ 的人，避免把 @ 写进 atuserlist 后发送失败。
        let lowered = userID.lowercased()
        guard !lowered.hasSuffix("@chatroom"), lowered != "self", lowered != "wxid_self" else {
            return nil
        }

        let displayName = ConversationName.learnedSenderName(
            message.senderName,
            conversationID: conversation.id,
            senderID: userID,
            selfID: selfID
        )
        return PatMention(userID: userID, displayName: displayName)
    }

    // MARK: Event parsing

    private struct RawFields {
        var fromID = ""
        var chatID = ""
        var targetID = ""
        var suffix: String?
        var template: String?
    }

    private static func event(fromEventObject object: [String: Any]) -> PatEvent? {
        var containers = [object]
        if let nested = object["data"] as? [String: Any] {
            containers.append(nested)
        }

        var structured = RawFields()
        var hasStructured = false
        for container in containers {
            if mergeStructuredFields(into: &structured, from: container) {
                hasStructured = true
            }
        }

        var xmlText: String?
        for container in containers {
            if let raw = stringValue(container["raw_message"]) ?? stringValue(container["rawMessage"]) {
                xmlText = raw
                break
            }
        }

        var xmlFields = RawFields()
        var xmlIsPat = false
        if let xmlText {
            let xml = WeChatXML.decodeEscapes(xmlText)
            xmlIsPat = looksLikePat(xml)
            if xmlIsPat {
                xmlFields = parseXMLFields(xml)
            }
        }

        guard hasStructured || xmlIsPat else { return nil }
        return PatEvent(
            fromID: firstNonEmpty(structured.fromID, xmlFields.fromID),
            chatID: firstNonEmpty(structured.chatID, xmlFields.chatID),
            targetID: firstNonEmpty(structured.targetID, xmlFields.targetID),
            suffix: structured.suffix ?? xmlFields.suffix,
            template: structured.template ?? xmlFields.template
        )
    }

    private static func event(fromXML xml: String) -> PatEvent? {
        guard looksLikePat(xml) else { return nil }
        let fields = parseXMLFields(xml)
        return PatEvent(
            fromID: fields.fromID,
            chatID: fields.chatID,
            targetID: fields.targetID,
            suffix: fields.suffix,
            template: fields.template
        )
    }

    private static func mergeStructuredFields(into fields: inout RawFields,
                                              from object: [String: Any]) -> Bool {
        var found = false
        if let value = stringValue(object["pat_from_wxid"]), !value.isEmpty {
            found = true
            if fields.fromID.isEmpty { fields.fromID = value }
        }
        if let value = stringValue(object["pat_chat_wxid"]), !value.isEmpty {
            found = true
            if fields.chatID.isEmpty { fields.chatID = value }
        }
        if let value = stringValue(object["pat_target_wxid"]), !value.isEmpty {
            found = true
            if fields.targetID.isEmpty { fields.targetID = value }
        }
        if let value = stringValue(object["pat_suffix"]), !value.isEmpty {
            found = true
            if fields.suffix == nil { fields.suffix = value }
        }
        if let value = stringValue(object["pat_template"]), !value.isEmpty {
            found = true
            if fields.template == nil { fields.template = value }
        }
        return found
    }

    /// 判定 raw XML 是否是拍一拍：4.1.15 appmsg `<patinfo>` / `<type>62</type>`，
    /// 旧版 `<sysmsg type="pat">` / `<patmsg>`。
    private static func looksLikePat(_ xml: String) -> Bool {
        let lowered = xml.lowercased()
        if lowered.contains("<patinfo") { return true }
        if lowered.contains("<patmsg") { return true }
        if lowered.contains("<pat>"), lowered.contains("<pattedusername") { return true }
        if matches(#"<sysmsg\b[^>]*\btype\s*=\s*(?:"|')pat(?:"|')"#, in: xml) { return true }
        if matches(#"<type>\s*62\s*</type>"#, in: xml) { return true }
        return false
    }

    private static func parseXMLFields(_ xml: String) -> RawFields {
        RawFields(
            fromID: WeChatXML.field("fromusername", in: xml) ?? "",
            chatID: WeChatXML.field("chatusername", in: xml) ?? "",
            targetID: WeChatXML.field("pattedusername", in: xml) ?? "",
            suffix: WeChatXML.field("patsuffix", in: xml),
            template: WeChatXML.field("template", in: xml)
        )
    }

    // MARK: Text matching

    private static func isPatMeTemplate(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("拍了拍我") || lowered.contains("patted me")
    }

    private static func containsSelfReference(_ text: String, selfID: String,
                                             mentionName: String?) -> Bool {
        guard !text.isEmpty else { return false }
        if !selfID.isEmpty, text.range(of: selfID, options: [.caseInsensitive]) != nil {
            return true
        }
        if let mentionName {
            let name = mentionName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, text.range(of: name, options: [.caseInsensitive]) != nil {
                return true
            }
        }
        return false
    }

    // MARK: String helpers

    private static func firstNonEmpty(_ first: String, _ second: String) -> String {
        first.isEmpty ? second : first
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let nsText = text as NSString
        return regex.firstMatch(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        ) != nil
    }
}
