import Foundation

/// Recognizes common command forms from the submitted text without evaluating the shell.
enum TerminalCommandRisk: String, Equatable {
    case delete, forcePush, reset, clean, disk, permissions

    private static let tokens = try? NSRegularExpression(
        pattern: #"(?:'[^']*'|"(?:\\.|[^"\\])*"|\\.|[^\s;&|()'"\\])+|[;&|()]"#
    )
    private static let separators: Set<String> = [";", "&", "|", "(", ")"]
    private static let wrappers: Set<String> = ["sudo", "command", "env", "exec", "noglob", "nohup"]

    static func detect(_ command: String) -> Self? {
        guard let tokens else { return nil }
        var words: [String] = []
        for match in tokens.matches(in: command, range: NSRange(command.startIndex..., in: command)) {
            guard let range = Range(match.range, in: command) else { continue }
            let word = String(command[range])
            if word.hasPrefix("#") { break }
            if separators.contains(word) {
                if let risk = classify(words) { return risk }
                words.removeAll(keepingCapacity: true)
            } else {
                words.append(unquote(word))
            }
        }
        return classify(words)
    }

    private static func unquote(_ word: String) -> String {
        var value = ""
        var quote: Character?
        var escaping = false
        for character in word {
            if escaping {
                value.append(character)
                escaping = false
            } else if character == "\\" && quote != "'" {
                escaping = true
            } else if let active = quote {
                if character == active { quote = nil } else { value.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
            } else {
                value.append(character)
            }
        }
        return value
    }

    private static func unwrap(_ words: [String]) -> (command: ArraySlice<String>, sudo: Bool) {
        var command = words[...]
        var sudo = false
        while let word = command.first {
            let name = (word as NSString).lastPathComponent
            if wrappers.contains(name) {
                sudo = sudo || name == "sudo"
                command = command.dropFirst()
                while let option = command.first, option.hasPrefix("-") {
                    command = command.dropFirst()
                    if option == "--" { break }
                    if ["-u", "-g", "-C", "-R", "-D", "-h", "-p", "-T"].contains(option) {
                        command = command.dropFirst()
                    }
                }
            } else if word.contains("="), !word.hasPrefix("/") {
                command = command.dropFirst()
            } else {
                break
            }
        }
        return (command, sudo)
    }

    private static func classify(_ words: [String]) -> Self? {
        let (command, sudo) = unwrap(words)
        guard let executable = command.first else { return nil }
        let name = (executable as NSString).lastPathComponent
        let arguments = command.dropFirst()
        let options = arguments.prefix(while: { $0 != "--" })
        let recursive = hasFlag("R", long: "--recursive", in: options)

        switch name {
        case "rm" where sudo || hasFlag("rRf", long: "--recursive", in: options)
            || options.contains("--force"):
            return .delete
        case "git": return gitRisk(arguments)
        case "dd" where arguments.contains(where: { $0.hasPrefix("if=") }): return .disk
        case "diskutil" where ["erase", "eraseDisk", "eraseVolume"].contains(arguments.first ?? ""): return .disk
        case "chmod" where recursive && options.first(where: { !$0.hasPrefix("-") }) == "777":
            return .permissions
        case "chown" where recursive: return .permissions
        case _ where name == "mkfs" || name.hasPrefix("mkfs."): return .disk
        default: return nil
        }
    }

    private static func gitRisk(_ arguments: ArraySlice<String>) -> Self? {
        var subcommand = arguments
        while let option = subcommand.first, option.hasPrefix("-") {
            subcommand = subcommand.dropFirst()
            if ["-C", "-c", "--git-dir", "--work-tree", "--namespace"].contains(option) {
                subcommand = subcommand.dropFirst()
            }
        }
        let flags = subcommand.dropFirst().prefix(while: { $0 != "--" })
        switch subcommand.first {
        case "push" where hasFlag("f", long: "--force", in: flags): return .forcePush
        case "reset" where flags.contains("--hard"): return .reset
        case "clean" where hasFlag("f", long: "--force", in: flags): return .clean
        default: return nil
        }
    }

    private static func hasFlag(_ letters: String, long: String, in arguments: ArraySlice<String>) -> Bool {
        arguments.contains { argument in
            if argument.hasPrefix("--") { return argument == long }
            return argument.hasPrefix("-") && argument.dropFirst().contains { letters.contains($0) }
        }
    }

    var impact: String { L("terminal.risk." + rawValue) }
}
