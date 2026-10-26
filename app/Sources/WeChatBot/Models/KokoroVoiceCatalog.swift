import Foundation

/// Kokoro multi-lang v1_1 的内置音色目录（2026-10-27）。
///
/// 数据来源：sherpa-onnx 官方模型页
/// <https://k2-fsa.github.io/sherpa/onnx/tts/all/Chinese-English/kokoro-multi-lang-v1_1.html>
///
/// `sid` 就是 `voices.bin` 的下标，顺序不能改；模型升级到新版本时需要同步更新本文件。
/// 此前设置页只暴露一个 0...200 的裸编号，用户无法知道 0 是英语女声、3 起才是中文女声，
/// 也没有试听入口。这里把官方 sid → name 映射固化下来，供选择器、分组、试听与校验使用。
enum KokoroVoiceCatalog {
    /// 全部内置音色，顺序即 sid（0...102）。
    static let all: [KokoroVoice] = names.enumerated().map { index, name in
        KokoroVoice(sid: index, name: name)
    }

    /// 音色总数（Kokoro multi-lang v1_1 固定 103）。
    static var count: Int { all.count }

    /// 按 sid 查找音色；越界返回 nil。
    static func voice(for sid: Int) -> KokoroVoice? {
        guard all.indices.contains(sid) else { return nil }
        return all[sid]
    }

    /// 展示名：已知音色返回 `zf_001`，未知/越界返回 `#编号`。
    static func displayName(for sid: Int) -> String {
        voice(for: sid)?.name ?? "#\(sid)"
    }

    /// 把任意编号收敛到合法 sid（UI、解码与合成共用）。
    static func clampedSpeakerID(_ sid: Int) -> Int {
        guard !all.isEmpty else { return 0 }
        return min(max(sid, 0), all.count - 1)
    }

    /// 某个分组的音色（保持 sid 升序）。
    static func voices(in group: KokoroVoiceGroup) -> [KokoroVoice] {
        all.filter { $0.group == group }
    }

    /// 官方 sid → name 映射，顺序不能改。
    private static let names: [String] = [
        // 0-2：英语女声（美式 2 + 英式 1）
        "af_maple", "af_sol", "bf_vale",
        // 3-57：中文女声
        "zf_001", "zf_002", "zf_003", "zf_004", "zf_005", "zf_006", "zf_007", "zf_008",
        "zf_017", "zf_018", "zf_019", "zf_021", "zf_022", "zf_023", "zf_024", "zf_026",
        "zf_027", "zf_028", "zf_032", "zf_036", "zf_038", "zf_039", "zf_040", "zf_042",
        "zf_043", "zf_044", "zf_046", "zf_047", "zf_048", "zf_049", "zf_051", "zf_059",
        "zf_060", "zf_067", "zf_070", "zf_071", "zf_072", "zf_073", "zf_074", "zf_075",
        "zf_076", "zf_077", "zf_078", "zf_079", "zf_083", "zf_084", "zf_085", "zf_086",
        "zf_087", "zf_088", "zf_090", "zf_092", "zf_093", "zf_094", "zf_099",
        // 58-102：中文男声
        "zm_009", "zm_010", "zm_011", "zm_012", "zm_013", "zm_014", "zm_015", "zm_016",
        "zm_020", "zm_025", "zm_029", "zm_030", "zm_031", "zm_033", "zm_034", "zm_035",
        "zm_037", "zm_041", "zm_045", "zm_050", "zm_052", "zm_053", "zm_054", "zm_055",
        "zm_056", "zm_057", "zm_058", "zm_061", "zm_062", "zm_063", "zm_064", "zm_065",
        "zm_066", "zm_068", "zm_069", "zm_080", "zm_081", "zm_082", "zm_089", "zm_091",
        "zm_095", "zm_096", "zm_097", "zm_098", "zm_100",
    ]
}

/// 单个 Kokoro 音色。
struct KokoroVoice: Identifiable, Hashable, Sendable {
    let sid: Int
    let name: String

    var id: Int { sid }

    /// 由官方命名前缀推导分组（af/bf 英文，zf 中文女声，zm 中文男声）。
    var group: KokoroVoiceGroup {
        if name.hasPrefix("zf_") { return .chineseFemale }
        if name.hasPrefix("zm_") { return .chineseMale }
        return .englishFemale
    }

    /// 分组标签（当前语言）。
    var localizedGroupTitle: String { L(group.title) }

    /// 搜索文本：同时包含中文源词与英文别名，中英文界面都能搜到。
    var searchText: String {
        ([name, group.title, group.englishTitle] + group.searchTerms).joined(separator: " ")
    }
}

/// Kokoro 音色分组（与官方 sid 区间一致）。
enum KokoroVoiceGroup: String, CaseIterable, Identifiable, Sendable {
    case chineseFemale
    case chineseMale
    case englishFemale

    var id: String { rawValue }

    /// 中文源文案（`L()` 会按当前语言翻译）。
    var title: String {
        switch self {
        case .chineseFemale: "中文女声"
        case .chineseMale: "中文男声"
        case .englishFemale: "英文女声"
        }
    }

    /// 筛选 chip 的短标签：英文分组在中文界面里也显示“英文”，不必加“女声”。
    var filterTitle: String {
        switch self {
        case .chineseFemale: "中文女声"
        case .chineseMale: "中文男声"
        case .englishFemale: "英文"
        }
    }

    var englishTitle: String {
        switch self {
        case .chineseFemale: "Chinese female"
        case .chineseMale: "Chinese male"
        case .englishFemale: "English female"
        }
    }

    /// 搜索别名（前缀 + 中英文关键词）。
    var searchTerms: [String] {
        switch self {
        case .chineseFemale: ["zf", "zh", "chinese", "female", "女声", "中文"]
        case .chineseMale: ["zm", "zh", "chinese", "male", "男声", "中文"]
        case .englishFemale: ["af", "bf", "en", "english", "female", "英语", "英文"]
        }
    }

    /// 分组内的音色数量。
    var count: Int {
        switch self {
        case .chineseFemale: 55
        case .chineseMale: 45
        case .englishFemale: 3
        }
    }
}
