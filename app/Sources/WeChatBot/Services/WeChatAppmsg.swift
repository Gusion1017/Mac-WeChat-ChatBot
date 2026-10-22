import Foundation

/// 微信 appmsg（`msg_type=49`）的结构化解析与展示文本。
///
/// 背景：hook 只把「拍一拍」（appmsg `<type>62</type>`）还原成文本，其余 appmsg
/// 一律写成占位符 `[链接/文件]`，导致引用回复的正文与被引用原文、链接标题、
/// 转账金额等对 App / 规则引擎 / AI 都不可见。这里在 App 侧从 `raw_message` 重新解析：
/// 同一份纯函数既服务实时事件，也能修复数据库里的历史消息。
///
/// 解析是纯函数、无 IO、值类型，可在 inbound 回调线程直接调用。
struct WeChatAppmsg: Equatable, Sendable {
    /// 被引用消息的摘要。
    ///
    /// 注意 `senderName` 可能为空（旧消息缺 `<displayname>`），展示层不能伪造；
    /// `messageType` 缺失时保持 `nil`，与「refermsg 为空」区分开。
    struct Quote: Equatable, Sendable {
        /// `<displayname>`；未知时为空字符串。
        var senderName: String
        /// 被引用消息的发送者 wxid：群引用取 `<chatusr>`，群内私聊形态/部分客户端
        /// 只有 `<fromusr>` 时回退（群 ID 会被忽略）。「引用机器人」触发用它和
        /// selfID 精确比对——昵称可重名，不能作为判定依据。
        var senderID: String = ""
        /// 被引用内容摘要（图片/表情等媒体转成 `[图片]` 之类）。
        var snippet: String
        /// refermsg `<type>`（1 文字 / 3 图片 / 34 语音 / 43 视频 / 47 表情 / 49 appmsg）。
        var messageType: Int?
    }

    /// appmsg `<type>`；缺失时 -1。
    var type: Int
    /// appmsg `<title>`；引用回复时就是回复正文。自闭合/缺失时为空字符串。
    var title: String
    /// 还原后的展示文本，保证非空。没有可读内容时退回 `[卡片]` / `[引用]` / `[拍一拍]`。
    var text: String
    /// 只有引用消息（type 57）才有；refermsg 损坏时字段为空但仍是引用消息。
    var quote: Quote?

    /// hook 对无法识别 appmsg 写的占位文本，用于历史消息幂等修复。
    static let placeholderText = "[链接/文件]"

    /// 拍一拍（appmsg type 62）；hook 正常时会先写好 title，走到这里多半是兜底。
    var isPat: Bool { type == 62 }

    // MARK: - 入口

    /// 从 hook 事件的 `raw_message`（appmsg XML）解析；不是 appmsg 返回 nil。
    ///
    /// 兼容被 JSON 二次转义的形态（字面量 `\u003c`）。先用 `<appmsg` 快速短路：
    /// 普通文本 / 图片 / 语音没有这个标签，不会被误判。
    static func parse(_ rawMessage: String?) -> WeChatAppmsg? {
        guard let rawMessage else { return nil }
        let trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 必须先解转义再判断标签：旧 bridge 保存的 raw_message 里 `<` 可能还是
        // 字面量 `\u003c`，直接找 `<appmsg` 会漏。
        let xml = WeChatXML.decodeEscapes(trimmed)
        guard WeChatXML.containsTag("appmsg", in: xml) else { return nil }

        // 只把 `<appmsg>` 内部当工作区：`<msg>` 外层的 fromusername 等字段、
        // refermsg 里转义过的同名标签都不会干扰字段查找。
        // 取不到（畸形/自闭合）时退回整段 XML，至少不丢标题。
        let appmsg = WeChatXML.block("appmsg", in: xml) ?? xml
        let type = Int(WeChatXML.field("type", in: appmsg) ?? "") ?? -1
        let title = WeChatXML.field("title", in: appmsg) ?? ""

        var quote: Quote?
        if type == 57 {
            // refermsg 可能是空容器（历史数据里真实存在 `<refermsg></refermsg>`），
            // 此时 quote 字段全空，展示文本退化成只有回复正文。
            let refer = WeChatXML.block("refermsg", in: appmsg) ?? ""
            let messageType = Int(WeChatXML.field("type", in: refer) ?? "")
            let content = WeChatXML.field("content", in: refer) ?? ""
            quote = Quote(
                senderName: WeChatXML.field("displayname", in: refer) ?? "",
                senderID: quotedSenderID(
                    chatUser: WeChatXML.field("chatusr", in: refer) ?? "",
                    fromUser: WeChatXML.field("fromusr", in: refer) ?? ""
                ),
                snippet: snippet(from: content, messageType: messageType),
                messageType: messageType
            )
        }

        let text = displayText(type: type, title: title, appmsg: appmsg, quote: quote)
        return WeChatAppmsg(type: type, title: title, text: text, quote: quote)
    }

    /// 从 App 保存的事件 `rawJSON` 解析；不是 appmsg 返回 nil。
    ///
    /// 支持三种形态：
    /// 1. JSON 事件的 `raw_message` / `rawMessage`（兼容 `data` 包装层）；
    /// 2. JSON 字符串（极少见，保持与 `PatMessage` 一致）；
    /// 3. `rawJSON` 本身就是 XML。
    static func parse(eventJSON: String?) -> WeChatAppmsg? {
        guard let eventJSON else { return nil }
        let trimmed = eventJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            if let text = json as? String {
                return parse(text)
            }
            guard let object = json as? [String: Any] else { return nil }
            var containers = [object]
            if let nested = object["data"] as? [String: Any] {
                containers.append(nested)
            }
            for container in containers {
                if let raw = stringValue(container["raw_message"])
                    ?? stringValue(container["rawMessage"]) {
                    return parse(raw)
                }
            }
            return nil
        }
        // 不是 JSON（或 JSON 坏掉）：按 XML 直接解析，与 `PatMessage.event(from:)` 一致。
        return parse(trimmed)
    }

    // MARK: - 展示文本

    /// 按 appmsg 类型生成展示文本（规格 §5.2）。
    private static func displayText(
        type: Int,
        title: String,
        appmsg: String,
        quote: Quote?
    ) -> String {
        switch type {
        case 57:
            return quoteText(title: title, quote: quote)
        case 62:
            // 拍一拍 hook 正常时会先填好「… 拍了拍 …」；这里只是兜底，
            // 不再加 `[拍一拍]` 前缀，避免规则层匹配模板时多出装饰。
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "[拍一拍]" : trimmed
        case 51:
            return cardText(label: label(for: type), content: finderFeedContent(in: appmsg))
        case 2000:
            return cardText(label: label(for: type), content: transferContent(title: title, appmsg: appmsg))
        case 8, 17:
            // 表情/位置共享没有可读正文；title 通常是自闭合空标签。
            return label(for: type)
        default:
            return cardText(label: label(for: type), content: title)
        }
    }

    /// 类型 → 中文标签。label 为空字符串的类型不会走到这里（57/62 单独处理）。
    private static func label(for type: Int) -> String {
        switch type {
        case 4: "[视频]"
        case 5: "[链接]"
        case 6: "[文件]"
        case 8: "[表情]"
        case 17: "[位置共享]"
        case 19: "[聊天记录]"
        case 33, 36: "[小程序]"
        case 42: "[名片]"
        case 48: "[位置]"
        case 51: "[视频号]"
        case 53: "[视频号直播]"
        case 87: "[群公告]"
        case 2000: "[转账]"
        case 2001: "[红包]"
        case 2003: "[音乐]"
        default: "[卡片]"
        }
    }

    /// `label + 空格 + 内容`；内容先 trim/压缩空白，再按 200 字符截断。
    private static func cardText(label: String, content: String) -> String {
        let normalized = truncate(normalizeWhitespace(content), limit: 200)
        return normalized.isEmpty ? label : "\(label) \(normalized)"
    }

    /// 引用消息：回复正文 + 换行 + `[引用 发送者] 原文摘要`。
    ///
    /// 回复正文**不压缩内部换行、不截断**（用户可能故意分行）；只 trim 首尾。
    /// 摘要为空（例如 refermsg 损坏）时只输出正文，不输出空的 `[引用]`。
    private static func quoteText(title: String, quote: Quote?) -> String {
        let reply = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = quote?.snippet ?? ""
        let sender = quote?.senderName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let quoteLine: String
        if snippet.isEmpty {
            quoteLine = ""
        } else if sender.isEmpty {
            quoteLine = "[引用] \(snippet)"
        } else {
            quoteLine = "[引用 \(sender)] \(snippet)"
        }

        if reply.isEmpty {
            return quoteLine.isEmpty ? "[引用]" : quoteLine
        }
        return quoteLine.isEmpty ? reply : reply + "\n" + quoteLine
    }

    /// 视频号：`<title>` 常是「当前版本不支持展示该内容，请升级至最新版本。」
    /// 这类占位文案，真实可读内容在 `<finderFeed>` 的 nickname/desc。
    private static func finderFeedContent(in appmsg: String) -> String {
        guard let feed = WeChatXML.block("finderFeed", in: appmsg) else { return "" }
        let nickname = WeChatXML.field("nickname", in: feed) ?? ""
        let desc = WeChatXML.field("desc", in: feed) ?? ""
        if !nickname.isEmpty, !desc.isEmpty {
            return "\(nickname)：\(desc)"
        }
        return nickname.isEmpty ? desc : nickname
    }

    /// 转账：优先 `<wcpayinfo><feedesc>`（如 `￥0.01`）+ `pay_memo`；
    /// 没有 feedesc 才回退 `<des>`，最后才用 title。
    private static func transferContent(title: String, appmsg: String) -> String {
        let payInfo = WeChatXML.block("wcpayinfo", in: appmsg) ?? ""
        let fee = WeChatXML.field("feedesc", in: payInfo) ?? ""
        let memo = WeChatXML.field("pay_memo", in: payInfo) ?? ""
        if !fee.isEmpty {
            return memo.isEmpty ? fee : fee + " " + memo
        }
        let des = WeChatXML.field("des", in: appmsg) ?? ""
        return des.isEmpty ? title : des
    }

    // MARK: - 被引用内容摘要

    /// 被引用内容摘要（规格 §5.1）：媒体转标签、纯文本压缩空白、
    /// 转义 XML 按标签分类；最后统一压缩空白并按 160 字符截断。
    private static func snippet(from content: String, messageType: Int?) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw: String
        if trimmed.isEmpty {
            // refermsg 只有 type、没有 content 时（例如老版本只存媒体引用）。
            raw = mediaLabel(for: messageType) ?? ""
        } else if trimmed.hasPrefix("<") {
            raw = snippetFromXML(trimmed)
        } else {
            raw = trimAndCollapseWhitespace(trimmed)
        }
        return truncate(normalizeWhitespace(raw), limit: 160)
    }

    /// content 为空时按 refermsg `<type>` 兜底媒体标签。
    private static func mediaLabel(for messageType: Int?) -> String? {
        switch messageType {
        case 3: "[图片]"
        case 34: "[语音]"
        case 43: "[视频]"
        case 47: "[表情]"
        case 48: "[位置]"
        case 42: "[名片]"
        default: nil
        }
    }

    /// 被引用内容本身是 XML（`field` 已反转义一次）时按标签分类。
    ///
    /// 顺序有意义：引用图片的 `<msg><img …/></msg>`、表情的 `<emoji>` 都含有
    /// 大量属性，必须先认标签再取文本；带 `<appmsg` 的引用要到「嵌套 appmsg」
    /// 分支，用内层展示文本而不是把整段 XML 当正文。
    private static func snippetFromXML(_ xml: String) -> String {
        if WeChatXML.containsTag("img", in: xml) { return "[图片]" }
        if WeChatXML.containsTag("videomsg", in: xml) { return "[视频]" }
        if WeChatXML.containsTag("voicemsg", in: xml) { return "[语音]" }
        if WeChatXML.containsTag("emoji", in: xml) { return "[表情]" }
        if WeChatXML.containsTag("location", in: xml) { return "[位置]" }
        if WeChatXML.containsTag("sysmsg", in: xml) || WeChatXML.containsTag("op", in: xml) {
            return "[系统消息]"
        }
        if WeChatXML.containsTag("appmsg", in: xml) {
            guard let nested = parse(xml) else { return "" }
            // 嵌套引用只取内层 title：否则外层会再套一层 `[引用 …]`，
            // 出现 `[引用 A] [引用 B] 正文` 这种双层方括号。
            if nested.type == 57 {
                return nested.title.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nested.text
        }
        // 未知 XML：先按 `<title>` 取，不行就去掉标签留下可读文本。
        if let title = WeChatXML.field("title", in: xml) { return title }
        let stripped = xml.replacingOccurrences(
            of: #"<[^>]*>"#,
            with: " ",
            options: .regularExpression
        )
        return WeChatXML.unescape(stripped)
    }

    // MARK: - 被引用消息的发送者

    /// 被引用消息的发送者 wxid：优先 `<chatusr>`（群聊引用实测可靠），
    /// 为空时回退 `<fromusr>`（私聊形态 / 部分客户端）。群 ID 是会话而不是发送者，
    /// 直接忽略；都取不到时返回空字符串。
    private static func quotedSenderID(chatUser: String, fromUser: String) -> String {
        for raw in [chatUser, fromUser] {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !id.lowercased().hasSuffix("@chatroom") else { continue }
            return id
        }
        return ""
    }

    // MARK: - 字符串工具

    /// 连续空白/换行压成单个空格，并 trim。
    ///
    /// 微信的引用正文经常带前导换行、卡片 `<des>` 带多行；展示时压平，
    /// 避免规则/日志里出现大段空白。U+2005 这类 @ 分隔符也属于空白，
    /// 会被压成普通空格（引用摘要不需要保留原样排版）。
    private static func normalizeWhitespace(_ text: String) -> String {
        trimAndCollapseWhitespace(text)
    }

    private static func trimAndCollapseWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 超过 `limit` 个字符时截断并追加省略号（总长最多 `limit + 1`）。
    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    /// JSON 字段兼容：字符串 trim 后空值视为缺失；数字原样转字符串。
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
}
