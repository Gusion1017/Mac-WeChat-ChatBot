import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 音色管理

/// CosyVoice3 音色管理器：内置三音色 + 用户新增音色（试听/使用/编辑/删除）。
///
/// 音色来源：本机 voices.json / 服务端 `/voices`；App 不内置任何音色。
struct CosyVoiceVoiceManagerSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast
    @Environment(\.dismiss) private var dismiss

    @State private var voices: [CosyVoiceManagedVoice] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var serviceReady = false
    @State private var editor: CosyVoiceVoiceEditorContext?
    @State private var pendingDelete: CosyVoiceManagedVoice?
    @State private var isDeleting = false
    @State private var isReloadingService = false
    @State private var isExporting = false

    private let voiceStore = CosyVoiceVoiceStore.shared
    private var voiceSettings: VoiceSettings { store.settings.bot.voiceSettings }
    private var customCount: Int { voices.filter(\.isCustom).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if isLoading && voices.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(L("正在读取本机音色库…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                errorState(loadError)
            } else {
                voiceList
            }
            footer
        }
        .padding(20)
        .frame(width: 680, height: 620)
        .task { await load() }
        .onDisappear { store.voicePreview.stop() }
        .sheet(item: $editor) { context in
            CosyVoiceVoiceEditorSheet(context: context) {
                Task { await load() }
            }
            .environment(store)
            .environment(toast)
        }
        .confirmationDialog(
            L("删除这个音色？"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("删除"), role: .destructive) {
                if let voice = pendingDelete { delete(voice) }
            }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("会删除该音色的参考音频、参考文本与清单条目，无法恢复；内置音色不可删除。"))
        }
    }

    // MARK: 头部 / 底部

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.wave.2.fill")
                .font(.system(size: 26))
                .foregroundStyle(Theme.violet)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(L("管理 CosyVoice3 音色"))
                        .font(.title3.weight(.semibold))
                }
                Text(L("App 不内置任何音色，音色仅保存在本机。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Button {
                    exportAllCustom()
                } label: {
                    Label(L("导出全部自定义音色…"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(customCount == 0 || isExporting)
                .help(customCount == 0
                    ? L("没有可导出的自定义音色")
                    : L("把本机全部自定义音色导出为一个 zip 备份"))
                Button {
                    editor = .add
                } label: {
                    Label(L("新增音色…"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button(L("关闭")) { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(L("App 不内置任何音色；内置音色只允许改名称/简介，自定义音色可编辑或删除。空音色时无法启动服务。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if !serviceReady {
                Text(L("服务未运行：改动将在下次启动服务后生效"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Button {
                    reloadService()
                } label: {
                    if isReloadingService {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label(L("重新加载服务音色"), systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isReloadingService)
                .help(L("让本地服务重新读取 voices.json（新增/编辑后自动执行）"))
            }
        }
        .padding(.top, 2)
    }

    // MARK: 列表

    @ViewBuilder
    private var voiceList: some View {
        if voices.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(voices) { voice in
                        voiceRow(voice)
                        Divider()
                    }
                }
            }
            .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(L("还没有任何音色"))
                .font(.callout.weight(.medium))
            Text(L("App 不内置任何音色。添加一段 5–30 秒的参考音频后，就可以用本机 CosyVoice3 合成语音。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button {
                editor = .add
            } label: {
                Label(L("添加音色…"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }

    private func voiceRow(_ voice: CosyVoiceManagedVoice) -> some View {
        let isSelected = voiceSettings.engine == .cosyVoice
            && voiceSettings.effectiveCosyVoiceVoiceID == voice.id
        let selection = selection(for: voice)
        let active = store.voicePreview.isActive(selection)
        let phase = store.voicePreview.phase
        let canPreview = serviceReady && voice.hasPromptWAV
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Theme.success : Color.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(voice.name)
                        .font(.callout.weight(.medium))
                    Text(voice.builtin ? L("内置") : L("自定义"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                if !voice.description.isEmpty {
                    Text(voice.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Label(durationLabel(voice), systemImage: "clock")
                    Label(modeLabel(voice), systemImage: "text.bubble")
                    Label(
                        voice.hasReferenceText
                            ? L("参考文本已就绪")
                            : L("cross-lingual（无参考文本）"),
                        systemImage: voice.hasReferenceText ? "checkmark.circle" : "waveform"
                    )
                    if !voice.hasPromptWAV {
                        Label(L("参考音频缺失"), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Theme.warning)
                    }
                    if voice.builtin {
                        Label(L("内置音色不可导出"), systemImage: "lock")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Button {
                    store.voicePreview.toggle(
                        voice: selection,
                        cosyVoice: VoicePreviewCosyVoiceOptions(
                            voiceID: voice.id,
                            endpoint: voiceSettings.effectiveCosyVoiceEndpoint,
                            speed: voiceSettings.effectiveCosyVoiceSpeed
                        )
                    ) { message in
                        toast.show(message, tone: .error)
                    }
                } label: {
                    if active, phase == .synthesizing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: active && phase == .playing
                            ? "stop.fill" : "play.fill")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canPreview)
                .help(canPreview ? L("试听") : L("服务未运行或缺少参考音频"))

                Button(L("使用")) {
                    use(voice)
                }
                .buttonStyle(.bordered)
                .tint(isSelected ? Theme.success : Theme.accent)
                .controlSize(.small)
                .disabled(isSelected)

                Button(L("编辑")) {
                    editor = .edit(voice)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    exportVoice(voice)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(voice.builtin || isExporting)
                .help(voice.builtin ? L("内置音色不可导出") : L("导出这个自定义音色"))

                Button(role: .destructive) {
                    pendingDelete = voice
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(voice.builtin || isDeleting)
                .help(voice.builtin ? L("内置音色不可删除") : L("删除"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isSelected ? Theme.success.opacity(0.05) : Color.clear)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(Theme.warning)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
            Button(L("重新加载")) {
                Task { await load() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 动作

    private func load() async {
        isLoading = true
        loadError = nil
        await CosyVoiceClient.shared.updateEndpoint(voiceSettings.effectiveCosyVoiceEndpoint)
        do {
            voices = try await voiceStore.list()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        let endpoint = voiceSettings.effectiveCosyVoiceEndpoint
        let state = await CosyVoiceRuntime.shared.quickStatus(endpoint: endpoint)
        serviceReady = state.isRunning
        isLoading = false
    }

    private func use(_ voice: CosyVoiceManagedVoice) {
        store.voicePreview.stop()
        store.settings.bot.voiceSettings.engine = .cosyVoice
        store.settings.bot.voiceSettings.cosyVoiceVoiceID = voice.id
        store.persist()
        toast.show(Lf("已切换到音色「%@」", voice.name), tone: .success)
    }

    private func delete(_ voice: CosyVoiceManagedVoice) {
        guard !isDeleting else { return }
        isDeleting = true
        pendingDelete = nil
        store.voicePreview.stop()
        Task {
            defer { isDeleting = false }
            do {
                try await voiceStore.delete(id: voice.id)
                if store.settings.bot.voiceSettings.engine == .cosyVoice,
                   store.settings.bot.voiceSettings.effectiveCosyVoiceVoiceID == voice.id {
                    // App 不内置音色：删掉当前音色后回到「未选择音色」，不回落到 girl。
                    store.settings.bot.voiceSettings.cosyVoiceVoiceID = ""
                    store.persist()
                }
                toast.show(L("已删除音色"), tone: .info)
                await load()
            } catch {
                toast.show(
                    (error as? LocalizedError)?.errorDescription ?? "\(error)",
                    tone: .error
                )
            }
        }
    }

    // MARK: 导出（仅自定义音色，个人备份）

    private func exportVoice(_ voice: CosyVoiceManagedVoice) {
        guard !voice.builtin else {
            toast.show(L("内置音色不可导出"), tone: .info)
            return
        }
        guard !isExporting,
              let destination = chooseExportDestination(
                defaultName: CosyVoiceVoiceStore.suggestedSingleFileName(for: voice),
                message: L("导出这个自定义音色")) else { return }
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let result = try await voiceStore.exportVoice(id: voice.id, to: destination)
                toast.show(Lf("已导出到 %@", result.zipURL.path), tone: .success)
            } catch {
                toast.show(
                    (error as? LocalizedError)?.errorDescription ?? "\(error)",
                    tone: .error
                )
            }
        }
    }

    private func exportAllCustom() {
        guard !isExporting else { return }
        guard customCount > 0 else {
            toast.show(L("没有可导出的自定义音色"), tone: .info)
            return
        }
        guard let destination = chooseExportDestination(
            defaultName: CosyVoiceVoiceStore.suggestedAllFileName(),
            message: L("导出全部自定义音色")) else { return }
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let result = try await voiceStore.exportAllCustom(to: destination)
                toast.show(
                    Lf("已导出 %d 个自定义音色到 %@", result.voiceIDs.count, result.zipURL.path),
                    tone: .success)
            } catch {
                toast.show(
                    (error as? LocalizedError)?.errorDescription ?? "\(error)",
                    tone: .error
                )
            }
        }
    }

    private func chooseExportDestination(defaultName: String, message: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        panel.message = message
        panel.prompt = L("导出")
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func reloadService() {
        guard !isReloadingService else { return }
        isReloadingService = true
        Task {
            defer { isReloadingService = false }
            if let warning = await voiceStore.reloadServiceIfRunning() {
                toast.show(warning, tone: .error)
            } else {
                toast.show(L("服务音色已重新加载"), tone: .success)
            }
            await load()
        }
    }

    // MARK: 展示辅助

    private func selection(for voice: CosyVoiceManagedVoice) -> VoiceSelection {
        VoiceSelection(
            engine: .cosyVoice,
            speed: voiceSettings.effectiveCosyVoiceSpeed,
            cosyVoiceVoiceID: voice.id
        )
    }

    private func durationLabel(_ voice: CosyVoiceManagedVoice) -> String {
        guard let duration = voice.duration, duration > 0 else { return L("时长未知") }
        return Lf("%.1f 秒", duration)
    }

    private func modeLabel(_ voice: CosyVoiceManagedVoice) -> String {
        voice.isCrossLingual
            ? L("cross-lingual")
            : L("zero-shot")
    }
}

// MARK: - 编辑上下文

enum CosyVoiceVoiceEditorContext: Identifiable {
    case add
    case edit(CosyVoiceManagedVoice)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let voice): return "edit-\(voice.id)"
        }
    }

    var voice: CosyVoiceManagedVoice? {
        if case .edit(let voice) = self { return voice }
        return nil
    }

    var isBuiltin: Bool { voice?.builtin == true }
}

// MARK: - 新增/编辑表单

/// 新增/编辑自定义音色；内置音色只展示参考音频/文本（只读），仅允许改名称/简介。
struct CosyVoiceVoiceEditorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast
    @Environment(\.dismiss) private var dismiss

    let context: CosyVoiceVoiceEditorContext
    let onSaved: @MainActor () -> Void

    @State private var name: String
    @State private var description: String
    @State private var referenceText: String
    @State private var crossLingual: Bool
    @State private var audioURL: URL?
    @State private var audioFileName: String
    @State private var isTranscribing = false
    @State private var isSaving = false
    @State private var errorText: String?
    @State private var importerPresented = false

    private let voiceStore = CosyVoiceVoiceStore.shared

    init(context: CosyVoiceVoiceEditorContext, onSaved: @escaping @MainActor () -> Void) {
        self.context = context
        self.onSaved = onSaved
        let voice = context.voice
        _name = State(initialValue: voice?.name ?? "")
        _description = State(initialValue: voice?.description ?? "")
        _referenceText = State(initialValue: voice?.referenceText ?? "")
        _crossLingual = State(initialValue: voice?.isCrossLingual ?? false)
        _audioURL = State(initialValue: nil)
        _audioFileName = State(initialValue: "")
    }

    private var isBuiltin: Bool { context.isBuiltin }
    private var isAdding: Bool {
        if case .add = context { return true }
        return false
    }
    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canSave: Bool {
        guard !isSaving, !trimmedName.isEmpty else { return false }
        if isAdding, audioURL == nil { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    infoSection
                    if !isBuiltin {
                        audioSection
                        referenceSection
                    } else {
                        builtinReadOnlySection
                    }
                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            actions
        }
        .padding(20)
        .frame(width: 560, height: 620)
        .fileImporter(
            isPresented: $importerPresented,
            allowedContentTypes: [.wav, .mpeg4Audio, .aiff],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { importAudio(url) }
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
        .onDisappear {
            // 表单里复制到临时目录的音频只是待保存源文件，关闭时清理。
            if let audioURL, audioURL.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isAdding ? "plus.circle.fill" : "pencil.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(Theme.violet)
            VStack(alignment: .leading, spacing: 2) {
                Text(isAdding ? L("新增 CosyVoice3 音色") : L("编辑 CosyVoice3 音色"))
                    .font(.title3.weight(.semibold))
                Text(isBuiltin
                    ? L("内置音色只允许修改名称和简介；参考音频/参考文本与官方参考音严格对应，不可替换。")
                    : L("参考音频需要 5–30 秒、单人说话；会转换为 24 kHz 单声道并做峰值归一。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L("音色信息"), symbol: "person.text.rectangle")
            TextField(L("名称（必填）"), text: $name)
                .textFieldStyle(.roundedBorder)
            TextField(L("简介（可选）"), text: $description)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L("参考音频"), symbol: "waveform")
            HStack(spacing: 8) {
                Button {
                    importerPresented = true
                } label: {
                    Label(
                        audioURL == nil ? L("选择音频…") : L("更换音频…"),
                        systemImage: "waveform.badge.plus"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if !audioFileName.isEmpty {
                    Text(audioFileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            Text(L("支持 wav / m4a / aiff；5–30 秒、单人说话、清晰无背景音乐。"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var referenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sectionTitle(L("参考文本"), symbol: "text.alignleft")
                Spacer()
                Button {
                    transcribeAudio()
                } label: {
                    if isTranscribing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label(L("自动转写"), systemImage: "waveform.and.mic")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(audioURL == nil || isTranscribing || isSaving)
                .help(audioURL == nil ? L("先选择参考音频") : L("用系统本地语音识别转写参考音频"))
            }
            TextEditor(text: $referenceText)
                .font(.callout)
                .frame(minHeight: 74, maxHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
            Toggle(isOn: $crossLingual) {
                Text(L("cross-lingual（只用参考音，不依赖参考文本）"))
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Text(L("建议填写与音频逐字对应的参考文本；留空或开启 cross-lingual 时只使用参考音，音色相似度可能略低。自动转写失败可手动填写。"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var builtinReadOnlySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L("参考音频与文本（只读）"), symbol: "lock.fill")
            HStack(spacing: 8) {
                Label(L("官方内置参考音"), systemImage: "waveform")
                Spacer()
                if let duration = context.voice?.duration, duration > 0 {
                    Text(Lf("%.1f 秒", duration))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            if let referenceText = context.voice?.referenceText, !referenceText.isEmpty {
                Text(referenceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text(L("该内置音色使用 cross-lingual 参考音，无参考文本。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Spacer()
            Button(L("取消")) { dismiss() }
                .buttonStyle(.bordered)
                .disabled(isSaving)
            Button {
                save()
            } label: {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Text(isAdding ? L("添加音色") : L("保存修改"))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)
            .help(canSave ? "" : L("请填写名称；新增时还需选择参考音频"))
        }
    }

    // MARK: 动作

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(L(title), systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func importAudio(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let ext = url.pathExtension.lowercased()
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("cosyvoice-voice-\(UUID().uuidString).\(ext.isEmpty ? "wav" : ext)")
            if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
            try FileManager.default.copyItem(at: url, to: temp)
            audioURL = temp
            audioFileName = url.lastPathComponent
            errorText = nil
        } catch {
            errorText = Lf("无法读取所选音频：%@", error.localizedDescription)
        }
    }

    private func transcribeAudio() {
        guard let audioURL, !isTranscribing else { return }
        isTranscribing = true
        errorText = nil
        Task {
            defer { isTranscribing = false }
            do {
                let transcription = try await store.voiceTranscription.transcribe(
                    fileURL: audioURL)
                if transcription.text.isEmpty {
                    errorText = L("没有识别到语音内容，请手动填写参考文本。")
                } else {
                    referenceText = transcription.text
                }
            } catch {
                errorText = Lf(
                    "自动转写失败：%@；可手动填写参考文本。",
                    (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        errorText = nil
        let name = trimmedName
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let referenceText = referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let crossLingual = crossLingual
        let audioURL = audioURL
        let context = context
        Task {
            defer { isSaving = false }
            do {
                switch context {
                case .add:
                    guard let audioURL else {
                        errorText = L("请先选择参考音频")
                        return
                    }
                    let voice = try await voiceStore.add(
                        name: name,
                        audioURL: audioURL,
                        referenceText: referenceText,
                        description: description,
                        crossLingual: crossLingual
                    )
                    store.settings.bot.voiceSettings.engine = .cosyVoice
                    store.settings.bot.voiceSettings.cosyVoiceVoiceID = voice.id
                    store.persist()
                    toast.show(L("音色已添加"), tone: .success)
                case .edit(let voice):
                    _ = try await voiceStore.update(
                        id: voice.id,
                        name: name,
                        description: description,
                        referenceText: voice.builtin ? nil : referenceText,
                        audioURL: voice.builtin ? nil : audioURL,
                        crossLingual: voice.builtin ? nil : crossLingual
                    )
                    toast.show(L("音色已保存"), tone: .success)
                }
                onSaved()
                dismiss()
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }
}
