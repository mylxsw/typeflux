enum OnboardingFileSearchChoice: String, CaseIterable {
    case off, names, contents

    init(settings: SettingsStore) {
        guard settings.askQuickFileSearchEnabled else {
            self = .off
            return
        }
        self = settings.semanticFileSearch.enabled && Self.supportsContents ? .contents : .names
    }

    static let supportsContents = SemanticFilePolicy.supported

    var icon: String {
        switch self {
        case .off: "folder"
        case .names: "magnifyingglass"
        case .contents: "doc.text.magnifyingglass"
        }
    }
}

extension OnboardingViewModel {
    func applyFileSearchChoice() {
        let enabled = fileSearchChoice != .off
        let contents = fileSearchChoice == .contents && OnboardingFileSearchChoice.supportsContents

        // Stop any existing content work before changing a scope that will only be searched by name.
        if !enabled { settingsStore.askQuickFileSearchEnabled = false }
        if !contents, settingsStore.semanticFileSearch.enabled {
            settingsStore.semanticFileSearch = .init()
        }
        guard enabled else { return }

        var search = settingsStore.askLauncherSearchSettings
        if search.fileRoots != fileSearchFolders {
            search.fileRoots = fileSearchFolders
            settingsStore.askLauncherSearchSettings = search
        }
        // Save the scope before enabling the indexes.
        settingsStore.askQuickFileSearchEnabled = true
        if contents, !settingsStore.semanticFileSearch.enabled {
            settingsStore.semanticFileSearch = .init(enabled: true)
        }
    }
}
