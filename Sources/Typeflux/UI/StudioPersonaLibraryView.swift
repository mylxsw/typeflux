import SwiftUI

/// A bounded master-detail editor. Only the roster and prompt scroll; actions stay visible.
struct StudioPersonaLibraryView: View {
    @ObservedObject var viewModel: StudioViewModel
    let onDelete: (PersonaProfile) -> Void

    private var isReadOnly: Bool {
        viewModel.selectedPersonaIsSystem && !viewModel.isCreatingPersonaDraft
    }

    var body: some View {
        HStack(alignment: .top, spacing: StudioTheme.Spacing.section) {
            roster
                .frame(width: StudioTheme.Layout.personasListWidth)
            editor
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var roster: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.large) {
            HStack(spacing: StudioTheme.Spacing.xSmall) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(StudioTheme.textSecondary)
                TextField(L("studio.search.personas"), text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(L("studio.search.personas"))
                if !viewModel.searchQuery.isEmpty {
                    Button { viewModel.searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StudioTheme.textSecondary)
                    .accessibilityLabel(L("settings.personas.clearSearch"))
                }
            }
            .font(.studioBody(StudioTheme.Typography.body))
            .padding(StudioTheme.Spacing.smallMedium)
            .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.small))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: StudioTheme.Spacing.section) {
                    StudioPersonaRosterRow(
                        title: L("settings.personas.none"),
                        subtitle: L("persona.none.subtitle"),
                        systemImage: "slash.circle",
                        isSelected: !viewModel.isCreatingPersonaDraft && viewModel.selectedPersonaID == nil,
                        isDefault: viewModel.isDefaultPersona(nil)
                    ) { viewModel.selectPersona(nil) }

                    rosterGroup(title: L("settings.personas.builtIn"), personas: viewModel.filteredBuiltInPersonas)
                    rosterGroup(title: L("settings.personas.custom"), personas: viewModel.filteredCustomPersonas)

                    if viewModel.filteredPersonas.isEmpty && !viewModel.searchQuery.isEmpty {
                        Text(L("settings.personas.noResults"))
                            .font(.studioBody(StudioTheme.Typography.bodySmall))
                            .foregroundStyle(StudioTheme.textSecondary)
                            .padding(.horizontal, StudioTheme.Spacing.xSmall)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func rosterGroup(title: String, personas: [PersonaProfile]) -> some View {
        if !personas.isEmpty {
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                Text(title)
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .padding(.horizontal, StudioTheme.Spacing.xSmall)
                ForEach(personas) { persona in
                    StudioPersonaRosterRow(
                        title: persona.name,
                        subtitle: viewModel.personaListSubtitle(for: persona),
                        systemImage: nil,
                        isSelected: !viewModel.isCreatingPersonaDraft && viewModel.selectedPersonaID == persona.id,
                        isDefault: viewModel.isDefaultPersona(persona.id)
                    ) { viewModel.selectPersona(persona.id) }
                    .contextMenu {
                        if !persona.isSystem {
                            Button(L("common.delete"), role: .destructive) { onDelete(persona) }
                        }
                    }
                }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.cardGroup) {
            HStack {
                Text(L("settings.personas.settingsTitle"))
                    .font(.studioBody(StudioTheme.Typography.settingTitle, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Spacer()
                if !viewModel.isCreatingPersonaDraft {
                    defaultButton
                }
            }
            .frame(minHeight: 32)

            if !viewModel.isCreatingPersonaDraft && viewModel.selectedPersonaID == nil {
                Text(L("persona.none.subtitle"))
                    .font(.studioBody(StudioTheme.Typography.body))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                nameField
                promptField
                editorFooter
            }
        }
        .padding(StudioTheme.Insets.cardDefault)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(StudioTheme.cardSurface, in: RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero))
        .overlay {
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.hero)
                .stroke(StudioTheme.border.opacity(StudioTheme.Opacity.cardBorder), lineWidth: 1)
        }
    }

    private var defaultButton: some View {
        Button {
            guard !viewModel.isEditingDefaultPersona else { return }
            if viewModel.selectedPersonaID == nil {
                viewModel.deactivatePersonaRewrite()
            } else {
                viewModel.activateSelectedPersona()
            }
        } label: {
            Label(L("settings.models.useAsDefault"), systemImage: "checkmark.circle.fill")
                .font(.studioBody(StudioTheme.Typography.bodySmall, weight: .medium))
                .foregroundStyle(viewModel.isEditingDefaultPersona ? StudioTheme.success : StudioTheme.textPrimary)
                .padding(.horizontal, StudioTheme.Spacing.smallMedium)
                .padding(.vertical, StudioTheme.Spacing.xSmall)
                .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.small))
                .overlay {
                    RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.small)
                        .stroke(StudioTheme.border, lineWidth: 1)
                }
        }
        .buttonStyle(StudioInteractiveButtonStyle())
        .accessibilityValue(viewModel.isEditingDefaultPersona ? L("settings.personas.default") : "")
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
            fieldLabel(L("settings.personas.name"))
            TextField(L("settings.personas.namePlaceholder"), text: $viewModel.personaDraftName)
                .textFieldStyle(.plain)
                .font(.studioBody(StudioTheme.Typography.body))
                .foregroundStyle(StudioTheme.textPrimary)
                .padding(StudioTheme.Spacing.smallMedium)
                .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.small))
                .overlay {
                    RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.small)
                        .stroke(StudioTheme.border, lineWidth: 1)
                }
                .disabled(isReadOnly)
                .accessibilityLabel(L("settings.personas.name"))
        }
    }

    private var promptField: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.xSmall) {
            fieldLabel(L("settings.personas.prompt"))
            TextEditor(text: $viewModel.personaDraftPrompt)
                .font(.studioBody(StudioTheme.Typography.body))
                .foregroundStyle(StudioTheme.textPrimary)
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .disabled(isReadOnly)
                .padding(StudioTheme.Spacing.smallMedium)
                .frame(minHeight: 0, maxHeight: .infinity)
                .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.small))
                .overlay {
                    RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.small)
                        .stroke(StudioTheme.border, lineWidth: 1)
                }
                .accessibilityLabel(L("settings.personas.prompt"))
        }
        .frame(maxHeight: .infinity)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.studioBody(StudioTheme.Typography.bodySmall))
            .foregroundStyle(StudioTheme.textSecondary)
    }

    private var editorFooter: some View {
        HStack(spacing: StudioTheme.Spacing.large) {
            if isReadOnly {
                fieldLabel(L("settings.personas.readOnly"))
            } else {
                if viewModel.hasPersonaDraftChanges {
                    fieldLabel(L("settings.personas.unsaved"))
                }
                Spacer(minLength: StudioTheme.Spacing.small)
                StudioButton(title: L("common.cancel"), systemImage: nil, variant: .ghost) {
                    viewModel.cancelPersonaEditing()
                }
                StudioButton(
                    title: L("settings.personas.saveChanges"),
                    systemImage: nil,
                    variant: .primary,
                    isDisabled: !viewModel.canSavePersonaDraft || !viewModel.hasPersonaDraftChanges
                ) { viewModel.savePersonaDraft() }
            }
        }
        .frame(minHeight: 34)
    }
}

private struct StudioPersonaRosterRow: View {
    let title: String
    let subtitle: String
    let systemImage: String?
    let isSelected: Bool
    let isDefault: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: StudioTheme.Spacing.smallMedium) {
                Group {
                    if let systemImage {
                        Image(systemName: systemImage)
                    } else {
                        Text(String(title.prefix(StudioTheme.Count.personaInitials)).uppercased())
                    }
                }
                .font(.studioBody(StudioTheme.Typography.bodySmall, weight: .semibold))
                .foregroundStyle(isSelected ? StudioTheme.accent : StudioTheme.textSecondary)
                .frame(width: 36, height: 36)
                .background(StudioTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.small))

                VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxSmall) {
                    Text(title)
                        .font(.studioBody(StudioTheme.Typography.body, weight: .medium))
                        .foregroundStyle(StudioTheme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.studioBody(StudioTheme.Typography.caption))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isDefault {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: StudioTheme.Typography.iconRegular))
                        .foregroundStyle(StudioTheme.success)
                }
            }
            .padding(StudioTheme.Spacing.xSmall)
            .frame(minHeight: 56)
            .background(
                isSelected ? StudioTheme.accent.opacity(0.10) : (isHovered ? StudioTheme.surfaceMuted : Color.clear),
                in: RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.small)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(title + ", " + subtitle)
        .accessibilityValue(isDefault ? L("settings.personas.default") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
