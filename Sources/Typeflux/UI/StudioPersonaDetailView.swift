import AppKit
import SwiftUI

struct StudioPersonaDetailView: View {
    @ObservedObject var viewModel: StudioViewModel
    let onDelete: (PersonaProfile) -> Void
    @FocusState private var nameFocused: Bool

    private var readOnly: Bool {
        viewModel.selectedPersonaIsSystem && !viewModel.isCreatingPersonaDraft
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            if readOnly {
                HStack(spacing: 8) {
                    Image(systemName: "lock")
                    Text(L("personas.redesign.builtInNote")).font(.system(size: 11)).lineLimit(2)
                    Spacer(minLength: 0)
                    Button(L("personas.redesign.copyToEdit")) {
                        if let persona = viewModel.selectedPersona {
                            viewModel.duplicatePersona(persona)
                        }
                    }
                    .buttonStyle(.plain).font(.system(size: 11)).fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(StudioTheme.border))
                }
                .foregroundStyle(StudioTheme.textSecondary)
                .padding(10)
                .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Text(L("settings.personas.prompt"))
                Spacer()
                if viewModel.isCreatingPersonaDraft {
                    templateMenu
                } else {
                    Text(L("personas.redesign.characterCount", viewModel.personaDraftPrompt.count))
                }
            }
            .font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
            definition
            if viewModel.isCreatingPersonaDraft {
                HStack {
                    Spacer()
                    StudioButton(title: L("common.cancel"), systemImage: nil, variant: .ghost) {
                        viewModel.cancelPersonaEditing()
                    }
                    StudioButton(title: L("personas.redesign.create"), systemImage: nil, variant: .primary,
                                 isDisabled: !viewModel.canSavePersonaDraft) { viewModel.savePersonaDraft() }
                        .accessibilityIdentifier("personas.saveDraft")
                        .keyboardShortcut("s", modifiers: .command)
                }
            } else if viewModel.hasPersonaDraftChanges {
                HStack {
                    Spacer()
                    StudioButton(title: L("personas.redesign.discardChanges"), systemImage: nil, variant: .ghost) {
                        viewModel.cancelPersonaEditing()
                    }
                    StudioButton(title: L("personas.redesign.save"), systemImage: nil, variant: .primary,
                                 isDisabled: !viewModel.canSavePersonaDraft) { viewModel.savePersonaDraft() }
                        .accessibilityIdentifier("personas.saveDraft")
                        .keyboardShortcut("s", modifiers: .command)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("personas.saveBar")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(PersonaPanelModifier())
        .task(id: viewModel.personaDraftCreationID) {
            guard viewModel.isCreatingPersonaDraft else { return }
            nameFocused = true
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, viewModel.isCreatingPersonaDraft else { return }
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if readOnly {
                Text(viewModel.personaDraftName).lineLimit(1)
                Text(L("personas.redesign.builtIn")).font(.system(size: 10))
                    .foregroundStyle(StudioTheme.textSecondary).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(StudioTheme.controlSurface, in: Capsule())
            } else {
                TextField(L("settings.personas.namePlaceholder"), text: $viewModel.personaDraftName)
                    .textFieldStyle(.plain).focused($nameFocused)
                    .accessibilityLabel(L("settings.personas.name"))
                    .accessibilityIdentifier("personas.name")
            }
            Spacer(minLength: 0)
            if !viewModel.isCreatingPersonaDraft, let persona = viewModel.selectedPersona {
                usageMenu(persona)
                Menu {
                    Button(L("personas.redesign.duplicate")) { viewModel.duplicatePersona(persona) }
                    if !persona.isSystem {
                        Divider()
                        Button(L("personas.redesign.delete"), role: .destructive) { onDelete(persona) }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 22, height: 20) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .accessibilityLabel(L("personas.redesign.more"))
            }
        }
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(StudioTheme.textPrimary)
        .frame(height: 28)
    }

    private func usageMenu(_ persona: PersonaProfile) -> some View {
        Menu {
            Button { viewModel.toggleDefaultPersona(persona.id) } label: {
                Label(
                    L("personas.redesign.dictation"),
                    systemImage: viewModel.isDefaultPersona(persona.id) ? "checkmark" : "waveform"
                )
            }
            Button { viewModel.useAuxiliaryPersona(persona.id) } label: {
                Label(
                    L("personas.redesign.auxiliary"),
                    systemImage: viewModel.auxiliaryPersonaID == persona.id.uuidString ? "checkmark" : "person.wave.2"
                )
            }
            Divider()
            Button(L("personas.redesign.useInApp")) { viewModel.openPersonaAppRules(adding: true, preset: persona.id) }
        } label: {
            Text(L("personas.redesign.setAs")).font(.system(size: 11))
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(StudioTheme.border))
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(StudioTheme.border))
    }

    private var templateMenu: some View {
        Menu {
            Button(L("personas.redesign.blank")) { viewModel.applyPersonaDraftTemplate(nil) }
            ForEach(viewModel.personas.filter(\.isSystem)) { persona in
                Button(L("personas.redesign.basedOn", persona.name)) { viewModel.applyPersonaDraftTemplate(persona.id) }
            }
            if viewModel.personas.contains(where: { !$0.isSystem }) {
                Divider()
                ForEach(viewModel.personas.filter { !$0.isSystem }) { persona in
                    Button(persona.name) { viewModel.applyPersonaDraftTemplate(persona.id) }
                }
            }
        } label: { Text(L("personas.redesign.startingPoint", viewModel.personaDraftTemplateTitle)) }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityIdentifier("personas.template")
    }

    private var definition: some View {
        Group {
            if readOnly {
                ScrollView {
                    Text(viewModel.personaDraftPrompt).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
                }
            } else {
                TextEditor(text: $viewModel.personaDraftPrompt)
                    .scrollContentBackground(.hidden).padding(8)
                    .accessibilityIdentifier("personas.definition")
            }
        }
        .font(.system(size: 13)).lineSpacing(5).foregroundStyle(StudioTheme.textPrimary)
        .frame(minHeight: 0, maxHeight: .infinity)
        .background(StudioTheme.controlSurface.opacity(readOnly ? 0.25 : 1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioTheme.border))
        .accessibilityLabel(L("settings.personas.prompt"))
    }
}
