import SwiftUI

extension LauncherSearchSettingsView {
    // MARK: - Exclusions

    @ViewBuilder var excludeTab: some View {
        AgentSettingsSection(title: L("launcher.search.exclude.paths"), detail: "\(search.excludedPaths.count)") {
            ForEach(search.excludedPaths, id: \.self) { path in
                pathRow(path, icon: "folder.badge.minus") { update { $0.excludedPaths.removeAll { $0 == path } } }
            }
            AgentSettingsActionRow(icon: "plus", title: L("launcher.search.add")) {
                if let paths = Self.pickFolders(allowApps: false) {
                    update { $0.excludedPaths = Self.adding(paths, to: $0.excludedPaths) }
                }
            }
        }
        tagSection(title: L("launcher.search.exclude.types"), values: search.excludedExtensions,
                   placeholder: L("launcher.search.exclude.types.placeholder"), text: $newExtension,
                   clean: AskLauncherSearchSettings
                       .cleanExtension) { values in update { $0.excludedExtensions = values } }
        tagSection(title: L("launcher.search.exclude.names"), values: search.excludedFolderNames,
                   placeholder: L("launcher.search.exclude.names.placeholder"), text: $newFolderName,
                   clean: AskLauncherSearchSettings
                       .cleanFolderName) { values in update { $0.excludedFolderNames = values } }
        AgentSettingsSection(title: L("launcher.search.exclude.more"),
                             footnote: L("launcher.search.exclude.footnote")) {
            AgentSettingsRow(icon: "eye.slash", title: L("launcher.search.hidden"),
                             subtitle: L("launcher.search.hidden.subtitle"), subtitleLineLimit: nil) {
                Toggle("", isOn: binding(\.includeHidden)).labelsHidden().toggleStyle(.switch)
                    .accessibilityLabel(L("launcher.search.hidden"))
            }
            AgentSettingsActionRow(icon: "arrow.counterclockwise", title: L("launcher.search.reset")) {
                update {
                    $0.excludedPaths = AskLauncherSearchSettings.defaultExcludedPaths
                    $0.excludedExtensions = []
                    $0.excludedFolderNames = AskLauncherSearchSettings.defaultExcludedFolderNames
                    $0.includeHidden = false
                }
            }
        }
    }

    // The editor needs its label, input, cleaning rule and persistence callback together.
    // swiftlint:disable:next function_parameter_count
    private func tagSection(title: String, values: [String], placeholder: String, text: Binding<String>,
                            clean: @escaping (String) -> String?, save: @escaping ([String]) -> Void) -> some View {
        AgentSettingsSection(title: title, detail: "\(values.count)") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(values, id: \.self) { value in
                    HStack {
                        Text(value).font(.body.monospaced()).textSelection(.enabled)
                        Spacer()
                        TypefluxIconButton(L("ask.remove") + " " + value, systemImage: "minus") {
                            save(values.filter { $0 != value })
                        }
                    }
                }
                HStack(spacing: 8) {
                    TextField(placeholder, text: text).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                        .onSubmit { add(text, clean: clean, to: values, save: save) }
                    Button(L("launcher.search.add")) { add(text, clean: clean, to: values, save: save) }
                        .controlSize(.small)
                        .disabled(clean(text.wrappedValue) == nil)
                }
            }
        }
    }

    private func add(
        _ text: Binding<String>,
        clean: (String) -> String?,
        to values: [String],
        save: ([String]) -> Void
    ) {
        guard let value = clean(text.wrappedValue) else { return }
        if !values.contains(value) {
            save(values + [value])
        }
        text.wrappedValue = ""
    }
}
