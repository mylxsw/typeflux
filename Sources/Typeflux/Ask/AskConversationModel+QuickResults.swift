import AppKit
import Foundation

/// What the launcher does after an action on a found application or file.
enum AskQuickActionOutcome: Equatable {
    case close
    case stay
    /// Show this panel instead (the applications for "Open With").
    case panel(AskQuickActionPanel)
    /// Put this in the editor (file mode in a folder).
    case text(String)
}

extension AskConversationModel {
    /// The launcher answers arithmetic itself unless the user turned it off.
    var quickCalculatorEnabled: Bool { modelLibrary.settings.askQuickCalculatorEnabled }
    /// The launcher lists matching applications unless the user turned it off.
    var quickAppsEnabled: Bool { modelLibrary.settings.askQuickAppSearchEnabled }
    /// The launcher lists matching files and folders unless the user turned it off.
    var quickFilesEnabled: Bool { modelLibrary.settings.askQuickFileSearchEnabled }
    /// Settings › Launcher › Search.
    var launcherSearchSettings: AskLauncherSearchSettings { modelLibrary.settings.askLauncherSearchSettings }

    /// A quick result was copied: the expression is done with, so the next
    /// launch starts empty instead of restoring it.
    func finishQuickResult() {
        launcherDraft.text = ""
        persistDrafts()
        AskQuickLook.shared.close()
    }

    /// Opens an application or settings pane from the launcher and ranks it higher next time.
    func openQuickApp(_ app: AskAppEntry) {
        appIndex.recordLaunch(app)
        if let settingsURL = app.settingsURL { openURL(settingsURL) } else { openApplication(app.url) }
        finishQuickResult()
    }

    /// Keeps the application list and the file index current; called when the launcher is built and opened.
    func refreshQuickApps() {
        if quickAppsEnabled { appIndex.refreshIfStale() }
        fileIndex.start()
    }

    /// Starts a question about a file: the launcher leaves keyword mode, empties its
    /// text and takes the file as an attachment.
    func attachFileToLauncher(_ url: URL) {
        plugins.deactivate()
        launcherDraft.text = ""
        addAttachments([.file(url)], launcher: true)
    }

    /// Carries out an action on an application from the launcher.
    func performQuickAppAction(_ action: AskQuickAction, _ app: AskAppEntry) -> AskQuickActionOutcome {
        switch action {
        case .reveal:
            revealFile(app.url)
        case .copyPath:
            AskQuickResults.copy(app.url.path)
        case .quit:
            if let id = app.bundleID {
                NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() }
            }
        default:
            openQuickApp(app)
            return .close
        }
        finishQuickResult()
        return .close
    }

    /// Carries out an action on a found file or folder. Opening checks that it is still
    /// there; one that is gone leaves the index and the launcher says so. One case
    /// per action; splitting them would only scatter them.
    func performQuickFileAction(_ action: AskQuickAction, _ file: AskFileHit) -> AskQuickActionOutcome { // swiftlint:disable:this cyclomatic_complexity
        let url = file.url
        if action != .copyPath, action != .copyName, !fileExists(file.path) {
            fileIndex.forget(file.path)
            confirm(L("ask.quick.file.gone"), for: .seconds(3))
            return .stay
        }
        switch action {
        case .open:
            fileIndex.recordOpen(file.path)
            openURL(url)
        case .openWith:
            let applications = AskQuickActionPanel.applications(for: url)
            guard !applications.isEmpty else { return performQuickFileAction(.open, file) }
            return .panel(AskQuickActionPanel(target: .file(file), actions: applications))
        case let .openIn(application):
            fileIndex.recordOpen(file.path)
            openFileWith(url, application)
        case .reveal:
            revealFile(url)
        case .quickLook:
            AskQuickLook.shared.toggle(url)
            return .stay
        case .copyPath:
            AskQuickResults.copy(file.path)
        case .copyFile:
            let pasteboard = AskQuickResults.pasteboard
            pasteboard.clearContents()
            pasteboard.writeObjects([url as NSURL])
        case .copyName:
            AskQuickResults.copy(file.name)
        case .askAI:
            attachFileToLauncher(url)
            return .stay
        case .openInTerminal:
            openFileWith(url, URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        case .searchInFolder:
            let keyword = plugins.availableKeywords.first { $0.enabled && $0.pluginID == AskFileSearchPlugin.id }
            guard let keyword else { return .stay }
            return .text(keyword.keyword + " in:" + file.name.filter { !$0.isWhitespace } + " ")
        case .trash:
            guard trashFile(url) else {
                confirm(L("ask.quick.file.trashFailed"), for: .seconds(3))
                return .stay
            }
            fileIndex.forget(file.path)
        case .quit:
            return .stay
        }
        finishQuickResult()
        return .close
    }
}
