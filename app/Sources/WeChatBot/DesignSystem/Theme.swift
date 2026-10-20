import AppKit
import SwiftUI

// MARK: - Design tokens

/// Central design tokens for the whole app. Keep visual decisions here so every
/// page shares the same rhythm, typography and semantic colors.
enum Theme {
    // MARK: Palette

    /// Brand green, refined for macOS materials.
    static let accent = Color(red: 0.20, green: 0.78, blue: 0.45)
    static let accentStrong = Color(red: 0.08, green: 0.60, blue: 0.33)
    static let accentSoft = Color(red: 0.20, green: 0.78, blue: 0.45).opacity(0.14)

    static let info = Color.blue
    static let success = Color(red: 0.16, green: 0.70, blue: 0.40)
    static let warning = Color.orange
    static let danger = Color.red
    static let violet = Color(red: 0.48, green: 0.42, blue: 0.92)

    /// 1px hairline used to separate cards from the page background.
    static let hairline = Color.primary.opacity(0.07)

    // MARK: Metrics

    static let sidebarWidth: CGFloat = 236
    static let listWidth: CGFloat = 304
    static let cornerRadius: CGFloat = 18
    static let cardPadding: CGFloat = 18
    static let pagePadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 20
    static let rowSpacing: CGFloat = 10
    static let controlRadius: CGFloat = 9
    /// Vertical room reserved for the traffic lights when the title bar is hidden.
    static let titlebarInset: CGFloat = 38

    // MARK: Typography (semantic fonts keep Dynamic Type working)

    static let pageTitle = Font.system(.title2, design: .default, weight: .semibold)
    static let sectionTitle = Font.system(.headline)
    static let cardTitle = Font.system(.subheadline, design: .default, weight: .semibold)
    static let bodyText = Font.system(.body)
    static let metaText = Font.system(.caption)
    static let monoText = Font.system(.caption, design: .monospaced)
    static let metric = Font.system(.largeTitle, design: .rounded, weight: .semibold)
    static let metricSmall = Font.system(.title2, design: .rounded, weight: .semibold)

    // MARK: Background

    static let pageGradient = LinearGradient(
        colors: [
            Color(nsColor: .windowBackgroundColor),
            Color(nsColor: .windowBackgroundColor).opacity(0.82),
            Color(red: 0.20, green: 0.78, blue: 0.45).opacity(0.045)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: Motion

    /// Reduce Motion is a hard requirement: callers pass the environment flag and
    /// receive `nil` (no animation) when the user enabled the accessibility setting.
    static func animation(_ reduceMotion: Bool, _ animation: Animation = .smooth(duration: 0.22)) -> Animation? {
        reduceMotion ? nil : animation
    }

    // MARK: Semantic helpers

    static func hookColor(_ state: HookState) -> Color {
        switch state {
        case .connected: success
        case .installed, .bridgeStarting, .waitingForGadget: warning
        case .failed: danger
        case .notInstalled, .wechatNotRunning, .unknown: .secondary
        }
    }

    static func providerTint(_ kind: ProviderKind) -> Color {
        switch kind {
        case .deepSeek: Color(red: 0.31, green: 0.45, blue: 0.98)
        case .openAI: Color(red: 0.06, green: 0.60, blue: 0.50)
        case .ollama: violet
        case .custom: info
        }
    }

    static func avatarTint(for seed: String) -> Color {
        let palette: [Color] = [
            accent, info, violet, warning, Color(red: 0.91, green: 0.44, blue: 0.32),
            Color(red: 0.24, green: 0.68, blue: 0.78), Color(red: 0.62, green: 0.42, blue: 0.85)
        ]
        let value = seed.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[abs(value) % palette.count]
    }
}

// MARK: - Color helpers

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Page background

/// Adaptive window background: semantic base color plus a very restrained brand glow.
struct PageBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Theme.accent.opacity(0.09), Color.clear, Theme.info.opacity(0.035)]
                    : [Theme.accent.opacity(0.065), Color.clear, Theme.info.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Formatting

enum UIFormat {
    static let time: DateFormatter = makeFormatter("HH:mm")
    static let shortTime: DateFormatter = makeFormatter("HH:mm:ss")
    static let dateTime: DateFormatter = makeFormatter("M月d日 HH:mm")
    static let fullDateTime: DateFormatter = makeFormatter("yyyy年M月d日 HH:mm")
    static let fileDate: DateFormatter = makeFormatter("yyyyMMdd-HHmmss")
    static let day: DateFormatter = makeFormatter("M月d日")

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = format
        return formatter
    }

    static let weekdayOptions: [(value: Int, label: String)] = [
        (2, "周一"), (3, "周二"), (4, "周三"), (5, "周四"),
        (6, "周五"), (7, "周六"), (1, "周日")
    ]

    static func weekdayName(_ value: Int) -> String {
        weekdayOptions.first(where: { $0.value == value })?.label ?? "周\(value)"
    }

    static func weekdaySummary(_ days: [Int]) -> String {
        let ordered = weekdayOptions.filter { days.contains($0.value) }.map(\.label)
        if ordered.count == 7 { return "每天" }
        if ordered == ["周一", "周二", "周三", "周四", "周五"] { return "工作日" }
        return ordered.isEmpty ? "未选择" : ordered.joined(separator: "、")
    }

    /// Compact timestamp for list rows: 14:20 / 昨天 / 3/12.
    static func relativeShort(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return time.string(from: date) }
        if calendar.isDateInYesterday(date) { return "昨天" }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return calendar.component(.month, from: date).description + "/" + calendar.component(.day, from: date).description
        }
        return day.string(from: date)
    }

    /// Human friendly timestamp for logs, activity and schedules.
    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let interval = now.timeIntervalSince(date)
        if interval < 45 { return "刚刚" }
        if interval < 3600 { return "\(max(1, Int(interval / 60))) 分钟前" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天 \(time.string(from: date))" }
        if calendar.isDateInYesterday(date) { return "昨天 \(time.string(from: date))" }
        if interval < 7 * 86_400 {
            return "\(weekdayName(calendar.component(.weekday, from: date))) \(time.string(from: date))"
        }
        return dateTime.string(from: date)
    }

    /// Absolute timestamp used when relative wording would be ambiguous.
    static func stamp(_ date: Date?) -> String {
        guard let date else { return "—" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return time.string(from: date) }
        if calendar.isDateInYesterday(date) { return "昨天 \(time.string(from: date))" }
        return dateTime.string(from: date)
    }

    static func duration(milliseconds: Double) -> String {
        guard milliseconds > 0 else { return "—" }
        if milliseconds < 1000 { return "\(Int(milliseconds)) ms" }
        return String(format: "%.1f s", milliseconds / 1000)
    }

    static func compactPath(_ path: String) -> String {
        guard !path.isEmpty else { return "未设置" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// 实时计时文案（回复流水线）：60 秒内保留一位小数，超过后显示「分 秒」。
    static func liveSeconds(_ interval: TimeInterval) -> String {
        let value = max(0, interval)
        if value < 60 {
            return String(format: "%.1f 秒", value)
        }
        let minutes = Int(value) / 60
        let seconds = Int(value) % 60
        return "\(minutes) 分 \(String(format: "%02d", seconds)) 秒"
    }

    static func logLine(_ entry: LogEntry) -> String {
        let stamp = fullDateTime.string(from: entry.date)
        return "\(stamp) [\(entry.level.label)] \(entry.source): \(entry.message)"
    }
}

// MARK: - Short aliases used by pages

typealias AccentColor = Theme
