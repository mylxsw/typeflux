import Foundation

struct TerminalGitStatus: Equatable, Sendable {
    let branch: String
    let dirty: Bool

    static func read(_ path: String) async -> Self? {
        let runner = ProcessCommandRunner(timeout: 2, outputLimit: 512 * 1024)
        let flags = ["--no-optional-locks", "-c", "core.fsmonitor=false", "status", "--porcelain=v2",
                     "--branch", "--no-ahead-behind", "--ignore-submodules=all", "-unormal"]
        guard let result = try? await runner.run(executablePath: "/usr/bin/git", arguments: flags,
                                                 currentDirectoryURL: URL(fileURLWithPath: path)) else { return nil }
        let lines = result.stdout.split(separator: "\n")
        let prefix = "# branch.head "
        guard let head = lines.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return Self(branch: String(head.dropFirst(prefix.count)), dirty: lines.contains { !$0.hasPrefix("# ") })
    }
}
