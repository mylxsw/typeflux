import Foundation

extension AskConversationModel {
    /// The launcher answers arithmetic itself unless the user turned it off.
    var quickCalculatorEnabled: Bool { modelLibrary.settings.askQuickCalculatorEnabled }
    /// The launcher lists matching applications unless the user turned it off.
    var quickAppsEnabled: Bool { modelLibrary.settings.askQuickAppSearchEnabled }

    /// A quick result was copied: the expression is done with, so the next
    /// launch starts empty instead of restoring it.
    func finishQuickResult() {
        launcherDraft.text = ""
        persistDrafts()
    }

    /// Opens an application from the launcher and ranks it higher next time.
    func openQuickApp(_ app: AskAppEntry) {
        appIndex.recordLaunch(app)
        openApplication(app.url)
        finishQuickResult()
    }

    /// Keeps the application list current; called when the launcher is built and opened.
    func refreshQuickApps() {
        guard quickAppsEnabled else { return }
        appIndex.refreshIfStale()
    }
}
