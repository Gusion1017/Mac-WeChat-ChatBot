import SwiftUI

/// Persona card used in the adaptive grid.
struct PersonaCard: View {
    let persona: Persona
    var isDefault: Bool
    var onEdit: () -> Void
    var onSetDefault: () -> Void
    var onDelete: () -> Void

    private var tint: Color { Theme.avatarTint(for: persona.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [tint, tint.opacity(0.68)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 34, height: 34)
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(persona.name.isEmpty ? "未命名人格" : persona.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if isDefault {
                            PillLabel(text: "默认", color: Theme.accent, symbol: "star.fill", filled: true)
                        }
                    }
                }
                Spacer(minLength: 2)
                Menu {
                    Button(L("编辑…"), action: onEdit)
                    Button(L("设为默认人格"), action: onSetDefault)
                        .disabled(isDefault)
                    Divider()
                    Button(L("删除人格…"), role: .destructive, action: onDelete)
                        .disabled(isDefault)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(L("\(persona.name) 更多操作"))
            }

            if !persona.summary.isEmpty {
                Text(persona.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(persona.systemPrompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 8) {
                if let model = persona.model, !model.isEmpty {
                    Label(model, systemImage: "cpu")
                }
                Spacer(minLength: 4)
                Button(L("编辑")) { onEdit() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(tint.opacity(0.045)), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }
}
