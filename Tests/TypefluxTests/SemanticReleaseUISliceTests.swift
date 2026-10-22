import AppKit
import Combine
import SwiftUI
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

private struct ReleaseUISliceBrowserSearch: AskBrowserSearching {
    func snapshot(kind _: AskBrowserSearchEntry.Kind, browsers _: [AskSearchBrowser],
                  interactive _: Bool) async -> AskBrowserSearchSnapshot {
        .init()
    }

    func focus(_: AskBrowserTabTarget) async throws {}
}

@MainActor
private enum ReleaseUISliceNativeUI {
    static func editor(in view: NSView) -> AskComposerTextView.Editor? {
        if let value = view as? AskComposerTextView.Editor {
            return value
        }
        return view.subviews.lazy.compactMap { editor(in: $0) }.first
    }

    static func oracle(in repository: URL) throws -> SemanticRankingComparisonTests.Capture {
        return try JSONDecoder().decode(SemanticRankingComparisonTests.Capture.self, from: Data(
            contentsOf: repository.appendingPathComponent(
                "docs/validation/gul-383/optimization/ranking-scale/final-holdout-vectors.json"
            )
        ))
    }

    static func previews(in state: URL) -> (MediaExtractionModule, ModuleRegistry) {
        let module = MediaExtractionModule(worker: .previews, healthDirectory: state, domain: .mediaPreviews)
        return (module, ModuleRegistry([module.registration]))
    }

    static func frame(on screen: NSRect, refresh: Bool) -> NSRect {
        NSRect(x: screen.minX + 12, y: screen.minY + 12,
               width: refresh ? AskLauncherPlacement.preferredFrame(on: screen).width : 720,
               height: refresh ? AskLauncherWindowMode.expandedHeight + 40 : 520)
    }

    static func run(
        _ hit: AskFileHit, model: AskConversationModel, fileMode: Bool, host: NSView
    ) async throws -> [String: Any] {
        func identities() -> [AskFileHit] {
            let hits = fileMode ? model.plugins.output?.items.compactMap(\.fileHit) ?? []
                : model.quickSearch.results?.files ?? []
            return hits
        }
        let before = identities(), cache = model.launcherIconCache
        try #require(before.contains { $0.path == hit.path }, "The target must be in the settled result set")
        let icon = MediaNativeIcon(kind: .file, value: hit.path)
        let revision = cache.revision(for: icon, modified: hit.modified)
        let previous = revision.value
        cache.clearFiles()
        _ = try await cache.load(icon, revision: hit.modified)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while revision.value == previous {
            try #require(ProcessInfo.processInfo.systemUptime < deadline, "Icon revision did not arrive")
            try await Task.sleep(for: .milliseconds(2))
        }
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        try #require(identities() == before, "An icon refresh changed the semantic result identities")
        try #require(SettingsBehaviorTestSupport.elements(in: host).contains {
            $0.text.contains(hit.name) || $0.label.contains(hit.name)
        })
        return ["before_revision": previous, "after_revision": revision.value,
                "result_identities_preserved": true, "target_still_in_ax": true]
    }
}

@Suite("Release candidate native search slice", .serialized, .exclusiveUIState)
@MainActor
struct SemanticReleaseUISliceTests {
    // Keep the bounded index-to-native-publication scenario together.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    @Test func `current bundle indexes changes and publishes both native entries`() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["TYPEFLUX_RELEASE_UI_OUTPUT"],
              let appPath = env["TYPEFLUX_RELEASE_UI_APP"],
              let modelPath = env["TYPEFLUX_RELEASE_UI_MODEL"] else { return }
        try requireSemanticValidationCacheIsolation()
        let refreshIcons = env["TYPEFLUX_RELEASE_UI_REFRESH_ICONS"] == "1"
        let outputURL = URL(fileURLWithPath: output)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let oracle = try ReleaseUISliceNativeUI.oracle(in: repository)
        let documents = oracle.documents.filter { $0.kind == "text" }
        // The production privacy policy excludes every source under .build, even an explicit root.
        let root = repository.appendingPathComponent("gul406-ui-runtime-" + UUID().uuidString)
        let corpus = root.appendingPathComponent("corpus")
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let model = URL(fileURLWithPath: modelPath)
        try SemanticModel.verify(model)
        try FileManager.default.linkItem(at: model, to: state.appendingPathComponent(model.lastPathComponent))
        for document in documents {
            try #require(SemanticFilePolicy.allows(corpus.appendingPathComponent(document.id + ".txt").path))
            try document.text.write(to: corpus.appendingPathComponent(document.id + ".txt"),
                                    atomically: true, encoding: .utf8)
        }
        let suite = "gul406-release-ui-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = SettingsStore(defaults: defaults)
        var names = AskLauncherSearchSettings()
        names.fileRoots = [corpus.path]; names.excludedPaths = []
        settings.askLauncherSearchSettings = names
        let scope = SemanticFilePolicy.scope(names: names, fullDiskAccess: true)
        let app = URL(fileURLWithPath: appPath)
        let helper = app.appendingPathComponent(
            "Contents/Resources/LocalRuntimes/SemanticSearch/TypefluxSemanticHelper"
        )
        let fileHelper = app.appendingPathComponent("Contents/MacOS/Typeflux")
        let service = SemanticFileSearchService(
            settings: settings, directory: state, helper: helper, supported: true, access: { true },
            automaticStart: false, budgetEnabled: true,
            makeReader: { AskFileReader(executable: fileHelper) }
        )
        let store = try SemanticFileStore(url: state.appendingPathComponent("semantic-files.sqlite"))
        var rows: [[String: Any]] = []
        var stage = "initial-index", complete = false
        var mutation: [String: Any] = [:]
        func save() throws {
            try JSONSerialization.data(withJSONObject: [
                "stage": stage, "complete": complete, "rows": rows, "mutation": mutation,
                "service_phase": String(describing: service.phase), "indexed_files": service.files,
                "model_ready": service.modelReady,
                "documents": documents.count, "model_sha256": SemanticModel.sha256,
                "source": """
                Existing final-holdout labels; all source and query embeddings inferred live.
                No captured vectors are used.
                """,
                "boundary": """
                Final NSTextView insertText commit to current production result publication,
                then forced layout/display and accessibility observation.
                No physical HID or WindowServer presentation fence.
                """
            ], options: [.prettyPrinted, .sortedKeys]).write(to: outputURL.appendingPathComponent("native-ui.json"))
        }
        func wait(_ predicate: () throws -> Bool, seconds: Double = 60) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while try !predicate() {
                try #require(service.phase != .failed, "Service failed at \(stage)")
                try #require(ProcessInfo.processInfo.systemUptime < deadline, "Timed out at \(stage)")
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        defer {
            try? save()
            try? store.destroy()
            defaults.removePersistentDomain(forName: suite)
        }
        let previews = refreshIcons ? ReleaseUISliceNativeUI.previews(in: state) : nil
        defer { withExtendedLifetime(previews?.0) {} }
        do {
            if let previews { try #require(await previews.1.startAll().isEmpty) }
            #expect(!service.preferences.enabled)
            try #require(service.setEnabled(true))
            try await wait({ service.phase == .ready && service.modelReady && service.files == documents.count },
                           seconds: 240)
            let changed = corpus.appendingPathComponent("final-en-00.txt")
            let oldVersion = try #require(store.job(changed.path)?.version)
            let source = try #require(documents.first { $0.id == "final-en-00" })
            stage = "file-change-through-fsevents"
            let changedAt = ProcessInfo.processInfo.systemUptime
            try (source.text + "\n" + source.text).write(to: changed, atomically: true, encoding: .utf8)
            try await wait({
                let job = try store.job(changed.path)
                return job?.version != oldVersion && job?.state == .done && service.phase == .ready
            }, seconds: 90)
            mutation = try ["file": changed.lastPathComponent, "old_version": oldVersion,
                            "new_version": #require(store.job(changed.path)?.version),
                            "milliseconds": (ProcessInfo.processInfo.systemUptime - changedAt) * 1000,
                            "trigger": "Real atomic write; production FSEvents; no explicit rescan"]
            service.pause(true)
            service.prepareForSearch()
            stage = "query-warmup"
            try await wait { service.queryState != .warming }
            _ = NSApplication.shared
            let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            let previous = NSApp.accessibilityAttributeValue(attribute)
            NSApp.accessibilitySetValue(true, forAttribute: attribute)
            defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
            for fileMode in [false, true] {
                let entryRoot = root.appendingPathComponent(fileMode ? "file-conversation" : "mixed-conversation")
                let model = try AskConversationModel(
                    api: AskTestAPI(),
                    cache: AskConversationCache(url: entryRoot.appendingPathComponent("cache.sqlite")),
                    tools: AskTestTools(), capture: AskTestCapture(), deviceId: "gul406-fixture",
                    modelLibrary: AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false),
                    defaults: defaults, session: { nil }
                )
                model.lastConversationKind = .work // Predates conversation kinds: keep tool flows.
                model.appIndex = AskTestAppIndex([])
                model.fileIndex = AskTestFileIndex()
                model.browserSearch = ReleaseUISliceBrowserSearch()
                let fixture = (root: entryRoot, model: model)
                fixture.model.semanticSearch = service
                if fileMode {
                    fixture.model.plugins.enter(AskFileSearchPlugin.keywords[0])
                }
                let screen = try #require(NSScreen.main).visibleFrame
                let window = NSWindow(contentRect: ReleaseUISliceNativeUI.frame(on: screen, refresh: refreshIcons),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let host = NSHostingView(rootView: AskComposer(model: fixture.model, launcher: true).padding(20))
                host.sizingOptions = []
                window.contentView = host; window.orderFront(nil)
                defer {
                    window.close(); fixture.model.resetSession()
                    try? FileManager.default.removeItem(at: fixture.root)
                }
                stage = "native-editor"
                try await wait { ReleaseUISliceNativeUI.editor(in: host) != nil }
                let input = try #require(ReleaseUISliceNativeUI.editor(in: host))
                func settled(_ text: String) -> Bool {
                    fileMode ? fixture.model.plugins.isPlanCurrent && fixture.model.plugins.request?.text == text
                        && fixture.model.plugins.output != nil
                        : fixture.model.quickSearch.isCurrent(text: text) && !fixture.model.quickSearch.isSearching
                }
                // Different existing queries in each entry prevent the shared query cache from answering them.
                let indices = fileMode ? 3 ..< 6 : 0 ..< 3
                for index in indices {
                    for group in ["lexical", "cross_language"] {
                        let id = String(format: "final_%@-%02d", group, index)
                        let query = try #require(oracle.queries.first { $0.id == id })
                        let target = try #require(query.expected.first) + ".txt"
                        stage = (fileMode ? "file-mode-" : "mixed-") + id
                        input.selectAll(nil); input.deleteBackward(nil)
                        try await wait {
                            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                            return fixture.model.launcherDraft.text.isEmpty && settled("")
                                && !SettingsBehaviorTestSupport.elements(in: host).contains {
                                    $0.text.contains(".txt") || $0.label.contains(".txt")
                                }
                        }
                        let lexical = try store.lexicalSearch(text: query.query, query: .init(query.query), type: .all,
                                                              scope: scope, limit: 50, cancelled: { false })
                        if group == "cross_language" {
                            try #require(
                                !lexical.contains { $0.name == target },
                                "Expected source must require live semantics"
                            )
                        }
                        var published: Double?, result: AskFileHit?
                        var start = ProcessInfo.processInfo.systemUptime
                        let watch: AnyCancellable = if fileMode {
                            fixture.model.plugins.$partial.sink { value in
                                guard published == nil, fixture.model.plugins.request?.text == query.query,
                                      let hit = value?.items.compactMap(\.fileHit).first(where: { $0.name == target })
                                else { return }
                                published = (ProcessInfo.processInfo.systemUptime - start) * 1000; result = hit
                            }
                        } else {
                            fixture.model.quickSearch.$results.sink { value in
                                guard published == nil, fixture.model.quickSearch.isCurrent(text: query.query),
                                      let hit = value?.files.first(where: { $0.name == target }) else { return }
                                published = (ProcessInfo.processInfo.systemUptime - start) * 1000; result = hit
                            }
                        }
                        defer { watch.cancel() }
                        for character in query.query.dropLast() {
                            input.insertText(
                                String(character),
                                replacementRange: NSRange(location: NSNotFound, length: 0)
                            )
                        }
                        start = ProcessInfo.processInfo.systemUptime
                        input.insertText(
                            String(query.query.suffix(1)),
                            replacementRange: NSRange(location: NSNotFound, length: 0)
                        )
                        try await wait { published != nil }
                        try await wait {
                            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                            return SettingsBehaviorTestSupport.elements(in: host).contains {
                                $0.text.contains(target) || $0.label.contains(target)
                            }
                        }
                        try #require(host.bounds.contains(input.convert(input.bounds, to: host)),
                                     "Native input must be fully inside the test host")
                        let drawn = (ProcessInfo.processInfo.systemUptime - start) * 1000
                        try await wait { settled(query.query) }
                        let completed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                        let hit = try #require(result), evidence = try #require(hit.evidence)
                        try #require(hit.path.hasPrefix(corpus.path + "/"))
                        try #require(evidence.version != nil && evidence.chunkID != nil)
                        let iconRefresh = refreshIcons
                            ? try await ReleaseUISliceNativeUI.run(
                                hit, model: fixture.model, fileMode: fileMode, host: host
                            ) : [:]
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        try #require(bitmap.representation(using: .png, properties: [:])).write(
                            to: outputURL.appendingPathComponent(stage + ".png")
                        )
                        try rows.append(["entry": fileMode ? "file-mode" : "mixed", "oracle_id": id,
                                         "query": query.query, "target": target, "group": group,
                                         "publication_ms": #require(published), "layout_ax_ms": drawn,
                                         "complete_query_ms": completed,
                                         "launcher_width": window.frame.width,
                                         "host_height": window.frame.height,
                                         "requested_launcher_width": AskMetrics.launcherWidth,
                                         "screen_visible_width": screen.width,
                                         "icon_refresh": iconRefresh,
                                         "target_in_fts": lexical.contains { $0.name == target },
                                         "source_version": evidence.version as Any? ?? NSNull(),
                                         "chunk_id": evidence.chunkID as Any? ?? NSNull(),
                                         "page": evidence.page as Any? ?? NSNull(),
                                         "time": evidence.time as Any? ?? NSNull(),
                                         "start_offset": evidence.startOffset as Any? ?? NSNull(),
                                         "end_offset": evidence.endOffset as Any? ?? NSNull()])
                        try save()
                    }
                }
            }
            complete = true; stage = "complete"
            service.endSearch(); await service.clear(removeModel: true)
            if let previews { await previews.1.shutdown() }
        } catch {
            service.endSearch(); await service.clear(removeModel: true)
            if let previews { await previews.1.shutdown() }
            throw error
        }
    }
}
