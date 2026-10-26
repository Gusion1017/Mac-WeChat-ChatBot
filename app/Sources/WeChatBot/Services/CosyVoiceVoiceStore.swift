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
    /// 参考文本；`mode == cross_lingual` 时可为空。
    var referenceText: String
    /// `zero_shot` / `cross_lingual`
    var mode: String
    /// 内部字段：恒为 true（UI 不展示）。
    var personalUseOnly: Bool
    var builtin: Bool
    var duration: TimeInterval?
    var source: String?
    /// 参考音绝对路径（目录不存在时为 nil）。
    var promptWAVPath: String?

    var isCustom: Bool { !builtin }
    var hasReferenceText: Bool {
        !referenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
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

/// CosyVoice3 音色库（`voices.json` + `<id>/prompt.wav|prompt.txt|meta.json`）。
///
/// 设计边界：
/// - **actor**：所有文件/manifest 读写串行；
/// - **manifest 是事实来源**：用户新增/编辑/删除只改已知字段，保留未知字段与其他音色；
/// - **路径安全**：音色 id 只允许 `[a-z0-9-]`，所有路径收敛在 voices 目录内；
/// - **音频规范**：任意可解码音频 → 24 kHz 单声道 float → 峰值归一到 0.95 → 16-bit PCM WAV；
/// - **原子性**：每次变更前记录 manifest/音色目录旧状态，任何失败（含服务 reload）回滚；
/// - **服务 reload**：服务就绪时调用 `POST /voices/reload`，失败回滚并抛错；未运行则跳过，
///   下次启动服务时读取新 manifest。
actor CosyVoiceVoiceStore {
    static let shared = CosyVoiceVoiceStore()

    static let builtinIDs: [String] = ["girl", "loli", "onee"]
    static let minDuration: TimeInterval = 5
    static let maxDuration: TimeInterval = 30
    static let sampleRate = 24_000
    /// 峰值归一目标（留 5% headroom，避免 16-bit 削波）。
    static let peakTarget: Float = 0.95
    static let maxNameLength = 40
    static let maxDescriptionLength = 200
    static let maxReferenceTextLength = 500
    static let allowedAudioExtensions: Set<String> = ["wav", "m4a", "aiff", "aif"]

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

    /// 新增自定义音色。
    ///
    /// - Parameters:
    ///   - audioURL: 用户选择的 wav/m4a/aiff（5–30 秒，单人说话）。
    ///   - referenceText: 参考文本；留空自动使用 cross_lingual。
    ///   - crossLingual: 强制 cross_lingual（忽略参考文本）。
    ///
    /// 内部 `personal_use_only` 恒为 true，不需要用户额外确认（UI 不展示）。
    @discardableResult
    func add(
        name: String,
        audioURL: URL,
        referenceText: String,
        description: String,
        crossLingual: Bool = false
    ) async throws -> CosyVoiceManagedVoice {
        let name = try Self.validatedName(name)
        let description = Self.validatedDescription(description)
        let referenceText = Self.validatedReferenceText(referenceText)
        let prepared = try Self.prepareAudio(url: audioURL)
        let mode = Self.resolvedMode(crossLingual: crossLingual, referenceText: referenceText)

        let manifest = try loadManifestForMutation()
        let id = Self.makeID(name: name)
        let directory = try directory(for: id)
        let previousManifest = manifest
        let identifier = UUID().uuidString.lowercased()
        let source = "app-import"

        do {
            try ensureVoicesDirectory()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeVoiceFiles(
                directory: directory,
                id: id,
                name: name,
                description: description,
                referenceText: referenceText,
                mode: mode,
                builtin: false,
                duration: prepared.duration,
                source: source,
                prepared: prepared,
                isNew: true,
                identifier: identifier
            )
            var entries = manifest.entries
            entries.append(
                Self.manifestEntry(
                    id: id, name: name, description: description,
                    referenceText: referenceText, mode: mode, builtin: false,
                    duration: prepared.duration, source: source))
            var root = manifest.root
            root["version"] = manifest.entries.isEmpty ? 1 : root["version"] ?? 1
            root["voices"] = entries
            try saveManifest(root)
            try await reloadServiceAfterMutation()
            return CosyVoiceManagedVoice(
                id: id, name: name, description: description,
                referenceText: referenceText, mode: mode, personalUseOnly: true,
                builtin: false, duration: prepared.duration, source: source,
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

    /// 编辑音色。
    ///
    /// - 内置（girl/loli/onee）：只允许改 `name` / `description`；
    ///   传 `audioURL` 或改变参考文本/模式会抛 `.builtinReferenceLocked`。
    /// - 自定义：可改名称/简介/参考文本/模式，传 `audioURL` 可替换参考音。
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
               referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
                != (Self.string(current["prompt_text"]) ?? "") {
                throw CosyVoiceVoiceStoreError.builtinReferenceLocked
            }
        }

        let directory = try directory(for: id)
        let promptURL = directory.appendingPathComponent("prompt.wav")
        let promptTextURL = directory.appendingPathComponent("prompt.txt")
        let metaURL = directory.appendingPathComponent("meta.json")
        let backup = DirectoryBackup(
            promptWAV: try? Data(contentsOf: promptURL),
            promptText: try? Data(contentsOf: promptTextURL),
            meta: try? Data(contentsOf: metaURL)
        )
        let previousManifest = manifest
        let oldReferenceText = Self.string(current["prompt_text"])
            ?? Self.readText(promptTextURL)
        let newReferenceText = builtin
            ? oldReferenceText
            : Self.validatedReferenceText(referenceText ?? oldReferenceText)
        let oldMode = Self.string(current["mode"]) ?? CosyVoiceManagedVoice.modeZeroShot
        let newMode: String
        if builtin {
            newMode = oldMode
        } else if let crossLingual {
            newMode = crossLingual
                ? CosyVoiceManagedVoice.modeCrossLingual
                : (newReferenceText.isEmpty
                    ? CosyVoiceManagedVoice.modeCrossLingual
                    : CosyVoiceManagedVoice.modeZeroShot)
        } else {
            newMode = newReferenceText.isEmpty
                ? CosyVoiceManagedVoice.modeCrossLingual
                : oldMode
        }
        let newName = try Self.validatedName(name ?? (Self.string(current["name"]) ?? id))
        let newDescription = Self.validatedDescription(
            description ?? (Self.string(current["description"]) ?? ""))
        let prepared = try audioURL.map { try Self.prepareAudio(url: $0) }
        let duration = prepared?.duration ?? Self.double(current["duration"])

        do {
            if !builtin {
                if let prepared {
                    try Self.writeWAV(
                        prepared.samples, to: promptURL, fileManager: fileManager)
                }
                try Data(newReferenceText.utf8).write(to: promptTextURL, options: .atomic)
                try writeMeta(
                    url: metaURL, id: id, name: newName, description: newDescription,
                    referenceText: newReferenceText, mode: newMode, builtin: false,
                    duration: duration, source: Self.string(current["source"]) ?? "app-import",
                    identifier: Self.string(current["custom_id"]) ?? UUID().uuidString.lowercased(),
                    merge: true
                )
            } else {
                try writeMeta(
                    url: metaURL, id: id, name: newName, description: newDescription,
                    referenceText: oldReferenceText, mode: oldMode, builtin: true,
                    duration: duration, source: Self.string(current["source"]) ?? "builtin",
                    identifier: id, merge: true)
            }
            var entries = manifest.entries
            var entry = entries[index]
            entry["name"] = newName
            entry["description"] = newDescription
            entry["personal_use_only"] = true
            entry["builtin"] = builtin
            if !builtin {
                entry["prompt_text"] = newReferenceText
                entry["mode"] = newMode
                if let prepared { entry["duration"] = prepared.duration }
            }
            entries[index] = entry
            var root = manifest.root
            root["voices"] = entries
            try saveManifest(root)
            try await reloadServiceAfterMutation()
            return CosyVoiceManagedVoice(
                id: id, name: newName, description: newDescription,
                referenceText: newReferenceText, mode: newMode, personalUseOnly: true,
                builtin: builtin, duration: duration,
                source: Self.string(entry["source"]),
                promptWAVPath: promptURL.path
            )
        } catch {
            restoreManifest(previousManifest)
            backup.restore(
                promptWAV: promptURL, promptText: promptTextURL, meta: metaURL,
                fileManager: fileManager)
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
                try writeExportMeta(
                    voice: voice,
                    sourceDirectory: sourceDirectory,
                    targetDirectory: targetDirectory,
                    exportedAt: exportedAt)
                try writeExportVoiceJSON(
                    voice: voice,
                    targetDirectory: targetDirectory,
                    exportedAt: exportedAt)
                try Data(Self.exportReadme(voiceName: voice.name, exportedAt: exportedAt).utf8)
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
        exportedAt: String
    ) throws {
        let sourceMeta = sourceDirectory.appendingPathComponent("meta.json")
        var object = Self.readJSONObject(sourceMeta) ?? [:]
        object["id"] = voice.id
        object["name"] = voice.name
        object["description"] = voice.description
        object["reference_text"] = voice.referenceText
        object["mode"] = voice.mode
        object["personal_use_only"] = true
        object["builtin"] = false
        if let duration = voice.duration { object["duration"] = duration }
        if object["source"] == nil {
            object["source"] = voice.source ?? "app-import"
        }
        object["exported_at"] = exportedAt
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

    nonisolated static func exportReadme(voiceName: String, exportedAt: String) -> String {
        """
        CosyVoice3 音色备份 / CosyVoice3 Voice Backup

        音色 / Voice: \(voiceName)
        导出时间 / Exported at: \(exportedAt)

        备份内容 / Contents:
          prompt.wav   参考音频 / reference audio
          prompt.txt   参考文本 / reference text
          meta.json    音色元数据 / voice metadata
          voice.json   导出描述 / export descriptor
          README.txt   本说明 / this file

        恢复方式 / How to restore:
          1. 先安装 CosyVoice3 运行环境与模型。
             Install the CosyVoice3 runtime and model first.
          2. 把 <id>/ 目录复制到本机音色目录（voices/）下，
             保持 prompt.wav / prompt.txt / meta.json 的相对路径不变。
             Copy the <id>/ directory into the local voices/ directory,
             keeping the relative paths of prompt.wav / prompt.txt / meta.json.
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
        state.entries = scanned.map(Self.manifestEntry(from:))
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
            guard fileManager.fileExists(atPath: promptURL.path) else { continue }
            let meta = Self.readJSONObject(directory.appendingPathComponent("meta.json")) ?? [:]
            let builtin = Self.isBuiltinID(id)
            var referenceText = Self.readText(directory.appendingPathComponent("prompt.txt"))
            if referenceText.isEmpty, let text = Self.string(meta["reference_text"]) {
                referenceText = text
            }
            let mode = Self.string(meta["mode"])
                ?? (referenceText.isEmpty
                    ? CosyVoiceManagedVoice.modeCrossLingual
                    : CosyVoiceManagedVoice.modeZeroShot)
            let duration = Self.double(meta["duration"]) ?? Self.audioDuration(url: promptURL)
            result.append(CosyVoiceManagedVoice(
                id: id,
                name: Self.string(meta["name"]) ?? (builtin
                    ? CosyVoiceVoiceCatalog.displayName(for: id) : id),
                description: Self.string(meta["description"]) ?? "",
                referenceText: referenceText,
                mode: mode,
                personalUseOnly: true,
                builtin: builtin,
                duration: duration,
                source: Self.string(meta["source"]),
                promptWAVPath: promptURL.path
            ))
        }
        return result
    }

    // MARK: 解析 manifest 条目

    private func parseEntry(_ entry: [String: Any]) -> CosyVoiceManagedVoice? {
        let id = Self.string(entry["id"]) ?? ""
        guard Self.isValidID(id) else { return nil }
        let promptRelative = Self.string(entry["prompt_wav"])
            ?? "\(id)/prompt.wav"
        let promptURL = resolvePromptURL(promptRelative, id: id)
        let builtin = Self.bool(entry["builtin"]) ?? Self.isBuiltinID(id)
        var referenceText = Self.string(entry["prompt_text"]) ?? ""
        if referenceText.isEmpty, let promptURL {
            referenceText = Self.readText(
                promptURL.deletingLastPathComponent().appendingPathComponent("prompt.txt"))
        }
        let mode = Self.string(entry["mode"])
            ?? (referenceText.isEmpty
                ? CosyVoiceManagedVoice.modeCrossLingual
                : CosyVoiceManagedVoice.modeZeroShot)
        let duration = Self.double(entry["duration"])
            ?? Self.double(entry["duration_s"])
            ?? promptURL.flatMap { Self.audioDuration(url: $0) }
        return CosyVoiceManagedVoice(
            id: id,
            name: Self.string(entry["name"]) ?? CosyVoiceVoiceCatalog.displayName(for: id),
            description: Self.string(entry["description"]) ?? "",
            referenceText: referenceText,
            mode: mode,
            personalUseOnly: true,
            builtin: builtin,
            duration: duration,
            source: Self.string(entry["source"]),
            promptWAVPath: promptURL?.path
        )
    }

    private func resolvePromptURL(_ relative: String, id: String) -> URL? {
        let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: URL
        if trimmed.hasPrefix("/") {
            candidate = URL(fileURLWithPath: trimmed)
        } else {
            candidate = voicesDirectory.appendingPathComponent(trimmed)
        }
        let root = voicesDirectory.standardizedFileURL.path
        let path = candidate.standardizedFileURL.path
        guard path == root || path.hasPrefix(root + "/") else {
            // 非法相对路径：回退到规范位置。
            return voicesDirectory.appendingPathComponent(id).appendingPathComponent("prompt.wav")
        }
        return candidate
    }

    // MARK: 写文件

    private func writeVoiceFiles(
        directory: URL,
        id: String,
        name: String,
        description: String,
        referenceText: String,
        mode: String,
        builtin: Bool,
        duration: TimeInterval?,
        source: String,
        prepared: AudioPreparation,
        isNew: Bool,
        identifier: String
    ) throws {
        try Self.writeWAV(
            prepared.samples,
            to: directory.appendingPathComponent("prompt.wav"),
            fileManager: fileManager)
        try Data(referenceText.utf8)
            .write(to: directory.appendingPathComponent("prompt.txt"), options: .atomic)
        try writeMeta(
            url: directory.appendingPathComponent("meta.json"),
            id: id, name: name, description: description,
            referenceText: referenceText, mode: mode, builtin: builtin,
            duration: duration, source: source, identifier: identifier, merge: false)
        _ = isNew
    }

    private func writeMeta(
        url: URL,
        id: String,
        name: String,
        description: String,
        referenceText: String,
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
        object["mode"] = mode
        object["personal_use_only"] = true
        object["builtin"] = builtin
        if let duration { object["duration"] = duration }
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
        String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxReferenceTextLength))
    }

    static func resolvedMode(crossLingual: Bool, referenceText: String) -> String {
        if crossLingual { return CosyVoiceManagedVoice.modeCrossLingual }
        return referenceText.isEmpty
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
    private static func manifestEntry(from voice: CosyVoiceManagedVoice) -> [String: Any] {
        manifestEntry(
            id: voice.id,
            name: voice.name,
            description: voice.description,
            referenceText: voice.referenceText,
            mode: voice.mode,
            builtin: voice.builtin,
            duration: voice.duration,
            source: voice.source ?? (voice.builtin ? "builtin" : "app-import")
        )
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

// MARK: - 目录备份（编辑回滚用）

private struct DirectoryBackup {
    var promptWAV: Data?
    var promptText: Data?
    var meta: Data?

    func restore(
        promptWAV promptURL: URL,
        promptText promptTextURL: URL,
        meta metaURL: URL,
        fileManager: FileManager
    ) {
        restore(promptWAV, to: promptURL, fileManager: fileManager)
        restore(promptText, to: promptTextURL, fileManager: fileManager)
        restore(meta, to: metaURL, fileManager: fileManager)
    }

    private func restore(_ data: Data?, to url: URL, fileManager: FileManager) {
        if let data {
            try? data.write(to: url, options: .atomic)
        } else if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }
}
