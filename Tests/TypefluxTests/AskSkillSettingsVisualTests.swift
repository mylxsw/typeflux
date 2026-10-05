import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

@MainActor
final class AskSkillSettingsVisualTests: XCTestCase {
    func testRenderSkillsWithDisabledUpdateAndRollback() async throws {
        guard let output = ProcessInfo.processInfo.environment["TYPEFLUX_SKILL_SNAPSHOTS"] else {
            throw XCTSkip("Set TYPEFLUX_SKILL_SNAPSHOTS to render the settings fixture")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = AskSkillLibrary(userDirectory: root.appendingPathComponent("Skills"))
        try installVersions(root: root, library: library)
        let suite = "skill-snapshot-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.askDisabledSkills = ["release-review"]
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        defer { AppLocalization.shared.setLanguage(language) }
        let outputURL = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        _ = NSApplication.shared
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = AskToolsSettingsView(settings: settings, skills: library,
                                            notes: AskMemoryNoteStore(fileURL: root
                                                .appendingPathComponent("notes.json")),
                                            owner: { "fixture" }, tab: .extensions)
                .padding(24).frame(width: 760, height: 650, alignment: .top).background(StudioTheme.surface)
            let file = outputURL.appendingPathComponent(appearance == .aqua ? "skills-light.png" : "skills-dark.png")
            try await render(view, appearance: appearance, file: file)
        }
    }

    private func installVersions(root: URL, library: AskSkillLibrary) throws {
        let store = AskSkillInstallationStore(directory: library.userDirectory)
        let staged = root.appendingPathComponent("staged")
        for version in ["1", "2"] {
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            let content =
                "---\nname: release-review\n"
                    + "description: Review a release and prepare a concise checklist.\n---\nVersion " + version
            try content.write(to: staged.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            let source = AskSkillSource(
                url: "https://github.com/example/skills",
                repository: "example/skills",
                ref: "main",
                path: "release-review",
                installedAt: Date(),
                commit: String(repeating: "a", count: 40),
                installationID: UUID(),
                version: version,
                resources: [],
                declaredPermissions: ["files.read"]
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(source).write(to: staged.appendingPathComponent(AskSkillSource.fileName))
            _ = try store.install([(name: "release-review", folder: staged)])
        }
    }

    private func render(_ view: some View, appearance: NSAppearance.Name, file: URL) async throws {
        let window = AskTestVoiceWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 650),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 4000)
        try png.write(to: file)
    }
}
