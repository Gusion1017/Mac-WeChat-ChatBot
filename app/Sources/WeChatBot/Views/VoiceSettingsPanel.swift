import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 语音设置面板（2026-10-26，2026-10-27 精简）。
///
/// 唯一入口是「机器人 → 语音」：2026-10-27 移除了设置页里重复的「语音」分类，
/// 面板本身与复用方式不变。本轮把原来分散的
/// 「语音引擎（TTS）」「语音模型与克隆音色」合并为「语音引擎与音色」：
/// - 音色按官方 sid → name 映射展示（103 个，可搜索/分组/试听），不再让用户手填编号；
/// - 模型只展示当前引擎需要的那一份，下载/取消/重试/删除都在同一行，
///   去掉「下载全部」与三个独立模型行的重复信息；
/// - 克隆音色用档案选择器替代「克隆音色档案 ID」文本框；
/// - 试听复用真实合成服务，本地播放，不发往微信；
/// - 语音发送状态只在开启语音回复时展示，并去掉与摘要重复的两行句柄明细。
struct VoiceSettingsPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast

    @State private var voiceAssetStatus: VoiceAssetStatus = .unknown
    @State private var isRefreshingVoiceAsset = false
    @State private var isInstallingVoiceAsset = false
    @State private var voiceStatusTick = Date()
    @State private var voiceSetupPresented = false
    @State private var isImportingVoiceClone = false
    @State private var voicePickerPresented = false
    @State private var pendingModelDownload = false
    @State private var pendingModelDelete = false
    @State private var clonePendingDelete: String?

    // CosyVoice3：服务状态/安装状态用 1s 轮询刷新（actor 内不驱动 UI）。
    // App 不内置任何音色：列表只来自本机 voices.json / 服务端 /voices，空库显示「未添加音色」。
    @State private var cosyVoiceRuntime = CosyVoiceRuntimeSnapshot.initial
    @State private var cosyVoiceInstall = CosyVoiceInstallSnapshot.initial
    @State private var cosyVoiceVoices: [CosyVoiceVoice] = []
    @State private var cosyVoiceVoicesLoaded = false
    @State private var cosyVoiceEndpointDraft = ""
    @State private var pendingCosyVoiceInstall = false
    @State private var pendingCosyVoiceDelete = false
    @State private var didAttemptCosyVoiceAutoStart = false
    @State private var voiceManagerPresented = false

    private var voiceSettings: VoiceSettings { store.settings.bot.voiceSettings }

    /// Kokoro 语速三档快捷（默认 1.25×）。
    private static let kokoroSpeedPresets: [Double] = [1.0, 1.25, 1.5]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            transcriptionSection
            replySection
            engineSection
            if voiceSettings.replyEnabled {
                sendStatusSection
            }
        }
        .task {
            VoiceModelStore.shared.refresh()
            await refreshVoiceAssetStatus()
        }
        .task(id: voiceSettings.replyEnabled) { await pollVoiceStatus() }
        .task(id: voiceSettings.engine) { await pollCosyVoice() }
        .onChange(of: voiceSettings.replyEnabled) { _, enabled in
            guard enabled else {
                store.voicePreview.stop()
                return
            }
            Task {
                await store.refreshVoiceStatus()
                voiceStatusTick = Date()
                // 首次开启（或微信重启后句柄失效）时先检测一次；只要当前不能发送语音，
                // 就弹出捕获引导。bridge 未连接/R3 未启用也提示，由弹窗解释当前状态。
                if !store.voiceRuntimeStatus.canSendVoice() {
                    voiceSetupPresented = true
                }
            }
        }
        // 音色/语速/引擎变化时立刻停掉旧试听，避免“听到的是上一个音色”。
        .onChange(of: voiceSettings.engine) { _, _ in store.voicePreview.stop() }
        .onChange(of: voiceSettings.kokoroSpeakerID) { _, _ in store.voicePreview.stop() }
        .onChange(of: voiceSettings.kokoroSpeed) { _, _ in store.voicePreview.stop() }
        .onChange(of: voiceSettings.cloneID) { _, _ in store.voicePreview.stop() }
        .onChange(of: voiceSettings.cosyVoiceVoiceID) { _, _ in store.voicePreview.stop() }
        .onChange(of: voiceSettings.cosyVoiceSpeed) { _, _ in store.voicePreview.stop() }
        .onDisappear { store.voicePreview.stop() }
        .sheet(isPresented: $voicePickerPresented) {
            KokoroVoicePickerSheet()
                .environment(store)
                .environment(toast)
        }
        .sheet(isPresented: $voiceSetupPresented) {
            VoiceHandleSetupSheet()
                .environment(store)
        }
        .confirmationDialog(
            L("下载语音模型"),
            isPresented: $pendingModelDownload,
            titleVisibility: .visible
        ) {
            Button(L("同意并下载")) {
                store.settings.bot.voiceSettings.modelDownloadConsent = true
                store.persist()
                startModelDownload()
            }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(modelDownloadMessage)
        }
        .confirmationDialog(
            L("删除语音模型？"),
            isPresented: $pendingModelDelete,
            titleVisibility: .visible
        ) {
            Button(L("删除"), role: .destructive) {
                deleteCurrentEngineModels()
            }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("删除后再次使用语音回复需要重新下载模型；已生成的语音文件不受影响。"))
        }
        .confirmationDialog(
            L("删除克隆音色？"),
            isPresented: Binding(
                get: { clonePendingDelete != nil },
                set: { if !$0 { clonePendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("删除"), role: .destructive) {
                deletePendingClone()
            }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("参考音频与参考文本会一并删除，无法恢复。"))
        }
        .confirmationDialog(
            L("下载并安装 CosyVoice3"),
            isPresented: $pendingCosyVoiceInstall,
            titleVisibility: .visible
        ) {
            Button(L("同意并安装")) { startCosyVoiceInstall() }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("将下载 CosyVoice3 运行环境（依赖约 2–3GB）与模型（约 5–7GB），合计约 8GB，保存在本机。安装可能持续数十分钟，可随时取消；取消后已下载内容会保留。"))
        }
        .confirmationDialog(
            L("删除 CosyVoice3？"),
            isPresented: $pendingCosyVoiceDelete,
            titleVisibility: .visible
        ) {
            Button(L("删除"), role: .destructive) { deleteCosyVoiceInstall() }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("会删除运行环境、模型与参考音（约 8GB），需要时可重新安装。已生成的语音文件不受影响。"))
        }
        .sheet(isPresented: $voiceManagerPresented, onDismiss: {
            Task { await refreshCosyVoiceState(loadVoices: true) }
        }) {
            CosyVoiceVoiceManagerSheet()
                .environment(store)
                .environment(toast)
        }
    }

    // MARK: - 转写

    private var transcriptionSection: some View {
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
                subtitle: voiceAssetSubtitle,
                symbol: "arrow.down.circle",
                tint: voiceAssetTint
            ) {
                HStack(spacing: 8) {
                    PillLabel(
                        text: L(voiceAssetStatus.label),
                        color: voiceAssetTint,
                        symbol: voiceAssetStatus == .installed
                            ? "checkmark.circle.fill" : "exclamationmark.circle"
                    )
                    if isInstallingVoiceAsset {
                        ProgressView().controlSize(.mini)
                    } else if voiceAssetStatus == .downloadable {
                        Button {
                            installVoiceAsset()
                        } label: {
                            Label(L("下载"), systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    Button {
                        Task { await refreshVoiceAssetStatus() }
                    } label: {
                        if isRefreshingVoiceAsset {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRefreshingVoiceAsset || isInstallingVoiceAsset)
                    .help(L("刷新"))
                }
            }
        }
    }

    private var voiceAssetSubtitle: String {
        switch voiceAssetStatus {
        case .installed: return L("已安装，可离线转写")
        case .downloadable: return L("系统支持但资源未安装，可直接在 App 内下载")
        case .unsupported: return L("当前系统不支持本地中文识别，文字聊天不受影响")
        case .unknown: return L("点击刷新检查本机语音资源状态")
        }
    }

    // MARK: - 回复策略

    private var replySection: some View {
        SettingsSection(
            title: "语音回复",
            footer: "只对满足条件的文字回复改发语音；发送失败（句柄未就绪、上传失败等）会自动改发文字，不会重复发送。"
        ) {
            SettingsRow(
                title: "允许语音回复",
                subtitle: "按概率把部分文字回复改成语音",
                symbol: "speaker.wave.2",
                tint: Theme.accent
            ) {
                Toggle(L("允许语音回复"), isOn: bind(\.bot.voiceSettings.replyEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if voiceSettings.replyEnabled {
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
                        Text("\(Int((voiceSettings.effectiveReplyProbability * 100).rounded()))%")
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
                if voiceSettings.shortReplyOnly {
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
                            Text(Lf("%d 字", voiceSettings.effectiveShortReplyMaxChars))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .fixedSize()
                    }
                }
                SettingsDivider()
                SettingsRow(
                    title: "语音最长时长",
                    subtitle: "超过上限时按下方策略处理",
                    symbol: "timer",
                    tint: Theme.warning
                ) {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { Double(voiceSettings.effectiveMaxVoiceSeconds) },
                                set: {
                                    store.settings.bot.voiceSettings.maxVoiceSeconds = Int($0.rounded())
                                    store.persist()
                                }
                            ),
                            in: 5...60,
                            step: 5
                        )
                        .frame(width: 180)
                        .labelsHidden()
                        Text("\(voiceSettings.effectiveMaxVoiceSeconds)s")
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
                SettingsDivider()
                SettingsRow(
                    title: "语音回复免拟人化延迟",
                    subtitle: "改为语音时直接发送，不再等待「拟人化」随机延迟，避免整体等待过久",
                    symbol: "bolt",
                    tint: Theme.accent
                ) {
                    Toggle(
                        L("语音回复免拟人化延迟"),
                        isOn: bind(\.bot.voiceSettings.skipHumanizeDelayForVoiceReply)
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - 引擎与音色

    private var engineSection: some View {
        SettingsSection(
            title: "语音引擎与音色",
            footer: "Kokoro / ZipVoice 模型按需下载到本机；CosyVoice3 为可选高保真引擎，运行环境与模型需单独安装（约 8GB）。语音合成全部在本机离线完成。发布版 App 内置 CosyVoice3 安装/启动脚本；若脚本缺失，可用 WECHATAI_COSYVOICE_SCRIPT / WECHATAI_COSYVOICE_INSTALL_SCRIPT 指定路径。App 不内置任何音色：音色仅保存在本机，需在「管理音色…」中添加。"
        ) {
            SettingsRow(
                title: "合成引擎",
                subtitle: engineSubtitle,
                symbol: "waveform.circle",
                tint: Theme.violet
            ) {
                Picker(L("合成引擎"), selection: engineBinding) {
                    Text("Kokoro").tag(VoiceEngineKind.kokoro)
                    Text(L("ZipVoice 克隆")).tag(VoiceEngineKind.zipvoiceClone)
                    Text("CosyVoice3").tag(VoiceEngineKind.cosyVoice)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 330)
            }
            SettingsDivider()
            switch voiceSettings.engine {
            case .kokoro:
                kokoroVoiceRow
                SettingsDivider()
                kokoroSpeedRow
                SettingsDivider()
                modelRow
            case .zipvoiceClone:
                cloneVoiceRow
                SettingsDivider()
                cloneSpeedRow
                SettingsDivider()
                modelRow
            case .cosyVoice:
                cosyVoiceServiceRow
                SettingsDivider()
                cosyVoiceInstallRow
                SettingsDivider()
                cosyVoiceVoiceRow
                SettingsDivider()
                cosyVoiceSpeedRow
                SettingsDivider()
                cosyVoiceAutoStartRow
                SettingsDivider()
                cosyVoiceEndpointRow
            }
        }
    }

    private var engineSubtitle: String {
        switch voiceSettings.engine {
        case .kokoro: return L("内置 103 个中英文音色，可逐个试听")
        case .zipvoiceClone: return L("用参考音频克隆音色，需要参考文本")
        case .cosyVoice: return L("本地大模型（Fun-CosyVoice3-0.5B），需下载约 8GB；首次启动与合成较慢（非实时，适合高质量语音）")
        }
    }

    private var kokoroVoiceRow: some View {
        SettingsRow(
            title: "音色",
            subtitle: kokoroVoiceSubtitle,
            symbol: "person.wave.2",
            tint: .secondary
        ) {
            HStack(spacing: 8) {
                previewButton(
                    selection: currentSelection,
                    enabled: VoiceSynthesisService.isReady(.kokoro)
                )
                Button {
                    store.voicePreview.stop()
                    voicePickerPresented = true
                } label: {
                    Label(L("选择…"), systemImage: "list.bullet")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var cloneVoiceRow: some View {
        SettingsRow(
            title: "克隆音色",
            subtitle: cloneSubtitle,
            symbol: "person.wave.2",
            tint: .secondary
        ) {
            HStack(spacing: 8) {
                previewButton(
                    selection: currentSelection,
                    enabled: selectedCloneProfile?.hasReferenceText == true
                        && VoiceSynthesisService.isReady(.zipvoiceClone),
                    disabledHint: clonePreviewDisabledHint
                )
                if VoiceCloneStore.shared.profiles.isEmpty {
                    Button {
                        importVoiceClone()
                    } label: {
                        if isImportingVoiceClone {
                            ProgressView().controlSize(.mini)
                        } else {
                            Label(L("导入…"), systemImage: "plus")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isImportingVoiceClone)
                } else {
                    Menu {
                        cloneMenuContent
                    } label: {
                        HStack(spacing: 4) {
                            Text(cloneMenuLabel)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(isImportingVoiceClone)
                }
            }
        }
    }

    @ViewBuilder
    private var cloneMenuContent: some View {
        Section(L("选择音色")) {
            ForEach(VoiceCloneStore.shared.profiles) { profile in
                Button {
                    selectClone(profile)
                } label: {
                    Label(
                        "\(profile.name) · \(Int(profile.duration.rounded()))s",
                        systemImage: voiceSettings.cloneID == profile.id ? "checkmark" : "circle"
                    )
                }
            }
        }
        Divider()
        Button {
            importVoiceClone()
        } label: {
            Label(L("导入参考音频…"), systemImage: "square.and.arrow.down")
        }
        if let profile = selectedCloneProfile {
            Divider()
            Button(role: .destructive) {
                clonePendingDelete = profile.id
            } label: {
                Label(L("删除当前克隆音色…"), systemImage: "trash")
            }
        }
    }

    /// Kokoro 语速：三档快捷（1.0 / 1.25 / 1.5，默认 1.25）+ 滑杆微调。
    private var kokoroSpeedRow: some View {
        SettingsRow(
            title: "语速",
            subtitle: "快捷档位 1.0× / 1.25× / 1.5×（默认 1.25×），也可拖动滑杆微调",
            symbol: "speedometer",
            tint: .secondary
        ) {
            VStack(alignment: .trailing, spacing: 6) {
                speedPresetPicker(
                    value: voiceSettings.effectiveKokoroSpeed,
                    presets: Self.kokoroSpeedPresets,
                    binding: bind(\.bot.voiceSettings.kokoroSpeed)
                )
                HStack(spacing: 10) {
                    Slider(value: bind(\.bot.voiceSettings.kokoroSpeed), in: 0.5...2.0, step: 0.05)
                        .frame(width: 200)
                        .labelsHidden()
                    Text(String(format: "%.2f×", voiceSettings.effectiveKokoroSpeed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            }
        }
    }

    /// ZipVoice 克隆语速（沿用 Kokoro 语速设置）。
    private var cloneSpeedRow: some View {
        SettingsRow(
            title: "语速",
            subtitle: "0.5×–2.0×，ZipVoice 克隆使用",
            symbol: "speedometer",
            tint: .secondary
        ) {
            HStack(spacing: 10) {
                Slider(value: bind(\.bot.voiceSettings.kokoroSpeed), in: 0.5...2.0, step: 0.05)
                    .frame(width: 200)
                    .labelsHidden()
                Text(String(format: "%.2f×", voiceSettings.effectiveKokoroSpeed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }

    /// 语速展示：去掉多余小数（1.0 → 1×，1.25 → 1.25×）。
    private static func speedLabel(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "×"
    }

    /// 三档快捷语速的分段选择；当前值不在预设档位时额外显示「自定义」段。
    @ViewBuilder
    private func speedPresetPicker(
        value: Double,
        presets: [Double],
        binding: Binding<Double>
    ) -> some View {
        Picker("", selection: Binding(
            get: { presets.first(where: { abs($0 - value) < 0.001 }) ?? value },
            set: { binding.wrappedValue = $0 }
        )) {
            ForEach(presets, id: \.self) { preset in
                Text(Self.speedLabel(preset)).tag(preset)
            }
            if !presets.contains(where: { abs($0 - value) < 0.001 }) {
                Text(Lf("自定义 %@", Self.speedLabel(value))).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 220)
    }

    /// CosyVoice3 语速：独立于 Kokoro，默认 1.0。
    private var cosyVoiceSpeedRow: some View {
        SettingsRow(
            title: "语速",
            subtitle: "0.5×–2.0×，仅对 CosyVoice3 生效",
            symbol: "speedometer",
            tint: .secondary
        ) {
            HStack(spacing: 10) {
                Slider(
                    value: bind(\.bot.voiceSettings.cosyVoiceSpeed),
                    in: 0.5...2.0,
                    step: 0.05
                )
                .frame(width: 200)
                .labelsHidden()
                Text(String(format: "%.2f×", voiceSettings.effectiveCosyVoiceSpeed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }

    // MARK: - CosyVoice3（本地大模型旁路）

    private var cosyVoiceServiceRow: some View {
        SettingsRow(
            title: "本地服务",
            subtitle: cosyVoiceServiceSubtitle,
            symbol: cosyVoiceServiceSymbol,
            tint: cosyVoiceServiceTint
        ) {
            HStack(spacing: 8) {
                PillLabel(
                    text: cosyVoiceServiceLabel,
                    color: cosyVoiceServiceTint,
                    symbol: cosyVoiceServiceSymbol
                )
                if cosyVoiceRuntime.state.isStarting {
                    ProgressView().controlSize(.mini)
                }
                if cosyVoiceInstall.state.isInstalled {
                    if cosyVoiceRuntime.state.isRunning {
                        Button(L("停止")) { stopCosyVoiceService() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    } else {
                        Button(L("启动")) {
                            Task { await startCosyVoiceService(userInitiated: true) }
                        }
                        .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(cosyVoiceRuntime.state.isStarting || cosyVoiceVoices.isEmpty)
                            .help(cosyVoiceVoices.isEmpty
                                ? L("先添加一个音色")
                                : L("启动本地 CosyVoice3 服务"))
                    }
                }
                Button {
                    Task { await refreshCosyVoiceState(loadVoices: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L("重新检测"))
            }
        }
    }

    private var cosyVoiceServiceLabel: String {
        switch cosyVoiceRuntime.state {
        case .running: return L("运行中")
        case .starting: return L("启动中")
        case .stopped: return L("未运行")
        case .failed: return L("异常")
        case .unknown: return L("未检测")
        }
    }

    private var cosyVoiceServiceSymbol: String {
        switch cosyVoiceRuntime.state {
        case .running: return "checkmark.circle.fill"
        case .starting: return "clock"
        case .stopped, .unknown: return "circle.dotted"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var cosyVoiceServiceTint: Color {
        switch cosyVoiceRuntime.state {
        case .running: return Theme.success
        case .starting: return Theme.warning
        case .stopped, .unknown: return .secondary
        case .failed: return Theme.danger
        }
    }

    private var cosyVoiceServiceSubtitle: String {
        switch cosyVoiceRuntime.state {
        case .running(let health):
            var parts: [String] = []
            let endpoint = cosyVoiceRuntime.endpoint?.absoluteString
                ?? voiceSettings.cosyVoiceEndpoint
            parts.append(endpoint)
            if let pid = cosyVoiceRuntime.pid { parts.append("pid \(pid)") }
            if let model = health.model, !model.isEmpty { parts.append(model) }
            if let device = health.device, !device.isEmpty {
                parts.append(device.uppercased())
            }
            return parts.joined(separator: " · ")
        case .starting(let message):
            return message
        case .failed(let reason):
            return Lf("启动失败：%@", String(reason.prefix(96)))
        case .stopped, .unknown:
            var text = Lf(
                "未运行 · %@（首次启动需加载模型，约 20–60 秒）",
                voiceSettings.cosyVoiceEndpoint)
            if cosyVoiceVoices.isEmpty {
                text += "；" + L("先添加一个音色")
            }
            return text
        }
    }

    private var cosyVoiceInstallRow: some View {
        SettingsRow(
            title: "运行环境与模型",
            subtitle: cosyVoiceInstallSubtitle,
            symbol: cosyVoiceInstallSymbol,
            tint: cosyVoiceInstallTint
        ) {
            HStack(spacing: 8) {
                switch cosyVoiceInstall.state {
                case .installing(let progress, _):
                    ProgressView(value: progress)
                        .frame(width: 90)
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                    Button(L("取消")) { cancelCosyVoiceInstall() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                case .installed:
                    Button(L("重新安装…")) { pendingCosyVoiceInstall = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button(L("删除…")) { pendingCosyVoiceDelete = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                case .failed:
                    Button(L("重试")) { pendingCosyVoiceInstall = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button(L("删除…")) { pendingCosyVoiceDelete = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                case .notInstalled, .unknown:
                    Button(L("下载并安装…")) { pendingCosyVoiceInstall = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            .help(cosyVoiceInstallLogSummary)
        }
    }

    /// 安装日志摘要（最近 4 行；鼠标悬停可见，失败原因已在 subtitle 里）。
    private var cosyVoiceInstallLogSummary: String {
        let lines = cosyVoiceInstall.logTail.suffix(4)
        guard !lines.isEmpty else { return L("安装日志：暂无输出") }
        return lines.joined(separator: "\n")
    }

    private var cosyVoiceInstallSymbol: String {
        switch cosyVoiceInstall.state {
        case .installed: return "checkmark.circle.fill"
        case .installing: return "arrow.down.circle"
        case .failed: return "exclamationmark.triangle.fill"
        case .unknown, .notInstalled: return "arrow.down.circle"
        }
    }

    private var cosyVoiceInstallTint: Color {
        switch cosyVoiceInstall.state {
        case .installed: return Theme.success
        case .installing: return Theme.info
        case .failed: return Theme.danger
        case .unknown, .notInstalled: return Theme.warning
        }
    }

    private var cosyVoiceInstallSubtitle: String {
        switch cosyVoiceInstall.state {
        case .installing(_, let message):
            return message
        case .installed(let installedAt):
            if let installedAt {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                return Lf("已安装 · %@ · %@", formatter.string(from: installedAt),
                          cosyVoiceInstall.homePath)
            }
            return Lf("已安装 · %@", cosyVoiceInstall.homePath)
        case .failed(let reason):
            return Lf("安装失败：%@", String(reason.prefix(180)))
        case .notInstalled, .unknown:
            return Lf(
                "未安装 · 合计约 %@（依赖约 2–3GB + 模型约 5–7GB）",
                sizeText(cosyVoiceInstall.estimatedBytes))
        }
    }

    private var cosyVoiceVoiceRow: some View {
        let hasVoices = !cosyVoiceVoices.isEmpty
        let selectedID = voiceSettings.effectiveCosyVoiceVoiceID
        let selection = currentSelection
        let enabled = cosyVoiceInstall.state.isInstalled
            && cosyVoiceRuntime.state.isRunning
            && hasVoices
            && !selectedID.isEmpty
        return SettingsRow(
            title: "音色",
            subtitle: cosyVoiceVoiceSubtitle,
            symbol: "person.wave.2",
            tint: .secondary
        ) {
            HStack(spacing: 8) {
                if hasVoices {
                    previewButton(
                        selection: selection,
                        enabled: enabled,
                        disabledHint: cosyVoicePreviewDisabledHint
                    )
                    Picker(L("音色"), selection: cosyVoiceVoiceBinding) {
                        if selectedID.isEmpty
                            || !cosyVoiceVoices.contains(where: { $0.id == selectedID }) {
                            Text(L("未选择音色")).tag("")
                        }
                        ForEach(cosyVoiceVoices) { voice in
                            Text(voice.name).tag(voice.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 128)
                } else {
                    Text(L("未添加音色"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Button {
                    store.voicePreview.stop()
                    voiceManagerPresented = true
                } label: {
                    Label(
                        hasVoices ? L("管理音色…") : L("添加音色…"),
                        systemImage: "person.2.badge.gearshape")
                }
                .buttonStyle(.bordered)
                .tint(hasVoices ? nil : Theme.accent)
                .controlSize(.small)
                .disabled(!cosyVoiceInstall.state.isInstalled)
                .help(cosyVoiceInstall.state.isInstalled
                    ? L("查看/新增/编辑/删除 CosyVoice3 音色")
                    : L("先安装 CosyVoice3 运行环境与模型"))
            }
        }
    }

    private var cosyVoiceVoiceSubtitle: String {
        if cosyVoiceVoices.isEmpty {
            return L("未添加音色 · App 不内置任何音色，音色仅保存在本机；点右侧「添加音色…」导入参考音")
        }
        let id = voiceSettings.effectiveCosyVoiceVoiceID
        guard !id.isEmpty,
              let voice = cosyVoiceVoices.first(where: { $0.id == id }) else {
            return L("未选择音色 · 从列表选择一个本机音色后才能试听或合成")
        }
        let base = voice.description.isEmpty
            ? voice.name
            : "\(voice.name) · \(voice.description)"
        if !cosyVoiceInstall.state.isInstalled {
            return "\(base) · " + L("先安装 CosyVoice3 后才能试听")
        }
        if !cosyVoiceRuntime.state.isRunning {
            return "\(base) · " + L("先启动本地服务后可试听")
        }
        return base
    }

    private var cosyVoicePreviewDisabledHint: String {
        if !cosyVoiceInstall.state.isInstalled { return L("先安装 CosyVoice3") }
        if cosyVoiceVoices.isEmpty { return L("先添加一个音色") }
        if voiceSettings.effectiveCosyVoiceVoiceID.isEmpty { return L("先选择音色") }
        if !cosyVoiceRuntime.state.isRunning { return L("先启动本地服务") }
        return L("用当前音色试听示例短句")
    }

    private var cosyVoiceAutoStartRow: some View {
        SettingsRow(
            title: "自动启动",
            subtitle: "启动 App 或切换到 CosyVoice3 时自动拉起本地服务",
            symbol: "power",
            tint: .secondary
        ) {
            Toggle(
                L("自动启动本地服务"),
                isOn: bind(\.bot.voiceSettings.cosyVoiceAutoStart)
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var cosyVoiceEndpointRow: some View {
        SettingsRow(
            title: "服务地址",
            subtitle: voiceSettings.hasValidCosyVoiceEndpoint
                ? L("默认 http://127.0.0.1:5051；仅允许本机回环地址，改端口后需重启本地服务")
                : L("仅允许本机回环地址，例如 http://127.0.0.1:5051"),
            symbol: "network",
            tint: voiceSettings.hasValidCosyVoiceEndpoint ? .secondary : Theme.warning
        ) {
            HStack(spacing: 6) {
                TextField(L("服务地址"), text: $cosyVoiceEndpointDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 210)
                    .onSubmit { commitCosyVoiceEndpoint() }
                Button(L("应用")) { commitCosyVoiceEndpoint() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - CosyVoice3 状态轮询 / 动作

    private func pollCosyVoice() async {
        guard voiceSettings.engine == .cosyVoice else { return }
        cosyVoiceEndpointDraft = voiceSettings.cosyVoiceEndpoint
        await refreshCosyVoiceState(loadVoices: true)
        if !didAttemptCosyVoiceAutoStart {
            didAttemptCosyVoiceAutoStart = true
            if voiceSettings.cosyVoiceAutoStart,
               cosyVoiceInstall.state.isInstalled,
               !cosyVoiceVoices.isEmpty,
               !cosyVoiceRuntime.state.isRunning,
               !cosyVoiceRuntime.state.isStarting {
                Task { await startCosyVoiceService(userInitiated: false) }
            }
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { break }
            await refreshCosyVoiceState(loadVoices: false)
        }
    }

    private func refreshCosyVoiceState(loadVoices: Bool) async {
        cosyVoiceInstall = await CosyVoiceInstaller.shared.refresh()
        cosyVoiceRuntime = await CosyVoiceRuntime.shared.refresh(
            endpoint: voiceSettings.effectiveCosyVoiceEndpoint)
        if loadVoices || !cosyVoiceVoicesLoaded {
            await loadCosyVoiceVoices()
        }
    }

    private func loadCosyVoiceVoices() async {
        guard cosyVoiceInstall.state.isInstalled else { return }
        // manifest 是本地事实来源：即使服务未启动，也要把用户新增/改名的音色展示出来。
        let stored = ((try? await CosyVoiceVoiceStore.shared.list()) ?? [])
            .map(\.asServiceVoice)
        let endpoint = voiceSettings.effectiveCosyVoiceEndpoint
        await CosyVoiceClient.shared.updateEndpoint(endpoint)
        if cosyVoiceRuntime.state.isRunning,
           let remote = try? await CosyVoiceClient.shared.voices(endpoint: endpoint),
           !remote.isEmpty {
            var merged = CosyVoiceVoiceCatalog.merged(remote: remote)
            let known = Set(merged.map(\.id))
            merged.append(contentsOf: stored.filter { !known.contains($0.id) })
            cosyVoiceVoices = merged
        } else if !stored.isEmpty {
            cosyVoiceVoices = CosyVoiceVoiceCatalog.merged(remote: stored)
        } else {
            // 分发边界：空音色库就是空，不把 fallbackVoices 当成可用三音色。
            cosyVoiceVoices = []
        }
        cosyVoiceVoicesLoaded = true
    }

    private func startCosyVoiceService(userInitiated: Bool) async {
        guard cosyVoiceInstall.state.isInstalled else {
            if userInitiated {
                toast.show(L("请先安装 CosyVoice3 运行环境与模型"), tone: .info)
            }
            return
        }
        guard !cosyVoiceVoices.isEmpty else {
            if userInitiated {
                toast.show(L("请先在「管理音色…」中添加一个音色"), tone: .info)
            }
            return
        }
        do {
            _ = try await CosyVoiceRuntime.shared.start(
                endpoint: voiceSettings.effectiveCosyVoiceEndpoint)
            if userInitiated {
                toast.show(L("CosyVoice3 服务已启动"), tone: .success)
            }
        } catch {
            if userInitiated {
                toast.show(error.localizedDescription, tone: .error)
            }
        }
        await refreshCosyVoiceState(loadVoices: true)
    }

    private func stopCosyVoiceService() {
        store.voicePreview.stop()
        Task {
            await CosyVoiceRuntime.shared.stop()
            await refreshCosyVoiceState(loadVoices: false)
        }
    }

    private func startCosyVoiceInstall() {
        Task {
            do {
                try await CosyVoiceInstaller.shared.install(consent: true)
                toast.show(L("CosyVoice3 已安装"), tone: .success)
                await refreshCosyVoiceState(loadVoices: true)
                if voiceSettings.cosyVoiceAutoStart {
                    Task { await startCosyVoiceService(userInitiated: false) }
                }
            } catch let error as CosyVoiceInstallError where error == .cancelled {
                toast.show(L("已取消安装"), tone: .info)
                await refreshCosyVoiceState(loadVoices: false)
            } catch {
                toast.show(error.localizedDescription, tone: .error)
                await refreshCosyVoiceState(loadVoices: false)
            }
        }
    }

    private func cancelCosyVoiceInstall() {
        Task {
            await CosyVoiceInstaller.shared.cancel()
            await refreshCosyVoiceState(loadVoices: false)
        }
    }

    private func deleteCosyVoiceInstall() {
        store.voicePreview.stop()
        Task {
            await CosyVoiceRuntime.shared.stop()
            do {
                try await CosyVoiceInstaller.shared.deleteLocalInstall()
                toast.show(L("已删除 CosyVoice3"), tone: .info)
            } catch {
                toast.show(error.localizedDescription, tone: .error)
            }
            await refreshCosyVoiceState(loadVoices: false)
        }
    }

    private func commitCosyVoiceEndpoint() {
        let raw = cosyVoiceEndpointDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = CosyVoiceClient.normalizedEndpoint(raw) else {
            toast.show(L("服务地址无效：仅允许本机回环地址，例如 http://127.0.0.1:5051"), tone: .error)
            cosyVoiceEndpointDraft = store.settings.bot.voiceSettings.cosyVoiceEndpoint
            return
        }
        let normalized = url.absoluteString
        cosyVoiceEndpointDraft = normalized
        guard store.settings.bot.voiceSettings.cosyVoiceEndpoint != normalized else { return }
        store.settings.bot.voiceSettings.cosyVoiceEndpoint = normalized
        store.persist()
        Task {
            await CosyVoiceRuntime.shared.stop()
            await CosyVoiceClient.shared.updateEndpoint(url)
            await refreshCosyVoiceState(loadVoices: true)
            if voiceSettings.cosyVoiceAutoStart,
               cosyVoiceInstall.state.isInstalled,
               !cosyVoiceVoices.isEmpty {
                Task { await startCosyVoiceService(userInitiated: false) }
            }
        }
    }

    private var cosyVoiceVoiceBinding: Binding<String> {
        Binding(
            get: { store.settings.bot.voiceSettings.effectiveCosyVoiceVoiceID },
            set: { id in
                store.voicePreview.stop()
                store.settings.bot.voiceSettings.cosyVoiceVoiceID = id
                store.persist()
            }
        )
    }

    private var modelRow: some View {
        let status = engineModelStatus
        return SettingsRow(
            title: "语音模型",
            subtitle: modelSubtitle(status),
            symbol: status.isReady ? "checkmark.circle.fill" : "arrow.down.circle",
            tint: status.isReady ? Theme.success : Theme.warning
        ) {
            HStack(spacing: 8) {
                if status.isBusy {
                    if status.isIndeterminateDownload {
                        ProgressView().controlSize(.small)
                    } else {
                        ProgressView(value: status.progress)
                            .frame(width: 90)
                    }
                    Button(L("取消")) {
                        VoiceModelStore.shared.cancel()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if status.isReady {
                    modelMenu(status)
                } else {
                    Button(status.failedState != nil ? L("重试") : L("下载")) {
                        requestModelDownload()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(VoiceModelStore.shared.isDownloading)
                    if !status.readyKinds.isEmpty {
                        modelMenu(status)
                    }
                }
            }
        }
    }

    private func modelMenu(_ status: VoiceEngineModelStatus) -> some View {
        Menu {
            if !status.readyKinds.isEmpty {
                Button(role: .destructive) {
                    pendingModelDelete = true
                } label: {
                    Label(L("删除当前引擎模型…"), systemImage: "trash")
                }
                Divider()
            }
            Button {
                NSWorkspace.shared.open(VoiceModelStore.modelsDirectory)
            } label: {
                Label(L("在 Finder 中显示模型"), systemImage: "folder")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func modelSubtitle(_ status: VoiceEngineModelStatus) -> String {
        if let busy = status.busyState {
            switch busy {
            case .downloading(let progress):
                if let progress {
                    return Lf("下载中 %d%% · 约 %@", Int((progress * 100).rounded()), sizeText(status.missingBytes))
                }
                return L("下载中…")
            case .verifying:
                return L("校验中…")
            case .extracting:
                return L("解包中…")
            case .notDownloaded, .ready, .failed:
                break
            }
        }
        if let reason = status.failureReason {
            let short = String(reason.prefix(72))
            return Lf("下载失败：%@%@", short, reason.count > 72 ? "…" : "")
        }
        if status.isReady {
            return Lf("已就绪 · 约 %@", sizeText(status.totalBytes))
        }
        if status.readyKinds.isEmpty {
            return Lf("未下载 · 约 %@", sizeText(status.missingBytes))
        }
        return Lf("缺少 %@ · 约 %@", missingModelNames(status), sizeText(status.missingBytes))
    }

    private var sendStatusSection: some View {
        SettingsSection(
            title: "语音发送状态",
            footer: "首次启用语音回复或微信重启后，需要在本机微信手动发一条文字和一条语音以捕获发送句柄；bridge 启动后的登录稳定期内不会发送语音。"
        ) {
            SettingsRow(
                title: "发送通道",
                subtitle: voiceRuntimeSummary,
                symbol: voiceRuntimeSymbol,
                tint: voiceRuntimeTint
            ) {
                HStack(spacing: 8) {
                    if store.voiceRuntimeStatus.remainingWarmupSeconds(now: voiceStatusTick) > 0 {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        Task {
                            await store.refreshVoiceStatus()
                            voiceStatusTick = Date()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(L("重新检测"))
                    if needsVoiceSetup {
                        Button(L("查看步骤…")) {
                            voiceSetupPresented = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Derived values

    private var kokoroVoice: KokoroVoice? {
        KokoroVoiceCatalog.voice(for: voiceSettings.effectiveKokoroSpeakerID)
    }

    private var kokoroVoiceSubtitle: String {
        guard let kokoroVoice else {
            return Lf("音色 #%d（未收录）", voiceSettings.effectiveKokoroSpeakerID)
        }
        return "\(kokoroVoice.localizedGroupTitle) · \(kokoroVoice.name)"
    }

    private var selectedCloneProfile: VoiceCloneProfile? {
        guard let id = voiceSettings.cloneID, !id.isEmpty else { return nil }
        return VoiceCloneStore.shared.profile(id: id)
    }

    private var clonePreviewDisabledHint: String {
        if !VoiceSynthesisService.isReady(.zipvoiceClone) { return "先下载语音模型" }
        if selectedCloneProfile == nil { return "先导入克隆音色" }
        return "补全参考文本后再试听"
    }

    private var cloneMenuLabel: String {
        if let profile = selectedCloneProfile {
            return profile.name
        }
        if voiceSettings.cloneID != nil {
            return L("音色不存在")
        }
        return L("选择克隆音色")
    }

    private var cloneSubtitle: String {
        let profiles = VoiceCloneStore.shared.profiles
        guard !profiles.isEmpty else {
            return L("还没有克隆音色；导入 10–30 秒单人参考音频")
        }
        if let profile = selectedCloneProfile {
            let state = profile.hasReferenceText
                ? L("参考文本已填写")
                : L("缺少参考文本，无法合成")
            return "\(Int(profile.duration.rounded()))s · \(state)"
        }
        if voiceSettings.cloneID != nil {
            return L("所选克隆音色不存在，请重新选择")
        }
        return Lf("未选择克隆音色（共 %d 个档案）", profiles.count)
    }

    private var currentSelection: VoiceSelection {
        switch voiceSettings.engine {
        case .cosyVoice:
            return VoiceSelection(
                engine: .cosyVoice,
                speed: voiceSettings.effectiveCosyVoiceSpeed,
                cosyVoiceVoiceID: voiceSettings.effectiveCosyVoiceVoiceID
            )
        case .kokoro, .zipvoiceClone:
            return VoiceSelection(
                engine: voiceSettings.engine,
                kokoroSpeakerID: voiceSettings.effectiveKokoroSpeakerID,
                speed: voiceSettings.effectiveKokoroSpeed,
                cloneID: voiceSettings.engine == .zipvoiceClone ? voiceSettings.cloneID : nil
            )
        }
    }

    private var engineModelStatus: VoiceEngineModelStatus {
        VoiceModelStore.shared.status(for: voiceSettings.engine)
    }

    private var modelDownloadMessage: String {
        let status = engineModelStatus
        let name: String
        if voiceSettings.engine == .kokoro {
            name = L("Kokoro 语音模型")
        } else if voiceSettings.engine == .cosyVoice {
            name = L("CosyVoice3 运行环境与模型")
        } else if status.missing == [.zipvoice, .vocoder] {
            name = L("ZipVoice 克隆模型与声码器")
        } else {
            name = missingModelNames(status)
        }
        return Lf(
            "将下载 %@ 到本机（约 %@）。下载过程不会上传音频或文本。",
            name,
            sizeText(status.missingBytes)
        )
    }

    private var needsVoiceSetup: Bool {
        voiceSettings.replyEnabled
            && !store.voiceRuntimeStatus.canSendVoice(now: voiceStatusTick)
    }

    private var engineBinding: Binding<VoiceEngineKind> {
        Binding(
            get: { store.settings.bot.voiceSettings.engine },
            set: { engine in
                store.voicePreview.stop()
                store.settings.bot.voiceSettings.engine = engine
                if engine == .zipvoiceClone, selectedCloneProfile == nil {
                    store.settings.bot.voiceSettings.cloneID =
                        VoiceCloneStore.shared.profiles.first?.id
                }
                store.persist()
                if engine == .cosyVoice,
                   store.settings.bot.voiceSettings.cosyVoiceAutoStart,
                   cosyVoiceInstall.state.isInstalled,
                   !cosyVoiceVoices.isEmpty,
                   !cosyVoiceRuntime.state.isRunning,
                   !cosyVoiceRuntime.state.isStarting {
                    Task { await startCosyVoiceService(userInitiated: false) }
                }
            }
        )
    }

    private func sizeText(_ bytes: Int64) -> String {
        // 模型体积按 1024 进制展示，与文档/模型页的 “365MB / 163MB” 对齐。
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }

    private func missingModelNames(_ status: VoiceEngineModelStatus) -> String {
        status.missing.compactMap { kind in
            VoiceModelStore.catalog.first { $0.kind == kind }?.displayName
        }.joined(separator: " / ")
    }

    // MARK: - Preview

    @ViewBuilder
    private func previewButton(
        selection: VoiceSelection,
        enabled: Bool,
        disabledHint: String = "先下载语音模型"
    ) -> some View {
        let active = store.voicePreview.isActive(selection)
        let phase = store.voicePreview.phase
        Button {
            store.voicePreview.toggle(
                voice: selection,
                cosyVoice: selection.engine == .cosyVoice
                    ? VoicePreviewCosyVoiceOptions(
                        voiceID: selection.cosyVoiceVoiceID
                            ?? voiceSettings.effectiveCosyVoiceVoiceID,
                        endpoint: voiceSettings.effectiveCosyVoiceEndpoint,
                        speed: selection.speed
                    )
                    : nil
            ) { message in
                toast.show(message, tone: .error)
            }
        } label: {
            if active, phase == .synthesizing {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(L("合成中…"))
                }
            } else if active, phase == .playing {
                Label(L("停止"), systemImage: "stop.fill")
            } else {
                Label(L("试听"), systemImage: "play.fill")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!enabled)
        .help(enabled ? L("用当前音色试听示例短句") : L(disabledHint))
    }

    // MARK: - Model actions

    private func requestModelDownload() {
        guard !engineModelStatus.missing.isEmpty else { return }
        if voiceSettings.modelDownloadConsent {
            startModelDownload()
        } else {
            pendingModelDownload = true
        }
    }

    private func startModelDownload() {
        let kinds = engineModelStatus.missing
        guard !kinds.isEmpty else { return }
        Task {
            do {
                try await VoiceModelStore.shared.download(kinds, consent: true)
                toast.show(L("语音模型下载完成"), tone: .success)
            } catch let error as VoiceModelError where error == .cancelled {
                toast.show(L("已取消下载"), tone: .info)
            } catch {
                toast.show(
                    (error as? LocalizedError)?.errorDescription ?? "\(error)",
                    tone: .error
                )
            }
        }
    }

    private func deleteCurrentEngineModels() {
        let kinds = engineModelStatus.readyKinds
        guard !kinds.isEmpty else { return }
        store.voicePreview.stop()
        do {
            for kind in kinds {
                try VoiceModelStore.shared.delete(kind)
            }
            toast.show(L("已删除语音模型"), tone: .info)
        } catch {
            toast.show(error.localizedDescription, tone: .error)
        }
    }

    // MARK: - Clone actions

    private func selectClone(_ profile: VoiceCloneProfile) {
        store.voicePreview.stop()
        store.settings.bot.voiceSettings.engine = .zipvoiceClone
        store.settings.bot.voiceSettings.cloneID = profile.id
        store.persist()
    }

    private func deletePendingClone() {
        guard let id = clonePendingDelete else { return }
        clonePendingDelete = nil
        do {
            try VoiceCloneStore.shared.delete(id: id)
            if store.settings.bot.voiceSettings.cloneID == id {
                store.settings.bot.voiceSettings.cloneID = nil
                store.persist()
            }
            store.voicePreview.stop()
            toast.show(L("已删除克隆音色"), tone: .info)
        } catch {
            toast.show(error.localizedDescription, tone: .error)
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
                store.voicePreview.stop()
                store.settings.bot.voiceSettings.engine = .zipvoiceClone
                store.settings.bot.voiceSettings.cloneID = profile.id
                store.persist()
                toast.show(L("已导入克隆音色"), tone: .success)
            } catch {
                toast.show(error.localizedDescription, tone: .error)
            }
        }
    }

    // MARK: - Voice runtime

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

    private func pollVoiceStatus() async {
        guard voiceSettings.replyEnabled else { return }
        await store.refreshVoiceStatus()
        voiceStatusTick = Date()
        var ticks = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { break }
            voiceStatusTick = Date()
            ticks += 1
            // 倒计时用本地 tick，每 5 秒才向 bridge 拉一次状态，避免每秒请求。
            if ticks % 5 == 0 {
                await store.refreshVoiceStatus()
                voiceStatusTick = Date()
            }
        }
    }

    // MARK: - Transcription assets

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

    private func bind<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { newValue in
                store.settings[keyPath: keyPath] = newValue
                store.persist()
            }
        )
    }
}
