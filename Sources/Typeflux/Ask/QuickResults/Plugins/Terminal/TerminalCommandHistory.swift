import Foundation

@MainActor
final class TerminalCommandHistory {
    private let defaults: UserDefaults
    private let key = "terminal.session.commandHistory"
    private(set) var commands: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        commands = Array((defaults.stringArray(forKey: key) ?? []).prefix(1000))
    }

    func record(_ command: String) {
        commands.removeAll { $0 == command }
        commands.insert(command, at: 0)
        if commands.count > 1000 {
            commands.removeLast()
        }
        defaults.set(commands, forKey: key)
    }
}
