import AppKit
import SwiftUI

/// 参考文本输入框（原生 `NSTextView` 包装）。
///
/// 为什么不用 SwiftUI `TextEditor`：音色编辑表单把每条参考片段放在 `ForEach($clips)` 里，
/// SwiftUI 的 `TextEditor` 在每次按键触发整组数据刷新时会重建 AppKit 文本视图，
/// 中文输入法的拼音候选、光标与焦点因此容易被打断（表现为吞字、跳焦点、候选消失）。
/// 这里直接持有稳定的 `NSTextView`，只有内容真正变化时才回写 Binding，并用
/// `hasMarkedText()` 保护输入法正在组词的状态。
struct ReferenceTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true
    var characterLimit: Int?
    /// 文本实际变化时回调（用于「开始手动输入就自动关闭 cross-lingual」等联动）。
    var onTextChanged: ((String) -> Void)?
    /// 超过字符上限时回调（用于提示，不阻塞输入框本身）。
    var onReachLimit: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // 用系统的 scrollableTextView 工厂保证 documentView 尺寸/滚动配置正确；
        // 再按我们的样式覆盖背景、字体与自动替换等行为。
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.string = text
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        // 输入法正在组词时不要覆盖 text storage，否则拼音会被清掉。
        guard !textView.hasMarkedText(), textView.string != text else { return }
        let selection = textView.selectedRange()
        context.coordinator.isProgrammaticUpdate = true
        textView.string = text
        context.coordinator.isProgrammaticUpdate = false
        let length = (text as NSString).length
        textView.setSelectedRange(
            NSRange(location: min(selection.location, length), length: 0))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ReferenceTextEditor
        var isProgrammaticUpdate = false

        init(_ parent: ReferenceTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate,
                  let textView = notification.object as? NSTextView else { return }
            let value = textView.string
            guard parent.text != value else { return }
            parent.text = value
            parent.onTextChanged?(value)
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard let limit = parent.characterLimit, limit > 0,
                  let replacement = replacementString else { return true }
            let candidate = (textView.string as NSString)
                .replacingCharacters(in: affectedCharRange, with: replacement)
            guard candidate.count > limit else { return true }
            parent.onReachLimit?()
            return false
        }
    }
}
