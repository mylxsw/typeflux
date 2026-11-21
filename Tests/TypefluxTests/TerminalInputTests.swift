import Foundation
import Testing
@testable import Typeflux

struct TerminalInputTests {
    @Test(arguments: [
        ("rm -rf build", TerminalCommandRisk.delete),
        ("/bin/rm -R folder", .delete),
        ("rm --recursive folder", .delete),
        ("rm --force file", .delete),
        ("rm -f file", .delete),
        ("sudo rm file", .delete),
        ("sudo -u root /bin/rm file", .delete),
        ("DEBUG=1 command rm -r build", .delete),
        (#"echo "rm -r fake"; 'r'm '-r' folder"#, .delete),
        ("echo start && /usr/bin/git -C repo push -f", .forcePush),
        ("git push origin --force", .forcePush),
        ("git reset --hard HEAD", .reset),
        ("git clean -df", .clean),
        ("git clean --force", .clean),
        ("dd if=/dev/zero of=image", .disk),
        ("mkfs /dev/disk1", .disk),
        ("mkfs.ext4 /dev/disk1", .disk),
        ("diskutil eraseDisk APFS Work /dev/disk1", .disk),
        ("diskutil eraseVolume APFS Work /dev/disk1", .disk),
        ("chmod -vR 777 folder", .permissions),
        ("chmod --recursive 777 folder", .permissions),
        ("chown -Rh user folder", .permissions),
    ])
    func riskyForms(command: String, risk: TerminalCommandRisk) {
        #expect(TerminalCommandRisk.detect(command) == risk)
    }

    @Test(arguments: [
        "rm build", "rm -- -rf", "rm --interactive=never file", "sudo ls", "git push --dry-run",
        "git push origin -- --force", "git reset --soft HEAD", "git clean -dn", "git config clean -f",
        "dd of=image", "not-mkfs image", "diskutil info /dev/disk1", "chmod 777 file", "chmod -R 755 folder",
        "chown user file", "echo rm -rf example", #"echo "this; rm -rf fake""#, "echo ok # comment; rm -rf file",
        "printf '%s' 'git reset --hard'", "printf 'diskutil eraseDisk'", "", "sudo -u",
    ])
    func safeForms(command: String) {
        #expect(TerminalCommandRisk.detect(command) == nil)
    }

    @Test func completionUsesExecutableSearchPathAndSessionFiles() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bin = folder.appendingPathComponent("test-bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        for (name, mode) in [("flux-run", 0o755), ("flux-read", 0o644)] {
            let url = bin.appendingPathComponent(name)
            try Data().write(to: url)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        for name in ["source one", "source two", ".source"] {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        var completion = TerminalCompletion()
        func tab(_ text: String) -> String? {
            completion.advance(text, cwd: folder.path, path: "test-bin:\(bin.path):/nonexistent", home: folder.path)
        }
        #expect(tab("fl") == "flux-run ")
        #expect(tab("./test-bin/fl") == "./test-bin/flux-run ")
        #expect(tab("ls ./test") == "ls ./test-bin/")
        #expect(tab("cd source") == nil)
        #expect(tab("cd test") == "cd test-bin/")
        #expect(tab("ls s") == #"ls source\ "#)
        #expect(completion.candidates == ["source one", "source two"])
        #expect(tab(#"ls source\ "#) == #"ls source\ one"#)
        #expect(tab(#"ls source\ one"#) == #"ls source\ two"#)
        #expect(tab(#"ls source\ two"#) == #"ls source\ one"#)
        #expect(tab(#"ls "source o"#) == #"ls source\ one "#)
        #expect(tab("ls ~/.s") == "ls ~/.source ")
        #expect(tab("ls ./missing/") == nil)
        #expect(tab("echo ready && git sta") == "echo ready && git stash")
        #expect(tab("echo ready && git stat") == "echo ready && git status ")
        #expect(tab("git svvv") == nil)
    }

    @Test func commonPrefixAndCycleInvalidateWhenTextOrWorkingDirectoryChanges() {
        #expect(TerminalCompletion.commonPrefix([]) == nil)
        #expect(TerminalCompletion.commonPrefix(["", "x"]) == "")
        #expect(TerminalCompletion.commonPrefix(["测试A", "测试B", "测试"]) == "测试")
        var completion = TerminalCompletion()
        #expect(completion.advance("git s", cwd: "/nonexistent", path: "/nonexistent") == "git stash")
        #expect(completion.advance("git stash", cwd: "/nonexistent", path: "/nonexistent") == "git status")
        #expect(completion.advance("git status", cwd: "/tmp", path: "/nonexistent") == "git status ")
        #expect(completion.advance("git di", cwd: "/tmp", path: "/nonexistent") == "git diff ")
        #expect(completion.candidates.isEmpty)
    }
}
