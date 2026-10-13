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
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: auxiliary ? "person.wave.2" : "waveform")
                    .foregroundStyle(auxiliary ? Color.purple : StudioTheme.success)
                Text(L(auxiliary ? "personas.redesign.auxiliary" : "personas.redesign.dictation"))
                    .foregroundStyle(StudioTheme.textSecondary)
                Spacer(minLength: 0)
                Button {
                    viewModel.openPersonaShortcutSettings()
                } label: {
                    Text((auxiliary ? viewModel.auxiliaryHotkey : viewModel.activationHotkey)
                        .map(HotkeyFormat.display) ?? L("personas.redesign.unset"))
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(StudioTheme.border))
                }
                .buttonStyle(.plain)
                .help(L("personas.redesign.shortcutsHelp"))
            }
            PersonaSelectionMenu(viewModel: viewModel,
                                 selection: auxiliary ? UUID(uuidString: viewModel.auxiliaryPersonaID) : viewModel
                                     .defaultPersonaSelectionID,
                                 allowsNone: !auxiliary, showsSummaries: true) { id in
                if auxiliary, let id {
                    viewModel.setAuxiliaryPersona(id.uuidString)
                } else {
                    viewModel.setDefaultPersonaSelection(id)
                }
            }
            .accessibilityIdentifier(auxiliary ? "personas.auxiliarySelection" : "personas.defaultSelection")
        }
        .font(.system(size: 12, weight: .medium))
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(PersonaPanelModifier())
    }

    private var appsCard: some View {
        VStack(alignment: .leading, spacing: narrow ? 0 : 12) {
            if !narrow {
                appTitle
            }
            HStack(spacing: 8) {
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
                    .lineLimit(1)
                if viewModel.personaAppBindingsEnabled, viewModel.pausedPersonaAppRuleCount > 0 {
                    Text(L("personas.redesign.pausedCount", viewModel.pausedPersonaAppRuleCount))
                        .foregroundStyle(StudioTheme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { viewModel.openPersonaAppRules() } label: {
                    HStack(spacing: 4) { Text(L("personas.redesign.manage")); Image(systemName: "chevron.right") }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(StudioTheme.border))
                .accessibilityIdentifier("personas.appRules")
            }
        }
        .font(.system(size: 11))
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(PersonaPanelModifier())
    }

    private var appTitle: some View {
        Label(L("personas.redesign.apps"), systemImage: "square.grid.2x2")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(StudioTheme.textSecondary)
    }
}

struct PersonaSelectionMenu: View {
    @ObservedObject var viewModel: StudioViewModel
    let selection: UUID?
    var allowsNone = true
    var showsSummaries = false
    let onSelect: (UUID?) -> Void
    @State private var presented = false

    private var noneTitle: String {
        L(showsSummaries ? "personas.redesign.none" : "personas.redesign.noneShort")
    }

    var body: some View {
        Button { presented.toggle() } label: {
            HStack {
                Text(selection == nil ? noneTitle : viewModel.personaTitle(selection)).lineLimit(1)
                    .foregroundStyle(isMissing ? Color.red : StudioTheme.textPrimary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(StudioTheme.controlSurface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(StudioTheme.border))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if allowsNone {
                        option(id: nil, title: noneTitle)
                        Divider()
                    }
                    group(title: L("settings.personas.custom"), personas: viewModel.personas.filter { !$0.isSystem })
                    group(title: L("personas.redesign.builtIn"), personas: viewModel.personas.filter(\.isSystem))
                }
                .padding(8)
            }
            .frame(width: 300, height: min(CGFloat(viewModel.personas.count) * (showsSummaries ? 50 : 34) + 100, 460))
            .background(StudioTheme.surface)
            .onExitCommand { presented = false }
        }
    }

    private var isMissing: Bool {
        selection.map { id in !viewModel.personas.contains { $0.id == id } } ?? false
    }

    @ViewBuilder private func group(title: String, personas: [PersonaProfile]) -> some View {
        if !personas.isEmpty {
            Text(title).font(.system(size: 10)).foregroundStyle(StudioTheme.textSecondary).padding(.horizontal, 8)
            ForEach(personas) { persona in
                option(id: persona.id, title: persona.name,
                       summary: showsSummaries ? viewModel.personaListSubtitle(for: persona) : nil)
            }
        }
    }

    private func option(id: UUID?, title: String, summary: String? = nil) -> some View {
        Button {
            onSelect(id)
            presented = false
        } label: {
            HStack {
                if selection == id {
                    Image(systemName: "checkmark")
                }
                VStack(alignment: .leading) {
                    Text(title).lineLimit(1)
                    if let summary {
                        Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12)).padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selection == id ? StudioTheme.accent.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("personas.pick." + (id?.uuidString ?? "none"))
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
                Image(systemName: "app.fill").resizable().foregroundStyle(StudioTheme.textSecondary)
            }
        }
        .scaledToFit().frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
