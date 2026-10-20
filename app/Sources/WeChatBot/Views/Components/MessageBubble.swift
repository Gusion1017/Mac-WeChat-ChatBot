import AppKit
import SwiftUI

/// Chat bubble supporting text / image / voice / emoji / file / video / link,
/// timestamps and delivery / generation state.
///
/// Equatable so streaming updates to a message list don't re-evaluate unchanged
/// bubbles (`ForEach` rows use `.equatable()`); all rendered state derives from
/// `message` and `showsSender`.
struct MessageBubble: View, Equatable {
    let message: ChatMessage
    var showsSender: Bool = true

    /// Loaded once per media path instead of on every body evaluation: the previous
    /// computed `NSImage(contentsOfFile:)` re-read the file from disk whenever the
    /// bubble's body ran again (e.g. once per incoming message).
    @State private var localImage: NSImage?
    /// Path that `localImage` was decoded from, so a changed path reloads.
    @State private var loadedImagePath: String?

    /// Manual comparison: `localImage` is view-local state and must not participate.
    static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message == rhs.message && lhs.showsSender == rhs.showsSender
    }

    var body: some View {
        if message.direction == .system || message.kind == .system {
            SystemNoticeRow(message: message)
        } else {
            bubbleRow
        }
    }

    // MARK: Bubble

    private var bubbleRow: some View {
        HStack(alignment: .bottom, spacing: 7) {
            if message.isOutgoing {
                Spacer(minLength: 70)
            } else {
                AvatarView(title: message.displaySender, kind: .direct, size: 26)
                    .padding(.bottom, 2)
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                if showsSender, !message.isOutgoing {
                    Text(message.displaySender)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 3)
                }
                bubble
                footer
            }

            if !message.isOutgoing {
                Spacer(minLength: 70)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var bubble: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(message.isOutgoing ? Color.white : Color.primary)
            .background {
                shape
                    .fill(backgroundStyle)
            }
            .overlay {
                shape
                    .strokeBorder(
                        message.isOutgoing ? Color.white.opacity(0.16) : Theme.hairline,
                        lineWidth: 1
                    )
            }
            .contextMenu {
                if !message.text.isEmpty {
                    Button("复制文本") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    }
                }
                Button("复制消息 ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.id, forType: .string)
                }
            }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
    }

    private var backgroundStyle: AnyShapeStyle {
        if message.isOutgoing {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Theme.accent.opacity(0.96), Theme.accent],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(.regularMaterial)
    }

    // MARK: Content by kind

    private var content: some View {
        Group {
            if message.status == .generating, message.text.isEmpty {
                TypingIndicator(tint: message.isOutgoing ? .white : Theme.accent)
                    .padding(.vertical, 2)
            } else {
                switch message.kind {
                case .text:
                    Text(message.text.isEmpty ? " " : message.text)
                        .font(.body)
                        .lineSpacing(3)
                case .image:
                    imageContent
                case .voice:
                    voiceContent
                case .emoji:
                    Text(message.text.isEmpty ? "🙂" : message.text)
                        .font(.system(size: 34))
                case .file:
                    fileContent
                case .video:
                    videoContent
                case .link:
                    linkContent
                case .system:
                    Text(message.text).font(.caption)
                }
            }
        }
    }

    /// Loads the local media file once per path (`.task(id:)`), never during body
    /// evaluation. Previously every body re-run re-read the file from disk.
    private func loadLocalImageIfNeeded() async {
        guard let path = message.mediaPath, !path.isEmpty else {
            localImage = nil
            loadedImagePath = nil
            return
        }
        guard loadedImagePath != path else { return }
        loadedImagePath = path
        localImage = NSImage(contentsOfFile: path)
    }

    private var remoteImageURL: URL? {
        guard let string = message.mediaURL,
              let url = URL(string: string),
              let scheme = url.scheme,
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    private var imageContent: some View {
        imageContentBody
            .task(id: message.mediaPath) { await loadLocalImageIfNeeded() }
    }

    @ViewBuilder
    private var imageContentBody: some View {
        if let localImage {
            Image(nsImage: localImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 240, maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if let remoteImageURL {
            AsyncImage(url: remoteImageURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                case .failure:
                    mediaPlaceholder(symbol: "photo.badge.exclamationmark", title: "图片加载失败", width: 168)
                case .empty:
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                        ProgressView().controlSize(.small)
                    }
                    .frame(width: 168, height: 108)
                @unknown default:
                    mediaPlaceholder(symbol: "photo", title: "图片", width: 168)
                }
            }
            .frame(maxWidth: 240, maxHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            mediaPlaceholder(symbol: "photo", title: "图片", width: 168)
        }
    }

    private var voiceContent: some View {
        HStack(spacing: 7) {
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .medium))
            VStack(alignment: .leading, spacing: 1) {
                Text(message.text.isEmpty ? "语音消息" : message.text)
                    .font(.callout)
                Text("语音")
                    .font(.system(size: 9))
                    .opacity(0.7)
            }
        }
        .frame(minWidth: 80, alignment: .leading)
    }

    private var fileContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .font(.system(size: 18))
                .opacity(0.9)
            VStack(alignment: .leading, spacing: 2) {
                Text(fileName)
                    .font(.callout)
                    .lineLimit(1)
                Text("文件")
                    .font(.system(size: 9))
                    .opacity(0.7)
            }
        }
        .frame(maxWidth: 240, alignment: .leading)
    }

    private var videoContent: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.14))
                .frame(width: 168, height: 100)
            VStack(spacing: 5) {
                Image(systemName: "play.fill")
                    .font(.system(size: 20))
                Text("视频")
                    .font(.caption2)
            }
        }
    }

    private var linkContent: some View {
        HStack(spacing: 7) {
            Image(systemName: "globe")
                .font(.system(size: 13, weight: .medium))
            Text(message.text.isEmpty ? (message.mediaURL ?? "链接") : message.text)
                .font(.callout)
                .lineLimit(2)
        }
        .frame(maxWidth: 260, alignment: .leading)
    }

    private func mediaPlaceholder(symbol: String, title: String, width: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.07))
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .light))
                Text(title)
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .frame(width: width, height: 100)
    }

    private var fileName: String {
        if let path = message.mediaPath, !path.isEmpty {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return message.text.isEmpty ? "文件" : message.text
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 4) {
            Text(UIFormat.time.string(from: message.timestamp))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            if message.isOutgoing {
                statusView
            }
        }
        .padding(.horizontal, 3)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var statusView: some View {
        switch message.status {
        case .generating:
            HStack(spacing: 3) {
                TypingIndicator()
                Text("生成中")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.accent)
            }
        case .pending:
            Image(systemName: "clock")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.success)
        case .failed:
            HStack(spacing: 2) {
                Image(systemName: "exclamationmark.circle.fill")
                Text("发送失败")
            }
            .font(.system(size: 9))
            .foregroundStyle(Theme.danger)
        case .received:
            EmptyView()
        }
    }

    private var accessibilityDescription: String {
        var parts: [String] = []
        parts.append(message.isOutgoing ? "我发送" : "\(message.displaySender) 发送")
        switch message.kind {
        case .text: parts.append(message.text)
        case .image: parts.append("图片")
        case .voice: parts.append("语音消息")
        case .emoji: parts.append("表情 \(message.text)")
        case .file: parts.append("文件 \(fileName)")
        case .video: parts.append("视频")
        case .link: parts.append("链接 \(message.text)")
        case .system: parts.append(message.text)
        }
        parts.append(UIFormat.stamp(message.timestamp))
        return parts.joined(separator: "，")
    }
}

/// Centered system notice (connection errors, AI failures, service hints).
struct SystemNoticeRow: View, Equatable {
    let message: ChatMessage

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "info.circle")
                .font(.system(size: 9))
            Text(message.text.isEmpty ? "系统消息" : message.text)
                .font(.caption)
                .multilineTextAlignment(.center)
            Text(UIFormat.time.string(from: message.timestamp))
                .font(.system(size: 9))
                .opacity(0.7)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Three-dot "AI is typing" indicator. Static under Reduce Motion.
struct TypingIndicator: View {
    var tint: Color = Theme.accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.4, paused: reduceMotion)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 3
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(tint)
                        .frame(width: 4.5, height: 4.5)
                        .opacity(reduceMotion ? 0.55 : (tick == index ? 1 : 0.3))
                        .scaleEffect(reduceMotion ? 1 : (tick == index ? 1.25 : 0.9))
                }
            }
        }
        .frame(height: 12)
        .accessibilityLabel("正在生成回复")
    }
}

/// Day / time separator between message bubbles.
struct DateSeparator: View, Equatable {
    let date: Date

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text(UIFormat.stamp(date))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .fixedSize()
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .padding(.vertical, 8)
        .accessibilityLabel("日期 \(UIFormat.stamp(date))")
    }
}
