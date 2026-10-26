import AVFoundation
import Foundation
import Observation

// MARK: - Profile

/// 一条克隆音色档案（spec §3.1 `VoiceCloneStore`）。
///
/// `audioPath` 指向统一转换后的 16 kHz 单声道 WAV（ZipVoice 的参考音频），
/// 原始 wav/m4a 不保留，避免重复占用空间；`referenceText` 是参考音频的转写文本
/// （ZipVoice 对齐用），默认可由 `VoiceTranscriptionService` 转写后填入，也可编辑。
struct VoiceCloneProfile: Codable, Sendable, Equatable, Hashable, Identifiable {
    var id: String
    var name: String
    var audioPath: String
    var referenceText: String
    var sampleRate: Int
    var duration: TimeInterval
    var createdAt: Date
    var updatedAt: Date

    var audioURL: URL { URL(fileURLWithPath: audioPath) }

    /// 参考文本是否已填写（ZipVoice 必须有参考文本才能对齐；为空时合成会明确报错）。
    var hasReferenceText: Bool {
        !referenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Errors

enum VoiceCloneError: Error, LocalizedError, Equatable {
    case emptyName
    case audioUnreadable(String)
    case audioTooLong(TimeInterval, max: TimeInterval)
    case saveFailed(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .emptyName: return "音色名称不能为空"
        case .audioUnreadable(let path): return "无法读取参考音频：\(path)"
        case .audioTooLong(let duration, let max):
            return String(format: "参考音频 %.1f 秒超过 %.0f 秒上限", duration, max)
        case .saveFailed(let reason): return "保存克隆音色失败：\(reason)"
        case .notFound(let id): return "克隆音色不存在：\(id)"
        }
    }
}

// MARK: - Store

/// 克隆音色档案的增删改查 + 参考音频导入（spec §3.1）。
///
/// - 目录：`~/Library/Application Support/WeChatAI/voice-clones/`；
/// - 索引：`clones.json`（原子写入，容忍旧库/损坏文件）；
/// - 导入 wav/m4a：`AVAudioFile` 解码 → `AVAudioConverter` 重采样到 16 kHz 单声道 →
///   写标准 16-bit WAV（超过 30 秒截断，避免参考音频过长拖慢合成）；
/// - `profile(id:)` / `loadProfiles()` 是 `nonisolated static`，合成服务与单测可在
///   任意线程读取，不依赖 MainActor。
@MainActor
@Observable
final class VoiceCloneStore {
    static let shared = VoiceCloneStore()

    /// 档案目录。
    nonisolated static var directory: URL {
        AppPaths.supportDirectory.appendingPathComponent("voice-clones", isDirectory: true)
    }

    /// 索引文件。
    nonisolated static var indexFile: URL {
        directory.appendingPathComponent("clones.json")
    }

    /// 克隆参考音频最长时长（秒）。
    nonisolated static var maxReferenceSeconds: TimeInterval {
        VoiceSynthesisAudio.maxReferenceSeconds
    }

    /// 全部档案（按创建时间倒序）。
    private(set) var profiles: [VoiceCloneProfile] = []

    /// 最近一次导入/保存的错误（UI 提示用）。
    private(set) var lastError: String?

    init() {
        profiles = Self.loadProfiles()
    }

    // MARK: Read

    /// 从磁盘重新加载索引。
    func reload() {
        profiles = Self.loadProfiles()
    }

    func profile(id: String) -> VoiceCloneProfile? {
        profiles.first { $0.id == id }
    }

    /// 静态读取（合成服务/单测用）。
    nonisolated static func profile(id: String) -> VoiceCloneProfile? {
        loadProfiles().first { $0.id == id }
    }

    /// 读取索引；文件缺失/损坏时返回空数组（不抛错，UI 显示空列表）。
    nonisolated static func loadProfiles() -> [VoiceCloneProfile] {
        guard let data = try? Data(contentsOf: indexFile) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let index = try? decoder.decode(CloneIndex.self, from: data) {
            return index.profiles.sorted { $0.createdAt > $1.createdAt }
        }
        // 兼容直接存数组的旧格式。
        if let list = try? decoder.decode([VoiceCloneProfile].self, from: data) {
            return list.sorted { $0.createdAt > $1.createdAt }
        }
        return []
    }

    // MARK: Create / Update / Delete

    /// 导入一条参考音频并创建档案。
    ///
    /// - Parameters:
    ///   - name: 展示名称；空时用音频文件名。
    ///   - audioURL: 用户选择的 wav/m4a。
    ///   - referenceText: 参考文本；空串表示待转写/待填写。
    @discardableResult
    func add(name: String, audioURL: URL, referenceText: String = "") throws -> VoiceCloneProfile {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty
            ? audioURL.deletingPathExtension().lastPathComponent
            : trimmedName
        guard !finalName.isEmpty else { throw VoiceCloneError.emptyName }

        try FileManager.default.createDirectory(
            at: Self.directory, withIntermediateDirectories: true)

        let id = UUID().uuidString
        let destination = Self.directory.appendingPathComponent("\(id).wav")
        let samples = try Self.loadReference(from: audioURL)
        try VoiceSynthesisAudio.writePCM16WAV(samples: samples, to: destination)

        let now = Date()
        let profile = VoiceCloneProfile(
            id: id,
            name: finalName,
            audioPath: destination.path,
            referenceText: referenceText.trimmingCharacters(in: .whitespacesAndNewlines),
            sampleRate: VoiceSynthesisAudio.targetSampleRate,
            duration: Double(samples.count) / Double(VoiceSynthesisAudio.targetSampleRate),
            createdAt: now,
            updatedAt: now
        )
        profiles.insert(profile, at: 0)
        try persist()
        lastError = nil
        return profile
    }

    /// 重命名。
    func rename(id: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VoiceCloneError.emptyName }
        try mutate(id: id) { profile in
            profile.name = trimmed
            profile.updatedAt = Date()
        }
    }

    /// 更新参考文本（例如自动转写结果）。
    func setReferenceText(id: String, text: String) throws {
        try mutate(id: id) { profile in
            profile.referenceText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.updatedAt = Date()
        }
    }

    /// 删除档案及参考音频。
    func delete(id: String) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw VoiceCloneError.notFound(id)
        }
        let profile = profiles.remove(at: index)
        try? FileManager.default.removeItem(at: profile.audioURL)
        try persist()
    }

    /// 替换某条档案的参考音频（重新导入）。
    func replaceAudio(id: String, audioURL: URL) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw VoiceCloneError.notFound(id)
        }
        let destination = Self.directory.appendingPathComponent("\(id).wav")
        let samples = try Self.loadReference(from: audioURL)
        try VoiceSynthesisAudio.writePCM16WAV(samples: samples, to: destination)
        profiles[index].audioPath = destination.path
        profiles[index].sampleRate = VoiceSynthesisAudio.targetSampleRate
        profiles[index].duration =
            Double(samples.count) / Double(VoiceSynthesisAudio.targetSampleRate)
        profiles[index].updatedAt = Date()
        try persist()
    }

    // MARK: Import

    /// 解码并转换参考音频（wav/m4a/aiff）到 16 kHz 单声道 float，超过上限截断。
    nonisolated static func loadReference(from url: URL) throws -> [Float] {
        let samples: [Float]
        do {
            samples = try VoiceSynthesisAudio.decodeMono16k(
                url: url, maxSeconds: maxReferenceSeconds)
        } catch {
            throw VoiceCloneError.audioUnreadable(url.path)
        }
        guard !samples.isEmpty else { throw VoiceCloneError.audioUnreadable(url.path) }
        return samples
    }

    // MARK: Persistence

    private func mutate(id: String, _ body: (inout VoiceCloneProfile) -> Void) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw VoiceCloneError.notFound(id)
        }
        body(&profiles[index])
        try persist()
    }

    private func persist() throws {
        do {
            try FileManager.default.createDirectory(
                at: Self.directory, withIntermediateDirectories: true)
            var updated = profiles
            updated.sort { $0.createdAt > $1.createdAt }
            let index = CloneIndex(version: 1, profiles: updated)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(index)
            try data.write(to: Self.indexFile, options: .atomic)
            profiles = updated
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw VoiceCloneError.saveFailed(error.localizedDescription)
        }
    }

    /// 索引文件顶层结构（便于以后加字段）。
    private struct CloneIndex: Codable {
        var version: Int
        var profiles: [VoiceCloneProfile]

        init(version: Int, profiles: [VoiceCloneProfile]) {
            self.version = version
            self.profiles = profiles
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            profiles = try container.decodeIfPresent([VoiceCloneProfile].self, forKey: .profiles) ?? []
        }
    }
}
