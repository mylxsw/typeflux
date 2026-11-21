import Foundation

/// Where Return sends a command: the launcher, a standalone window or an external terminal app.
enum TerminalRunner: String, CaseIterable, Sendable {
    case launcher, window, external
}

/// What the built-in terminal window does once its command exits.
enum TerminalFinishPolicy: String, CaseIterable, Sendable {
    /// Closes after a silent success; keeps output and failures on screen.
    case auto
    case keep
    /// Closes after any success; a failure stays open so its error can be read.
    case close

    func closesWindow(exitCode: Int32, hasOutput: Bool) -> Bool {
        guard exitCode == 0 else { return false }
        switch self {
        case .auto: return !hasOutput
        case .keep: return false
        case .close: return true
        }
    }
}

/// Which startup files the account's shell reads before the command.
enum TerminalShellProfile: String, CaseIterable, Sendable {
    /// Login and interactive: `.zprofile` and `.zshrc`, so aliases and functions work.
    case interactive
    /// Login only: `.zprofile`; faster, without the interactive configuration.
    case login
}

/// The built-in terminal's options for one keyword, read from its saved options.
struct TerminalRunSettings: Equatable, Sendable {
    static let runnerOption = "runner"
    static let finishOption = "finish"
    static let shellOption = "shell"
    static let directoryOption = "directory"
    static let pinnedOption = "pinned"
    static let notifyOption = "notify"
    static let startDirectoryOption = "startDirectory"
    static let idleOption = "idle"
    static let riskOption = "confirmRisky"
    static let insertOption = "insert"
    static let defaultDirectory = "~"

    enum StartDirectory: String, CaseIterable, Sendable { case last, finder, fixed }
    enum Idle: String, CaseIterable, Sendable { case thirtyMinutes, always, never }
    enum Insert: String, CaseIterable, Sendable { case output, commandAndOutput }

    var startDirectory: StartDirectory
    var idle: Idle
    var confirmsRisky: Bool
    var insert: Insert
    var finish: TerminalFinishPolicy = .auto
    var shell: TerminalShellProfile = .interactive
    /// As typed in settings; `~` and `~/…` are expanded when the command starts.
    var directory: String = Self.defaultDirectory
    /// Keeps the window above other apps' windows.
    var pinned = true
    /// Sends a notification when a long command finishes in the background.
    var notifies = true

    init(finish: TerminalFinishPolicy = .auto, shell: TerminalShellProfile = .interactive,
         directory: String = Self.defaultDirectory, pinned: Bool = true, notifies: Bool = true,
         startDirectory: StartDirectory? = nil, idle: Idle = .thirtyMinutes,
         confirmsRisky: Bool = true, insert: Insert = .output) {
        self.startDirectory = startDirectory ?? Self.defaultStartDirectory(for: directory)
        self.idle = idle
        self.confirmsRisky = confirmsRisky
        self.insert = insert
        self.finish = finish
        self.shell = shell
        self.directory = directory
        self.pinned = pinned
        self.notifies = notifies
    }

    /// Unknown or missing values fall back to the defaults, so older keywords keep working.
    init(options: [String: String]) {
        finish = options[Self.finishOption].flatMap(TerminalFinishPolicy.init(rawValue:)) ?? .auto
        shell = options[Self.shellOption].flatMap(TerminalShellProfile.init(rawValue:)) ?? .interactive
        let directory = options[Self.directoryOption]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.directory = directory.isEmpty ? Self.defaultDirectory : directory
        startDirectory = options[Self.startDirectoryOption].flatMap(StartDirectory.init(rawValue:))
            ?? Self.defaultStartDirectory(for: directory)
        idle = options[Self.idleOption].flatMap(Idle.init(rawValue:)) ?? .thirtyMinutes
        confirmsRisky = options[Self.riskOption] != "false"
        insert = options[Self.insertOption].flatMap(Insert.init(rawValue:)) ?? .output
        pinned = options[Self.pinnedOption] != "false"
        notifies = options[Self.notifyOption] != "false"
    }

    static func runner(in options: [String: String]) -> TerminalRunner {
        let saved = options[runnerOption]
        if saved == "builtin" { return .launcher }
        return saved.flatMap(TerminalRunner.init(rawValue:)) ?? .launcher
    }

    static func alternateRunner(in options: [String: String]) -> TerminalRunner {
        runner(in: options) == .window ? .launcher : .window
    }

    /// Only values that differ from the defaults are stored.
    func write(into options: inout [String: String]) {
        options[Self.finishOption] = finish == .auto ? nil : finish.rawValue
        options[Self.shellOption] = shell == .interactive ? nil : shell.rawValue
        let directory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        options[Self.directoryOption] = directory.isEmpty || directory == Self.defaultDirectory ? nil : directory
        options[Self.startDirectoryOption] = startDirectory == Self.defaultStartDirectory(for: directory)
            ? nil : startDirectory.rawValue
        options[Self.idleOption] = idle == .thirtyMinutes ? nil : idle.rawValue
        options[Self.riskOption] = confirmsRisky ? nil : "false"
        options[Self.insertOption] = insert == .output ? nil : insert.rawValue
        options[Self.pinnedOption] = pinned ? nil : "false"
        options[Self.notifyOption] = notifies ? nil : "false"
    }

    // A working directory saved before directory modes existed was always fixed.
    private static func defaultStartDirectory(for directory: String) -> StartDirectory {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == defaultDirectory ? .last : .fixed
    }

    func startingPath(home: String, last: String?, finder: () -> String?,
                      isDirectory: (String) -> Bool) -> String {
        switch startDirectory {
        case .fixed:
            return Self.expand(directory, home: home)
        case .finder:
            if let path = finder(), isDirectory(path) { return path }
        case .last:
            break
        }
        if let last, isDirectory(last) { return last }
        return home
    }

    func insertion(command: String, output: String) -> String {
        guard insert == .commandAndOutput else { return output }
        return output.isEmpty ? command : command + "\n" + output
    }

    /// `~`, `~/path` and absolute paths; anything else is taken relative to the home directory.
    static func expand(_ directory: String, home: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") { return (home as NSString).appendingPathComponent(String(trimmed.dropFirst(2))) }
        if trimmed.hasPrefix("/") { return (trimmed as NSString).standardizingPath }
        return (home as NSString).appendingPathComponent(trimmed)
    }

    /// The directory as people read it: the home directory as `~`.
    static func abbreviate(_ path: String, home: String) -> String {
        if path == home { return "~" }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }
}
