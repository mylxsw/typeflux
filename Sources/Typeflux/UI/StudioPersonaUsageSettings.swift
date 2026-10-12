import SwiftUI

/// Input defaults stay visible above the persona roster without replacing the current editor draft.
struct StudioPersonaUsageSettings: View {
    @ObservedObject var viewModel: StudioViewModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: StudioTheme.Spacing.large) {
                defaultSelection
                auxiliarySelection
            }
            VStack(spacing: StudioTheme.Spacing.small) {
                defaultSelection
                auxiliarySelection
            }
        }
    }

    private var defaultSelection: some View {
        selectionControl(title: L("settings.personaDefault.title"),
                      help: L("settings.personaDefault.subtitle"), icon: "person.crop.circle.badge.checkmark") {
            StudioMenuPicker(
                options: [(label: L("persona.none.title"), value: nil as UUID?)]
                    + viewModel.personas.map { (label: $0.name, value: $0.id as UUID?) },
                selection: Binding(
                    get: { viewModel.defaultPersonaSelectionID },
                    set: viewModel.setDefaultPersonaSelection
                ),
                width: 160
            )
            .accessibilityLabel(L("settings.personaDefault.title"))
            .accessibilityIdentifier("personas.defaultSelection")
        }
    }

    private var auxiliarySelection: some View {
        selectionControl(title: L("settings.shortcuts.auxiliary.persona"),
                      help: L("settings.personaAuxiliary.subtitle"), icon: "person.wave.2") {
            StudioMenuPicker(
                options: viewModel.personas.map { (label: $0.name, value: $0.id.uuidString) },
                selection: Binding(
                    get: { viewModel.auxiliaryPersonaID },
                    set: viewModel.setAuxiliaryPersona
                ),
                width: 160
            )
            .accessibilityLabel(L("settings.shortcuts.auxiliary.persona"))
            .accessibilityIdentifier("personas.auxiliarySelection")
        }
    }

    private func selectionControl(title: String, help: String, icon: String,
                               @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: StudioTheme.Spacing.small) {
            Label(title, systemImage: icon)
                .font(.studioBody(StudioTheme.Typography.bodySmall, weight: .medium))
                .foregroundStyle(StudioTheme.textSecondary)
                .fixedSize()
            control()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help)
    }
}
