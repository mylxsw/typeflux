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
        TypefluxForm {
            StudioPersonaUsageStrip(viewModel: viewModel)
            Section {
                header
                if readOnly {
                    TypefluxSettingsRow(L("personas.redesign.builtInNote")) {
                        Button(L("personas.redesign.copyToEdit")) {
                            if let persona = viewModel.selectedPersona {
                                viewModel.duplicatePersona(persona)
                            }
                        }.buttonStyle(.bordered)
                    }
                }
                HStack {
                    Text(L("settings.personas.prompt"))
                    Spacer()
                    if viewModel.isCreatingPersonaDraft {
                        templateMenu
                    } else {
                        Text(L("personas.redesign.characterCount", viewModel.personaDraftPrompt.count))
                    }
                }.font(.subheadline).foregroundStyle(.secondary)
                definition
                if viewModel.isCreatingPersonaDraft || viewModel.hasPersonaDraftChanges {
                    HStack {
                        Spacer()
                        Button(L(viewModel
                                .isCreatingPersonaDraft ? "common.cancel" : "personas.redesign.discardChanges")) {
                            viewModel.cancelPersonaEditing()
                        }
                        Button(L(viewModel
                                .isCreatingPersonaDraft ? "personas.redesign.create" : "personas.redesign.save")) {
                            viewModel.savePersonaDraft()
                        }.buttonStyle(.borderedProminent).disabled(!viewModel.canSavePersonaDraft)
                            .accessibilityIdentifier("personas.saveDraft").keyboardShortcut("s", modifiers: .command)
                    }.accessibilityIdentifier("personas.saveBar")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let message = viewModel.personaUndoMessage, viewModel.personaPendingDeletion == nil {
                Group {
                    HStack {
                        Text(message).font(.callout)
                        Spacer()
                        Button(L("personas.redesign.undo")) { viewModel.undoPersonaChange() }
                            .accessibilityIdentifier("personas.undoAction")
                        TypefluxIconButton(L("personas.redesign.close"), systemImage: "xmark") {
                            viewModel.dismissPersonaUndo()
                        }
                    }.padding(8).background(TypefluxColor.contentBackground.color)
                        .accessibilityIdentifier("personas.undo")
                }
            }
        }
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
                Text(L("personas.redesign.builtIn")).font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                TextField(L("settings.personas.namePlaceholder"), text: $viewModel.personaDraftName)
                    .textFieldStyle(.roundedBorder).focused($nameFocused)
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
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .accessibilityLabel(L("personas.redesign.more"))
            }
        }
        .font(.body)
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
        } label: { Text(L("personas.redesign.setAs")) }
            .menuStyle(.borderlessButton)
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
                Text(viewModel.personaDraftPrompt).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                TextEditor(text: $viewModel.personaDraftPrompt)
                    .frame(minHeight: 180)
                    .accessibilityIdentifier("personas.definition")
            }
        }.font(.body).accessibilityLabel(L("settings.personas.prompt"))
    }
}
