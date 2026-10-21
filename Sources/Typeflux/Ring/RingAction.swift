import Foundation

/// A Typeflux feature the ring can run. They are the same entry points as the global shortcuts.
enum RingFeature: String, CaseIterable, Codable, Sendable {
    case dictation
    case ask
    case chat
    case screenshot
    case screenshotText
    case screenshotTranslation
    case translate
    case clipboard
    case notes
    case wordBook
    case persona
    case studio

    var title: String {
        L("ring.feature.\(rawValue).title")
    }

    var detail: String {
        L("ring.feature.\(rawValue).detail")
    }

    var symbol: String {
        switch self {
        case .dictation: "mic"
        case .ask: "sparkles"
        case .chat: "bubble.left.and.bubble.right"
        case .screenshot: "camera.viewfinder"
        case .screenshotText: "text.viewfinder"
        case .screenshotTranslation: "viewfinder"
        case .translate: "character.bubble"
        case .clipboard: "doc.on.clipboard"
        case .notes: "note.text"
        case .wordBook: "character.book.closed"
        case .persona: "person.crop.rectangle.stack"
        case .studio: "macwindow"
        }
    }
}

extension RingFeature {
    /// Features that already have a global shortcut run through the same handler.
    var shortcutAction: AppHotkeyAction? {
        switch self {
        case .chat: .openChat
        case .screenshotText: .screenshotText
        case .screenshotTranslation: .screenshotTranslation
        case .translate: .translate
        case .notes: .openNotes
        case .wordBook: .openWordBook
        case .studio: .openStudio
        case .dictation, .ask, .screenshot, .clipboard, .persona: nil
        }
    }
}

/// A macOS action the ring can run without another app.
enum RingSystemAction: String, CaseIterable, Codable, Sendable {
    case darkMode
    case mute
    case missionControl
    case lockScreen
    case emoji
    case keepAwake

    var title: String {
        L("ring.system.\(rawValue).title")
    }

    var detail: String {
        L("ring.system.\(rawValue).detail")
    }

    var symbol: String {
        switch self {
        case .darkMode: "circle.lefthalf.filled"
        case .mute: "speaker.slash"
        case .missionControl: "rectangle.3.group"
        case .lockScreen: "lock"
        case .emoji: "face.smiling"
        case .keepAwake: "bolt"
        }
    }
}

/// What a slice does. The associated values are everything needed to run it later.
enum RingActionKind: Codable, Equatable, Sendable {
    case feature(RingFeature)
    /// A launcher keyword or workflow keyword, run on the selected text like a keyword shortcut.
    case keyword(keyword: String, pluginID: String)
    case app(bundleIdentifier: String, name: String)
    /// A key combination sent to the app that was in front when the ring opened.
    case keys(HotkeyBinding)
    case system(RingSystemAction)
    /// A shortcut from the macOS Shortcuts app, by name.
    case shortcut(name: String)
    case url(String)
    case folder(path: String)

    var type: RingActionType {
        switch self {
        case .feature: .feature
        case .keyword: .keyword
        case .app: .app
        case .keys: .keys
        case .system: .system
        case .shortcut: .shortcut
        case .url: .url
        case .folder: .folder
        }
    }
}

extension RingActionKind {
    /// A stable key for pickers; the kind itself is not hashable because of `HotkeyBinding`.
    var pickerKey: String {
        switch self {
        case let .feature(feature): "feature.\(feature.rawValue)"
        case let .keyword(keyword, pluginID): "keyword.\(pluginID)/\(keyword.lowercased())"
        case let .app(bundleIdentifier, _): "app.\(bundleIdentifier)"
        case let .keys(binding): "keys.\(binding.signature)"
        case let .system(system): "system.\(system.rawValue)"
        case let .shortcut(name): "shortcut.\(name)"
        case let .url(url): "url.\(url)"
        case let .folder(path): "folder.\(path)"
        }
    }
}

/// The kinds of action offered in the editor, in menu order.
enum RingActionType: String, CaseIterable, Identifiable, Sendable {
    case feature
    case keyword
    case app
    case keys
    case system
    case shortcut
    case url
    case folder

    var id: String {
        rawValue
    }

    var title: String {
        L("ring.type.\(rawValue).title")
    }

    /// The label of the editor field that chooses the target.
    var targetLabel: String {
        L("ring.type.\(rawValue).target")
    }

    var symbol: String {
        switch self {
        case .feature: "infinity"
        case .keyword: "command"
        case .app: "app"
        case .keys: "keyboard"
        case .system: "gearshape"
        case .shortcut: "square.stack.3d.up"
        case .url: "link"
        case .folder: "folder"
        }
    }
}

/// One slice of the ring.
struct RingAction: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var kind: RingActionKind
    /// Shown on the slice. Users may rename it; new actions start with the target's name.
    var title: String
    /// SF Symbol drawn on the slice. Apps draw their own icon instead.
    var symbol: String

    init(id: UUID = UUID(), kind: RingActionKind, title: String, symbol: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.symbol = symbol
    }

    static func feature(_ feature: RingFeature) -> RingAction {
        RingAction(kind: .feature(feature), title: feature.title, symbol: feature.symbol)
    }
}
