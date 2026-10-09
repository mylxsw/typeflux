/// What Esc does in the launcher: one layer at a time, from the topmost.
/// A preview or menu closes first, then a pending question or a running
/// keyword, then keyword mode itself, and only then the launcher (which keeps
/// its draft for next time).
enum AskLauncherEscape: Equatable {
    case closeQuickLook
    /// A glass menu (attach, model, storage, context) or a found item's actions.
    case closeMenu
    case closeActions
    /// A workflow waiting for permission is told no.
    case declineApproval
    case cancelRun
    /// Back to the plain launcher, keeping what was typed after the keyword.
    case exitKeyword
    case closeLauncher

    struct State: Equatable {
        var quickLook = false
        var menu = false
        var actions = false
        var approval = false
        var running = false
        var keyword = false
    }

    static func resolve(_ state: State) -> AskLauncherEscape {
        if state.quickLook { return .closeQuickLook }
        if state.menu { return .closeMenu }
        if state.actions { return .closeActions }
        if state.approval { return .declineApproval }
        if state.running { return .cancelRun }
        if state.keyword { return .exitKeyword }
        return .closeLauncher
    }
}
