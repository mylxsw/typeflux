import AppKit
import SwiftUI

struct StudioPersonaUsageStrip: View {
    @ObservedObject var viewModel: StudioViewModel
    let narrow: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                selectionCard(auxiliary: false)
                selectionCard(auxiliary: true)
                if !narrow {
                    appsCard
                }
            }
            if narrow {
                appsCard
            }
        }
    }

    private func selectionCard(auxiliary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TFIconTile(systemImage: auxiliary ? "person.wave.2" : "waveform",
                           tint: auxiliary ? .purple : TFColors.success, size: 22, style: .soft)
                Text(L(auxiliary ? "personas.redesign.auxiliary" : "personas.redesign.dictation"))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(TFColors.textSecondary)
                Spacer(minLength: 0)
                Button {
                    viewModel.openPersonaShortcutSettings()
                } label: {
                    TFKeyCap(text: (auxiliary ? viewModel.auxiliaryHotkey : viewModel.activationHotkey)
                        .map(HotkeyFormat.display) ?? L("personas.redesign.unset"))
                }
                .buttonStyle(.plain)
                .help(L("personas.redesign.shortcutsHelp"))
            }
            PersonaSelectionMenu(viewModel: viewModel,
                                 selection: auxiliary ? UUID(uuidString: viewModel.auxiliaryPersonaID) : viewModel
                                     .defaultPersonaSelectionID,
                                 allowsNone: !auxiliary, showsSummaries: true,
                                 identifier: auxiliary ? "personas.auxiliarySelection" : "personas.defaultSelection") { id in
                if auxiliary, let id {
                    viewModel.setAuxiliaryPersona(id.uuidString)
                } else {
                    viewModel.setDefaultPersonaSelection(id)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tfCardSurface()
    }

    private var appsCard: some View {
        VStack(alignment: .leading, spacing: narrow ? 0 : 10) {
            if !narrow {
                appTitle
            }
            HStack(spacing: TFMetrics.toolbarSpacing) {
                if narrow {
                    appTitle
                }
                HStack(spacing: -4) {
                    ForEach(Array(viewModel.personaAppBindings.prefix(4))) { binding in
                        PersonaAppIcon(identifier: binding.appIdentifier, size: 22)
                            .opacity(viewModel.personaAppBindingsEnabled && binding.isEnabled ? 1 : 0.4)
                    }
                }
                Text(viewModel.personaAppBindingsEnabled
                    ? L("personas.redesign.appCount", viewModel.personaAppBindings.count)
                    : L("personas.redesign.allPaused"))
                    .font(.system(size: 12)).foregroundStyle(TFColors.textPrimary)
                    .lineLimit(1)
                if viewModel.personaAppBindingsEnabled, viewModel.pausedPersonaAppRuleCount > 0 {
                    TFFootnote(text: L("personas.redesign.pausedCount", viewModel.pausedPersonaAppRuleCount))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                TFButton(title: L("personas.redesign.manage"), systemImage: "chevron.right", size: .small) {
                    viewModel.openPersonaAppRules()
                }
                .accessibilityIdentifier("personas.appRules")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tfCardSurface()
    }

    private var appTitle: some View {
        HStack(spacing: 6) {
            TFIconTile(systemImage: "square.grid.2x2", size: 22, style: .neutral)
            Text(L("personas.redesign.apps")).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TFColors.textSecondary)
        }
    }
}

/// Picks a persona (or none) from a panel listing custom and built-in personas with their summaries.
struct PersonaSelectionMenu: View {
    @ObservedObject var viewModel: StudioViewModel
    let selection: UUID?
    var allowsNone = true
    var showsSummaries = false
    var identifier: String?
    let onSelect: (UUID?) -> Void

    private var noneTitle: String {
        L(showsSummaries ? "personas.redesign.none" : "personas.redesign.noneShort")
    }

    var body: some View {
        TFRichPicker(title: selection == nil ? noneTitle : viewModel.personaTitle(selection), sections: sections,
                     selection: Binding(get: { selection }, set: onSelect), width: nil, identifier: identifier)
            .frame(maxWidth: .infinity)
    }

    private var sections: [TFRichSection<UUID?>] {
        var result: [TFRichSection<UUID?>] = []
        if allowsNone {
            result.append(TFRichSection(options: [TFRichOption(nil, noneTitle, identifier: "personas.pick.none")]))
        }
        for (title, personas) in [(L("settings.personas.custom"), viewModel.personas.filter { !$0.isSystem }),
                                  (L("personas.redesign.builtIn"), viewModel.personas.filter(\.isSystem))]
            where !personas.isEmpty {
            result.append(TFRichSection(title, options: personas.map { persona in
                TFRichOption(persona.id, persona.name,
                             subtitle: showsSummaries ? viewModel.personaListSubtitle(for: persona) : nil,
                             identifier: "personas.pick." + persona.id.uuidString)
            }))
        }
        return result
    }
}

struct PersonaAppIcon: View {
    let identifier: String
    var url: URL?
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let appURL = url ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path)).resizable()
            } else {
                Image(systemName: "app.fill").resizable().foregroundStyle(TFColors.textSecondary)
            }
        }
        .scaledToFit().frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
