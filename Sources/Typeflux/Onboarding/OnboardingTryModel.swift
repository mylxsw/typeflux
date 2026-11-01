import Combine
import Foundation

@MainActor
final class OnboardingTryModel: ObservableObject {
    enum Feature: String, CaseIterable, Identifiable {
        case voice
        case launcher
        case ring
        case chat

        var id: String {
            rawValue
        }

        var iconSymbol: String {
            switch self {
            case .voice: "mic"
            case .launcher: "magnifyingglass"
            case .ring: "circle.circle"
            case .chat: "bubble.left.and.bubble.right"
            }
        }
    }

    weak var session: OnboardingViewModel?

    @Published var canContinue: Bool? = nil
    @Published var isBusy = false
    @Published var primaryAction: (() -> Void)?

    @Published var selectedFeature: Feature = .voice
    @Published private(set) var triedFeatures: Set<Feature> = []

    init(session: OnboardingViewModel) {
        self.session = session
    }

    func isTried(_ feature: Feature) -> Bool {
        if feature == .voice {
            return session?.voicePracticeSucceeded == true
        }
        return triedFeatures.contains(feature)
    }

    func markTried(_ feature: Feature) {
        guard feature != .voice, isConnected(feature) else { return }
        triedFeatures.insert(feature)
    }

    var isVoiceConnected: Bool {
        guard let session else { return false }
        if session.serviceRoute == .launcherOnly {
            return false
        }
        if session.speechSkipped {
            return false
        }
        if session.serviceRoute == .custom, !session.speechConfigured {
            return false
        }
        return true
    }

    var isAIConnected: Bool {
        guard let session else { return false }
        if session.serviceRoute == .launcherOnly {
            return false
        }
        if session.aiSkipped {
            return false
        }
        if session.serviceRoute == .custom, !session.languageConfigured {
            return false
        }
        return true
    }

    func isConnected(_ feature: Feature) -> Bool {
        switch feature {
        case .voice: isVoiceConnected
        case .launcher: true
        case .ring: true
        case .chat: isAIConnected
        }
    }

    func shortcutKeys(for feature: Feature) -> [String] {
        guard let session else { return [] }
        switch feature {
        case .voice:
            return session.settingsStore.activationHotkey.map(HotkeyFormat.components) ?? []
        case .launcher:
            return session.launcherHotkey.map(HotkeyFormat.components) ?? []
        case .ring:
            return session.ringHotkey.map(HotkeyFormat.components) ?? []
        case .chat:
            let launcher = session.launcherHotkey.map(HotkeyFormat.components) ?? []
            return launcher.isEmpty ? [] : launcher + ["↩"]
        }
    }

    func selectFeature(_ feature: Feature) {
        selectedFeature = feature
    }
}
