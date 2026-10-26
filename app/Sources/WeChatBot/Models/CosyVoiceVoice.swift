import Foundation

// MARK: - 音色

/// CosyVoice3 的一套参考音色（与 `devtools/cosyvoice/CONTRACT.md` 的 `/voices` 对齐）。
///
/// 服务端是音色的事实来源（用户之后可以换参考音/加音色），本地只保留三套默认音色
/// 用于「服务尚未启动/未安装」时的稳定展示。解码全部字段可选，坏条目不会让整包失败。
struct CosyVoiceVoice: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    /// 简介（可为空）。
    var description: String
    /// 推理方式：`zero_shot`（带参考文本）或 `cross_lingual`（只用参考音）。
    var mode: String?
    /// 仅限个人使用（产品约束：CosyVoice3 音色一律 true，不提供关闭开关）。
    var personalUseOnly: Bool
    /// 是否为内置音色（girl/loli/onee）。
    var builtin: Bool
    /// 参考音时长（秒；服务端可选返回）。
    var duration: TimeInterval?
    /// 来源标记（`builtin` / `edge-tts` / `app-import` 等，服务端可选返回）。
    var source: String?

    /// 默认按 id 推断内置；`personalUseOnly` 默认 true 兼容旧响应。
    init(
        id: String,
        name: String,
        description: String = "",
        mode: String? = nil,
        personalUseOnly: Bool = true,
        builtin: Bool? = nil,
        duration: TimeInterval? = nil,
        source: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.mode = mode
        self.personalUseOnly = personalUseOnly
        self.builtin = builtin ?? CosyVoiceVoiceCatalog.isBuiltIn(id)
        self.duration = duration
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case desc
        case mode
        case personalUseOnly = "personal_use_only"
        case personalUseOnlyCamel = "personalUseOnly"
        case builtin
        case duration
        case durationSeconds = "duration_s"
        case source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? ""
        let rawName = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        let rawDescription = (try? container.decodeIfPresent(String.self, forKey: .description))
            ?? (try? container.decodeIfPresent(String.self, forKey: .desc))
            ?? ""
        let trimmedID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        id = trimmedID
        name = trimmedName.isEmpty
            ? CosyVoiceVoiceCatalog.displayName(for: trimmedID)
            : trimmedName
        description = (rawDescription ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        mode = (try? container.decodeIfPresent(String.self, forKey: .mode)) ?? nil
        // 旧服务响应缺字段：默认仅限个人使用 + 按 id 推断内置。
        let personal = (try? container.decodeIfPresent(Bool.self, forKey: .personalUseOnly))
            ?? (try? container.decodeIfPresent(Bool.self, forKey: .personalUseOnlyCamel))
            ?? nil
        personalUseOnly = personal ?? true
        let builtinFlag = (try? container.decodeIfPresent(Bool.self, forKey: .builtin)) ?? nil
        builtin = builtinFlag ?? CosyVoiceVoiceCatalog.isBuiltIn(trimmedID)
        if let seconds = (try? container.decodeIfPresent(Double.self, forKey: .duration)) ?? nil {
            duration = seconds
        } else if let seconds = (try? container.decodeIfPresent(Double.self, forKey: .durationSeconds))
            ?? nil {
            duration = seconds
        }
        source = (try? container.decodeIfPresent(String.self, forKey: .source)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(mode, forKey: .mode)
        try container.encode(personalUseOnly, forKey: .personalUseOnly)
        try container.encode(builtin, forKey: .builtin)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(source, forKey: .source)
    }
}

/// `/voices` 回包（`{"voices":[...]}`）；单条坏数据跳过而不是整包失败。
struct CosyVoiceVoiceList: Codable, Hashable, Sendable {
    var voices: [CosyVoiceVoice]

    init(voices: [CosyVoiceVoice]) {
        self.voices = voices
    }

    private enum CodingKeys: String, CodingKey {
        case voices
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = ((try? container.decodeIfPresent([FailableDecodable<CosyVoiceVoice>].self, forKey: .voices))
            ?? nil) ?? []
        voices = entries.compactMap(\.value).filter { !$0.id.isEmpty }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(voices, forKey: .voices)
    }
}

/// 数组元素容错解码：单条坏数据变成 `nil`，不影响其余条目。
struct FailableDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

// MARK: - 默认三音色目录

/// 内置三音色（少女/萝莉/御姐）与服端音色的合并策略。
///
/// - 顺序：少女、萝莉、御姐，服务端新增的音色追加在后；
/// - 名称/简介：服务端值优先（用户可自定义参考音），空值回退本地默认；
/// - 未知 `voice_id`：不丢弃，按 `id` 展示，保持「服务端是事实来源」。
enum CosyVoiceVoiceCatalog {
    static let defaultVoiceID = "girl"
    static let supportedIDs: [String] = ["girl", "loli", "onee"]

    static let fallbackVoices: [CosyVoiceVoice] = [
        CosyVoiceVoice(
            id: "girl",
            name: "少女",
            description: "清甜少女音，本机参考音"
        ),
        CosyVoiceVoice(
            id: "loli",
            name: "萝莉",
            description: "轻快明亮的萝莉音"
        ),
        CosyVoiceVoice(
            id: "onee",
            name: "御姐",
            description: "成熟稳重的御姐音"
        ),
    ]

    static func voice(for id: String) -> CosyVoiceVoice? {
        fallbackVoices.first { $0.id == id }
    }

    /// 展示名：本地三音色 → 中文名；未知 → 原样返回（服务端自定义音色）。
    static func displayName(for id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "未选择" }
        return voice(for: trimmed)?.name ?? trimmed
    }

    /// 生效的音色 ID：只做 trim，**空字符串保持为空**（未选择音色）。
    /// App 不内置任何音色，因此不能把空选择回退到 girl。
    static func resolvedVoiceID(_ raw: String?) -> String {
        (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 是否为内置三音色之一。
    static func isBuiltIn(_ id: String) -> Bool {
        supportedIDs.contains(id)
    }

    /// 合并音色：**只处理输入里实际存在的音色**。
    ///
    /// 分发边界：App 不自带 girl/loli/onee，普通用户的空音色库必须保持空；
    /// 因此这里不会无条件补内置三音色，`fallbackVoices` 只用于给「实际存在的外置 id」
    /// 补展示名/简介兜底。所有音色仍统一标记 `personalUseOnly = true`。
    static func merged(remote: [CosyVoiceVoice]) -> [CosyVoiceVoice] {
        let remoteByID = Dictionary(
            remote.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var result: [CosyVoiceVoice] = []
        // 实际存在的内置音色排在最前（girl/loli/onee 固定顺序）。
        for id in supportedIDs {
            guard let remote = remoteByID[id] else { continue }
            let display = fallbackVoices.first { $0.id == id }
            result.append(CosyVoiceVoice(
                id: id,
                name: remote.name.isEmpty ? (display?.name ?? id) : remote.name,
                description: remote.description.isEmpty
                    ? (display?.description ?? "")
                    : remote.description,
                mode: remote.mode,
                personalUseOnly: true,
                builtin: true,
                duration: remote.duration,
                source: remote.source ?? "builtin"
            ))
        }
        // 其余音色（含用户新增）按名称/ID 追加；不存在的不凭空出现。
        let extras = remoteByID.values
            .filter { !isBuiltIn($0.id) && !$0.id.isEmpty }
            .sorted { lhs, rhs in
                let order = lhs.name.localizedStandardCompare(rhs.name)
                if order != .orderedSame { return order == .orderedAscending }
                return lhs.id < rhs.id
            }
        for voice in extras {
            result.append(CosyVoiceVoice(
                id: voice.id,
                name: voice.name.isEmpty ? voice.id : voice.name,
                description: voice.description,
                mode: voice.mode,
                personalUseOnly: true,
                builtin: false,
                duration: voice.duration,
                source: voice.source
            ))
        }
        return result
    }

    /// 是否至少有一个音色，可以启动本地服务。
    /// 空音色库时 UI 必须禁用「启动服务」并提示先添加音色（App 不内置任何音色）。
    static func canStartService(with voices: [CosyVoiceVoice]) -> Bool {
        !voices.isEmpty
    }
}

// MARK: - /health

/// `GET /health` 回包。加载中服务返回 503 + `{"ok":false,"loading":true,...}`，
/// 此时 `client.health()` 抛 `CosyVoiceError.serviceLoading`，但解析逻辑仍复用本结构。
struct CosyVoiceHealth: Codable, Hashable, Sendable {
    var ok: Bool = false
    var ready: Bool = false
    var loading: Bool = false
    var model: String?
    var sampleRate: Int = CosyVoiceClient.defaultSampleRate
    var voices: [String] = []
    var voicesDetail: [CosyVoiceVoice] = []
    var device: String?
    var rtfEstimate: Double?
    var progress: String?
    var error: String?

    init(
        ok: Bool = false,
        ready: Bool = false,
        loading: Bool = false,
        model: String? = nil,
        sampleRate: Int = CosyVoiceClient.defaultSampleRate,
        voices: [String] = [],
        voicesDetail: [CosyVoiceVoice] = [],
        device: String? = nil,
        rtfEstimate: Double? = nil,
        progress: String? = nil,
        error: String? = nil
    ) {
        self.ok = ok
        self.ready = ready
        self.loading = loading
        self.model = model
        self.sampleRate = sampleRate
        self.voices = voices
        self.voicesDetail = voicesDetail
        self.device = device
        self.rtfEstimate = rtfEstimate
        self.progress = progress
        self.error = error
    }

    // 健康检查响应是外部数据（另一个进程/版本），所有字段都容忍缺失与类型异常。
    private enum CodingKeys: String, CodingKey {
        case ok
        case ready
        case loading
        case model
        case sampleRate = "sample_rate"
        case voices
        case voicesDetail = "voices_detail"
        case device
        case rtfEstimate = "rtf_estimate"
        case progress
        case error
        case detail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CosyVoiceHealth()
        ok = (try? container.decodeIfPresent(Bool.self, forKey: .ok)) ?? defaults.ok
        ready = (try? container.decodeIfPresent(Bool.self, forKey: .ready)) ?? defaults.ready
        loading = (try? container.decodeIfPresent(Bool.self, forKey: .loading)) ?? defaults.loading
        model = (try? container.decodeIfPresent(String.self, forKey: .model)) ?? nil
        if let rate = try? container.decodeIfPresent(Int.self, forKey: .sampleRate), rate > 0 {
            sampleRate = rate
        }
        voices = ((try? container.decodeIfPresent([String].self, forKey: .voices)) ?? nil) ?? []
        voicesDetail = ((try? container.decodeIfPresent([CosyVoiceVoice].self, forKey: .voicesDetail))
            ?? nil) ?? []
        device = (try? container.decodeIfPresent(String.self, forKey: .device)) ?? nil
        if let rtf = try? container.decodeIfPresent(Double.self, forKey: .rtfEstimate),
           rtf.isFinite, rtf > 0 {
            rtfEstimate = rtf
        }
        progress = (try? container.decodeIfPresent(String.self, forKey: .progress)) ?? nil
        let reason = (try? container.decodeIfPresent(String.self, forKey: .error)) ?? nil
        let detail = (try? container.decodeIfPresent(String.self, forKey: .detail)) ?? nil
        error = Self.combinedReason(reason: reason, detail: detail)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ok, forKey: .ok)
        try container.encode(ready, forKey: .ready)
        try container.encode(loading, forKey: .loading)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(sampleRate, forKey: .sampleRate)
        try container.encode(voices, forKey: .voices)
        try container.encode(voicesDetail, forKey: .voicesDetail)
        try container.encodeIfPresent(device, forKey: .device)
        try container.encodeIfPresent(rtfEstimate, forKey: .rtfEstimate)
        try container.encodeIfPresent(progress, forKey: .progress)
        try container.encodeIfPresent(error, forKey: .error)
    }

    /// 服务就绪 = 明确 ready 且 ok。
    var isReady: Bool { ok && ready }

    /// 对外错误文案（ok=false 时）。
    var failureReason: String? {
        if let error, !error.isEmpty { return error }
        return nil
    }

    /// 合并 `error` 与 `detail`：避免两者相同时重复展示。
    static func combinedReason(reason: String?, detail: String?) -> String? {
        let a = (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let b = (detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b.isEmpty ? nil : b }
        if b.isEmpty || b == a { return a }
        return "\(a)：\(b)"
    }
}

// MARK: - 服务状态（UI/日志共用）

/// CosyVoice3 本地服务的运行状态。
enum CosyVoiceServiceState: Equatable, Sendable {
    /// 尚未检测。
    case unknown
    /// 未运行（App 未启动，或上次启动后退出）。
    case stopped
    /// 正在启动/加载模型；字符串是给用户看的阶段说明。
    case starting(String)
    /// 健康可用。
    case running(CosyVoiceHealth)
    /// 启动失败/运行中崩溃。
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var isStarting: Bool {
        if case .starting = self { return true }
        return false
    }

    var health: CosyVoiceHealth? {
        if case .running(let health) = self { return health }
        return nil
    }

    var failureReason: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }

    /// 启动中提示（含外部服务加载）。
    var startingMessage: String? {
        if case .starting(let message) = self { return message }
        return nil
    }
}


// MARK: - 出站语音的引擎回退计划

/// 一次出站语音合成可能尝试的引擎（顺序即优先级，`text` 表示最终降级文字）。
enum VoiceSynthesisAttempt: Equatable, Sendable {
    case cosyVoice
    case kokoro
    case zipvoiceClone
    case text
}

/// 出站语音引擎回退决策（纯函数，便于单测）。
///
/// 产品约定：
/// - CosyVoice3 可选，Kokoro 仍默认；
/// - 选了 CosyVoice3 但服务不可用时，先回退 Kokoro，Kokoro 也失败才发文字；
/// - CosyVoice3 未安装＝引擎不可用，直接文字（UI 会引导安装）；
/// - Kokoro/ZipVoice 保持原行为：失败即文字，不跨引擎回退。
enum VoiceFallbackPlanner {
    static func attempts(
        for engine: VoiceEngineKind,
        cosyVoiceInstalled: Bool,
        cosyVoiceServiceReady: Bool,
        kokoroReady: Bool,
        zipvoiceReady: Bool
    ) -> [VoiceSynthesisAttempt] {
        switch engine {
        case .cosyVoice:
            guard cosyVoiceInstalled else { return [.text] }
            var attempts: [VoiceSynthesisAttempt] = []
            if cosyVoiceServiceReady { attempts.append(.cosyVoice) }
            if kokoroReady { attempts.append(.kokoro) }
            return attempts.isEmpty ? [.text] : attempts
        case .kokoro:
            return kokoroReady ? [.kokoro] : [.text]
        case .zipvoiceClone:
            return zipvoiceReady ? [.zipvoiceClone] : [.text]
        }
    }
}
