import Carbon.HIToolbox
import Foundation

struct AskLauncherInputSource: Equatable, Identifiable {
    let id: String
    let name: String
}

@MainActor
protocol AskLauncherInputSourceSelecting {
    func select(sourceID: String)
}

@MainActor
protocol AskLauncherInputSourceListing {
    func availableSources() -> [AskLauncherInputSource]
}

struct SystemAskLauncherInputSourceSelector: AskLauncherInputSourceSelecting, AskLauncherInputSourceListing {
    private let inputSources: @MainActor @Sendable () -> [TISInputSource]
    private let selectSource: @MainActor @Sendable (TISInputSource) -> Void

    nonisolated init(
        inputSources: @escaping @MainActor @Sendable () -> [TISInputSource] = { Self.enabledInputSources() },
        selectSource: @escaping @MainActor @Sendable (TISInputSource) -> Void = { TISSelectInputSource($0) }
    ) {
        self.inputSources = inputSources
        self.selectSource = selectSource
    }

    func availableSources() -> [AskLauncherInputSource] {
        inputSources().compactMap { source in
            guard let id = Self.stringProperty(kTISPropertyInputSourceID, of: source),
                  let name = Self.stringProperty(kTISPropertyLocalizedName, of: source) else { return nil }
            return AskLauncherInputSource(id: id, name: name)
        }
    }

    func select(sourceID: String) {
        // Re-query enabled sources: a saved input method may have been disabled or uninstalled.
        guard !sourceID.isEmpty,
              let source = inputSources().first(where: {
                  Self.stringProperty(kTISPropertyInputSourceID, of: $0) == sourceID
              }) else { return }
        selectSource(source)
    }

    private nonisolated static func enabledInputSources() -> [TISInputSource] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as Any,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        return TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
    }

    private static func stringProperty(_ key: CFString, of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}

extension SettingsStore {
    /// An empty ID leaves the current input source unchanged when opening the launcher.
    var askLauncherInputSourceID: String {
        get { defaults.object(forKey: "ask.launcher.inputSourceID") as? String ?? "" }
        set { defaults.set(newValue, forKey: "ask.launcher.inputSourceID") }
    }
}
