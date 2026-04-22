import Foundation

/// Classifies whether a given macOS bundle identifier corresponds to a code editor,
/// IDE, or terminal emulator. Used to enrich transcription and rewrite prompts with
/// a coding-context hint so the LLM can prefer technical interpretations of the
/// user's speech.
enum CodingAppDetector {
    /// Exact bundle identifiers of well-known coding apps and terminals.
    private static let exactBundleIdentifiers: Set<String> = [
        // Apple / IDEs
        "com.apple.dt.Xcode",
        "com.apple.Terminal",
        // Microsoft Visual Studio Code family
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss",
        "com.vscodium",
        // Cursor / Windsurf / other AI code editors
        "com.anysphere.cursor",
        "com.exafunction.windsurf",
        "com.trae.app",
        // Zed / Nova / Sublime / Fleet / Lapce
        "dev.zed.Zed",
        "dev.zed.Zed-Preview",
        "com.panic.Nova",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "com.lapce.lapce",
        // Classic editors
        "org.gnu.Emacs",
        "org.vim.MacVim",
        "com.macromates.TextMate",
        "com.barebones.bbedit",
        // Terminal emulators
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp-Preview",
        "com.mitchellh.ghostty",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
        "com.github.wez.wezterm",
        "io.alacritty",
        "com.tabby",
    ]

    /// Bundle identifier prefixes that cover families of coding apps (e.g. every
    /// JetBrains IDE shares `com.jetbrains.` and shipping a new one shouldn't
    /// require an update here).
    private static let bundlePrefixes: [String] = [
        "com.jetbrains.",       // IntelliJ, GoLand, PyCharm, WebStorm, RustRover, Fleet, ...
        "com.google.android.studio", // Android Studio variants
    ]

    /// Returns `true` when the given bundle identifier belongs to a code editor,
    /// IDE, or terminal emulator. A `nil` or empty identifier returns `false`.
    static func isCodingApp(bundleIdentifier: String?) -> Bool {
        guard let raw = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return false
        }

        if exactBundleIdentifiers.contains(raw) {
            return true
        }

        for prefix in bundlePrefixes where raw.hasPrefix(prefix) {
            return true
        }

        return false
    }
}
