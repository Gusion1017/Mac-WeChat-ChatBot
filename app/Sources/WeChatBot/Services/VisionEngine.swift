import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Errors

/// 识图链路的可展示错误（只写 debug 日志，不进入 UI 错误条）。
enum VisionError: LocalizedError, Equatable {
    case invalidPath
    case tooLarge(Int)
    case unreadableImage
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "图片路径为空"
        case .tooLarge(let bytes):
            return "图片过大（\(bytes) 字节）"
        case .unreadableImage:
            return "无法读取图片内容"
        case .encodingFailed:
            return "图片转码失败"
        }
    }
}

// MARK: - Vision support

/// 识图（视觉模型）的纯函数支持层（2026-10-23）。
///
/// 设计边界：
/// - **不发起网络请求**：请求由运行时通过 `AIClient` 发出，便于单测与替换；
/// - **不改主回复模型**：图片先变成一段文字描述（`ChatMessage.imageDescription`），
///   主回复始终是文本请求；
/// - 候选图片按需挑选：只处理「入站 + 图片 + 最近 10 分钟 + 尚未识别」的消息，
///   每次回复最多 `maxImagesPerReply` 张，避免群聊图片流产生不可控费用。
enum VisionSupport {
    /// 只识别最近 10 分钟内的图片；更早的图片继续使用 `[图片]` 占位。
    static let maxImageAge: TimeInterval = 600
    /// 单次回复最多识别几张上下文图片。
    static let maxImagesPerReply = 2
    /// 原图文件上限；超过时直接跳过，避免把超大图读进内存再编码。
    static let maxSourceBytes = 12 * 1024 * 1024
    /// 发给视觉模型的图片最长边（像素）。
    static let maxDimension = 1280
    /// 描述落库前的字符上限。
    static let maxDescriptionCharacters = 400
    /// JPEG 压缩质量。
    static let jpegQuality: Double = 0.8

    // MARK: Candidates

    /// 消息是否已有可用的识图描述。
    static func hasDescription(_ message: ChatMessage) -> Bool {
        guard let raw = message.imageDescription else { return false }
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 是否为「需要识图」的近期入站图片。
    static func isRecognizable(_ message: ChatMessage, now: Date = Date()) -> Bool {
        guard message.kind == .image, message.direction == .incoming else { return false }
        guard !hasDescription(message) else { return false }
        let age = now.timeIntervalSince(message.timestamp)
        // 容忍少量时钟偏差（未来 60 秒内），但不识别明显过旧的图片。
        return age >= -60 && age <= maxImageAge
    }

    /// 从上下文消息里挑选待识别的图片，最新优先，最多 `limit` 张。
    ///
    /// 不用 `mediaPath` 过滤：本轮图片可能还在 `ImageFetcher` 队列里，
    /// 由运行时决定是否等待；没有文件且不会再有文件的消息会在运行时被跳过。
    static func candidates(
        in messages: [ChatMessage],
        now: Date = Date(),
        limit: Int = VisionSupport.maxImagesPerReply
    ) -> [ChatMessage] {
        guard limit > 0 else { return [] }
        return messages
            .filter { isRecognizable($0, now: now) }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: Request

    /// 识图请求的思考模式：DeepSeek 默认开启 thinking（默认 effort high），
    /// 思考内容会占用 `max_tokens` 并把最终 `content` 挤空（2026-10-23 真机日志：
    /// 「AI 返回了空内容」）。识图只需要短描述，对 DeepSeek 系通道显式关闭。
    static func thinkingMode(for provider: AIProvider) -> AIThinkingMode? {
        if provider.kind == .deepSeek { return .disabled }
        let host = URL(string: provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?
            .host?
            .lowercased() ?? ""
        return host.contains("deepseek") ? .disabled : nil
    }

    /// 引用图片时附在当前消息末尾的说明（2026-10-23）。
    ///
    /// 微信引用只带 `svrid`/摘要 `[图片]`，主回复模型看不到图片本体；把被引用原图的
    /// 识图描述作为一条显式说明附加，模型才能知道「引用的是哪张图」。
    /// `description` 为空表示原图未能识别/未落盘，也要明确告知，避免模型猜图。
    static func quotedImageNote(description: String?) -> String {
        let value = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "（引用的图片内容暂不可用）" : "（引用图片内容：\(value)）"
    }

    /// 构造一次视觉请求：单条 user 消息 = 提示词 + 图片 data URL。
    static func requestMessages(prompt: String, imageDataURL: String) -> [AIMessage] {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.isEmpty ? VisionSettings.defaultPrompt : trimmed
        return [.user(text, images: [imageDataURL])]
    }

    /// 清洗模型返回的描述：折叠空白、去掉包裹引号、限制长度。
    static func normalizedDescription(
        _ raw: String,
        limit: Int = VisionSupport.maxDescriptionCharacters
    ) -> String? {
        let collapsed = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        var text = collapsed
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // 去掉模型偶尔加上的整段包裹引号（不动正文里的引号）。
        for pair in [("\"", "\""), ("“", "”"), ("'", "'"), ("『", "』")] {
            if text.hasPrefix(pair.0), text.hasSuffix(pair.1), text.count >= pair.0.count + pair.1.count {
                text = String(text.dropFirst(pair.0.count).dropLast(pair.1.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        guard !text.isEmpty else { return nil }

        if text.count > limit {
            text = String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return text
    }

    // MARK: Image encoding

    /// 把本地图片缩放并转成 JPEG data URL（OpenAI 兼容 `image_url.url`）。
    static func imageDataURL(forFileAt path: String) throws -> String {
        let data = try jpegData(forFileAt: path)
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    /// `imageDataURL` 的后台版本：识图前的解码/缩放/JPEG 重编码/base64 是 CPU
    /// 密集操作（12MP 图约 50–300ms/张），调用方在 MainActor 上时必须走这里，
    /// 否则用户发图后的等待阶段会明显卡界面。
    static func imageDataURLAsync(forFileAt path: String) async throws -> String {
        try await Task.detached(priority: .utility) {
            try imageDataURL(forFileAt: path)
        }.value
    }

    /// 读取本地图片（JPEG/PNG/HEIC/WebP 等 ImageIO 支持的格式），
    /// 等比缩放到最长边 `maxDimension`，重新编码为 JPEG，避免不同服务对格式/尺寸的差异。
    static func jpegData(
        forFileAt path: String,
        maxDimension: Int = VisionSupport.maxDimension
    ) throws -> Data {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VisionError.invalidPath }
        let url = URL(fileURLWithPath: trimmed)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { throw VisionError.unreadableImage }
        guard size <= maxSourceBytes else { throw VisionError.tooLarge(size) }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw VisionError.unreadableImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxDimension)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw VisionError.unreadableImage
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw VisionError.encodingFailed
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw VisionError.encodingFailed
        }
        return output as Data
    }
}
