import Foundation

/// Each session has its own private startup directory. While sourcing a user's
/// file, expose their real ZDOTDIR (including changes made by .zshenv).
final class TerminalSessionShell {
    let directory: URL

    init(settings: TerminalRunSettings) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            for file in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
                var script = ""
                if file != ".zshrc" || settings.shell == .interactive {
                    script = """
                    typeset -g _typeflux_shim="$ZDOTDIR"
                    ZDOTDIR="$_typeflux_user_dir"
                    [[ ! -r "$ZDOTDIR/\(file)" ]] || source "$ZDOTDIR/\(file)"
                    _typeflux_user_dir="${ZDOTDIR:-$HOME}"
                    ZDOTDIR="$_typeflux_shim"

                    """
                }
                if file == ".zlogin" {
                    script += Self.integration
                }
                try script.write(to: directory.appendingPathComponent(file), atomically: true, encoding: .utf8)
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func launch(settings: TerminalRunSettings, base: [String: String] = ProcessInfo.processInfo.environment,
                home: String = NSHomeDirectory()) -> TerminalShellLaunch {
        let shell = TerminalShellLaunch.fallbackShell
        var launch = TerminalShellLaunch(command: "", settings: settings, shell: shell, base: base, home: home)
        launch.arguments = [shell, "-l", "-i"]
        launch.environment.removeValue(forKey: TerminalShellLaunch.commandVariable)
        launch.environment[TerminalShellLaunch.markerVariable] = "launcher"
        launch.environment["_typeflux_user_dir"] = base["ZDOTDIR"] ?? launch.environment["HOME"]
        launch.environment["ZDOTDIR"] = directory.path
        return launch
    }

    private static let integration = #"""
    ZDOTDIR="$_typeflux_user_dir"
    unset _typeflux_user_dir _typeflux_shim
    unsetopt prompt_sp
    _typeflux_precmd() {
      local result=$?
      emulate -L zsh
      if [[ -n $_typeflux_executing ]]; then
        builtin printf '\033]133;D;%d\007' "$result"
        unset _typeflux_executing
      fi
      local LC_ALL=C p="" c
      for c in ${(s::)PWD}; do
        case "$c" in
          [a-zA-Z0-9/._~-]) p+="$c" ;;
          *) builtin printf -v c '%%%02X' "'$c"; p+="$c" ;;
        esac
      done
      builtin printf '\033]7;file://%s%s\007\033]133;A\007' "$HOST" "$p"
    }
    _typeflux_preexec() {
      _typeflux_executing=1
      builtin printf '\033]133;C\007'
    }
    precmd_functions=(_typeflux_precmd ${precmd_functions:#_typeflux_precmd})
    preexec_functions+=( _typeflux_preexec )
    PS1='%{'$'\033]133;B\007''%}'
    bindkey -M emacs '^[[200~' bracketed-paste
    bindkey -M viins '^[[200~' bracketed-paste
    """#
}
