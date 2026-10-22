import Foundation
import Network

/// What the composer offers while Typeflux Cloud cannot be reached and its model is a
/// Cloud model. Messages are never queued for later; the user picks a model that works.
enum AskOfflineSuggestion: Equatable {
    /// A new conversation can switch to this local model; it then runs on this Mac and
    /// synchronizes once the network returns.
    case useLocalModel(String)
    /// A started conversation that runs in Typeflux Cloud carries on in a new one on
    /// this Mac, with this local model.
    case continueLocally(String)
    /// No local model is configured; only Settings can help.
    case needsLocalModel
}

extension AskConversationModel {
    func offlineSuggestion(launcher: Bool) -> AskOfflineSuggestion? {
        guard !networkAvailable, isSignedIn, modelReference(launcher: launcher).hasPrefix("cloud:") else { return nil }
        let hasImage = requiresVision(launcher: launcher)
        guard let local = modelLibrary.firstLocalReference(hasImage: hasImage)
            ?? modelLibrary.firstLocalReference(hasImage: hasImage, confirmedVision: false) else { return .needsLocalModel }
        if launcher || selectedId == nil { return .useLocalModel(local) }
        return .continueLocally(local)
    }

    func applyOfflineSuggestion(_ suggestion: AskOfflineSuggestion, launcher: Bool) {
        switch suggestion {
        case let .useLocalModel(reference):
            selectModel(reference, launcher: launcher)
        case let .continueLocally(reference):
            continueInNew(conversationKind(launcher: false))
            selectModel(reference, launcher: false)
        case .needsLocalModel:
            break
        }
    }

    /// Follows the system's network path; a test or preview sets `networkAvailable` directly.
    func startNetworkMonitor() {
        guard networkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in self?.networkAvailable = available }
        }
        monitor.start(queue: DispatchQueue(label: "typeflux.ask.network"))
        networkMonitor = monitor
    }
}
