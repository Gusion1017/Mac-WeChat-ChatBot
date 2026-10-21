import Foundation

/// Interface language preference. `system` follows the macOS preferred language.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    /// Bilingual label so the picker is understandable in either language.
    var displayName: String {
        switch self {
        case .system: "跟随系统 / System"
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }

    var locale: Locale {
        switch self {
        case .system:
            let code = Locale.current.language.languageCode?.identifier ?? "zh"
            return Locale(identifier: code == "zh" ? "zh-Hans" : "en")
        case .simplifiedChinese:
            return Locale(identifier: "zh-Hans")
        case .english:
            return Locale(identifier: "en")
        }
    }
}

/// Runtime UI string lookup. Chinese is the source language; English strings live in
/// `en.lproj/Localizable.strings` inside the app bundle.
///
/// SwiftUI localizes `Text("中文")` automatically through the environment locale.
/// This helper covers labels built as `String` values (enum labels, custom components)
/// and dynamic strings that would otherwise stay in Chinese.
enum L10n {
    private(set) nonisolated(unsafe) static var language: String = "zh-Hans"
    private nonisolated(unsafe) static var englishBundle: Bundle?

    static func resolvedLanguage(_ raw: String) -> String {
        switch AppLanguage(rawValue: raw) ?? .system {
        case .simplifiedChinese:
            return "zh-Hans"
        case .english:
            return "en"
        case .system:
            let code = Locale.current.language.languageCode?.identifier ?? "zh"
            return code == "zh" ? "zh-Hans" : "en"
        }
    }

    static func apply(_ raw: String) {
        let resolved = resolvedLanguage(raw)
        guard resolved != language || englishBundle == nil else { return }
        language = resolved
        if resolved == "en" {
            if let path = Bundle.main.path(forResource: "en", ofType: "lproj") {
                englishBundle = Bundle(path: path)
            }
        } else {
            englishBundle = nil
        }
    }

    static func text(_ key: String) -> String {
        guard language == "en", let bundle = englishBundle else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

/// Translate a Chinese UI string at runtime. Unknown keys fall back to the source string.
func L(_ key: String) -> String { L10n.text(key) }
