import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

final class SemanticFixtureModels: SemanticModelHandling, @unchecked Sendable {
    var failure = false
    var status = 200
    var delay: Duration = .zero
    let source: URL
    init(source: URL) {
        self.source = source
    }

    func verify(_: URL, cancelled: @Sendable () -> Bool) throws {
        if cancelled() {
            throw CancellationError()
        }
        if failure {
            throw SemanticFileStore.Failure.invalidVector
        }
    }

    func install(_ url: URL, to target: URL, cancelled: @Sendable () -> Bool) throws {
        try verify(url, cancelled: cancelled)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: url, to: target)
    }

    func fetch(progress: @escaping @Sendable (Int64) -> Void) async throws -> (URL, URLResponse) {
        progress(100)
        try await Task.sleep(for: delay)
        let copy = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: copy)
        return (copy, HTTPURLResponse(url: SemanticModel.url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class SemanticFixtureQuery: SemanticQueryEmbedding, @unchecked Sendable {
    func query(_: String, lifecycle: AskSearchCancellation) async throws -> [Float] {
        if lifecycle.isCancelled {
            throw CancellationError()
        }
        return semanticVector()
    }

    func stop() {}
}

final class SemanticFixtureWatcher: AskFileWatching {
    var started: [String] = []
    var change: (([AskFileChange], UInt64) -> Void)?
    func start(paths: [String], since _: UInt64?, onChange: @escaping ([AskFileChange], UInt64) -> Void) {
        started = paths; change = onChange
    }

    func stop() {
        started = []; change = nil
    }
}

@Suite("Semantic service lifecycle", .serialized, .exclusiveUIState)
@MainActor
struct SemanticFileServiceTests {
    func fixture(supported: Bool = true) throws
        -> (SemanticFileSearchService, URL, SemanticFixtureReader, SemanticFixtureModels) {
        let root = try semanticFixture(), suite = "semantic-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = SettingsStore(defaults: defaults)
        // Tests never use standard defaults, watched home folders, network or a real model.
        var names = AskLauncherSearchSettings(); names.fileRoots = [root.path]; names.excludedPaths = []
        settings.askLauncherSearchSettings = names
        let source = root.appendingPathComponent("fixture-model"); try Data("model".utf8).write(to: source)
        let reader = SemanticFixtureReader(path: root.path + "/handbook.txt"),
            models = SemanticFixtureModels(source: source)
        let service = SemanticFileSearchService(
            settings: settings,
            directory: root,
            helper: URL(fileURLWithPath: "/usr/bin/true"),
            supported: supported,
            watcher: SemanticFixtureWatcher(),
            access: { true },
            automaticStart: false,
            resourceConstrained: { false },
            models: models,
            makeReader: { reader },
            makeEncoder: { _, _ in SemanticFixtureEncoder() },
            makeQuery: { _, _ in SemanticFixtureQuery() }
        )
        defaults.removePersistentDomain(forName: suite)
        settings.askLauncherSearchSettings = names
        return (service, root, reader, models)
    }

    static func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test func `default off and unsupported cannot be enabled`() async throws {
        let (service, root, _, _) = try fixture(supported: false)
        defer { try? FileManager.default.removeItem(at: root) }
        service.start()
        #expect(service.phase == .off); #expect(!service.setEnabled(true, roots: [root.path]))
        #expect(!service.preferences.enabled)
        #expect(await service.search("query", type: .all, limit: 10).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("semantic-files.sqlite").path))
        #expect(!service.setEnabled(true))
        service.settings.semanticFileSearch = .init(enabled: true, roots: [root.path])
        service.start(force: true)
        #expect(service.phase == .off, "persisted preferences cannot bypass the hardware gate")
        await service.clear()
    }

    @Test func `model download retry search rebuild and removal`() async throws {
        let (service, root, reader, models) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!service.setEnabled(true))
        #expect(service.setEnabled(true, roots: [root.path]))
        try await Self.wait { service.phase == .modelRequired }
        models.status = 503
        service.downloadModel()
        try await Self.wait { service.phase == .failed }
        models.status = 200
        service.downloadModel()
        try await Self.wait { service.phase == .ready }
        #expect(service.files == 1); #expect(service.chunks == 1); #expect(service.modelReady)
        let hits = await service.search("报销流程", type: .all, limit: 10)
        #expect(hits.map(\.path) == [reader.path]); #expect(hits.first?.evidence != nil)
        reader.failed = true
        #expect(await service.search("reimbursement", type: .all, limit: 10).isEmpty)
        reader.failed = false
        #expect(await service.search("", type: .all, limit: 10).isEmpty)
        service.settings.askQuickFileSearchEnabled = false
        #expect(!service.setEnabled(true))
        #expect(await service.search("query", type: .all, limit: 10).isEmpty)
        service.settings.askQuickFileSearchEnabled = true
        service.pause(true)
        try await Self.wait { service.phase == .paused }
        #expect(service.files == 1)
        service.pause(false)
        try await Self.wait { service.phase == .ready }
        service.setForegroundBusy(true)
        try await Self.wait { service.phase == .paused }
        service.setForegroundBusy(false)
        try await Self.wait { service.phase == .ready }
        await service.rebuild()
        try await Self.wait { service.phase == .ready }
        await service.clear()
        #expect(service.phase == .off); #expect(service.files == 0)
        #expect(FileManager.default.fileExists(atPath: service.modelURL.path))
        await service.clear(removeModel: true)
        #expect(!FileManager.default.fileExists(atPath: service.modelURL.path)); #expect(!service.modelReady)
    }

    @Test func `download cancellation corruption and empty scope`() async throws {
        let (service, root, _, models) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(service.setEnabled(true, roots: [root.path]))
        try await Self.wait { service.phase == .modelRequired }
        models.delay = .seconds(1)
        service.downloadModel(); service.cancelDownload()
        try await Self.wait { service.phase == .modelRequired }
        #expect(!FileManager.default.fileExists(atPath: service.modelURL.path))
        models.delay = .zero; models.failure = true
        service.downloadModel()
        try await Self.wait { service.phase == .failed }
        #expect(!service.modelReady)
        service.setRoots([])
        #expect(service.phase == .off); #expect(!service.preferences.enabled)
        await service.clear()
        #expect(throws: (any Error).self) { try SemanticModel.verify(models.source) }
        #expect(throws: CancellationError.self) { try SemanticModel.verify(models.source, cancelled: { true }) }
    }

    @Test func automaticSettingsWatcherAndPowerChangesKeepLifecycleCoherent() async throws {
        let (fixture, root, reader, models) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: models.source, to: fixture.modelURL)
        let watcher = SemanticFixtureWatcher(), encoder = SemanticFixtureEncoder()
        let constrained = AskSearchCancellation(), updated = AskSearchCancellation()
        let service = SemanticFileSearchService(settings: fixture.settings, directory: root,
            helper: URL(fileURLWithPath: "/usr/bin/true"), supported: true, watcher: watcher,
            access: { true }, resourceConstrained: { constrained.isCancelled }, models: models,
            makeReader: { reader }, makeEncoder: { _, _ in encoder }, makeQuery: { _, _ in SemanticFixtureQuery() })
        fixture.settings.semanticFileSearch = .init(enabled: true, roots: [root.path])
        try await Self.wait { service.phase == .ready }
        #expect(watcher.started == [root.path])
        reader.modified = reader.modified.addingTimeInterval(1)
        encoder.after = { updated.cancel() }
        watcher.change?([.init(path: reader.path, rescan: false)], 1)
        try await Self.wait { updated.isCancelled }
        try await Self.wait { service.phase == .ready }
        constrained.cancel()
        NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: ProcessInfo.processInfo)
        try await Self.wait { service.phase == .paused }
        NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: ProcessInfo.processInfo)
        try await Task.sleep(for: .milliseconds(30))
        try await Self.wait { service.phase == .paused }
        fixture.settings.semanticFileSearch = .init(enabled: false, roots: [root.path])
        try await Self.wait { service.phase == .off }
        #expect(watcher.started.isEmpty)
        await service.clear(removeModel: true)
    }

    @Test func corruptIndexCanBeClearedWithoutRemovingVerifiedModel() async throws {
        let (service, root, _, models) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: models.source, to: service.modelURL)
        let index = root.appendingPathComponent("semantic-files.sqlite")
        try Data("corrupt index".utf8).write(to: index)
        #expect(service.setEnabled(true, roots: [root.path]))
        try await Self.wait { service.phase == .failed }
        #expect(service.modelReady)
        await service.clear()
        #expect(!FileManager.default.fileExists(atPath: index.path))
        #expect(FileManager.default.fileExists(atPath: service.modelURL.path))
        #expect(service.setEnabled(true))
        try await Self.wait { service.phase == .ready }
        await service.clear(removeModel: true)
    }

    @Test func downloadFailuresAndEarlyCancellationReleaseSession() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SemanticFailureURLProtocol.self]
        let downloader = SemanticModelDownload(url: URL(string: "https://semantic.test/model")!, configuration: config, progress: { _ in })
        await #expect(throws: (any Error).self) { try await downloader.fetch() }
        await #expect(throws: (any Error).self) { try await downloader.fetch() }
        let cancelled = SemanticModelDownload(url: URL(string: "https://semantic.test/model")!, configuration: config, progress: { _ in })
        let task = Task { try await cancelled.fetch() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func liveModelDownloadWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_LIVE_DOWNLOAD"] == "1" else { return }
        let progress = AskSearchCancellation()
        let (temporary, response) = try await SemanticModelFiles().fetch { received in
            if received > 0, received < SemanticModel.bytes { progress.cancel() }
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(progress.isCancelled, "the real downloader must report progress")
        try await Task.detached { try SemanticModel.verify(temporary) }.value
    }

    @Test func `actual model checksum and atomic install when provided`() async throws {
        guard let path = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_TEST_MODEL"] else { return }
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("model.gguf"), source = URL(fileURLWithPath: path)
        try await Task.detached {
            try SemanticModel.verify(source)
            try SemanticModel.install(source, to: target, cancelled: { false })
            try SemanticModel.verify(target)
        }.value
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(throws: CancellationError.self) { try SemanticModel.install(source, to: target, cancelled: { true }) }
    }

    @Test func nativeControlsDisableUnsupportedHardwareAndCompleteSetup() async throws {
        typealias UI = SettingsBehaviorTestSupport
        @MainActor func press(_ title: String, in root: Any) async throws {
            try await UI.wait {
                UI.elements(in: root).contains {
                    $0.role == NSAccessibility.Role.button.rawValue && $0.label == title &&
                        $0.value("isAccessibilityEnabled") as? Bool != false
                }
            }
            try UI.button(title, in: root).press()
        }
        let (unsupported, unsupportedRoot, _, _) = try fixture(supported: false)
        let (service, root, _, _) = try fixture()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: unsupportedRoot)
        }
        try await UI.withFixture { _ in
            try await UI.withWindow(SemanticFileSearchSettingsView(service: unsupported, filesEnabled: true),
                                    width: 760, height: 220) { _, host in
                let toggle = try #require(UI.elements(in: host).first {
                    $0.value("accessibilityIdentifier") as? String == "semantic.enabled"
                })
                #expect(toggle.value("isAccessibilityEnabled") as? Bool == false)
            }
            let view = SemanticFileSearchSettingsView(service: service, filesEnabled: true,
                pickFolders: { [root.path, "/outside-content-scope"] })
            try await UI.withWindow(view, width: 760, height: 240) { window, host in
                let toggle = try #require(UI.elements(in: host).first {
                    $0.value("accessibilityIdentifier") as? String == "semantic.enabled"
                })
                #expect(toggle.value("isAccessibilityEnabled") as? Bool == true)
                try toggle.press()
                try await UI.wait { window.attachedSheet != nil }
                let firstSetup = try #require(window.attachedSheet)
                try await Task.sleep(for: .milliseconds(200))
                try await UI.wait { UI.contains(L("semantic.cancel"), in: firstSetup) }
                try await press(L("semantic.cancel"), in: firstSetup)
                try await UI.wait { window.attachedSheet == nil }
                #expect(!service.preferences.enabled)
                try toggle.press()
                try await UI.wait { window.attachedSheet != nil }
                let sheet = try #require(window.attachedSheet)
                let content = sheet
                try await UI.wait { UI.contains(L("semantic.enable"), in: content) }
                let enable = try UI.button(L("semantic.enable"), in: content)
                #expect(enable.value("isAccessibilityEnabled") as? Bool == false)
                try await press(L("launcher.search.add"), in: content)
                try await UI.wait { UI.contains(L("semantic.scopeError"), in: content) }
                try await press(L("semantic.enable"), in: content)
                try await UI.wait { service.phase == .ready }
                try await UI.wait { UI.contains(L("semantic.pause"), in: content) }
                try await press(L("semantic.pause"), in: content)
                try await UI.wait { service.phase == .paused }
                try await press(L("semantic.resume"), in: content)
                try await UI.wait { service.phase == .ready }
                try await press(L("semantic.rebuild"), in: content)
                try await Task.sleep(for: .milliseconds(30))
                try await UI.wait { service.phase == .ready && service.files == 1 }
                for key in ["semantic.clear", "semantic.remove"] {
                    try await press(L(key), in: content)
                    try await UI.wait { sheet.attachedSheet != nil }
                    let confirmation = try #require(sheet.attachedSheet)
                    try await press(L("semantic.confirm"), in: confirmation)
                    try await UI.wait { !service.preferences.enabled && service.phase == .off }
                }
                try await UI.wait { !service.modelReady }
                #expect(!FileManager.default.fileExists(atPath: service.modelURL.path))
                try await press(L("semantic.close"), in: content)
                try await UI.wait { window.attachedSheet == nil }
            }
        }
        await service.clear(removeModel: true)
    }

    @Test func `native settings render in both appearances and unsupported state`() async throws {
        _ = NSApplication.shared
        let (service, root, _, _) = try fixture(supported: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 760, height: 250),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        for (name, scheme, appearance) in [
            ("light", ColorScheme.light, NSAppearance.Name.aqua),
            ("dark", .dark, .darkAqua)
        ] {
            window.appearance = NSAppearance(named: appearance)
            let host = NSHostingView(rootView: SemanticFileSearchSettingsView(service: service, filesEnabled: true)
                .padding(24).frame(width: 760, height: 250).background(StudioTheme.background).environment(
                    \.colorScheme,
                    scheme
                ))
            window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0)
            if let folder = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_SCREENSHOTS"],
               let data = bitmap.representation(using: .png, properties: [:]) {
                let destination = URL(fileURLWithPath: folder)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try data.write(to: destination.appendingPathComponent("unsupported-\(name).png"))
            }
        }
    }

    @Test func `native setup and management use existing settings surfaces`() async throws {
        _ = NSApplication.shared
        let language = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(language) }
        let (service, root, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        service.setRoots([root.path])
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 620, height: 670),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        for setup in [true, false] {
            if !setup {
                #expect(service.setEnabled(true))
                await service.prepareModelIfNeeded()
                try await Self.wait { service.phase == .ready }
            }
            for (name, scheme, appearance) in [
                ("light", ColorScheme.light, NSAppearance.Name.aqua),
                ("dark", .dark, .darkAqua)
            ] {
                window.appearance = NSAppearance(named: appearance)
                let view = SemanticFileSearchSheet(service: service, setup: setup, onClose: {})
                let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
                window.contentView = host; window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                #expect(bitmap.pixelsHigh > 600)
                if let folder = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_SCREENSHOTS"],
                   let data = bitmap.representation(using: .png, properties: [:]) {
                    let destination = URL(fileURLWithPath: folder)
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    try data.write(to: destination.appendingPathComponent("\(setup ? "setup" : "manage")-\(name).png"))
                }
            }
        }
        await service.clear(removeModel: true)
    }
}
