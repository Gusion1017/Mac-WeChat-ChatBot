import Foundation

/// 微信 XML 片段的最小工具集（appmsg / refermsg / patinfo 共用）。
///
/// 这里刻意不用 `XMLParser`：`raw_message` 是微信自己拼出来的非严格 XML
/// （标签可能带属性、内容包 CDATA、`<refermsg><content>` 里还嵌着转义过一次的
/// XML），而 `XMLParser` 要求格式良好的文档、会把 `&amp;lt;` 这类双层实体多解一次，
/// 也不方便取「原始内部块」。正则 + 手工切片足够处理微信这几类固定结构，
/// 还能保持 `PatMessage` 既有的 CDATA / 属性 / 大小写容错行为。
enum WeChatXML {
    // MARK: - 转义

    /// JSON 二次转义兼容：Go `encoding/json` 会把 `<>&` 写成 `\u003c` 等；
    /// 个别历史数据被编码两次，JSON 解码后仍残留字面量 `\u003c`。
    ///
    /// 只处理单反斜杠形态，避免把用户正文里合法的 `\\u003c` 误还原。
    static func decodeEscapes(_ value: String) -> String {
        var text = value
        if text.contains("\\u") {
            text = decodeUnicodeEscapes(in: text)
        }
        if text.contains("\\\"") {
            text = text.replacingOccurrences(of: "\\\"", with: "\"")
        }
        if text.contains("\\/") {
            text = text.replacingOccurrences(of: "\\/", with: "/")
        }
        return text
    }

    /// XML 实体反转义：数字实体与 `&lt; &gt; &quot; &apos;`，`&amp;` 最后处理。
    ///
    /// `&amp;` 必须最后：`&amp;lt;` 应先还原成 `&lt;`（引用里常见的双层转义），
    /// 如果先解 `&amp;` 就会把它当成 `<`，导致被引用 XML 的结构被提前破坏。
    static func unescape(_ value: String) -> String {
        var text = value
        text = replacingNumericEntities(in: text)
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&apos;", with: "'")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        return text
    }

    // MARK: - 取值

    /// 取首个 `<tag ...>…</tag>` 的内部文本：去 CDATA、反转义一次、trim。
    ///
    /// 空文本、自闭合 `<tag />`、没有闭合标签都返回 `nil`——调用方把 `nil`
    /// 当作「字段不存在」，与 `PatMessage` 原先 `xmlField` 的语义一致。
    static func field(_ tag: String, in xml: String) -> String? {
        guard let opening = openingTag(tag, in: xml),
              !isSelfClosing(opening, in: xml),
              let closing = closingTag(tag, in: xml, from: opening.contentStart) else {
            return nil
        }
        var value = String(xml[opening.contentStart..<closing.lowerBound])
        value = strippingCDATA(value)
        value = unescape(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// 取首个 `<tag ...>…</tag>` 的**原始**内部块（不反转义、不去 CDATA）。
    ///
    /// `<refermsg>` / `<appmsg>` / `<finderFeed>` / `<wcpayinfo>` 这类容器必须
    /// 保留内层转义 XML 交给下一步解析；提前解实体反而会丢结构。
    /// 自闭合/无闭合返回 `nil`；空容器返回空字符串。
    static func block(_ tag: String, in xml: String) -> String? {
        guard let opening = openingTag(tag, in: xml),
              !isSelfClosing(opening, in: xml),
              let closing = closingTag(tag, in: xml, from: opening.contentStart) else {
            return nil
        }
        return String(xml[opening.contentStart..<closing.lowerBound])
    }

    /// 是否出现 `<tag`，要求标签名边界（`<tag>` / `<tag ` / `<tag/`），忽略大小写。
    ///
    /// 用边界而不是裸 `contains("<img")`，避免属性值或正文里的 `<imgxxx`
    /// 把普通文本误判成图片。
    static func containsTag(_ tag: String, in xml: String) -> Bool {
        openingTag(tag, in: xml) != nil
    }

    // MARK: - 标签定位

    /// 一个开标签的位置：`afterName` 是标签名之后、属性之前的索引，
    /// `contentStart` 是 `>` 之后（内容起点）的索引。
    private struct OpeningTag {
        var afterName: String.Index
        var contentStart: String.Index
    }

    /// 找首个名字完全匹配的 `<tag ...>`。
    ///
    /// 从每个 `<tag` 候选位置检查后一个字符是否为边界，`<tags>` / `<tagfoo>`
    /// 这类更长的标签名会被跳过；找不到合法的 `>` 时返回 `nil`。
    private static func openingTag(_ tag: String, in xml: String) -> OpeningTag? {
        let needle = "<" + tag
        var searchStart = xml.startIndex
        while searchStart < xml.endIndex,
              let range = xml.range(
                  of: needle,
                  options: [.caseInsensitive],
                  range: searchStart..<xml.endIndex
              ) {
            let afterName = range.upperBound
            guard afterName < xml.endIndex else { return nil }
            let boundary = xml[afterName]
            if boundary == ">" || boundary == "/" || boundary.isWhitespace {
                guard let close = xml[afterName...].firstIndex(of: ">") else { return nil }
                return OpeningTag(afterName: afterName, contentStart: xml.index(after: close))
            }
            // `<tags>` 之类不是目标标签，从 `<` 之后继续找。
            searchStart = xml.index(after: range.lowerBound)
        }
        return nil
    }

    /// `<tag />` / `<tag/>`：属性区最后一个非空白字符是 `/`。
    private static func isSelfClosing(_ opening: OpeningTag, in xml: String) -> Bool {
        let attributeEnd = xml.index(before: opening.contentStart)
        let attributes = xml[opening.afterName..<attributeEnd]
        return attributes.last == "/"
    }

    /// 找内容起点之后的第一个 `</tag>`（忽略大小写）。
    private static func closingTag(
        _ tag: String,
        in xml: String,
        from start: String.Index
    ) -> Range<String.Index>? {
        let needle = "</" + tag + ">"
        return xml.range(of: needle, options: [.caseInsensitive], range: start..<xml.endIndex)
    }

    // MARK: - 实体细节

    /// 数字实体（`&#39;` / `&#x27;`）先解；非法码点跳过，保留原文。
    private static func replacingNumericEntities(in text: String) -> String {
        var result = text
        let patterns: [(pattern: String, radix: Int)] = [
            (#"&#x([0-9a-fA-F]+);"#, 16),
            (#"&#([0-9]+);"#, 10)
        ]
        for entry in patterns {
            guard let regex = try? NSRegularExpression(pattern: entry.pattern) else { continue }
            let nsResult = result as NSString
            let matches = regex.matches(
                in: result,
                range: NSRange(location: 0, length: nsResult.length)
            )
            // 从后往前替换，保证前面匹配的 Range 仍然有效。
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let range = Range(match.range, in: result),
                      let captureRange = Range(match.range(at: 1), in: result),
                      let code = UInt32(result[captureRange], radix: entry.radix),
                      let scalar = UnicodeScalar(code) else { continue }
                result.replaceSubrange(range, with: String(Character(scalar)))
            }
        }
        return result
    }

    /// 字面量 `\u003c` → `<`；只替换 4 位十六进制，其他形态保持原样。
    private static func decodeUnicodeEscapes(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\\u([0-9a-fA-F]{4})"#) else {
            return text
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var result = text
        // 从后往前替换，保证前面匹配的 Range 仍然有效。
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let range = Range(match.range, in: result),
                  let captureRange = Range(match.range(at: 1), in: result),
                  let code = UInt32(result[captureRange], radix: 16),
                  let scalar = UnicodeScalar(code) else { continue }
            result.replaceSubrange(range, with: String(Character(scalar)))
        }
        return result
    }

    /// `<![CDATA[正文]]>` → `正文`；没有 CDATA 包装时原样返回。
    private static func strippingCDATA(_ value: String) -> String {
        if let cdataStart = value.range(of: "<![CDATA["),
           let cdataEnd = value.range(of: "]]>", range: cdataStart.upperBound..<value.endIndex) {
            return String(value[cdataStart.upperBound..<cdataEnd.lowerBound])
        }
        return value
    }
}
