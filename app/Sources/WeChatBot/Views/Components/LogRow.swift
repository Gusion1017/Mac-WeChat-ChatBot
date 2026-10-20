import SwiftUI

/// Compact monospaced log line with level, source and message.
struct LogRow: View {
    let entry: LogEntry
    var showsDate: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(UIFormat.shortTime.string(from: entry.date))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .leading)

            Text(entry.level.label)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(entry.level.color)
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(entry.level.color.opacity(0.12), in: Capsule())
                .frame(width: 34, alignment: .leading)

            Text(entry.source)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 70, alignment: .leading)

            Text(entry.message)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.88))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(rowBackground)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.level.label)，\(entry.source)，\(entry.message)")
    }

    private var rowBackground: Color {
        switch entry.level {
        case .error: Theme.danger.opacity(0.045)
        case .warning: Theme.warning.opacity(0.04)
        default: .clear
        }
    }
}
