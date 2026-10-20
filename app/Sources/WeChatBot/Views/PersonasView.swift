import SwiftUI

/// 人格设定：卡片网格 + 编辑弹窗。
struct PersonasView: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast

    @State private var editingPersona: Persona?
    @State private var isEditingNew = false
    @State private var pendingDelete: Persona?

    private let columns = [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 12, alignment: .top)]

    var body: some View {
        ScrollingPage(title: "人格设定", subtitle: subtitle) {
            Button {
                addPersona()
            } label: {
                Label("添加人格", systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
        } content: {
            if store.personas.isEmpty {
                GlassCard {
                    EmptyState(
                        symbol: "person.crop.circle",
                        title: "还没有人格",
                        message: "人格决定 AI 的系统提示词与模型覆盖，可被会话引用。",
                        actionTitle: "创建第一个人格"
                    ) {
                        addPersona()
                    }
                }
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(sortedPersonas) { persona in
                        PersonaCard(
                            persona: persona,
                            isDefault: isDefault(persona),
                            onEdit: {
                                isEditingNew = false
                                editingPersona = persona
                            },
                            onSetDefault: { setDefault(persona) },
                            onDelete: { pendingDelete = persona }
                        )
                    }
                }
            }

            InlineNotice(
                kind: .info,
                title: "人格如何生效",
                message: "优先级：会话单独设置 > 机器人默认人格 > 全局默认。人格的系统提示词会直接发送给模型。"
            )
        }
        .sheet(item: $editingPersona) { persona in
            PersonaEditorSheet(persona: persona, isNew: isEditingNew) { updated in
                save(updated)
            }
        }
        .confirmationDialog(
            "删除人格",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { persona in
            Button("删除 \(persona.name)", role: .destructive) {
                delete(persona)
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("使用该人格的会话会自动回退到默认人格。")
        }
    }

    private var subtitle: String {
        let defaultName = store.personas.first(where: \.isDefault)?.name
            ?? store.settings.persona(id: store.settings.bot.defaultPersonaID)?.name
        if let defaultName {
            return "\(store.personas.count) 个人格 · 默认「\(defaultName)」"
        }
        return "\(store.personas.count) 个人格"
    }

    private var sortedPersonas: [Persona] {
        store.personas.sorted { lhs, rhs in
            if isDefault(lhs) != isDefault(rhs) { return isDefault(lhs) }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    private func isDefault(_ persona: Persona) -> Bool {
        persona.isDefault || store.settings.bot.defaultPersonaID == persona.id
    }

    private func addPersona() {
        var draft = Persona(name: "新人格", summary: "", systemPrompt: "")
        draft.id = UUID().uuidString
        draft.isDefault = store.personas.isEmpty
        isEditingNew = true
        editingPersona = draft
    }

    private func save(_ persona: Persona) {
        if let index = store.personas.firstIndex(where: { $0.id == persona.id }) {
            store.personas[index] = persona
            toast.show("人格已保存", tone: .success)
        } else {
            store.personas.append(persona)
            toast.show("人格已添加", tone: .success)
        }
        if persona.isDefault || store.settings.bot.defaultPersonaID == nil {
            setDefaultSilently(persona)
        }
        store.persist()
    }

    private func setDefault(_ persona: Persona) {
        setDefaultSilently(persona)
        store.persist()
        toast.show("已将 \(persona.name) 设为默认人格", tone: .success, symbol: "star.fill")
    }

    private func setDefaultSilently(_ persona: Persona) {
        for index in store.personas.indices {
            store.personas[index].isDefault = store.personas[index].id == persona.id
        }
        store.settings.bot.defaultPersonaID = persona.id
    }

    private func delete(_ persona: Persona) {
        pendingDelete = nil
        store.personas.removeAll { $0.id == persona.id }
        if store.settings.bot.defaultPersonaID == persona.id {
            let next = store.personas.first
            store.settings.bot.defaultPersonaID = next?.id
            if let next, let index = store.personas.firstIndex(where: { $0.id == next.id }) {
                store.personas[index].isDefault = true
            }
        }
        store.persist()
        toast.show("人格已删除", tone: .info, symbol: "trash")
    }
}

/// Add / edit sheet for a persona.
struct PersonaEditorSheet: View {
    let persona: Persona
    let isNew: Bool
    let onSave: (Persona) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: Persona
    @State private var validationMessage: String?

    init(persona: Persona, isNew: Bool, onSave: @escaping (Persona) -> Void) {
        self.persona = persona
        self.isNew = isNew
        self.onSave = onSave
        _draft = State(initialValue: persona)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Theme.avatarTint(for: draft.name))
                        .frame(width: 32, height: 32)
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(isNew ? "添加人格" : "编辑人格").font(.headline)
                    Text("决定系统提示词与模型覆盖")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    FormField(label: "名称") {
                        TextField("例如：温柔助手", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    FormField(label: "简介", hint: "用于人格列表展示，可留空") {
                        TextField("一句话描述这个人格", text: $draft.summary)
                            .textFieldStyle(.roundedBorder)
                    }

                    FormField(
                        label: "系统提示词",
                        hint: "描述角色、语气、禁忌与回答长度。"
                    ) {
                        TextEditor(text: $draft.systemPrompt)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 170)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(Theme.hairline, lineWidth: 1)
                            }
                            .accessibilityLabel("系统提示词")
                    }

                    FormField(
                        label: "覆盖模型",
                        hint: "留空跟随通道；温度在「AI 模型 → 模型温度」中按模型统一配置"
                    ) {
                        TextField(
                            "例如 deepseek-chat",
                            text: Binding(
                                get: { draft.model ?? "" },
                                set: { draft.model = $0.isEmpty ? nil : $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: 220)
                    }

                    if let validationMessage {
                        InlineNotice(kind: .danger, title: "无法保存", message: validationMessage)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack(spacing: 9) {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "添加人格" : "保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 580, height: 620)
        .background(.regularMaterial)
    }

    private func save() {
        var candidate = draft
        candidate.name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.summary = candidate.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.systemPrompt = candidate.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !candidate.name.isEmpty else {
            validationMessage = "请填写人格名称。"
            return
        }
        guard !candidate.systemPrompt.isEmpty else {
            validationMessage = "请填写系统提示词，否则人格不会产生效果。"
            return
        }
        validationMessage = nil
        onSave(candidate)
        dismiss()
    }
}
