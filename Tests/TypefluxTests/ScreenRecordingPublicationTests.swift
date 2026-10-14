import Foundation
import Testing
@testable import Typeflux

struct ScreenRecordingPublicationTests {
    @Test func `named publication preserves collisions and explicit save as replaces chosen file`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        try Data([1, 2, 3]).write(to: source)
        let directory = root.appendingPathComponent("output")
        let files = ScreenRecordingFiles(root: root.appendingPathComponent("sessions"))
        let first = try files.publish(source, in: directory, format: .mp4, name: "Demo")
        let second = try files.publish(source, in: directory, format: .mp4, name: "Demo")
        #expect(first.lastPathComponent == "Demo.mp4")
        #expect(second.lastPathComponent == "Demo (2).mp4")
        try Data([4]).write(to: source)
        #expect(try files.publish(source, in: directory, format: .mp4, destinationURL: first) == first)
        #expect(try Data(contentsOf: first) == Data([4]))
        #expect(throws: CocoaError.self) { try files.publish(
            source,
            in: directory,
            format: .mp4,
            destinationURL: root.appendingPathComponent("escape.mp4")
        ) }
        let chosen = directory.appendingPathComponent("Chosen.mp4")
        #expect(try files.publish(source, in: directory, format: .mp4, destinationURL: chosen) == chosen)
        #expect(try (FileManager.default.contentsOfDirectory(atPath: directory.path))
            .allSatisfy { !$0.hasPrefix(".typeflux-") })
    }

    @Test func `Unicode names stay within filesystem byte limits`() {
        let value = ScreenRecordingLayout.fileName(String(repeating: "录", count: 180))
        #expect(value.utf8.count <= 220)
        #expect(!value.isEmpty)
    }
}
