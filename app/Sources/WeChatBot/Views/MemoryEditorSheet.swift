import SwiftUI

/// 记忆卡中的一条记忆：新增 / 编辑 / 删除。
struct MemoryEditorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast
    @Environment(\.dismiss) private var dismiss

    let original: CharacterMemory
    let isNew: Bool
    let conversationTitle: String
    let settings: MemorySettings

    @State private var content: String
    @State private var category: MemoryCategory
    @State private var importance: Double
    @State private var pinned: Bool
    @State private var archived: Bool
    @State private var keywordsText: String
    @State private var isSaving = false
    @State private var confirmDelete = false

    init(
        original: CharacterMemory,
        isNew: Bool,
        conversationTitle: String,
        settings: MemorySettings
    ) {
        self.original = original
        self.isNew = isNew
        self.conversationTitle = conversationTitle
        self.settings = settings
        _content = State(initialValue: original.content)
        _category = State(initialValue: original.category)
        _importance = State(initialValue: min(max(original.importance, 1), 10))
        _pinned = State(initialValue: original.pinned)
        _archived = State(initialValue: original.archived)
        _keywordsText = State(initialValue: original.keywords.joined(separator: " "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            header

            InlineNotice(
                kind: .info,
                title: isNew ? "手写记忆" : "记忆详情",
                message: "来源与时间由系统记录；编辑后会刷新更新时间，时间衰减从头计算。"
            )

            contentEditor

            categoryRow
            importanceRow
            optionRows
            keywordsRow

            weightPreview

            footer
        }
        .padding(22)
        .frame(width: 580)
        .background(.regularMaterial)
        .confirmationDialog(
            "删除这条记忆？",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button(L("删除"), role: .destructive) { delete() }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("删除后无法恢复；不会影响微信聊天记录与其它记忆。"))
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: category.symbol)
                .font(.system(size: 22))
                .foregroundStyle(categoryTint)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(isNew ? "新增记忆" : "编辑记忆")).font(.headline)
                Text(conversationTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    // MARK: Content

    private var contentEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("记忆内容")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextEditor(text: $content)
                .font(.body)
                .frame(minHeight: 140, maxHeight: 200)
                .padding(6)
                .background(
                    Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .disabled(isSaving)
            HStack(spacing: 8) {
                Text(L("例如：对方叫小林，喜欢猫；我们约好周五晚上讨论旅行计划。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(content.count) / 2000")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(content.count > 2000 ? Theme.danger : Color.secondary)
            }
        }
    }

    // MARK: Category

    private var categoryRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L("类别")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Picker(L("类别"), selection: $category) {
                ForEach(MemoryCategory.allCases) { item in
                    Label(item.label, systemImage: item.symbol).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isSaving)
        }
    }

    // MARK: Importance

    private var importanceRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L("重要度")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f", importance))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(importance >= settings.importanceThreshold
                        ? Theme.warning : Color.secondary)
            }
            Slider(value: $importance, in: 1...10, step: 0.5) {
                Text(L("重要度"))
            } minimumValueLabel: {
                Text("1").font(.system(size: 9)).foregroundStyle(.tertiary)
            } maximumValueLabel: {
                Text("10").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .tint(importance >= settings.importanceThreshold ? Theme.warning : Theme.accent)
            .disabled(isSaving)
            .accessibilityLabel(L("重要度"))
            .accessibilityValue(String(format: "%.1f", importance))
            Text(Lf(
                "重要度 ≥ %.1f 时按「重要」慢衰减；置顶记忆不衰减。",
                settings.importanceThreshold
            ))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Toggles

    private var optionRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $pinned) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("置顶记忆")).font(.callout)
                    Text(L("不参与时间衰减，召回时优先注入。"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.violet)
            .disabled(isSaving)

            if !isNew {
                Toggle(isOn: $archived) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("已归档")).font(.callout)
                        Text(L("归档后不参与自动召回，可在「已归档」筛选中恢复。"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .toggleStyle(.switch)
                .tint(Theme.warning)
                .disabled(isSaving)
            }
        }
    }

    // MARK: Keywords

    private var keywordsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("关键词")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField(
                L("关键词"),
                text: $keywordsText,
                prompt: Text(L("用逗号或空格分隔，最多 8 个"))
            )
            .textFieldStyle(.roundedBorder)
            .disabled(isSaving)
            if !parsedKeywords.isEmpty {
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    ForEach(parsedKeywords, id: \.self) { keyword in
                        Text(keyword)
                            .font(.caption2)
                            .foregroundStyle(Theme.info)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Theme.info.opacity(0.12), in: Capsule())
                    }
                }
            }
        }
    }

    // MARK: Weight preview

    private var weightPreview: some View {
        HStack(spacing: 8) {
            Image(systemName: "scalemass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.success)
            Text(Lf("保存后综合权重约 %.2f", estimatedScore))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if isNew {
                Text(L("来源：手写"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text(Lf("合并 %d 次 · 召回 %d 次", original.mergeCount, original.accessCount))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 9) {
            if !isNew {
                Button(L("删除"), systemImage: "trash", role: .destructive) {
                    confirmDelete = true
                }
                .buttonStyle(.glass)
                .disabled(isSaving)
            }
            Spacer()
            Button(L("取消")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
            Button(isSaving ? L("保存中…") : L("保存")) { save() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave || isSaving)
        }
    }

    // MARK: Derived

    private var trimmedContent: String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedContent.isEmpty && content.count <= 2000 && !original.characterID.isEmpty
    }

    private var categoryTint: Color { MemoryCategory.tint(for: category) }

    /// 保存后的预估权重：刷新更新时间，其余字段取当前编辑值。
    private var estimatedScore: Double {
        var preview = original
        preview.content = trimmedContent.isEmpty ? original.content : trimmedContent
        preview.category = category
        preview.importance = importance
        preview.pinned = pinned
        preview.archived = archived
        preview.normalizeKind(threshold: settings.importanceThreshold)
        preview.updatedAt = Date()
        preview.lastAccessedAt = nil
        return preview.score(settings: settings)
    }

    /// 逗号/空格/顿号/分号分隔，去重后最多 8 个（§4.1、§7.2）。
    private var parsedKeywords: [String] {
        var seen = Set<String>()
        let separators = CharacterSet(charactersIn: ",，、;； \n\t")
        return keywordsText
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 24 && seen.insert($0).inserted }
            .prefix(8)
            .map { $0 }
    }

    // MARK: Actions

    private func save() {
        guard canSave else { return }
        var updated = original
        if trimmedContent != original.content {
            updated.content = trimmedContent
            // 正文变了，旧的压缩摘要立即失效；下次压缩/归档再生成。
            updated.compressedContent = nil
        }
        updated.category = category
        updated.importance = importance
        updated.pinned = pinned
        updated.archived = archived
        updated.keywords = parsedKeywords
        updated.source = isNew ? .manual : original.source
        isSaving = true
        Task {
            let saved = await store.saveCharacterMemory(updated)
            isSaving = false
            if saved {
                toast.show(
                    isNew ? L("已新增记忆") : L("已保存记忆"),
                    tone: .success,
                    symbol: "checkmark.circle.fill"
                )
                dismiss()
            } else {
                toast.show(L("保存记忆失败，请查看日志"), tone: .error)
            }
        }
    }

    private func delete() {
        isSaving = true
        Task {
            await store.deleteCharacterMemory(original)
            isSaving = false
            toast.show(L("已删除记忆"), tone: .info, symbol: "trash")
            dismiss()
        }
    }
}

// MARK: - Category tint

extension MemoryCategory {
    /// 类别在卡片/编辑器中的统一色，避免各处手写 switch。
    static func tint(for category: MemoryCategory) -> Color {
        switch category {
        case .fact: Theme.info
        case .decision: Theme.violet
        case .todo: Theme.accent
        case .lesson: Theme.warning
        }
    }

    var tint: Color { Self.tint(for: self) }
}
