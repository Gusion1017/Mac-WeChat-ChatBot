import AVFoundation
import Foundation

// MARK: - 可管理音色

/// 设置页「音色管理」使用的完整音色档案（含参考音/参考文本/个人使用声明）。
///
/// 与 `CosyVoiceVoice` 的区别：后者是服务端 `/voices` 的展示投影（可能拿不到参考文本），
/// 这里是 `voices.json` + 音色目录的事实来源，供管理器列表/编辑使用。
struct CosyVoiceManagedVoice: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var description: String
    /// 参考音频与参考文本（按保存顺序）；至少 1 条。
    /// `mode == cross_lingual` 时文本可为空；多条时文本必须同时为空或同时填写。
    var references: [CosyVoiceReferenceClip]
    /// `zero_shot` / `cross_lingual`
    var mode: String
    /// 内部字段：恒为 true（UI 不展示）。
    var personalUseOnly: Bool
    var builtin: Bool
    /// 合并后的参考音总时长（秒），含片段之间的静音。
    var duration: TimeInterval?
    var source: String?
    /// 合并 prompt 的绝对路径（目录不存在时为 nil）。
    var promptWAVPath: String?

    /// 全部参考片段的合并文本（只读）：展示与旧接口兼容用。
    var referenceText: String {
        CosyVoiceReferenceSpec.combinedText(references.map(\.text))
    }
    var referenceCount: Int { references.count }
    var isCustom: Bool { !builtin }
    var hasReferenceText: Bool { references.contains(where: \.hasText) }
    var isCrossLingual: Bool { mode == CosyVoiceManagedVoice.modeCrossLingual }
    var hasPromptWAV: Bool {
        guard let promptWAVPath else { return false }
        return FileManager.default.fileExists(atPath: promptWAVPath)
    }

    static let modeZeroShot = "zero_shot"
    static let modeCrossLingual = "cross_lingual"

    /// 投影成设置页/服务共用的轻量音色。
    var asServiceVoice: CosyVoiceVoice {
        CosyVoiceVoice(
            id: id,
            name: name,
            description: description,
            mode: mode,
            personalUseOnly: true,
            builtin: builtin,
            duration: duration,
            source: source
        )
    }
}

// MARK: - Errors

enum CosyVoiceVoiceStoreError: Error, LocalizedError, Equatable {
    case invalidName(String)
    case invalidAudio(String)
    case audioTooShort(seconds: Double)
    case audioTooLong(seconds: Double)
    case silentAudio
    case invalidID(String)
    case notFound(String)
    /// 内置音色不可删除。
    case builtinProtected
    /// 内置音色的参考音/参考文本与官方参考音严格对应，不允许替换。
    case builtinReferenceLocked
    /// 内置音色不允许导出（避免把参考音分发给其他人）。
    case builtinExportDenied
    /// 没有可导出的自定义音色。
    case nothingToExport
    case manifestCorrupted(String)
    /// 文件已保存但服务重载失败时回滚后抛出。
    case reloadFailed(String)
    case saveFailed(String)
    case deleteFailed(String)
    case exportFailed(String)
    /// 一个音色最多保存的参考音频条数被超过。
    case tooManyReferences(max: Int)
    /// 一条参考音频都没有。
    case missingReferences
    /// 多条参考音频的文本没有统一「全填」或「全空」。
    case inconsistentReferenceText
    /// 合并后的参考音频总时长超过上限。
    case referenceTotalTooLong(seconds: Double)
    /// 某一条参考音频/片段路径不可用。
    case invalidReference(String)

    var errorDescription: String? {
        switch self {
        case .invalidName(let reason):
            return "音色名称无效：\(reason)"
        case .invalidAudio(let reason):
            return "参考音频无法使用：\(reason)"
        case .audioTooShort(let seconds):
            return String(format: "参考音频太短（%.1f 秒），需要 5–30 秒", seconds)
        case .audioTooLong(let seconds):
            return String(format: "参考音频太长（%.1f 秒），需要 5–30 秒", seconds)
        case .silentAudio:
            return "参考音频几乎无声，请换一段清晰的单人说话录音"
        case .invalidID(let id):
            return "音色 ID 不合法：\(id)"
        case .notFound(let id):
            return "音色不存在：\(id)"
        case .builtinProtected:
            return "内置音色不能删除"
        case .builtinReferenceLocked:
            return "内置音色只允许修改名称和简介，参考音频与参考文本不可替换"
        case .builtinExportDenied:
            return "内置音色不可导出（只有自定义/克隆音色可以备份）"
        case .nothingToExport:
            return "没有可导出的自定义音色"
        case .manifestCorrupted(let reason):
            return "音色清单损坏：\(reason)"
        case .reloadFailed(let reason):
            return "音色文件已保存，但服务重载失败，已回滚：\(reason)"
        case .saveFailed(let reason):
            return "保存音色失败：\(reason)"
        case .deleteFailed(let reason):
            return "删除音色失败：\(reason)"
        case .exportFailed(let reason):
            return "导出音色失败：\(reason)"
        case .tooManyReferences(let max):
            return "一条音色最多保存 \(max) 条参考音频"
        case .missingReferences:
            return "请至少添加一条参考音频"
        case .inconsistentReferenceText:
            return "多条参考音频的参考文本需要同时填写或同时留空"
        case .referenceTotalTooLong(let seconds):
            return String(
                format: "参考音频总时长过长（%.1f 秒），最多 %.0f 秒",
                seconds, CosyVoiceReferenceSpec.maxTotalDuration)
        case .invalidReference(let reason):
            return "参考音频不可用：\(reason)"
        }
    }
}

// MARK: - Export result

/// 一次音色导出的结果：zip 最终路径与实际导出的自定义音色 ID。
struct CosyVoiceVoiceExportResult: Sendable, Equatable {
    var zipURL: URL
    var voiceIDs: [String]
}

// MARK: - Store

/// CosyVoice3 音色库（`voices.json` + `<id>/prompt.wav|prompt.txt|refs/|meta.json`）。
///
/// 设计边界：
/// - **actor**：所有文件/manifest 读写串行；
/// - **manifest 是事实来源**：用户新增/编辑/删除只改已知字段，保留未知字段与其他音色；
/// - **路径安全**：音色 id 只允许 `[a-z0-9-]`，所有路径收敛在 voices 目录内；
/// - **音频规范**：任意可解码音频 → 24 kHz 单声道 float → 峰值归一到 0.95 → 16-bit PCM WAV；
/// - **多条参考音**：1–5 条，每条 5–30 秒；按顺序拼接成合并 prompt（片段间 0.25s 静音），
///   `prompt.wav` / `prompt.txt` 仍是服务端合成入口，原始片段保存在 `<id>/refs/ref-N.wav|txt`；
/// - **原子性**：每次变更前记录 manifest/音色目录旧状态，任何失败（含服务 reload）回滚；
/// - **服务 reload**：服务就绪时调用 `POST /voices/reload`，失败回滚并抛错；未运行则跳过，
///   下次启动服务时读取新 manifest。
actor CosyVoiceVoiceStore {
    static let shared = CosyVoiceVoiceStore()

    static let builtinIDs: [String] = ["girl", "loli", "onee"]
    static let minDuration: TimeInterval = CosyVoiceReferenceSpec.minClipDuration
    static let maxDuration: TimeInterval = CosyVoiceReferenceSpec.maxClipDuration
    static let sampleRate = CosyVoiceReferenceSpec.sampleRate
    /// 峰值归一目标（留 5% headroom，避免 16-bit 削波）。
    static let peakTarget: Float = 0.95
    static let maxNameLength = 40
    static let maxDescriptionLength = 200
    static let maxReferenceTextLength = CosyVoiceReferenceSpec.maxTextLength
    static let allowedAudioExtensions: Set<String> = ["wav", "m4a", "aiff", "aif"]
    /// 原始参考片段目录名（相对音色目录）。
    static let refsDirectoryName = "refs"

    nonisolated let voicesDirectory: URL
    private let client: CosyVoiceClient
    private let serviceReadyProvider: @Sendable () -> Bool
    private let fileManager: FileManager

    init(
        voicesDirectory: URL? = nil,
        client: CosyVoiceClient? = nil,
        serviceReady: (@Sendable () -> Bool)? = nil,
        fileManager: FileManager = .default
    ) {
        self.voicesDirectory = voicesDirectory ?? CosyVoiceInstallation.voicesDirectory()
        self.client = client ?? .shared
        self.serviceReadyProvider = serviceReady ?? {
            CosyVoiceRuntime.shared.isServiceReadySnapshot
        }
        self.fileManager = fileManager
    }

    // MARK: 查询

    /// 列出全部音色：本机实际存在的内置音色在前（girl/loli/onee 固定顺序），自定义按名称/ID 排序。
    ///
    /// `voices.json` 不存在时扫描音色目录；**两者都没有时返回空列表**——
    /// App 不内置任何音色，不能用 girl/loli/onee 假装有可用音色。
    func list() throws -> [CosyVoiceManagedVoice] {
        let manifest = try loadManifestIfPresent()
        if let manifest {
            let voices = manifest.entries.compactMap { parseEntry($0) }
            return Self.sorted(voices)
        }
        // 分发边界：App 不内置任何音色。空目录/无 manifest 时必须返回空列表，
        // 不能回退成 girl/loli/onee（那是本机已有安装才会有的本地文件）。
        return Self.sorted(scanDirectories())
    }

    /// 当前音色的托管档案；不存在返回 nil。
    func voice(id: String) throws -> CosyVoiceManagedVoice? {
        try list().first { $0.id == id }
    }

    /// 音色库是否为空（UI 用它禁用「启动服务」）。
    func hasVoices() throws -> Bool {
        try !list().isEmpty
    }

    // MARK: 新增

    /// 兼容入口：单条参考音频 = 一条 `references`。
    ///
    /// - Parameters:
    ///   - audioURL: 用户选择的 wav/m4a/aiff（5–30 秒，单人说话）。
    ///   - referenceText: 参考文本；留空自动使用 cross_lingual。
    ///   - crossLingual: 强制 cross_lingual。
    @discardableResult
    func add(
        name: String,
        audioURL: URL,
        referenceText: String,
        description: String,
        crossLingual: Bool = false
    ) async throws -> CosyVoiceManagedVoice {
        try await add(
            name: name,
            references: [.newAudio(audioURL, text: referenceText)],
            description: description,
            crossLingual: crossLingual
        )
    }

    /// 新增自定义音色（1–5 条参考音频）。
    ///
    /// 内部 `personal_use_only` 恒为 true，不需要用户额外确认（UI 不展示）。
    @discardableResult
    func add(
        name: String,
        references: [CosyVoiceReferenceInput],
        description: String,
        crossLingual: Bool = false
    ) async throws -> CosyVoiceManagedVoice {
        let name = try Self.validatedName(name)
        let description = Self.validatedDescription(description)
        // 先做只读校验/转码（不落盘，失败不会留下半截目录）。
        let plan = try prepareReferences(
            references, voiceDirectory: nil, crossLingual: crossLingual)

        let manifest = try loadManifestForMutation()
        let id = Self.makeID(name: name)
        let directory = try directory(for: id)
        let previousManifest = manifest
        let identifier = UUID().uuidString.lowercased()
        let source = "app-import"

        do {
            try ensureVoicesDirectory()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeVoiceContent(
                directory: directory,
                id: id,
                name: name,
                description: description,
                clips: plan.clips,
                mode: plan.mode,
                builtin: false,
                duration: plan.duration,
                source: source,
                identifier: identifier,
                isNew: true
            )
            var entries = manifest.entries
            var entry = Self.manifestEntry(
                id: id, name: name, description: description,
                referenceText: plan.text, mode: plan.mode, builtin: false,
                duration: plan.duration, source: source)
            entry["references"] = Self.manifestReferenceObjects(id: id, clips: plan.clips)
            entries.append(entry)
            var root = manifest.root
            // 新增音色一定写出 v2 布局（references + refs/），清单版本同步为 2。
            root["version"] = 2
            root["voices"] = entries
            try saveManifest(root)
            try await reloadServiceAfterMutation()
            return CosyVoiceManagedVoice(
                id: id, name: name, description: description,
                references: Self.referenceClips(from: plan.clips, directory: directory),
                mode: plan.mode, personalUseOnly: true,
                builtin: false, duration: plan.duration, source: source,
                promptWAVPath: directory.appendingPathComponent("prompt.wav").path
            )
        } catch {
            // 回滚：恢复旧 manifest（或删除新建的），再删掉半截音色目录。
            restoreManifest(previousManifest)
            try? fileManager.removeItem(at: directory)
            throw Self.mapped(error)
        }
    }

    // MARK: 编辑

    /// 兼容入口（旧 UI/旧测试）：只对单条音色做内容替换。
    ///
    /// - 内置（girl/loli/onee）：只允许改 `name` / `description`；
    ///   传 `audioURL` / 改变参考文本或模式会抛 `.builtinReferenceLocked`。
    /// - 自定义：可改名称/简介/参考文本/模式，传 `audioURL` 可替换参考音。
    /// - **多条参考音频**调用本入口抛 `.invalidReference`，请改用
    ///   `update(id:name:description:references:crossLingual:)`。
    /// - 只改名称/简介（文本与音频都没变）时不重写音频、不迁移 `refs/` 布局。
    @discardableResult
    func update(
        id: String,
        name: String? = nil,
        description: String? = nil,
        referenceText: String? = nil,
        audioURL: URL? = nil,
        crossLingual: Bool? = nil
    ) async throws -> CosyVoiceManagedVoice {
        guard Self.isValidID(id) else { throw CosyVoiceVoiceStoreError.invalidID(id) }
        let manifest = try loadManifestForMutation()
        guard let index = manifest.entries.firstIndex(where: {
            (Self.string($0["id"]) ?? "") == id
        }) else {
            throw CosyVoiceVoiceStoreError.notFound(id)
        }
        let current = manifest.entries[index]
        let builtin = Self.bool(current["builtin"]) ?? Self.isBuiltinID(id)
        if builtin {
            if audioURL != nil || crossLingual != nil {
                throw CosyVoiceVoiceStoreError.builtinReferenceLocked
            }
            if let referenceText,
               Self.validatedReferenceText(referenceText)
                != (Self.string(current["prompt_text"]) ?? "") {
                throw CosyVoiceVoiceStoreError.builtinReferenceLocked
            }
        }

        guard let oldVoice = parseEntry(current) else {
            throw CosyVoiceVoiceStoreError.notFound(id)
        }
        var referenceInputs: [CosyVoiceReferenceInput]?
        if !builtin {
            let wantsClipChange = audioURL != nil || referenceText != nil
            if wantsClipChange {
                guard oldVoice.references.count <= 1 else {
                    throw CosyVoiceVoiceStoreError.invalidReference(
                        "该音色有多条参考音频，请使用完整参考片段编辑")
                }
                let oldText = oldVoice.referenceText
                let newText = Self.validatedReferenceText(referenceText ?? oldText)
                if let audioURL {
                    referenceInputs = [.newAudio(audioURL, text: newText)]
                } else if newText != oldText {
                    guard let clip = oldVoice.references.first,
                          let audioPath = clip.audioPath else {
                        throw CosyVoiceVoiceStoreError.invalidReference("缺少参考音频文件")
                    }
                    referenceInputs = [.existing(
                        id: clip.id, audioPath: audioPath, text: newText)]
                }
                // 文本没变且没换音频：视为只改名称/简介，不迁移 refs/。
            }
        }

        let newName = try Self.validatedName(name ?? (Self.string(current["name"]) ?? id))
        let newDescription = Self.validatedDescription(
            description ?? (Self.string(current["description"]) ?? ""))
        return try await performUpdate(
            id: id,
            manifest: manifest,
            index: index,
            current: current,
            builtin: builtin,
            oldVoice: oldVoice,
            newName: newName,
            newDescription: newDescription,
            referenceInputs: referenceInputs,
            crossLingual: builtin ? nil : crossLingual
        )
    }

    /// 新入口：全量替换参考片段（顺序即拼接顺序）；`name` / `description` 为 nil 时保留原值。
    ///
    /// - `crossLingual == nil`：按文本推断（全空 → cross_lingual，全填 → zero_shot）。
    /// - `crossLingual == false`：全空仍 cross_lingual；部分填写抛 `.inconsistentReferenceText`。
    /// - `crossLingual == true`：强制 cross_lingual。
    @discardableResult
    func update(
        id: String,
        name: String? = nil,
        description: String? = nil,
        references: [CosyVoiceReferenceInput],
        crossLingual: Bool? = nil
    ) async throws -> CosyVoiceManagedVoice {
        guard Self.isValidID(id) else { throw CosyVoiceVoiceStoreError.invalidID(id) }
        let manifest = try loadManifestForMutation()
        guard let index = manifest.entries.firstIndex(where: {
            (Self.string($0["id"]) ?? "") == id
        }) else {
            throw CosyVoiceVoiceStoreError.notFound(id)
        }
        let current = manifest.entries[index]
        let builtin = Self.bool(current["builtin"]) ?? Self.isBuiltinID(id)
        guard !builtin else { throw CosyVoiceVoiceStoreError.builtinReferenceLocked }
        guard let oldVoice = parseEntry(current) else {
            throw CosyVoiceVoiceStoreError.notFound(id)
        }
        let newName = try Self.validatedName(name ?? (Self.string(current["name"]) ?? id))
        let newDescription = Self.validatedDescription(
            description ?? (Self.string(current["description"]) ?? ""))
        return try await performUpdate(
            id: id,
            manifest: manifest,
            index: index,
            current: current,
            builtin: false,
            oldVoice: oldVoice,
            newName: newName,
            newDescription: newDescription,
            referenceInputs: references,
            crossLingual: crossLingual
        )
    }

    /// 编辑统一实现：只读校验 → 目录快照 → 落盘 → manifest → reload；任何失败完整回滚。
    ///
    /// `referenceInputs == nil` 表示不触碰参考片段（只改名称/简介/模式，旧音色不迁移 `refs/`）。
    private func performUpdate(
        id: String,
        manifest: ManifestState,
        index: Int,
        current: [String: Any],
        builtin: Bool,
        oldVoice: CosyVoiceManagedVoice,
        newName: String,
        newDescription: String,
        referenceInputs: [CosyVoiceReferenceInput]?,
        crossLingual: Bool?
    ) async throws -> CosyVoiceManagedVoice {
        let directory = try directory(for: id)
        let promptURL = directory.appendingPathComponent("prompt.wav")
        let metaURL = directory.appendingPathComponent("meta.json")
        let source = Self.string(current["source"]) ?? (builtin ? "builtin" : "app-import")
        let identifier = Self.string(current["custom_id"]) ?? UUID().uuidString.lowercased()

        // 1. 先做只读校验/转码（不落盘）。
        var plan: ReferencePlan?
        let newMode: String
        let newText: String
        let duration: TimeInterval?
        if !builtin, let referenceInputs {
            let prepared = try prepareReferences(
                referenceInputs, voiceDirectory: directory, crossLingual: crossLingual)
            plan = prepared
            newMode = prepared.mode
            newText = prepared.text
            duration = prepared.duration
        } else {
            newText = oldVoice.referenceText
            duration = Self.double(current["duration"])
                ?? Self.double(current["duration_s"])
                ?? oldVoice.duration
            if builtin {
                newMode = oldVoice.mode
            } else if let crossLingual {
                guard CosyVoiceReferenceSpec.hasConsistentTexts(
                    oldVoice.references.map(\.text), crossLingual: crossLingual) else {
                    throw CosyVoiceVoiceStoreError.inconsistentReferenceText
                }
                newMode = crossLingual
                    ? CosyVoiceManagedVoice.modeCrossLingual
                    : (newText.isEmpty
                        ? CosyVoiceManagedVoice.modeCrossLingual
                        : CosyVoiceManagedVoice.modeZeroShot)
            } else {
                newMode = newText.isEmpty
                    ? CosyVoiceManagedVoice.modeCrossLingual
                    : oldVoice.mode
            }
        }

        // 2. 整目录快照 + manifest 旧状态：失败（含 reload）时原样恢复。
        let previousManifest = manifest
        var snapshot: DirectorySnapshot
        do {
            snapshot = try DirectorySnapshot(directory: directory, fileManager: fileManager)
        } catch {
            throw CosyVoiceVoiceStoreError.saveFailed(error.localizedDescription)
        }
        defer { snapshot.cleanup(fileManager: fileManager) }

        do {
            if let plan {
                try writeVoiceContent(
                    directory: directory,
                    id: id,
                    name: newName,
                    description: newDescription,
                    clips: plan.clips,
                    mode: newMode,
                    builtin: false,
                    duration: plan.duration,
                    source: source,
                    identifier: identifier,
                    isNew: false
                )
            } else {
                // 只改名称/简介/模式：不重写音频，也不迁移旧音色到 refs/。
                try writeMeta(
                    url: metaURL,
                    id: id,
                    name: newName,
                    description: newDescription,
                    referenceText: newText,
                    references: nil,
                    mode: newMode,
                    builtin: builtin,
                    duration: duration,
                    source: source,
                    identifier: builtin ? id : identifier,
                    merge: true
                )
            }
            var entries = manifest.entries
            var entry = entries[index]
            entry["name"] = newName
            entry["description"] = newDescription
            entry["personal_use_only"] = true
            entry["builtin"] = builtin
            if !builtin {
                entry["prompt_text"] = newText
                entry["mode"] = newMode
                if let plan {
                    entry["prompt_wav"] = "\(id)/prompt.wav"
                    entry["references"] = Self.manifestReferenceObjects(
                        id: id, clips: plan.clips)
                    entry["duration"] = plan.duration
                }
            }
            entries[index] = entry
            var root = manifest.root
            // 写出 v2 片段布局时清单版本升到 2；只改名/简介时保持原值（旧清单不迁移）。
            if plan != nil { root["version"] = 2 }
            root["voices"] = entries
            try saveManifest(root)
            try await reloadServiceAfterMutation()
            let resolvedReferences = plan.map {
                Self.referenceClips(from: $0.clips, directory: directory)
            } ?? oldVoice.references
            return CosyVoiceManagedVoice(
                id: id, name: newName, description: newDescription,
                references: resolvedReferences, mode: newMode, personalUseOnly: true,
                builtin: builtin, duration: duration,
                source: Self.string(entry["source"]),
                promptWAVPath: promptURL.path
            )
        } catch {
            restoreManifest(previousManifest)
            snapshot.restore(to: directory, fileManager: fileManager)
            throw Self.mapped(error)
        }
    }

    // MARK: 删除

    /// 删除自定义音色（内置拒绝）。manifest 先移除，再删除目录；任何一个失败都回滚。
    func delete(id: String) async throws {
        guard Self.isValidID(id) else { throw CosyVoiceVoiceStoreError.invalidID(id) }
        guard !Self.isBuiltinID(id) else { throw CosyVoiceVoiceStoreError.builtinProtected }
        let manifest = try loadManifestForMutation()
        guard let index = manifest.entries.firstIndex(where: {
            (Self.string($0["id"]) ?? "") == id
        }) else {
            throw CosyVoiceVoiceStoreError.notFound(id)
        }
        let entry = manifest.entries[index]
        guard !(Self.bool(entry["builtin"]) ?? Self.isBuiltinID(id)) else {
            throw CosyVoiceVoiceStoreError.builtinProtected
        }
        let directory = try directory(for: id)
        let exists = fileManager.fileExists(atPath: directory.path)
        let trash = voicesDirectory.appendingPathComponent(
            ".trash-\(UUID().uuidString.lowercased())", isDirectory: true)
        let previousManifest = manifest
        do {
            if exists {
                try fileManager.moveItem(at: directory, to: trash)
            }
            var entries = manifest.entries
            entries.remove(at: index)
            var root = manifest.root
            root["voices"] = entries
            try saveManifest(root)
            try await reloadServiceAfterMutation()
            if exists { try? fileManager.removeItem(at: trash) }
        } catch {
            restoreManifest(previousManifest)
            if exists, fileManager.fileExists(atPath: trash.path) {
                try? fileManager.removeItem(at: directory)
                try? fileManager.moveItem(at: trash, to: directory)
            }
            throw Self.mapped(error)
        }
    }

    // MARK: 导出（个人备份）

    static let exportAppName = "WeChatAI"
    static let exportSchema = "wechatai.cosyvoice-voice-export"

    /// 单个自定义音色导出（内置拒绝）。
    ///
    /// - `to`: 目标文件，或已存在目录（会自动用默认文件名）。
    /// - 扩展名不是 `.zip` 时自动补。
    func exportVoice(
        id: String,
        to destination: URL
    ) async throws -> CosyVoiceVoiceExportResult {
        guard Self.isValidID(id) else { throw CosyVoiceVoiceStoreError.invalidID(id) }
        let voices = try list()
        guard let voice = voices.first(where: { $0.id == id }) else {
            throw CosyVoiceVoiceStoreError.notFound(id)
        }
        guard !voice.builtin, !Self.isBuiltinID(id) else {
            throw CosyVoiceVoiceStoreError.builtinExportDenied
        }
        return try export(
            voices: [voice],
            to: destination,
            defaultFileName: Self.suggestedSingleFileName(for: voice)
        )
    }

    /// 导出全部自定义音色；0 个时抛 `.nothingToExport`。
    func exportAllCustom(to destination: URL) async throws -> CosyVoiceVoiceExportResult {
        let custom = try list().filter { !$0.builtin && !Self.isBuiltinID($0.id) }
        guard !custom.isEmpty else { throw CosyVoiceVoiceStoreError.nothingToExport }
        return try export(
            voices: custom,
            to: destination,
            defaultFileName: Self.suggestedAllFileName()
        )
    }

    /// 单个导出的默认文件名：`<安全名称>.cosyvoice-voice.zip`。
    nonisolated static func suggestedSingleFileName(for voice: CosyVoiceManagedVoice) -> String {
        "\(safeFileName(voice.name)).cosyvoice-voice.zip"
    }

    /// 全部导出的默认文件名：`cosyvoice-voices-<yyyyMMdd-HHmmss>.zip`。
    nonisolated static func suggestedAllFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "cosyvoice-voices-\(formatter.string(from: date)).zip"
    }

    /// 文件名安全化：去掉路径分隔符/控制字符，保留 Unicode 字母数字与 `-_.`。
    nonisolated static func safeFileName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_."))
        var result = ""
        for scalar in raw.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else if !result.hasSuffix("-") {
                result.append("-")
            }
        }
        result = result.trimmingCharacters(
            in: CharacterSet(charactersIn: "-._"))
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        if result.isEmpty { result = "voice" }
        return String(result.prefix(48))
    }

    /// 目标解析：已存在目录 → 追加默认文件名；扩展名非 `.zip` → 自动补 `.zip`。
    nonisolated static func exportDestination(
        _ destination: URL,
        defaultFileName: String,
        fileManager: FileManager = .default
    ) -> URL {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return destination.appendingPathComponent(defaultFileName)
        }
        if destination.pathExtension.lowercased() != "zip" {
            return destination.appendingPathExtension("zip")
        }
        return destination
    }

    // MARK: 导出实现

    private func export(
        voices: [CosyVoiceManagedVoice],
        to destination: URL,
        defaultFileName: String
    ) throws -> CosyVoiceVoiceExportResult {
        guard !voices.isEmpty else { throw CosyVoiceVoiceStoreError.nothingToExport }
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "cosyvoice-export-\(UUID().uuidString.lowercased())", isDirectory: true)
        let staging = temporaryRoot.appendingPathComponent("staging", isDirectory: true)
        let temporaryZip = temporaryRoot.appendingPathComponent("export.zip")
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let exportedAt = ISO8601DateFormatter().string(from: Date())
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw CosyVoiceVoiceStoreError.exportFailed(error.localizedDescription)
        }

        var voiceIDs: [String] = []
        for voice in voices {
            guard !voice.builtin, !Self.isBuiltinID(voice.id) else {
                throw CosyVoiceVoiceStoreError.builtinExportDenied
            }
            guard let promptPath = voice.promptWAVPath else {
                throw CosyVoiceVoiceStoreError.exportFailed(
                    "音色「\(voice.name)」缺少参考音频 prompt.wav")
            }
            let sourceDirectory = URL(fileURLWithPath: promptPath).deletingLastPathComponent()
            let promptSource = URL(fileURLWithPath: promptPath)
            guard fileManager.fileExists(atPath: promptSource.path) else {
                throw CosyVoiceVoiceStoreError.exportFailed(
                    "音色「\(voice.name)」的参考音频不存在")
            }
            // 只有 v2 布局（片段在 refs/ 下）才导出 refs/；旧音色保持 prompt.wav 单文件布局。
            let includesReferenceClips = voice.references.contains { clip in
                guard let audioPath = clip.audioPath else { return false }
                return URL(fileURLWithPath: audioPath)
                    .deletingLastPathComponent().lastPathComponent == Self.refsDirectoryName
            }
            let targetDirectory = staging.appendingPathComponent(
                voice.id, isDirectory: true)
            do {
                try fileManager.createDirectory(
                    at: targetDirectory, withIntermediateDirectories: true)
                try fileManager.copyItem(
                    at: promptSource,
                    to: targetDirectory.appendingPathComponent("prompt.wav"))
                try Data(voice.referenceText.utf8).write(
                    to: targetDirectory.appendingPathComponent("prompt.txt"),
                    options: .atomic)
                if includesReferenceClips {
                    let targetRefs = targetDirectory.appendingPathComponent(
                        Self.refsDirectoryName, isDirectory: true)
                    try fileManager.createDirectory(
                        at: targetRefs, withIntermediateDirectories: true)
                    for (index, clip) in voice.references.enumerated() {
                        let number = index + 1
                        guard let audioPath = clip.audioPath,
                              fileManager.fileExists(atPath: audioPath) else {
                            throw CosyVoiceVoiceStoreError.exportFailed(
                                "音色「\(voice.name)」缺少第 \(number) 条参考音频")
                        }
                        try fileManager.copyItem(
                            at: URL(fileURLWithPath: audioPath),
                            to: targetRefs.appendingPathComponent("ref-\(number).wav"))
                        try Data(clip.text.utf8).write(
                            to: targetRefs.appendingPathComponent("ref-\(number).txt"),
                            options: .atomic)
                    }
                }
                try writeExportMeta(
                    voice: voice,
                    sourceDirectory: sourceDirectory,
                    targetDirectory: targetDirectory,
                    includesReferenceClips: includesReferenceClips,
                    exportedAt: exportedAt)
                try writeExportVoiceJSON(
                    voice: voice,
                    targetDirectory: targetDirectory,
                    exportedAt: exportedAt)
                try Data(Self.exportReadme(
                    voiceName: voice.name,
                    exportedAt: exportedAt,
                    includesReferenceClips: includesReferenceClips).utf8)
                    .write(
                        to: targetDirectory.appendingPathComponent("README.txt"),
                        options: .atomic)
            } catch let error as CosyVoiceVoiceStoreError {
                throw error
            } catch {
                throw CosyVoiceVoiceStoreError.exportFailed(error.localizedDescription)
            }
            voiceIDs.append(voice.id)
        }

        // export.json（根）：schema/version/exported_at/app/个人使用声明。
        do {
            let exportObject: [String: Any] = [
                "schema": Self.exportSchema,
                "version": 1,
                "exported_at": exportedAt,
                "app": Self.exportAppName,
                "personal_use_only": true,
                "voices": voiceIDs,
            ]
            try writeJSONObject(exportObject, to: staging.appendingPathComponent("export.json"))
        } catch let error as CosyVoiceVoiceStoreError {
            throw error
        } catch {
            throw CosyVoiceVoiceStoreError.exportFailed(error.localizedDescription)
        }

        try runZipTool(sourceDirectory: staging, destination: temporaryZip)
        guard fileManager.fileExists(atPath: temporaryZip.path) else {
            throw CosyVoiceVoiceStoreError.exportFailed("zip 未生成")
        }

        let finalDestination = Self.exportDestination(
            destination, defaultFileName: defaultFileName, fileManager: fileManager)
        do {
            let parent = finalDestination.deletingLastPathComponent()
            if !parent.path.isEmpty {
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            if fileManager.fileExists(atPath: finalDestination.path) {
                _ = try fileManager.replaceItemAt(
                    finalDestination, withItemAt: temporaryZip)
            } else {
                try fileManager.moveItem(at: temporaryZip, to: finalDestination)
            }
        } catch {
            throw CosyVoiceVoiceStoreError.exportFailed(
                "写入目标文件失败：\(error.localizedDescription)")
        }
        return CosyVoiceVoiceExportResult(
            zipURL: finalDestination, voiceIDs: voiceIDs)
    }

    private func writeExportMeta(
        voice: CosyVoiceManagedVoice,
        sourceDirectory: URL,
        targetDirectory: URL,
        includesReferenceClips: Bool,
        exportedAt: String
    ) throws {
        let sourceMeta = sourceDirectory.appendingPathComponent("meta.json")
        var object = Self.readJSONObject(sourceMeta) ?? [:]
        object["id"] = voice.id
        object["name"] = voice.name
        object["description"] = voice.description
        object["reference_text"] = voice.referenceText
        object["prompt_text"] = voice.referenceText
        object["mode"] = voice.mode
        object["personal_use_only"] = true
        object["builtin"] = false
        if let duration = voice.duration { object["duration"] = duration }
        if object["source"] == nil {
            object["source"] = voice.source ?? "app-import"
        }
        object["exported_at"] = exportedAt
        if includesReferenceClips {
            object["references"] = voice.references.enumerated().map { index, clip in
                var item: [String: Any] = [
                    "audio": "\(Self.refsDirectoryName)/ref-\(index + 1).wav",
                    "text": clip.text,
                ]
                if let duration = clip.duration { item["duration"] = duration }
                return item
            }
        } else {
            // 旧布局导出：只保留合并 prompt，不写指向不存在文件的 references。
            object.removeValue(forKey: "references")
        }
        try writeJSONObject(
            object, to: targetDirectory.appendingPathComponent("meta.json"))
    }

    private func writeExportVoiceJSON(
        voice: CosyVoiceManagedVoice,
        targetDirectory: URL,
        exportedAt: String
    ) throws {
        var object: [String: Any] = [
            "id": voice.id,
            "name": voice.name,
            "description": voice.description,
            "mode": voice.mode,
            "personal_use_only": true,
            "builtin": false,
            "source": voice.source ?? "app-import",
            "exported_at": exportedAt,
            "app": Self.exportAppName,
            "reference_count": voice.referenceCount,
        ]
        if let duration = voice.duration { object["duration"] = duration }
        try writeJSONObject(
            object, to: targetDirectory.appendingPathComponent("voice.json"))
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CosyVoiceVoiceStoreError.exportFailed(
                "\(url.lastPathComponent) 无法序列化")
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url, options: .atomic)
        } catch {
            throw CosyVoiceVoiceStoreError.exportFailed(error.localizedDescription)
        }
    }

    /// 用 `/usr/bin/ditto` 打 zip。
    ///
    /// 这里刻意**不传** `--keepParent`：`ditto --keepParent <staging> out.zip` 会把
    /// 临时目录名套进 zip 根，而导出契约要求根下直接是 `<id>/...` 与 `export.json`。
    /// 其余参数保持 `-c -k --sequesterRsrc`。
    private func runZipTool(sourceDirectory: URL, destination: URL) throws {
        let executable = URL(fileURLWithPath: "/usr/bin/ditto")
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw CosyVoiceVoiceStoreError.exportFailed("找不到 /usr/bin/ditto")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "-c", "-k", "--sequesterRsrc",
            sourceDirectory.path, destination.path,
        ]
        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw CosyVoiceVoiceStoreError.exportFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CosyVoiceVoiceStoreError.exportFailed(
                message.isEmpty ? "ditto 退出码 \(process.terminationStatus)" : message)
        }
    }

    nonisolated static func exportReadme(
        voiceName: String,
        exportedAt: String,
        includesReferenceClips: Bool = false
    ) -> String {
        let referenceContents = includesReferenceClips
            ? """
                refs/        原始参考音频片段 / individual reference clips
              """
            : ""
        let restorePaths = includesReferenceClips
            ? "prompt.wav / prompt.txt / refs/ / meta.json"
            : "prompt.wav / prompt.txt / meta.json"
        let multipleReferenceNote = includesReferenceClips
            ? """

            多条参考音频 / Multiple reference clips:
              一个音色最多保存 5 条参考音频；prompt.wav 是按顺序合并后的合成用音频，
              refs/ 下保留每条原始片段与逐字对应的文本。
              A voice can keep up to 5 reference clips; prompt.wav is the merged audio
              used for synthesis, while refs/ keeps each original clip and its text.
            """
            : ""
        return """
        CosyVoice3 音色备份 / CosyVoice3 Voice Backup

        音色 / Voice: \(voiceName)
        导出时间 / Exported at: \(exportedAt)

        备份内容 / Contents:
          prompt.wav   合并参考音频 / merged reference audio
          prompt.txt   合并参考文本 / merged reference text
        \(referenceContents)
          meta.json    音色元数据 / voice metadata
          voice.json   导出描述 / export descriptor
          README.txt   本说明 / this file
        \(multipleReferenceNote)

        恢复方式 / How to restore:
          1. 先安装 CosyVoice3 运行环境与模型。
             Install the CosyVoice3 runtime and model first.
          2. 把 <id>/ 目录复制到本机音色目录（voices/）下，
             保持 \(restorePaths) 的相对路径不变。
             Copy the <id>/ directory into the local voices/ directory,
             keeping the relative paths of \(restorePaths).
          3. 重启本地服务，或在 App 的「管理音色…」中重新加载，音色即会出现在列表里。
             Restart the local service, or reload voices in the app, and the voice
             will appear in the list.

        App 不内置任何音色；音色仅保存在本机。
        The app ships with no voices; voices stay on this Mac.
        """
    }

    // MARK: 服务重载

    /// 服务就绪时请求 `POST /voices/reload`；返回 nil 表示成功/跳过，非 nil 为警告文案。
    /// 用于管理器「重试 reload」等手动入口；增删改内部走 `reloadServiceAfterMutation`
    /// （失败会回滚并抛错，不会把坏音色留在列表里）。
    func reloadServiceIfRunning() async -> String? {
        guard serviceReadyProvider() else { return nil }
        do {
            _ = try await client.reloadVoices()
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    private func reloadServiceAfterMutation() async throws {
        guard serviceReadyProvider() else { return }
        do {
            _ = try await client.reloadVoices()
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            throw CosyVoiceVoiceStoreError.reloadFailed(reason)
        }
    }

    // MARK: Manifest

    private struct ManifestState {
        var root: [String: Any]
        var entries: [[String: Any]]
        var existed: Bool
        /// 原始文件字节：回滚时原样写回（保证格式/未知字段逐字节不变）。
        var originalData: Data?
    }

    private var manifestURL: URL { voicesDirectory.appendingPathComponent("voices.json") }

    private func ensureVoicesDirectory() throws {
        do {
            try fileManager.createDirectory(
                at: voicesDirectory, withIntermediateDirectories: true)
        } catch {
            throw CosyVoiceVoiceStoreError.saveFailed(error.localizedDescription)
        }
    }

    private func loadManifestIfPresent() throws -> ManifestState? {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }
        return try loadManifestState()
    }

    /// 修改类操作使用：manifest 缺失时先从目录扫描重建条目（避免新增时丢掉已有内置音色）。
    private func loadManifestForMutation() throws -> ManifestState {
        var state = try loadManifestState()
        guard !state.existed else { return state }
        let scanned = Self.sorted(scanDirectories())
        state.entries = scanned.map {
            Self.manifestEntry(from: $0, voicesDirectory: voicesDirectory)
        }
        // 重建出的条目已带 references（v2 字段），清单版本同步为 2。
        state.root["version"] = 2
        state.root["voices"] = state.entries
        return state
    }

    private func loadManifestState() throws -> ManifestState {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return ManifestState(
                root: ["version": 1, "voices": []], entries: [],
                existed: false, originalData: nil)
        }
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw CosyVoiceVoiceStoreError.manifestCorrupted(error.localizedDescription)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CosyVoiceVoiceStoreError.manifestCorrupted("不是合法 JSON 对象")
        }
        var root = object
        let rawEntries = (object["voices"] as? [Any]) ?? []
        let entries: [[String: Any]] = rawEntries.compactMap { $0 as? [String: Any] }
        if !rawEntries.isEmpty, entries.count != rawEntries.count {
            throw CosyVoiceVoiceStoreError.manifestCorrupted("voices 数组里有非对象条目")
        }
        root["voices"] = entries
        if root["version"] == nil { root["version"] = 1 }
        return ManifestState(
            root: root, entries: entries, existed: true, originalData: data)
    }

    private func saveManifest(_ root: [String: Any]) throws {
        try ensureVoicesDirectory()
        guard JSONSerialization.isValidJSONObject(root) else {
            throw CosyVoiceVoiceStoreError.saveFailed("manifest 无法序列化")
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            throw CosyVoiceVoiceStoreError.saveFailed(error.localizedDescription)
        }
    }

    private func restoreManifest(_ state: ManifestState) {
        if state.existed {
            if let original = state.originalData {
                try? original.write(to: manifestURL, options: .atomic)
            } else if let data = try? JSONSerialization.data(
                withJSONObject: state.root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                try? data.write(to: manifestURL, options: .atomic)
            }
        } else if fileManager.fileExists(atPath: manifestURL.path) {
            try? fileManager.removeItem(at: manifestURL)
        }
    }

    // MARK: 目录扫描（manifest 缺失时的兜底）

    private func scanDirectories() -> [CosyVoiceManagedVoice] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: voicesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var result: [CosyVoiceManagedVoice] = []
        for directory in contents {
            let isDirectory = (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            guard isDirectory else { continue }
            let id = directory.lastPathComponent
            guard Self.isValidID(id) else { continue }
            let promptURL = directory.appendingPathComponent("prompt.wav")
            let promptExists = fileManager.fileExists(atPath: promptURL.path)
            let meta = Self.readJSONObject(directory.appendingPathComponent("meta.json")) ?? [:]
            let builtin = Self.isBuiltinID(id)
            let referenceFiles = Self.referenceAudioFiles(
                in: directory.appendingPathComponent(Self.refsDirectoryName, isDirectory: true),
                fileManager: fileManager)
            let metaTexts = Self.metaReferenceTexts(meta)
            let references: [CosyVoiceReferenceClip]
            if !referenceFiles.isEmpty {
                // v2 布局：refs/ref-*.wav 是条目事实来源；prompt.wav 缺失也允许展示。
                references = referenceFiles.map { fileURL in
                    let stem = fileURL.deletingPathExtension().lastPathComponent
                    var text = Self.readText(
                        fileURL.deletingPathExtension().appendingPathExtension("txt"))
                    if text.isEmpty, let metaText = metaTexts[stem] { text = metaText }
                    return CosyVoiceReferenceClip(
                        id: stem,
                        audioPath: fileURL.path,
                        text: text,
                        duration: Self.audioDuration(url: fileURL),
                        fileName: fileURL.lastPathComponent
                    )
                }
            } else {
                // 旧布局：必须存在 prompt.wav，避免把半截目录当音色。
                guard promptExists else { continue }
                var referenceText = Self.readText(
                    directory.appendingPathComponent("prompt.txt"))
                if referenceText.isEmpty, let text = Self.string(meta["reference_text"]) {
                    referenceText = text
                }
                references = [CosyVoiceReferenceClip(
                    id: "ref-1",
                    audioPath: promptURL.path,
                    text: referenceText,
                    duration: Self.audioDuration(url: promptURL),
                    fileName: promptURL.lastPathComponent
                )]
            }
            let combinedText = CosyVoiceReferenceSpec.combinedText(references.map(\.text))
            let mode = Self.string(meta["mode"])
                ?? (combinedText.isEmpty
                    ? CosyVoiceManagedVoice.modeCrossLingual
                    : CosyVoiceManagedVoice.modeZeroShot)
            let duration = Self.double(meta["duration"])
                ?? Self.combinedDuration(of: references)
            result.append(CosyVoiceManagedVoice(
                id: id,
                name: Self.string(meta["name"]) ?? (builtin
                    ? CosyVoiceVoiceCatalog.displayName(for: id) : id),
                description: Self.string(meta["description"]) ?? "",
                references: references,
                mode: mode,
                personalUseOnly: true,
                builtin: builtin,
                duration: duration,
                source: Self.string(meta["source"]),
                promptWAVPath: promptExists ? promptURL.path : nil
            ))
        }
        return result
    }

    /// `refs/` 下的 `ref-*.wav`，按编号排序。
    private static func referenceAudioFiles(
        in directory: URL,
        fileManager: FileManager
    ) -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let files = contents.filter { url in
            guard url.pathExtension.lowercased() == "wav" else { return false }
            return url.deletingPathExtension().lastPathComponent.hasPrefix("ref-")
        }
        return files.sorted { lhs, rhs in
            let lhsNumber = referenceNumber(lhs)
            let rhsNumber = referenceNumber(rhs)
            if lhsNumber != rhsNumber { return lhsNumber < rhsNumber }
            return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
                == .orderedAscending
        }
    }

    /// `ref-<N>.wav` 里的编号；解析不出来时排到最后。
    private static func referenceNumber(_ url: URL) -> Int {
        let stem = url.deletingPathExtension().lastPathComponent
        var digits = ""
        var collecting = false
        for character in stem {
            if character.isNumber {
                collecting = true
                digits.append(character)
            } else if collecting {
                break
            }
        }
        return Int(digits) ?? Int.max
    }

    /// `meta.json` 里 references 的文本（按文件名匹配，供目录扫描兜底）。
    private static func metaReferenceTexts(_ meta: [String: Any]) -> [String: String] {
        guard let rows = meta["references"] as? [Any] else { return [:] }
        var result: [String: String] = [:]
        for row in rows {
            guard let object = row as? [String: Any] else { continue }
            guard let audio = string(object["audio"]) ?? string(object["audio_path"]) else {
                continue
            }
            guard let text = string(object["text"]) ?? string(object["prompt_text"]) else {
                continue
            }
            let stem = URL(fileURLWithPath: audio).deletingPathExtension().lastPathComponent
            if !stem.isEmpty { result[stem] = text }
        }
        return result
    }

    // MARK: 解析 manifest 条目

    private func parseEntry(_ entry: [String: Any]) -> CosyVoiceManagedVoice? {
        let id = Self.string(entry["id"]) ?? ""
        guard Self.isValidID(id) else { return nil }
        let builtin = Self.bool(entry["builtin"]) ?? Self.isBuiltinID(id)
        let promptRelative = Self.string(entry["prompt_wav"]) ?? "\(id)/prompt.wav"
        let promptURL = resolvePromptURL(promptRelative, id: id)
        let entryText = Self.string(entry["prompt_text"]) ?? ""
        var references = parseReferences(entry["references"], entryText: entryText)
        if references.isEmpty {
            // 旧条目（无 references 或全部片段失效）：视为一条 prompt 参考音。
            var legacyText = entryText
            if legacyText.isEmpty, let promptURL {
                legacyText = Self.readText(
                    promptURL.deletingLastPathComponent().appendingPathComponent("prompt.txt"))
            }
            references = [CosyVoiceReferenceClip(
                id: "ref-1",
                audioPath: promptURL?.path,
                text: legacyText,
                duration: Self.double(entry["duration"]),
                fileName: promptURL?.lastPathComponent
            )]
        }
        let combinedText = CosyVoiceReferenceSpec.combinedText(references.map(\.text))
        let mode = Self.string(entry["mode"])
            ?? (combinedText.isEmpty
                ? CosyVoiceManagedVoice.modeCrossLingual
                : CosyVoiceManagedVoice.modeZeroShot)
        let duration = Self.double(entry["duration"])
            ?? Self.double(entry["duration_s"])
            ?? Self.combinedDuration(of: references)
        return CosyVoiceManagedVoice(
            id: id,
            name: Self.string(entry["name"]) ?? CosyVoiceVoiceCatalog.displayName(for: id),
            description: Self.string(entry["description"]) ?? "",
            references: references,
            mode: mode,
            personalUseOnly: true,
            builtin: builtin,
            duration: duration,
            source: Self.string(entry["source"]),
            promptWAVPath: promptURL?.path
        )
    }

    /// 解析 `references` 数组：路径必须存在且收敛在 voices 目录内，否则跳过该片段。
    private func parseReferences(_ raw: Any?, entryText: String) -> [CosyVoiceReferenceClip] {
        guard let rows = raw as? [Any] else { return [] }
        var clips: [CosyVoiceReferenceClip] = []
        for (index, row) in rows.enumerated() {
            guard let object = row as? [String: Any] else { continue }
            guard let rawAudio = Self.string(object["audio"])
                ?? Self.string(object["audio_path"]) else { continue }
            guard let audioURL = resolveReferenceURL(rawAudio) else { continue }
            var text = Self.string(object["text"])
                ?? Self.string(object["prompt_text"])
                ?? ""
            if text.isEmpty {
                // 没写文本时读同目录同名 .txt（ref-1.wav → ref-1.txt）。
                text = Self.readText(
                    audioURL.deletingPathExtension().appendingPathExtension("txt"))
            }
            let duration = Self.double(object["duration"])
                ?? Self.audioDuration(url: audioURL)
            clips.append(CosyVoiceReferenceClip(
                id: "ref-\(index + 1)",
                audioPath: audioURL.path,
                text: text,
                duration: duration,
                fileName: audioURL.lastPathComponent
            ))
        }
        if clips.count == 1, clips[0].text.isEmpty, !entryText.isEmpty {
            clips[0].text = entryText
        }
        return clips
    }

    private func resolvePromptURL(_ relative: String, id: String) -> URL? {
        let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: URL
        if trimmed.hasPrefix("/") {
            candidate = URL(fileURLWithPath: trimmed)
        } else {
            candidate = voicesDirectory.appendingPathComponent(trimmed)
        }
        guard Self.isPath(candidate, inside: voicesDirectory) else {
            // 非法相对路径：回退到规范位置。
            return voicesDirectory.appendingPathComponent(id).appendingPathComponent("prompt.wav")
        }
        return candidate
    }

    /// 解析 `references[].audio`（相对 voices 目录或绝对路径）；非法/不存在返回 nil。
    private func resolveReferenceURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate: URL
        if trimmed.hasPrefix("/") {
            candidate = URL(fileURLWithPath: trimmed)
        } else {
            candidate = voicesDirectory.appendingPathComponent(trimmed)
        }
        guard Self.isPath(candidate, inside: voicesDirectory) else { return nil }
        let standardized = candidate.standardizedFileURL
        guard fileManager.fileExists(atPath: standardized.path) else { return nil }
        return standardized
    }

    // MARK: 参考片段准备

    /// 一条已转码完成、可直接落盘的参考片段。
    private struct PreparedClip {
        var samples: [Float]
        var text: String
        var duration: TimeInterval
    }

    /// 一次保存的参考片段集合（顺序即拼接顺序）。
    private struct ReferencePlan {
        var clips: [PreparedClip]
        var text: String
        var mode: String
        var duration: TimeInterval
    }

    /// 校验输入条数/文本一致性 → 逐条转码/校验 → 合并总时长。
    ///
    /// 全部为只读操作，失败时不会留下任何落盘副作用。
    private func prepareReferences(
        _ inputs: [CosyVoiceReferenceInput],
        voiceDirectory: URL?,
        crossLingual: Bool?
    ) throws -> ReferencePlan {
        guard !inputs.isEmpty else { throw CosyVoiceVoiceStoreError.missingReferences }
        guard inputs.count <= CosyVoiceReferenceSpec.maxCount else {
            throw CosyVoiceVoiceStoreError.tooManyReferences(
                max: CosyVoiceReferenceSpec.maxCount)
        }
        let texts: [String] = inputs.map { input in
            switch input {
            case .newAudio(_, let text):
                return Self.validatedReferenceText(text)
            case .existing(_, _, let text):
                return Self.validatedReferenceText(text)
            }
        }
        // 文本规则先于音频校验：部分填写/部分留空直接给出明确错误。
        guard CosyVoiceReferenceSpec.hasConsistentTexts(
            texts, crossLingual: crossLingual ?? false) else {
            throw CosyVoiceVoiceStoreError.inconsistentReferenceText
        }
        var clips: [PreparedClip] = []
        clips.reserveCapacity(inputs.count)
        for (index, input) in inputs.enumerated() {
            let text = texts[index]
            let prepared: AudioPreparation
            switch input {
            case .newAudio(let url, _):
                prepared = try Self.preparedReferenceAudio(url: url)
            case .existing(_, let audioPath, _):
                guard let voiceDirectory else {
                    throw CosyVoiceVoiceStoreError.invalidReference(
                        "新增音色不能引用已有参考片段")
                }
                let url = try existingReferenceURL(
                    audioPath, voiceDirectory: voiceDirectory)
                prepared = try Self.preparedReferenceAudio(url: url)
            }
            clips.append(PreparedClip(
                samples: prepared.samples, text: text, duration: prepared.duration))
        }
        let duration = CosyVoiceReferenceSpec.combinedDuration(clips.map(\.duration))
        guard duration <= CosyVoiceReferenceSpec.maxTotalDuration + 0.001 else {
            throw CosyVoiceVoiceStoreError.referenceTotalTooLong(seconds: duration)
        }
        return ReferencePlan(
            clips: clips,
            text: CosyVoiceReferenceSpec.combinedText(texts),
            mode: Self.resolvedMode(crossLingual: crossLingual, references: texts),
            duration: duration
        )
    }

    /// `.newAudio` / `.existing` 的统一转码入口（保留 store 错误类型，其余包成 invalidReference）。
    private static func preparedReferenceAudio(url: URL) throws -> AudioPreparation {
        do {
            return try prepareAudio(url: url)
        } catch let error as CosyVoiceVoiceStoreError {
            throw error
        } catch {
            throw CosyVoiceVoiceStoreError.invalidReference(error.localizedDescription)
        }
    }

    /// `.existing` 片段路径校验：必须收敛在 `<voices>/<id>/` 内且存在可读。
    private func existingReferenceURL(
        _ rawPath: String,
        voiceDirectory: URL
    ) throws -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CosyVoiceVoiceStoreError.invalidReference("参考音频路径为空")
        }
        let candidate: URL
        if trimmed.hasPrefix("/") {
            candidate = URL(fileURLWithPath: trimmed)
        } else {
            candidate = voiceDirectory.appendingPathComponent(trimmed)
        }
        guard Self.isPath(candidate, inside: voiceDirectory) else {
            throw CosyVoiceVoiceStoreError.invalidReference("片段路径不在音色目录内")
        }
        let standardized = candidate.standardizedFileURL
        guard standardized.path != voiceDirectory.standardizedFileURL.path,
              fileManager.fileExists(atPath: standardized.path) else {
            throw CosyVoiceVoiceStoreError.invalidReference("参考音频不存在")
        }
        return standardized
    }

    private static func referenceClips(
        from clips: [PreparedClip],
        directory: URL
    ) -> [CosyVoiceReferenceClip] {
        clips.enumerated().map { index, clip in
            let name = "ref-\(index + 1)"
            return CosyVoiceReferenceClip(
                id: name,
                audioPath: directory
                    .appendingPathComponent(refsDirectoryName, isDirectory: true)
                    .appendingPathComponent("\(name).wav").path,
                text: clip.text,
                duration: clip.duration,
                fileName: "\(name).wav"
            )
        }
    }

    /// `voices.json` 里的 references（相对 voices 目录）。
    private static func manifestReferenceObjects(
        id: String,
        clips: [PreparedClip]
    ) -> [[String: Any]] {
        clips.enumerated().map { index, clip in
            var item: [String: Any] = [
                "audio": "\(id)/\(refsDirectoryName)/ref-\(index + 1).wav",
                "text": clip.text,
            ]
            item["duration"] = clip.duration
            return item
        }
    }

    /// `meta.json` 里的 references（相对音色目录）。
    private static func metaReferenceObjects(_ clips: [PreparedClip]) -> [[String: Any]] {
        clips.enumerated().map { index, clip in
            var item: [String: Any] = [
                "audio": "\(refsDirectoryName)/ref-\(index + 1).wav",
                "text": clip.text,
            ]
            item["duration"] = clip.duration
            return item
        }
    }

    // MARK: 写文件

    /// 写 v2 布局：refs/ref-N.wav|txt（原始片段）+ prompt.wav|txt（合并）+ meta.json。
    private func writeVoiceContent(
        directory: URL,
        id: String,
        name: String,
        description: String,
        clips: [PreparedClip],
        mode: String,
        builtin: Bool,
        duration: TimeInterval?,
        source: String,
        identifier: String,
        isNew: Bool
    ) throws {
        let refsDirectory = directory.appendingPathComponent(
            Self.refsDirectoryName, isDirectory: true)
        if !isNew, fileManager.fileExists(atPath: refsDirectory.path) {
            try fileManager.removeItem(at: refsDirectory)
        }
        try fileManager.createDirectory(
            at: refsDirectory, withIntermediateDirectories: true)
        for (index, clip) in clips.enumerated() {
            let number = index + 1
            try Self.writeWAV(
                clip.samples,
                to: refsDirectory.appendingPathComponent("ref-\(number).wav"),
                fileManager: fileManager)
            try Data(clip.text.utf8).write(
                to: refsDirectory.appendingPathComponent("ref-\(number).txt"),
                options: .atomic)
        }
        let mergedSamples = CosyVoiceReferenceSpec.combinedSamples(clips.map(\.samples))
        try Self.writeWAV(
            mergedSamples,
            to: directory.appendingPathComponent("prompt.wav"),
            fileManager: fileManager)
        let combinedText = CosyVoiceReferenceSpec.combinedText(clips.map(\.text))
        try Data(combinedText.utf8).write(
            to: directory.appendingPathComponent("prompt.txt"), options: .atomic)
        try writeMeta(
            url: directory.appendingPathComponent("meta.json"),
            id: id,
            name: name,
            description: description,
            referenceText: combinedText,
            references: Self.metaReferenceObjects(clips),
            mode: mode,
            builtin: builtin,
            duration: duration,
            source: source,
            identifier: identifier,
            merge: !isNew
        )
    }

    private func writeMeta(
        url: URL,
        id: String,
        name: String,
        description: String,
        referenceText: String,
        references: [[String: Any]]?,
        mode: String,
        builtin: Bool,
        duration: TimeInterval?,
        source: String,
        identifier: String,
        merge: Bool
    ) throws {
        var object: [String: Any] = [:]
        if merge, let existing = Self.readJSONObject(url) { object = existing }
        let now = ISO8601DateFormatter().string(from: Date())
        object["id"] = id
        object["name"] = name
        object["description"] = description
        object["reference_text"] = referenceText
        object["prompt_text"] = referenceText
        object["mode"] = mode
        object["personal_use_only"] = true
        object["builtin"] = builtin
        if let duration { object["duration"] = duration }
        if let references { object["references"] = references }
        object["source"] = source
        object["custom_id"] = identifier
        if object["created_at"] == nil { object["created_at"] = now }
        object["updated_at"] = now
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CosyVoiceVoiceStoreError.saveFailed("meta.json 无法序列化")
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url, options: .atomic)
        } catch {
            throw CosyVoiceVoiceStoreError.saveFailed(error.localizedDescription)
        }
    }

    /// 24 kHz 单声道 16-bit PCM WAV（RIFF）。
    static func writeWAV(
        _ samples: [Float],
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        guard !samples.isEmpty else {
            throw CosyVoiceVoiceStoreError.invalidAudio("音频为空")
        }
        let data = pcm16WAVData(samples)
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw CosyVoiceVoiceStoreError.saveFailed(error.localizedDescription)
        }
    }

    private static func pcm16WAVData(_ samples: [Float]) -> Data {
        var payload = Data()
        payload.reserveCapacity(samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let value = Int16((clamped * 32_767).rounded())
            withUnsafeBytes(of: value.littleEndian) { payload.append(contentsOf: $0) }
        }
        func appendU16(_ value: Int, to data: inout Data) {
            var little = UInt16(value).littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func appendU32(_ value: Int, to data: inout Data) {
            var little = UInt32(value).littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        appendU32(36 + payload.count, to: &data)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendU32(16, to: &data)
        appendU16(1, to: &data)
        appendU16(1, to: &data)
        appendU32(sampleRate, to: &data)
        appendU32(sampleRate * 2, to: &data)
        appendU16(2, to: &data)
        appendU16(16, to: &data)
        data.append(contentsOf: Array("data".utf8))
        appendU32(payload.count, to: &data)
        data.append(payload)
        return data
    }

    // MARK: 音频处理

    struct AudioPreparation: Sendable, Equatable {
        var samples: [Float]
        var duration: TimeInterval
    }

    /// 读取用户音频 → 24 kHz 单声道 → 5–30s 校验 → 峰值归一。
    static func prepareAudio(url: URL) throws -> AudioPreparation {
        let extensionName = url.pathExtension.lowercased()
        guard allowedAudioExtensions.contains(extensionName) else {
            throw CosyVoiceVoiceStoreError.invalidAudio(
                "不支持 .\(extensionName.isEmpty ? "未知" : extensionName) 格式；请使用 wav / m4a / aiff")
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw CosyVoiceVoiceStoreError.invalidAudio("无法读取该音频文件")
        }
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else {
            throw CosyVoiceVoiceStoreError.invalidAudio("音频为空")
        }
        guard let input = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw CosyVoiceVoiceStoreError.invalidAudio("无法分配音频缓冲")
        }
        do {
            try file.read(into: input)
        } catch {
            throw CosyVoiceVoiceStoreError.invalidAudio("读取音频失败")
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: input.format, to: outputFormat) else {
            throw CosyVoiceVoiceStoreError.invalidAudio("无法转换音频格式")
        }
        var samples: [Float] = []
        samples.reserveCapacity(
            Int(Double(input.frameLength) * Double(sampleRate) / input.format.sampleRate) + 1024)
        var supplied = false
        var finished = false
        var rounds = 0
        while !finished {
            rounds += 1
            if rounds > 100_000 {
                throw CosyVoiceVoiceStoreError.invalidAudio("音频转换未收敛")
            }
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 16_384)
            else {
                throw CosyVoiceVoiceStoreError.invalidAudio("无法分配输出缓冲")
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
                if supplied {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return input
            }
            if let conversionError {
                throw CosyVoiceVoiceStoreError.invalidAudio(conversionError.localizedDescription)
            }
            if output.frameLength > 0, let channel = output.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(
                    start: channel, count: Int(output.frameLength)))
            }
            switch status {
            case .haveData, .inputRanDry:
                continue
            case .endOfStream:
                finished = true
            case .error:
                throw CosyVoiceVoiceStoreError.invalidAudio("音频转换失败")
            @unknown default:
                finished = true
            }
        }
        guard !samples.isEmpty else {
            throw CosyVoiceVoiceStoreError.invalidAudio("音频为空")
        }
        let duration = Double(samples.count) / Double(sampleRate)
        guard duration >= minDuration - 0.05 else {
            throw CosyVoiceVoiceStoreError.audioTooShort(seconds: duration)
        }
        guard duration <= maxDuration + 0.05 else {
            throw CosyVoiceVoiceStoreError.audioTooLong(seconds: duration)
        }
        var peak: Float = 0
        for sample in samples { peak = max(peak, abs(sample)) }
        guard peak > 0.0001 else { throw CosyVoiceVoiceStoreError.silentAudio }
        let gain = peakTarget / peak
        var normalized = samples
        if abs(gain - 1) > 0.0001 {
            for index in normalized.indices {
                normalized[index] = max(-1, min(1, normalized[index] * gain))
            }
        }
        return AudioPreparation(samples: normalized, duration: duration)
    }

    // MARK: 校验/工具

    static func validatedName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CosyVoiceVoiceStoreError.invalidName("不能为空")
        }
        guard trimmed.count <= maxNameLength else {
            throw CosyVoiceVoiceStoreError.invalidName("最多 \(maxNameLength) 个字符")
        }
        guard !trimmed.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || $0.value == 0x2F
        }) else {
            throw CosyVoiceVoiceStoreError.invalidName("包含非法字符")
        }
        return trimmed
    }

    static func validatedDescription(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maxDescriptionLength))
    }

    static func validatedReferenceText(_ raw: String) -> String {
        String(raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(maxReferenceTextLength))
    }

    /// 参考文本 → 合成模式：显式 cross-lingual 优先；否则文本全空即 cross-lingual。
    static func resolvedMode(crossLingual: Bool?, references texts: [String]) -> String {
        if crossLingual == true { return CosyVoiceManagedVoice.modeCrossLingual }
        return CosyVoiceReferenceSpec.combinedText(texts).isEmpty
            ? CosyVoiceManagedVoice.modeCrossLingual
            : CosyVoiceManagedVoice.modeZeroShot
    }

    static func isBuiltinID(_ id: String) -> Bool {
        builtinIDs.contains(id)
    }

    /// id 安全：只允许小写字母/数字/连字符，不能以连字符开头/结尾或出现连续连字符。
    static func isValidID(_ id: String) -> Bool {
        guard (1...80).contains(id.count) else { return false }
        for scalar in id.unicodeScalars {
            let value = scalar.value
            let isLower = (97...122).contains(value)
            let isDigit = (48...57).contains(value)
            guard isLower || isDigit || value == 45 else { return false }
        }
        return !id.hasPrefix("-") && !id.hasSuffix("-") && !id.contains("--")
    }

    /// `custom-<slug>-<uuid4>`；中文名 slug 为空时用 `voice`。
    static func makeID(name: String) -> String {
        let lowered = name.lowercased()
        var slug = ""
        var lastWasHyphen = false
        for scalar in lowered.unicodeScalars {
            let value = scalar.value
            let isLower = (97...122).contains(value)
            let isDigit = (48...57).contains(value)
            if isLower || isDigit {
                slug.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen, !slug.isEmpty {
                slug.append("-")
                lastWasHyphen = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        slug = String(slug.prefix(20))
        if slug.isEmpty { slug = "voice" }
        return "custom-\(slug)-\(UUID().uuidString.lowercased())"
    }

    private func directory(for id: String) throws -> URL {
        guard Self.isValidID(id) else { throw CosyVoiceVoiceStoreError.invalidID(id) }
        let url = voicesDirectory.appendingPathComponent(id, isDirectory: true)
        let root = voicesDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else {
            throw CosyVoiceVoiceStoreError.invalidID(id)
        }
        return url
    }

    /// 路径是否收敛在目录内（兼容 `/var/...` 与 `/private/var/...` 两种写法）。
    private static func isPath(_ url: URL, inside directory: URL) -> Bool {
        let root = directory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == root || path.hasPrefix(root + "/") { return true }
        let resolvedRoot = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        return resolvedPath == resolvedRoot || resolvedPath.hasPrefix(resolvedRoot + "/")
    }

    private static func sorted(_ voices: [CosyVoiceManagedVoice]) -> [CosyVoiceManagedVoice] {
        voices.sorted { lhs, rhs in
            let lhsBuiltin = lhs.builtin
            let rhsBuiltin = rhs.builtin
            if lhsBuiltin != rhsBuiltin { return lhsBuiltin }
            if lhsBuiltin, rhsBuiltin {
                let lhsIndex = builtinIDs.firstIndex(of: lhs.id) ?? Int.max
                let rhsIndex = builtinIDs.firstIndex(of: rhs.id) ?? Int.max
                if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
            }
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    private static func mapped(_ error: Error) -> CosyVoiceVoiceStoreError {
        if let voiceError = error as? CosyVoiceVoiceStoreError { return voiceError }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return .saveFailed(description)
        }
        return .saveFailed((error as NSError).localizedDescription)
    }

    // MARK: manifest 条目/JSON 工具

    private static func manifestEntry(
        id: String,
        name: String,
        description: String,
        referenceText: String,
        mode: String,
        builtin: Bool,
        duration: TimeInterval?,
        source: String
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "id": id,
            "name": name,
            "description": description,
            "prompt_wav": "\(id)/prompt.wav",
            "prompt_text": referenceText,
            "mode": mode,
            "personal_use_only": true,
            "builtin": builtin,
            "source": source,
        ]
        if let duration { entry["duration"] = duration }
        return entry
    }

    /// 从目录扫描出的托管音色重建 manifest 条目（manifest 缺失/损坏修复用）。
    private static func manifestEntry(
        from voice: CosyVoiceManagedVoice,
        voicesDirectory: URL
    ) -> [String: Any] {
        var entry = manifestEntry(
            id: voice.id,
            name: voice.name,
            description: voice.description,
            referenceText: voice.referenceText,
            mode: voice.mode,
            builtin: voice.builtin,
            duration: voice.duration,
            source: voice.source ?? (voice.builtin ? "builtin" : "app-import")
        )
        let root = voicesDirectory.standardizedFileURL.path
        entry["references"] = voice.references.enumerated().map { index, clip in
            var item: [String: Any] = ["text": clip.text]
            if let audioPath = clip.audioPath {
                let standardized = URL(fileURLWithPath: audioPath).standardizedFileURL.path
                if standardized.hasPrefix(root + "/") {
                    item["audio"] = String(standardized.dropFirst(root.count + 1))
                } else {
                    item["audio"] = audioPath
                }
            }
            if let duration = clip.duration { item["duration"] = duration }
            return item
        }
        return entry
    }

    /// 合并后的参考音总时长；任一片段拿不到时长返回 nil。
    private static func combinedDuration(
        of references: [CosyVoiceReferenceClip]
    ) -> TimeInterval? {
        var durations: [TimeInterval] = []
        durations.reserveCapacity(references.count)
        for clip in references {
            if let duration = clip.duration {
                durations.append(duration)
            } else if let path = clip.audioPath,
                      let duration = audioDuration(url: URL(fileURLWithPath: path)) {
                durations.append(duration)
            } else {
                return nil
            }
        }
        guard !durations.isEmpty else { return nil }
        return CosyVoiceReferenceSpec.combinedDuration(durations)
    }

    private static func string(_ any: Any?) -> String? {
        if let value = any as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func bool(_ any: Any?) -> Bool? {
        if let value = any as? Bool { return value }
        if let value = any as? NSNumber { return value.boolValue }
        return nil
    }

    private static func double(_ any: Any?) -> Double? {
        if let value = any as? Double, value.isFinite { return value }
        if let value = any as? NSNumber, value.doubleValue.isFinite { return value.doubleValue }
        if let value = any as? String, let parsed = Double(value), parsed.isFinite {
            return parsed
        }
        return nil
    }

    private static func readJSONObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return object
    }

    private static func readText(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func audioDuration(url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        guard file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

// MARK: - 目录快照（编辑回滚用）

/// 编辑前把整个音色目录复制一份到临时目录；失败时原样恢复（含 refs/ 与未知文件）。
private struct DirectorySnapshot {
    var existed: Bool
    var backupURL: URL?
    /// 回滚失败时置 false，cleanup 会保留临时备份，避免二次丢数据。
    var discardBackupOnCleanup = true

    init(directory: URL, fileManager: FileManager) throws {
        let exists = fileManager.fileExists(atPath: directory.path)
        self.existed = exists
        guard exists else {
            self.backupURL = nil
            return
        }
        let backup = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "cosyvoice-dir-backup-\(UUID().uuidString.lowercased())", isDirectory: true)
        try fileManager.copyItem(at: directory, to: backup)
        self.backupURL = backup
    }

    /// 恢复成功返回 true；失败时保留临时备份（cleanup 不会删除），避免回滚过程二次丢数据。
    @discardableResult
    mutating func restore(to directory: URL, fileManager: FileManager) -> Bool {
        if fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.removeItem(at: directory)
            } catch {
                discardBackupOnCleanup = false
                return false
            }
        }
        guard existed else { return true }
        guard let backupURL, fileManager.fileExists(atPath: backupURL.path) else {
            discardBackupOnCleanup = false
            return false
        }
        do {
            // 同卷下是原子 rename；跨卷时 FileManager 会退回复制，成功后才移除备份。
            try fileManager.moveItem(at: backupURL, to: directory)
            return true
        } catch {
            discardBackupOnCleanup = false
            return false
        }
    }

    func cleanup(fileManager: FileManager) {
        guard discardBackupOnCleanup, let backupURL else { return }
        try? fileManager.removeItem(at: backupURL)
    }
}
