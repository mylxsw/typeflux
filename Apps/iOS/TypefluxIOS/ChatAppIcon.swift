import Observation
import UIKit

enum ChatAppIcon: String, CaseIterable, Identifiable {
    case primary, glassFrosted, pureWhite, white, black, colorful, retroMosaic
    case cartoonPetrol, cartoonCobalt, cartoonLavender, yarnBall, hairyPuppet

    var id: String {
        rawValue
    }

    var title: String {
        NSLocalizedString("appIcon." + rawValue, comment: "App icon style")
    }

    var alternateName: String? {
        self == .primary ? nil : "AppIcon-" + rawValue
    }

    var previewName: String {
        "IconPreview-" + rawValue
    }

    static func current(named name: String?) -> ChatAppIcon? {
        allCases.first { $0.alternateName == name }
    }
}

@MainActor
protocol ChatIconApplication {
    var supportsAlternateIcons: Bool { get }
    var alternateIconName: String? { get }
    func setIcon(named name: String?) async throws
}

@MainActor
struct SystemChatIconApplication: ChatIconApplication {
    var supportsAlternateIcons: Bool {
        UIApplication.shared.supportsAlternateIcons
    }

    var alternateIconName: String? {
        UIApplication.shared.alternateIconName
    }

    func setIcon(named name: String?) async throws {
        try await UIApplication.shared.setAlternateIconName(name)
    }
}

/// iOS owns persistence; never keep a second, potentially stale preference.
@MainActor @Observable
final class ChatAppIconController {
    private let application: any ChatIconApplication
    private(set) var selected: ChatAppIcon?
    private(set) var isChanging = false
    private(set) var supportsAlternateIcons: Bool
    var changeFailed = false

    init(application: any ChatIconApplication = SystemChatIconApplication()) {
        self.application = application
        selected = ChatAppIcon.current(named: application.alternateIconName)
        supportsAlternateIcons = application.supportsAlternateIcons
    }

    func refresh() {
        guard !isChanging else { return }
        selected = ChatAppIcon.current(named: application.alternateIconName)
        supportsAlternateIcons = application.supportsAlternateIcons
    }

    func select(_ icon: ChatAppIcon) async {
        guard !isChanging, supportsAlternateIcons else { return }
        guard application.alternateIconName != icon.alternateName else {
            refresh()
            return
        }
        isChanging = true
        changeFailed = false
        defer {
            isChanging = false
            refresh()
        }
        do {
            try await application.setIcon(named: icon.alternateName)
        } catch {
            changeFailed = true
        }
    }
}
