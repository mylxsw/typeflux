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
            TFDivider(inset: 0)
            if readOnly {
                HStack(spacing: TFMetrics.toolbarSpacing) {
                    TFNotice(text: L("personas.redesign.builtInNote"))
                    TFButton(title: L("personas.redesign.copyToEdit"), systemImage: "doc.on.doc", size: .small) {
                        if let persona = viewModel.selectedPersona {
                            viewModel.duplicatePersona(persona)
                        }
                    }
                }
            }
            HStack {
                TFSectionHeader(title: L("settings.personas.prompt"))
                Spacer()
                if viewModel.isCreatingPersonaDraft {
                    templateMenu
                } else {
                    TFFootnote(text: L("personas.redesign.characterCount", viewModel.personaDraftPrompt.count))
                }
            }
            definition
            if viewModel.isCreatingPersonaDraft {
                HStack(spacing: TFMetrics.toolbarSpacing) {
                    Spacer()
                    TFButton(title: L("common.cancel"), kind: .plain) { viewModel.cancelPersonaEditing() }
                    TFButton(title: L("personas.redesign.create"), kind: .primary) { viewModel.savePersonaDraft() }
                        .disabled(!viewModel.canSavePersonaDraft)
                        .accessibilityIdentifier("personas.saveDraft")
                        .keyboardShortcut("s", modifiers: .command)
                }
            } else if viewModel.hasPersonaDraftChanges {
                HStack(spacing: TFMetrics.toolbarSpacing) {
                    Spacer()
                    TFButton(title: L("personas.redesign.discardChanges"), kind: .plain) {
                        viewModel.cancelPersonaEditing()
                    }
                    TFButton(title: L("personas.redesign.save"), kind: .primary) { viewModel.savePersonaDraft() }
                        .disabled(!viewModel.canSavePersonaDraft)
                        .accessibilityIdentifier("personas.saveDraft")
                        .keyboardShortcut("s", modifiers: .command)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("personas.saveBar")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tfCardSurface()
        .task(id: viewModel.personaDraftCreationID) {
            guard viewModel.isCreatingPersonaDraft else { return }
            nameFocused = true
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, viewModel.isCreatingPersonaDraft else { return }
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
        }
    }

    private var header: some View {
        HStack(spacing: TFMetrics.toolbarSpacing) {
            if readOnly {
                Text(viewModel.personaDraftName).lineLimit(1)
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(TFColors.textPrimary)
                TFTag(text: L("personas.redesign.builtIn"))
            } else {
                TextField(L("settings.personas.namePlaceholder"), text: $viewModel.personaDraftName)
                    .textFieldStyle(.plain).focused($nameFocused)
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(TFColors.textPrimary)
                    .accessibilityLabel(L("settings.personas.name"))
                    .accessibilityIdentifier("personas.name")
            }
            Spacer(minLength: 0)
            if !viewModel.isCreatingPersonaDraft, let persona = viewModel.selectedPersona {
                usageMenu(persona)
                TFMenuButton(title: L("personas.redesign.more"), systemImage: "ellipsis", kind: .plain,
                             size: .small, iconOnly: true, actions: [
                                 .action(L("personas.redesign.duplicate")) { viewModel.duplicatePersona(persona) }
                             ] + (persona.isSystem ? [] : [
                                 .separator,
                                 .action(L("personas.redesign.delete"), destructive: true) { onDelete(persona) }
                             ]))
            }
        }
        .frame(height: 28)
    }

    private func usageMenu(_ persona: PersonaProfile) -> some View {
        TFMenuButton(title: L("personas.redesign.setAs"), size: .small, actions: [
            .action(L("personas.redesign.dictation"),
                    systemImage: viewModel.isDefaultPersona(persona.id) ? "checkmark" : "waveform") {
                viewModel.toggleDefaultPersona(persona.id)
            },
            .action(L("personas.redesign.auxiliary"),
                    systemImage: viewModel.auxiliaryPersonaID == persona.id.uuidString ? "checkmark" : "person.wave.2") {
                viewModel.useAuxiliaryPersona(persona.id)
            },
            .separator,
            .action(L("personas.redesign.useInApp")) {
                viewModel.openPersonaAppRules(adding: true, preset: persona.id)
            }
        ])
    }

    private var templateMenu: some View {
        let system = viewModel.personas.filter(\.isSystem)
        let custom = viewModel.personas.filter { !$0.isSystem }
        var actions: [TFMenuAction] = [.action(L("personas.redesign.blank")) { viewModel.applyPersonaDraftTemplate(nil) }]
        actions += system.map { persona in
            .action(L("personas.redesign.basedOn", persona.name)) { viewModel.applyPersonaDraftTemplate(persona.id) }
        }
        if !custom.isEmpty {
            actions.append(.separator)
            actions += custom.map { persona in
                .action(persona.name) { viewModel.applyPersonaDraftTemplate(persona.id) }
            }
        }
        return TFMenuButton(title: L("personas.redesign.startingPoint", viewModel.personaDraftTemplateTitle),
                            kind: .plain, size: .small, actions: actions, identifier: "personas.template")
    }

    private var definition: some View {
        let shape = RoundedRectangle(cornerRadius: TFMetrics.textAreaCornerRadius, style: .continuous)
        return Group {
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
        .font(.system(size: 13)).lineSpacing(5).foregroundStyle(TFColors.textPrimary)
        .frame(minHeight: 0, maxHeight: .infinity)
        .background(TFColors.control.opacity(readOnly ? 0.5 : 1), in: shape)
        .overlay(shape.strokeBorder(TFColors.border, lineWidth: TFMetrics.borderWidth))
        .accessibilityLabel(L("settings.personas.prompt"))
    }
}
