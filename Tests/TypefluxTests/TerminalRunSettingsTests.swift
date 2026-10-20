import Foundation
import Testing
@testable import Typeflux

@Suite("Built-in terminal settings and shell launch")
struct TerminalRunSettingsTests {
    private let home = "/Users/tester"

    @Test func `missing and unknown options use the defaults`() {
        let defaults = TerminalRunSettings(options: [:])
        #expect(defaults == TerminalRunSettings())
        #expect(defaults.finish == .auto && defaults.shell == .interactive && defaults.directory == "~")
        #expect(defaults.pinned && defaults.notifies)
        #expect(TerminalRunSettings.runner(in: [:]) == .builtin)
        let odd = TerminalRunSettings(options: [
            TerminalRunSettings.finishOption: "sometimes", TerminalRunSettings.shellOption: "csh",
            TerminalRunSettings.directoryOption: "   ", TerminalRunSettings.pinnedOption: "maybe"
        ])
        #expect(odd == TerminalRunSettings())
        #expect(TerminalRunSettings.runner(in: [TerminalRunSettings.runnerOption: "remote"]) == .builtin)
        #expect(TerminalRunSettings.runner(in: [TerminalRunSettings.runnerOption: "external"]) == .external)
        #expect(TerminalRunner.builtin.other == .external && TerminalRunner.external.other == .builtin)
    }

    @Test func `options round trip and store only changes`() {
        var options = ["terminal": "iterm", TerminalRunSettings.finishOption: "keep"]
        TerminalRunSettings().write(into: &options)
        #expect(options == ["terminal": "iterm"])
        let custom = TerminalRunSettings(finish: .close, shell: .login, directory: " ~/Projects ",
                                         pinned: false, notifies: false)
        custom.write(into: &options)
        #expect(options[TerminalRunSettings.directoryOption] == "~/Projects")
        #expect(options[TerminalRunSettings.pinnedOption] == "false")
        let read = TerminalRunSettings(options: options)
        #expect(read.finish == .close && read.shell == .login && read.directory == "~/Projects")
        #expect(!read.pinned && !read.notifies)
        var cleared = options
        TerminalRunSettings(directory: "~").write(into: &cleared)
        #expect(cleared == ["terminal": "iterm"])
    }

    @Test(arguments: [
        (TerminalFinishPolicy.auto, Int32(0), false, true), (.auto, 0, true, false), (.auto, 1, false, false),
        (.keep, 0, false, false), (.keep, 2, true, false),
        (.close, 0, true, true), (.close, 0, false, true), (.close, 130, true, false)
    ])
    func `finish policy closes only successes it is meant to`(policy: TerminalFinishPolicy, code: Int32,
                                                                 output: Bool, closes: Bool) {
        #expect(policy.closesWindow(exitCode: code, hasOutput: output) == closes)
    }

    @Test func `directories expand and abbreviate around home`() {
        #expect(TerminalRunSettings.expand("~", home: home) == home)
        #expect(TerminalRunSettings.expand("", home: home) == home)
        #expect(TerminalRunSettings.expand(" ~/Projects/demo ", home: home) == home + "/Projects/demo")
        #expect(TerminalRunSettings.expand("/tmp/../var", home: home) == "/var")
        #expect(TerminalRunSettings.expand("Code", home: home) == home + "/Code")
        #expect(TerminalRunSettings.abbreviate(home, home: home) == "~")
        #expect(TerminalRunSettings.abbreviate(home + "/a/b", home: home) == "~/a/b")
        #expect(TerminalRunSettings.abbreviate("/Users/testerx", home: home) == "/Users/testerx")
        #expect(TerminalRunSettings.abbreviate("/opt", home: home + "/") == "/opt")
    }

    @Test func `zsh starts as a login and interactive shell that evaluates the command variable`() {
        let launch = TerminalShellLaunch(command: "ll ~/Projects", settings: .init(directory: "~/Projects"),
                                         shell: "/bin/zsh", base: [:], home: home)
        #expect(launch.executable == "/bin/zsh" && launch.shellName == "zsh")
        #expect(Array(launch.arguments.prefix(4)) == ["/bin/zsh", "-l", "-i", "-c"])
        #expect(launch.arguments.count == 5 && !launch.arguments.contains("ll ~/Projects"))
        #expect(launch.arguments[4].contains("unset TYPEFLUX_COMMAND") && launch.arguments[4].contains("eval"))
        #expect(launch.environment[TerminalShellLaunch.commandVariable] == "ll ~/Projects")
        #expect(launch.directory == home + "/Projects")
        let login = TerminalShellLaunch(command: "pwd", settings: .init(shell: .login), shell: "/bin/bash",
                                        base: [:], home: home)
        #expect(Array(login.arguments.prefix(3)) == ["/bin/bash", "-l", "-c"])
    }

    @Test func `fish gets its own syntax and unsupported shells fall back to zsh`() {
        let fish = TerminalShellLaunch(command: "ls", settings: .init(), shell: "/opt/homebrew/bin/fish",
                                       base: [:], home: home)
        #expect(fish.arguments.last?.contains("set -e TYPEFLUX_COMMAND") == true)
        for shell in [nil, "", "tcsh", "/bin/tcsh", "/usr/local/bin/nu"] {
            #expect(TerminalShellLaunch.supportedShell(shell) == TerminalShellLaunch.fallbackShell)
        }
        #expect(TerminalShellLaunch.supportedShell("/bin/dash") == "/bin/dash")
    }

    @Test func `environment is rebuilt from a short allow list`() {
        let base = ["HOME": "/Users/real", "USER": "real", "SSH_AUTH_SOCK": "/tmp/agent", "LANG": "zh_CN.UTF-8",
                    "PATH": "/app/private/bin", "DYLD_INSERT_LIBRARIES": "/evil.dylib", "OPENAI_API_KEY": "secret",
                    "TERM": "dumb", TerminalShellLaunch.commandVariable: "stale"]
        let launch = TerminalShellLaunch(command: "echo hi", settings: .init(), shell: "/bin/zsh", base: base,
                                         home: home)
        let env = launch.environment
        #expect(env["HOME"] == "/Users/real" && env["USER"] == "real" && env["SSH_AUTH_SOCK"] == "/tmp/agent")
        #expect(env["LANG"] == "zh_CN.UTF-8" && env["PATH"] == TerminalShellLaunch.fallbackPath)
        #expect(env["DYLD_INSERT_LIBRARIES"] == nil && env["OPENAI_API_KEY"] == nil)
        #expect(env["TERM"] == "xterm-256color" && env["COLORTERM"] == "truecolor" && env["TERM_PROGRAM"] == "Typeflux")
        #expect(env["SHELL"] == "/bin/zsh" && env[TerminalShellLaunch.markerVariable] == "1")
        #expect(env[TerminalShellLaunch.commandVariable] == "echo hi")
        #expect(launch.environmentList == launch.environmentList.sorted())
        #expect(launch.environmentList.contains("TYPEFLUX_TERMINAL=1"))
        let bare = TerminalShellLaunch(command: "x", settings: .init(), shell: "/bin/zsh", base: [:], home: home)
        #expect(bare.environment["HOME"] == home)
    }

    @Test func `missing LANG follows the region when the locale exists`() {
        let china = Locale(identifier: "zh-Hans_CN")
        #expect(TerminalShellLaunch.language(for: china) { $0 == "zh_CN.UTF-8" } == "zh_CN.UTF-8")
        #expect(TerminalShellLaunch.language(for: china) { _ in false } == "en_US.UTF-8")
        #expect(TerminalShellLaunch.language(for: Locale(identifier: "en")) { _ in true } == "en_US.UTF-8")
        let launch = TerminalShellLaunch(command: "x", settings: .init(), shell: "/bin/zsh", base: [:], home: home,
                                         locale: Locale(identifier: "ja_JP"), localeExists: { _ in true })
        #expect(launch.environment["LANG"] == "ja_JP.UTF-8")
        #expect(TerminalShellLaunch.localeExists("en_US.UTF-8"))
    }

    @Test func `wait status decodes exit codes and signals like a shell`() {
        #expect(TerminalPTYProcess.exitCode(fromWaitStatus: 0) == 0)
        #expect(TerminalPTYProcess.exitCode(fromWaitStatus: 3 << 8) == 3)
        #expect(TerminalPTYProcess.exitCode(fromWaitStatus: 255 << 8) == 255)
        #expect(TerminalPTYProcess.exitCode(fromWaitStatus: SIGKILL) == 137)
        #expect(TerminalPTYProcess.exitCode(fromWaitStatus: SIGHUP) == 129)
    }

    @Test func `durations and notices read naturally`() {
        #expect(TerminalRunModel.format(0.04) == "0.0s")
        #expect(TerminalRunModel.format(2.45) == "2.5s" || TerminalRunModel.format(2.45) == "2.4s")
        #expect(TerminalRunModel.format(-1) == "0.0s")
        #expect(TerminalRunModel.format(75) == "1m 15s")
        #expect(TerminalRunModel.format(3725) == "1h 2m")
        #expect(TerminalRunModel.truncated("short", limit: 10) == "short")
        #expect(TerminalRunModel.truncated("0123456789abc", limit: 5) == "0123…")
    }
}
