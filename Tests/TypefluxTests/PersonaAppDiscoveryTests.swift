import AppKit
import Testing
@testable import Typeflux

@Suite("Persona app discovery", .serialized, .exclusiveUIState)
@MainActor
struct PersonaAppDiscoveryTests {
    @Test func `preferred identifier and merge keep running metadata`() {
        let installed = PersonaAppCandidate(
            id: "COM.APPLE.MAIL",
            displayName: "Mail",
            bundleIdentifier: "com.apple.mail",
            appURL: nil,
            isRunning: false
        )
        let running = PersonaAppCandidate(
            id: "com.apple.mail",
            displayName: "Mail",
            bundleIdentifier: "com.apple.mail",
            appURL: nil,
            isRunning: true
        )
        let unnamed = PersonaAppCandidate(
            id: "name",
            displayName: "Name",
            bundleIdentifier: "",
            appURL: nil,
            isRunning: false
        )
        let noBundle = PersonaAppCandidate(
            id: "another",
            displayName: "Another",
            bundleIdentifier: nil,
            appURL: nil,
            isRunning: false
        )
        #expect(running.preferredIdentifier == "com.apple.mail")
        #expect(unnamed.preferredIdentifier == "Name")
        #expect(noBundle.preferredIdentifier == "Another")
        let result = PersonaAppDiscovery.mergePersonaAppCandidates([running], [installed, unnamed, noBundle])
        #expect(result.map(\.displayName) == ["Another", "Mail", "Name"])
        #expect(result.first { $0.id == running.id }?.isRunning == true)
        #expect(!PersonaAppPickerScope.running.title.isEmpty)
        #expect(!PersonaAppPickerScope.all.title.isEmpty)
    }

    @Test func `installed discovery uses bundle metadata deduplicates and skips nested apps`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Example.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("Nested.app"),
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.persona-test",
            "CFBundleDisplayName": "Example Display",
            "CFBundleName": "Example Name"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let plain = root.appendingPathComponent("Plain.app")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Ignored.txt"))
        let result = PersonaAppDiscovery.installedPersonaAppCandidates(searchRoots: [
            root,
            root,
            root.appendingPathComponent("missing")
        ])
        #expect(result.count == 2)
        #expect(result.first { $0.id == "com.example.persona-test" }?.displayName == "Example Display")
        #expect(result.allSatisfy { !$0.isRunning })
        #expect(PersonaAppDiscovery.appDisplayName(for: app) == "Example Display")
        #expect(PersonaAppDiscovery.appDisplayName(for: plain) == "Plain")
        #expect(PersonaAppDiscovery.appDisplayName(for: nil) == nil)
        let named = root.appendingPathComponent("Named.app/Contents")
        try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
        let nameData = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleName": "Bundle Name"],
            format: .xml,
            options: 0
        )
        try nameData.write(to: named.appendingPathComponent("Info.plist"))
        #expect(PersonaAppDiscovery.appDisplayName(for: named.deletingLastPathComponent()) == "Bundle Name")
    }

    @Test func `running discovery returns unique running candidates`() async {
        let candidates = await PersonaAppDiscovery.discoverPersonaAppCandidates(scope: .running)
        #expect(candidates.filter { !$0.isRunning }.isEmpty)
        #expect(Set(candidates.map { $0.id.lowercased() }).count == candidates.count)
        #expect(candidates.allSatisfy { !$0.preferredIdentifier.isEmpty })
    }
}
