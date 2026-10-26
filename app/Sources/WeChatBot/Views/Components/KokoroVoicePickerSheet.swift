import SwiftUI

// MARK: - Kokoro 音色选择

/// Kokoro 内置音色选择器：搜索 + 分组 + 逐项试听。
///
/// 103 个音色不适合塞进下拉菜单；这里按官方中文女声/中文男声/英文女声分组，
/// 行内可直接试听，选中即时写回设置（关闭时无需额外保存）。
struct KokoroVoicePickerSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selectedGroup: KokoroVoiceGroup?

    private var voiceSettings: VoiceSettings { store.settings.bot.voiceSettings }

    private var filteredVoices: [KokoroVoice] {
        let base = selectedGroup.map(KokoroVoiceCatalog.voices(in:)) ?? KokoroVoiceCatalog.all
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        return base.filter { $0.searchText.localizedCaseInsensitiveContains(trimmed) }
    }

    private var kokoroReady: Bool {
        VoiceSynthesisService.isReady(.kokoro)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.wave.2.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.violet)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("选择音色"))
                        .font(.title3.weight(.semibold))
                    Text(Lf("%d 个 Kokoro 内置音色；点按行选中，右侧可试听。",
                            KokoroVoiceCatalog.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("关闭")) { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            SearchField(text: $query, placeholder: "搜索音色")

            HStack(spacing: 7) {
                FilterChip(
                    title: "全部",
                    count: KokoroVoiceCatalog.count,
                    isSelected: selectedGroup == nil
                ) {
                    selectedGroup = nil
                }
                ForEach(KokoroVoiceGroup.allCases) { group in
                    FilterChip(
                        title: group.filterTitle,
                        count: group.count,
                        isSelected: selectedGroup == group
                    ) {
                        selectedGroup = group
                    }
                }
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredVoices) { voice in
                        voiceRow(voice)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 10) {
                Text(Lf("当前音色：%@", currentVoiceLabel))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("完成")) { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
        .onDisappear { store.voicePreview.stop() }
    }

    private func voiceRow(_ voice: KokoroVoice) -> some View {
        let isSelected = voice.sid == voiceSettings.effectiveKokoroSpeakerID
        let selection = VoiceSelection(
            engine: .kokoro,
            kokoroSpeakerID: voice.sid,
            speed: voiceSettings.effectiveKokoroSpeed
        )
        let active = store.voicePreview.isActive(selection)
        let phase = store.voicePreview.phase
        return HStack(spacing: 10) {
            Button {
                selectVoice(voice)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? Theme.success : Color.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(voice.name)
                            .font(.system(.callout, design: .monospaced))
                        Text(voice.localizedGroupTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(voice.localizedGroupTitle) \(voice.name)")
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])

            Button {
                store.voicePreview.toggle(voice: selection) { message in
                    toast.show(message, tone: .error)
                }
            } label: {
                if active, phase == .synthesizing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: active && phase == .playing ? "stop.fill" : "play.fill")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!kokoroReady)
            .help(L(active && phase == .playing ? "停止试听" : (kokoroReady ? "试听" : "先下载语音模型")))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isSelected ? Theme.success.opacity(0.06) : Color.clear)
    }

    private func selectVoice(_ voice: KokoroVoice) {
        store.voicePreview.stop()
        store.settings.bot.voiceSettings.kokoroSpeakerID = voice.sid
        store.persist()
    }

    private var currentVoiceLabel: String {
        let sid = voiceSettings.effectiveKokoroSpeakerID
        guard let voice = KokoroVoiceCatalog.voice(for: sid) else { return "#\(sid)" }
        return "\(voice.localizedGroupTitle) · \(voice.name)"
    }
}
