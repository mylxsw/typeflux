import Foundation
import Testing
@testable import Typeflux

@Suite("Private execution snapshots")
struct AskPrivateFileTests {
    @Test func writesReplaceAtomicallyWithOwnerOnlyPermissionsAndNoStagingLeftovers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("state.json")
        for content in ["first", "second"] {
            try AskPrivateFile.write(Data(content.utf8), to: file)
            #expect(try String(contentsOf: file, encoding: .utf8) == content)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["state.json"])
        }
        let target = root.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try AskPrivateFile.write(Data("new".utf8), to: target) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "second")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["directory", "state.json"])
    }

    @Test func replacingASymlinkDoesNotWriteThroughIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("original"), link = root.appendingPathComponent("snapshot")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try AskPrivateFile.write(Data("saved".utf8), to: link)
        #expect(try String(contentsOf: target, encoding: .utf8) == "untouched")
        #expect(try String(contentsOf: link, encoding: .utf8) == "saved")
        #expect(try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType == .typeRegular)
    }
}
