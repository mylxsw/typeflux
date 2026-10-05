import Foundation

extension AskConversationModel {
    /// The launcher answers arithmetic itself unless the user turned it off.
    var quickResultsEnabled: Bool { modelLibrary.settings.askQuickCalculatorEnabled }

    /// A quick result was copied: the expression is done with, so the next
    /// launch starts empty instead of restoring it.
    func finishQuickResult() {
        launcherDraft.text = ""
        persistDrafts()
    }
}
