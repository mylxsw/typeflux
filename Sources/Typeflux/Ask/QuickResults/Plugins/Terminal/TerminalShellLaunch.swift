import Darwin
import Foundation

/// How the built-in terminal starts a command: the account's login shell, its startup
/// files, a fresh environment and the chosen directory. Pure, so it is tested without a process.
struct TerminalShellLaunch: Equatable, Sendable {
    /// Carries the command into the shell. The shell clears it before running the command,
    /// so it never reaches the command's own processes, and unlike an argument it is not
    /// visible to other users' `ps`.
    static let commandVariable = "TYPEFLUX_COMMAND"
    /// Lets startup files skip what only makes sense in a full terminal (`exec tmux`, prompts).
    static let markerVariable = "TYPEFLUX_TERMINAL"
    static let fallbackShell = "/bin/zsh"
    static let fallbackPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    /// Values a terminal app also hands on from the login session.
    static let inheritedVariables = ["HOME", "USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING",
                                     "LANG", "LC_ALL", "LC_CTYPE"]

    private static let posixShells: Set<String> = ["zsh", "bash", "sh", "dash", "ksh", "mksh"]

    var executable: String
    /// Including `argv[0]`.
    var arguments: [String]
    var environment: [String: String]
    var directory: String

    /// - Parameters:
    ///   - shell: the account's login shell; an unsupported or missing one uses zsh.
    ///   - base: the app's environment, of which only `inheritedVariables` are kept.
    init(command: String, settings: TerminalRunSettings, shell: String?, base: [String: String], home: String,
         locale: Locale = .current, localeExists: (String) -> Bool = TerminalShellLaunch.localeExists) {
        let shell = Self.supportedShell(shell)
        let name = (shell as NSString).lastPathComponent
        let script = name == "fish"
            ? "set -l __typeflux_command $\(Self.commandVariable); set -e \(Self.commandVariable); eval $__typeflux_command"
            : "__typeflux_command=$\(Self.commandVariable); unset \(Self.commandVariable); eval \"$__typeflux_command\""
        executable = shell
        arguments = [shell, "-l"] + (settings.shell == .interactive ? ["-i"] : []) + ["-c", script]
        directory = TerminalRunSettings.expand(settings.directory, home: home)

        var environment = base.filter { Self.inheritedVariables.contains($0.key) }
        environment["HOME"] = environment["HOME"] ?? home
        environment["SHELL"] = shell
        // The login shell's startup files (path_helper, Homebrew) build the full PATH.
        environment["PATH"] = Self.fallbackPath
        if environment["LANG"] == nil {
            environment["LANG"] = Self.language(for: locale, exists: localeExists)
        }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Typeflux"
        environment[Self.markerVariable] = "1"
        environment[Self.commandVariable] = command
        self.environment = environment
    }

    var environmentList: [String] {
        environment.map { "\($0.key)=\($0.value)" }.sorted()
    }

    /// The shell's name as the footer shows it ("zsh").
    var shellName: String {
        (executable as NSString).lastPathComponent
    }

    static func supportedShell(_ shell: String?) -> String {
        guard let shell, shell.hasPrefix("/"),
              posixShells.contains((shell as NSString).lastPathComponent)
              || (shell as NSString).lastPathComponent == "fish" else { return fallbackShell }
        return shell
    }

    /// The shell set for this account (System Settings → Users & Groups), not the app's `$SHELL`.
    static func accountShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        let value = String(cString: shell)
        return value.isEmpty ? nil : value
    }

    /// GUI apps start without `LANG`; terminals derive it from the region so UTF-8 output works.
    static func language(for locale: Locale, exists: (String) -> Bool) -> String {
        if let language = locale.language.languageCode?.identifier, let region = locale.region?.identifier {
            let candidate = "\(language)_\(region).UTF-8"
            if exists(candidate) { return candidate }
        }
        return "en_US.UTF-8"
    }

    static func localeExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: "/usr/share/locale/" + name)
    }
}
