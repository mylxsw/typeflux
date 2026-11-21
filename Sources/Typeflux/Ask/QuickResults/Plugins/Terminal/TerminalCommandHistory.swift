import Foundation

@MainActor
final class TerminalCommandHistory {
    let defaults: UserDefaults
    private let key = "terminal.session.commandHistory"
    private(set) var commands: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: key) ?? []
        commands = Array(stored.lazy.filter { !$0.hasPrefix(" ") }.prefix(1000))
        if stored != commands { defaults.set(commands, forKey: key) }
    }

    func record(_ command: String) {
        guard !command.hasPrefix(" ") else { return }
        commands.removeAll { $0 == command }
        commands.insert(command, at: 0)
        if commands.count > 1000 {
            commands.removeLast()
        }
        defaults.set(commands, forKey: key)
    }
}
