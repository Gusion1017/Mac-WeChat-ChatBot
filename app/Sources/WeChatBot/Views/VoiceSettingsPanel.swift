import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 语音设置面板（2026-10-26）。
///
/// 从「设置 → 语音」抽出为可复用视图，同时用于：
/// - 机器人页（BotView）的「语音」区；
/// - 设置页的「语音」分类（保持原入口）。
struct VoiceSettingsPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast

    @State private var voiceAssetStatus: VoiceAssetStatus = .unknown
    @State private var isRefreshingVoiceAsset = false
    @State private var isInstallingVoiceAsset = false
    @State private var voiceStatusTick = Date()
    @State private var voiceSetupPresented = false
    @State private var isImportingVoiceClone = false

    var body: some View {

        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            SettingsSection(
                title: "语音转写",
                footer: "使用 macOS 26 本地语音识别（SpeechAnalyzer），音频与转写只保存在本机，日志不打印转写原文。"
            ) {
                SettingsRow(
                    title: "转写收到的语音",
                    subtitle: "语音消息自动获取音频并转写，用于气泡展示、AI 回复与记忆",
                    symbol: "waveform",
                    tint: Theme.violet
                ) {
                    Toggle(L("转写收到的语音"), isOn: bind(\.bot.voiceSettings.transcriptionEnabled))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(
                    title: "气泡显示转写",
                    subtitle: "关闭后气泡只显示「语音 Ns」，转写仍用于 AI 回复",
                    symbol: "text.bubble",
                    tint: .secondary
                ) {
                    Toggle(L("气泡显示转写"), isOn: bind(\.bot.voiceSettings.showTranscriptInBubble))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(
                    title: "转写写入记忆与搜索",
                    subtitle: "关闭后转写只用于即时回复，不进入长期记忆总结",
                    symbol: "brain",
                    tint: Theme.info
                ) {
                    Toggle(L("转写写入记忆与搜索"), isOn: bind(\.bot.voiceSettings.saveTranscriptToMemory))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(
                    title: "转写资源",
                    subtitle: voiceAssetDetail,
                    symbol: "arrow.down.circle",
                    tint: voiceAssetTint
                ) {
                    HStack(spacing: 8) {
                        PillLabel(
                            text: L(voiceAssetStatus.label),
                            color: voiceAssetTint,
                            symbol: voiceAssetStatus == .installed ? "checkmark.circle.fill" : "exclamationmark.circle"
                        )
                        Button {
                            Task { await refreshVoiceAssetStatus() }
                        } label: {
                            if isRefreshingVoiceAsset {
                                ProgressView().controlSize(.mini)
                            } else {
                                Label(L("刷新"), systemImage: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(isRefreshingVoiceAsset)
                    }
                }
            }

            if voiceAssetStatus == .downloadable {
                VStack(alignment: .leading, spacing: 10) {
                    InlineNotice(
                        kind: .info,
                        title: "需要安装中文语音资源",
                        message: "系统支持中文语音识别但资源尚未安装。可直接在 App 内下载，无需手动打开系统设置。"
                    )
                    Button {
                        installVoiceAsset()
                    } label: {
                        HStack(spacing: 7) {
                            if isInstallingVoiceAsset { ProgressView().controlSize(.small) }
                            Label(isInstallingVoiceAsset ? L("正在下载语音资源…") : L("下载中文语音资源"), systemImage: "arrow.down.circle.fill")
                        }
                    }
                    .buttonStyle(.glass)
                    .disabled(isInstallingVoiceAsset)
                }
            } else if voiceAssetStatus == .unsupported {
                InlineNotice(
                    kind: .warning,
                    title: "当前系统不支持本地中文语音识别",
                    message: "需要 macOS 26 及以上并支持 SpeechTranscriber 的中文语言包；转写将不可用，但文字聊天不受影响。"
                )
            }

            SettingsSection(
                title: "语音回复",
                footer: "仅短回复会转语音：「对等」只对语音消息回语音。发送失败（如未捕获语音句柄、上传链路未就绪）会安全降级为文字（不会重复发送）。"
            ) {
                SettingsRow(
                    title: "允许语音回复",
                    subtitle: "按概率把部分文字回复改成语音；会话可单独覆盖",
                    symbol: "speaker.wave.2",
                    tint: Theme.accent
                ) {
                    Toggle(L("允许语音回复"), isOn: bind(\.bot.voiceSettings.replyEnabled))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(
                    title: "语音回复概率",
                    subtitle: "每条符合条件的回复按概率转语音",
                    symbol: "percent",
                    tint: Theme.info
                ) {
                    HStack(spacing: 10) {
                        Slider(value: bind(\.bot.voiceSettings.replyProbability), in: 0...1, step: 0.05)
                            .frame(width: 180)
                            .labelsHidden()
                        Text("\(Int((store.settings.bot.voiceSettings.effectiveReplyProbability * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                SettingsDivider()
                SettingsRow(
                    title: "对等回复",
                    subtitle: "只有收到语音消息时才用语音回复",
                    symbol: "arrow.left.arrow.right",
                    tint: .secondary
                ) {
                    Toggle(L("对等回复"), isOn: bind(\.bot.voiceSettings.mirrorIncomingVoice))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(
                    title: "仅短回复发语音",
                    subtitle: "长回复继续发文字，避免语音过长",
                    symbol: "text.alignleft",
                    tint: .secondary
                ) {
                    Toggle(L("仅短回复发语音"), isOn: bind(\.bot.voiceSettings.shortReplyOnly))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                if store.settings.bot.voiceSettings.shortReplyOnly {
                    SettingsDivider()
                    SettingsRow(
                        title: "短回复字数阈值",
                        subtitle: "超过该字数的回复一律发文字",
                        symbol: "character.cursor.ibeam",
                        tint: .secondary
                    ) {
                        Stepper(
                            value: bind(\.bot.voiceSettings.shortReplyMaxChars),
                            in: 20...300,
                            step: 10
                        ) {
                            Text(Lf("%d 字", store.settings.bot.voiceSettings.effectiveShortReplyMaxChars))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .fixedSize()
                    }
                }
                SettingsDivider()
                SettingsRow(
                    title: "语音最长时长",
                    subtitle: "超过上限时按下方策略处理（语音回复用）",
                    symbol: "timer",
                    tint: Theme.warning
                ) {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { Double(store.settings.bot.voiceSettings.effectiveMaxVoiceSeconds) },
                                set: { store.settings.bot.voiceSettings.maxVoiceSeconds = Int($0.rounded()); store.persist() }
                            ),
                            in: 5...60,
                            step: 5
                        )
                        .frame(width: 180)
                        .labelsHidden()
                        Text("\(store.settings.bot.voiceSettings.effectiveMaxVoiceSeconds)s")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                SettingsDivider()
                SettingsRow(
                    title: "超限处理",
                    subtitle: "改发文字：直接降级；按句截断：切到不超限后重新合成",
                    symbol: "scissors",
                    tint: Theme.warning
                ) {
                    Picker(L("超限处理"), selection: bind(\.bot.voiceSettings.overLimit)) {
                        ForEach(VoiceOverLimit.allCases) { limit in
                            Text(limit.label).tag(limit)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 210)
                }
            }

            SettingsSection(
                title: L("语音发送状态"),
                footer: L("首次启用语音回复或微信重启后，需要在本机微信手动发一条文字和一条语音以捕获发送句柄；bridge 启动后的登录稳定期内不会发送语音。")
            ) {
                SettingsRow(
                    title: L("发送通道"),
                    subtitle: voiceRuntimeSummary,
                    symbol: voiceRuntimeSymbol,
                    tint: voiceRuntimeTint
                ) {
                    HStack(spacing: 8) {
                        if store.voiceRuntimeStatus.remainingWarmupSeconds(now: voiceStatusTick) > 0 {
                            ProgressView().controlSize(.small)
                        }
                        Button(L("重新检测")) {
                            Task {
                                await store.refreshVoiceStatus()
                                voiceStatusTick = Date()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                SettingsDivider()
                voiceSeedRow(title: L("文本发送句柄"), ready: store.voiceRuntimeStatus.textSeed)
                SettingsDivider()
                voiceSeedRow(title: L("语音发送句柄"), ready: store.voiceRuntimeStatus.voiceSeed)
                if store.settings.bot.voiceSettings.replyEnabled,
                   store.voiceRuntimeStatus.configured,
                   !store.voiceRuntimeStatus.canSendVoice(now: voiceStatusTick) {
                    SettingsDivider()
                    SettingsRow(
                        title: L("需要捕获发送句柄"),
                        subtitle: L("点开查看步骤；捕获完成前语音回复会自动降级文字"),
                        symbol: "waveform.badge.exclamationmark",
                        tint: Theme.warning
                    ) {
                        Button(L("查看步骤…")) { voiceSetupPresented = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
            }

            SettingsSection(
                title: "语音引擎（TTS）",
                footer: "模型首次使用时按需下载到本机；下载前必须同意。首次启用语音发送或微信重启后，请先在 Mac 微信手动发一条文字 + 一条语音以捕获发送句柄（bridge 重启会自动恢复）；发送失败会自动降级为文字。"
            ) {
                SettingsRow(
                    title: "合成引擎",
                    subtitle: "Kokoro 内置音色；ZipVoice 使用克隆音色（需导入参考音频）",
                    symbol: "waveform.circle",
                    tint: Theme.violet
                ) {
                    Picker(L("合成引擎"), selection: bind(\.bot.voiceSettings.engine)) {
                        ForEach([VoiceEngineKind.kokoro, .zipvoiceClone], id: \.self) { kind in
                            Text(voiceEngineLabel(kind)).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                }
                if store.settings.bot.voiceSettings.engine == .zipvoiceClone {
                    SettingsDivider()
                    SettingsRow(
                        title: "克隆音色档案 ID",
                        subtitle: "在语音模型管理中导入参考音频后填写（留空则不可用）",
                        symbol: "person.wave.2",
                        tint: .secondary
                    ) {
                        TextField(L("克隆音色档案 ID"), text: cloneIDBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }
                } else {
                    SettingsDivider()
                    SettingsRow(
                        title: "Kokoro 音色",
                        subtitle: "音色编号（以模型说明为准，0 为默认音色）",
                        symbol: "person.2.wave.2",
                        tint: .secondary
                    ) {
                        Stepper(
                            value: bind(\.bot.voiceSettings.kokoroSpeakerID),
                            in: 0...200,
                            step: 1
                        ) {
                            Text("#\(store.settings.bot.voiceSettings.kokoroSpeakerID)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .fixedSize()
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "Kokoro 语速",
                        subtitle: "0.5×–2.0×，默认 1.0×",
                        symbol: "speedometer",
                        tint: .secondary
                    ) {
                        HStack(spacing: 10) {
                            Slider(value: bind(\.bot.voiceSettings.kokoroSpeed), in: 0.5...2.0, step: 0.05)
                                .frame(width: 180)
                                .labelsHidden()
                            Text(String(format: "%.2f×", store.settings.bot.voiceSettings.effectiveKokoroSpeed))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                }
                SettingsDivider()
                SettingsRow(
                    title: "允许下载语音模型",
                    subtitle: "首次使用前需要同意；模型较大（Kokoro 约 365MB、ZipVoice 约 109MB）",
                    symbol: "arrow.down.circle",
                    tint: Theme.warning
                ) {
                    Toggle(L("允许下载语音模型"), isOn: bind(\.bot.voiceSettings.modelDownloadConsent))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            SettingsSection(
                title: L("语音模型与克隆音色"),
                footer: L("模型按需下载到本机，不入 App 包体；下载前需先允许。ZipVoice 克隆需要参考音频与参考文本（导入后自动用本地语音识别转写，可手动修正）。")
            ) {
                ForEach(Array(VoiceModelKind.allCases), id: \.rawValue) { kind in
                    let spec = VoiceModelStore.catalog.first { $0.kind == kind }
                    let state = VoiceModelStore.shared.state(for: kind)
                    SettingsRow(
                        title: spec?.displayName ?? kind.rawValue,
                        subtitle: "\(state.displayText) · 约 \(ByteCountFormatter.string(fromByteCount: spec?.approximateBytes ?? 0, countStyle: .file))",
                        symbol: state.isReady ? "checkmark.circle.fill" : "arrow.down.circle",
                        tint: state.isReady ? Theme.success : Theme.warning
                    ) {
                        HStack(spacing: 8) {
                            if state.isBusy {
                                ProgressView(value: state.fraction)
                                    .frame(width: 90)
                            }
                            if state.isReady {
                                Button(L("删除")) {
                                    do {
                                        try VoiceModelStore.shared.delete(kind)
                                    } catch {
                                        toast.show(error.localizedDescription, tone: .error)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            } else {
                                Button(L("下载")) {
                                    downloadVoiceModels([kind])
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(state.isBusy || VoiceModelStore.shared.isDownloading)
                            }
                        }
                    }
                    SettingsDivider()
                }
                SettingsRow(
                    title: L("下载全部语音模型"),
                    subtitle: L("Kokoro 约 365MB、ZipVoice 约 109MB、声码器约 54MB；网络较慢时请耐心等待"),
                    symbol: "arrow.down.circle",
                    tint: Theme.violet
                ) {
                    Button(L("下载全部")) {
                        downloadVoiceModels(VoiceModelKind.allCases)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(VoiceModelStore.shared.isDownloading)
                }
                SettingsDivider()
                SettingsRow(
                    title: L("克隆音色档案"),
                    subtitle: VoiceCloneStore.shared.profiles.isEmpty
                        ? L("还没有克隆音色；导入 10–30 秒参考音频即可")
                        : Lf("共 %d 个克隆音色", VoiceCloneStore.shared.profiles.count),
                    symbol: "person.wave.2",
                    tint: .secondary
                ) {
                    Button(L("导入参考音频…")) {
                        importVoiceClone()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isImportingVoiceClone)
                }
                if !VoiceCloneStore.shared.profiles.isEmpty {
                    ForEach(VoiceCloneStore.shared.profiles) { profile in
                        SettingsDivider()
                        SettingsRow(
                            title: profile.name,
                            subtitle: "\(Int(profile.duration.rounded()))s · \(profile.hasReferenceText ? L("参考文本已填写") : L("缺少参考文本（克隆不可用）"))",
                            symbol: store.settings.bot.voiceSettings.cloneID == profile.id
                                ? "checkmark.circle.fill" : "circle",
                            tint: store.settings.bot.voiceSettings.cloneID == profile.id ? Theme.success : .secondary
                        ) {
                            HStack(spacing: 8) {
                                Button(L("使用")) {
                                    store.settings.bot.voiceSettings.engine = .zipvoiceClone
                                    store.settings.bot.voiceSettings.cloneID = profile.id
                                    store.persist()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                Button(L("删除")) {
                                    do {
                                        try VoiceCloneStore.shared.delete(id: profile.id)
                                        if store.settings.bot.voiceSettings.cloneID == profile.id {
                                            store.settings.bot.voiceSettings.cloneID = nil
                                            store.persist()
                                        }
                                    } catch {
                                        toast.show(error.localizedDescription, tone: .error)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
        .task { await refreshVoiceAssetStatus() }
        .task {
            while !Task.isCancelled {
                await store.refreshVoiceStatus()
                voiceStatusTick = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: store.settings.bot.voiceSettings.replyEnabled) { _, enabled in
            guard enabled else { return }
            Task {
                await store.refreshVoiceStatus()
                voiceStatusTick = Date()
                if store.voiceRuntimeStatus.configured,
                   !store.voiceRuntimeStatus.canSendVoice() {
                    voiceSetupPresented = true
                }
            }
        }
        .sheet(isPresented: $voiceSetupPresented) {
            VoiceHandleSetupSheet()
                .environment(store)
        }
    }
    /// 下载语音模型（必须已有用户同意；未同意时提示，不自动改设置）。
    private func downloadVoiceModels(_ kinds: [VoiceModelKind]) {
        guard store.settings.bot.voiceSettings.modelDownloadConsent else {
            toast.show(L("请先打开「允许下载语音模型」"), tone: .warning)
            return
        }
        Task {
            do {
                try await VoiceModelStore.shared.download(kinds, consent: true)
                toast.show(L("语音模型下载完成"), tone: .success)
            } catch {
                toast.show(error.localizedDescription, tone: .error)
            }
        }
    }

    /// 导入克隆参考音频：导入 → 本地转写参考文本（失败可稍后手动补）→ 自动选中。
    private func importVoiceClone() {
        guard !isImportingVoiceClone else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L("选择 10–30 秒、单人说话的参考音频（wav/m4a）")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isImportingVoiceClone = true
        Task {
            defer { Task { @MainActor in isImportingVoiceClone = false } }
            do {
                let name = url.deletingPathExtension().lastPathComponent
                let profile = try VoiceCloneStore.shared.add(name: name, audioURL: url)
                if let transcription = try? await store.voiceTranscription.transcribe(
                    fileURL: profile.audioURL
                ), !transcription.text.isEmpty {
                    try? VoiceCloneStore.shared.setReferenceText(id: profile.id, text: transcription.text)
                }
                store.settings.bot.voiceSettings.engine = .zipvoiceClone
                store.settings.bot.voiceSettings.cloneID = profile.id
                store.persist()
                toast.show(L("已导入克隆音色"), tone: .success)
            } catch {
                toast.show(error.localizedDescription, tone: .error)
            }
        }
    }


    private var voiceRuntimeSummary: String {
        let status = store.voiceRuntimeStatus
        if status.available, status.remainingWarmupSeconds(now: voiceStatusTick) > 0 {
            return Lf("预热中：约 %d 秒后可发送语音", status.remainingWarmupSeconds(now: voiceStatusTick))
        }
        return status.summary(now: voiceStatusTick)
    }

    private var voiceRuntimeSymbol: String {
        store.voiceRuntimeStatus.canSendVoice(now: voiceStatusTick)
            ? "checkmark.circle.fill" : "waveform.badge.exclamationmark"
    }

    private var voiceRuntimeTint: Color {
        if store.voiceRuntimeStatus.canSendVoice(now: voiceStatusTick) { return Theme.success }
        if store.voiceRuntimeStatus.remainingWarmupSeconds(now: voiceStatusTick) > 0 { return Theme.warning }
        return Theme.danger
    }

    @ViewBuilder
    private func voiceSeedRow(title: String, ready: Bool) -> some View {
        SettingsRow(
            title: title,
            subtitle: ready ? L("已捕获") : L("未捕获"),
            symbol: ready ? "checkmark.circle.fill" : "circle",
            tint: ready ? Theme.success : .secondary
        ) {
            Text(ready ? L("就绪") : L("待捕获"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var voiceAssetDetail: String {
        switch voiceAssetStatus {
        case .installed: return "已安装中文语音资源，可以离线转写"
        case .downloadable: return "系统支持但资源未安装，可直接在 App 内下载"
        case .unsupported: return "当前系统或语言包不支持本地中文语音识别"
        case .unknown: return "点击「刷新」检查本机语音资源状态"
        }
    }

    private var voiceAssetTint: Color {
        switch voiceAssetStatus {
        case .installed: return Theme.success
        case .downloadable: return Theme.warning
        case .unsupported: return Theme.danger
        case .unknown: return .secondary
        }
    }

    private func refreshVoiceAssetStatus() async {
        guard !isRefreshingVoiceAsset else { return }
        isRefreshingVoiceAsset = true
        defer { isRefreshingVoiceAsset = false }
        voiceAssetStatus = await store.voiceAssetStatus()
    }

    /// 引擎展示名：不依赖 `VoiceEngineKind` 是否 CaseIterable/Identifiable。
    private func voiceEngineLabel(_ kind: VoiceEngineKind) -> String {
        if kind == .kokoro { return "Kokoro" }
        if kind == .zipvoiceClone { return L("ZipVoice 克隆") }
        return kind.rawValue
    }

    /// 克隆音色档案 ID：空字符串 ↔ nil。
    private var cloneIDBinding: Binding<String> {
        Binding(
            get: { store.settings.bot.voiceSettings.cloneID ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                store.settings.bot.voiceSettings.cloneID = trimmed.isEmpty ? nil : trimmed
                store.persist()
            }
        )
    }

    private func bind<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { newValue in
                store.settings[keyPath: keyPath] = newValue
                store.persist()
            }
        )
    }

    /// 直接下载系统中文语音资源（无需用户手动去系统设置）。
    private func installVoiceAsset() {
        guard !isInstallingVoiceAsset else { return }
        isInstallingVoiceAsset = true
        Task {
            defer { Task { @MainActor in isInstallingVoiceAsset = false } }
            do {
                try await store.voiceTranscription.installAssets()
                voiceAssetStatus = await store.voiceAssetStatus()
                toast.show(L("中文语音资源已安装"), tone: .success)
            } catch {
                toast.show(error.localizedDescription, tone: .error)
            }
        }
    }
}
