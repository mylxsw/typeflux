import AppKit
import Combine
import Testing
@testable import Typeflux

/// Measures what makes the launcher feel smooth: the main thread's cost from a
/// keystroke to drawn pixels, the longest main-thread stall while typing and
/// resizing, and how often the result list changes per keystroke.
///
/// Opt-in: set `TYPEFLUX_LAUNCHER_SMOOTHNESS_BENCH` to an output JSON path.
/// `TYPEFLUX_LAUNCHER_SMOOTHNESS_SCRIPT` (comma-separated inputs) and
/// `TYPEFLUX_LAUNCHER_SMOOTHNESS_ROUNDS` replace the typing script;
/// `TYPEFLUX_LAUNCHER_SMOOTHNESS_SAMPLE` writes a `/usr/bin/sample` call tree there.
@Suite("Launcher smoothness benchmark", .serialized, .exclusiveUIState)
@MainActor
struct AskLauncherSmoothnessBenchmarkTests {
    @MainActor private final class StallProbe {
        private var timer: Timer?
        private var last = ProcessInfo.processInfo.systemUptime
        private(set) var gaps: [Double] = []

        func start() {
            last = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 0.001, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    self.gaps.append((now - self.last) * 1000)
                    self.last = now
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }
    }

    private static func editor(in view: NSView) -> AskComposerTextView.Editor? {
        (view as? AskComposerTextView.Editor) ?? view.subviews.lazy.compactMap(editor(in:)).first
    }

    /// The main thread's own CPU time in milliseconds: unlike wall time, other
    /// processes competing for the machine do not inflate it.
    private static func threadCPUMilliseconds() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) * 1000 + Double(time.tv_nsec) / 1e6
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }

    @Test func `measure typing, publication and resize smoothness when requested`() async throws {
        guard let output = ProcessInfo.processInfo.environment["TYPEFLUX_LAUNCHER_SMOOTHNESS_BENCH"] else { return }
        _ = NSApplication.shared
        let previousStore = KeychainTokenStore.useInMemoryStoreForTesting
        KeychainTokenStore.useInMemoryStoreForTesting = true
        _ = AuthState.shared
        KeychainTokenStore.useInMemoryStoreForTesting = previousStore
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let names = ["Alpha", "Albatross", "Alchemy", "Almanac", "Alpine", "Altitude", "Aluminium", "Always",
                     "Beta", "Bravo", "Calendar", "Camera", "Chess", "Clock", "Contacts", "Dictionary"]
        fixture.model.appIndex = AskTestAppIndex(names.enumerated().map { AskTestAppIndex.app($1, id: "bench.\($0)") })
        fixture.model.fileIndex = AskTestFileIndex((0 ..< 40).map {
            ("/Users/test/Documents/Alpha Project/alpha notes \($0).txt", .file, Double($0))
        })
        let suite = "ask-smoothness-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        await fixture.model.prepareLauncher()
        let controller = AskConversationWindowController(
            settings: settings, model: fixture.model,
            dockVisibility: DockVisibilityController(app: BenchActivationPolicy()),
            launcherInputSource: BenchInputSource()
        )
        defer { controller.dismissLauncher() }
        controller.showLauncher()
        let window = try #require(controller.launcherWindow)
        let content = try #require(window.contentView)
        try await fixture.wait { !fixture.model.capturing && !fixture.model.quickSearch.isSearching }
        try await Task.sleep(for: .milliseconds(300))
        let editor = try #require(Self.editor(in: content))

        var publications = 0
        let subscription = fixture.model.quickSearch.$results.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        let probe = StallProbe()
        var keystrokes: [Double] = []
        var slowest: [String: Double] = [:]
        var keystrokeCPU: [Double] = []
        var publicationsPerKey: [Int] = []
        var heights: [CGFloat] = []
        probe.start()
        // Optional call-tree sample of this process while it types.
        var sampler: Process?
        if let path = ProcessInfo.processInfo.environment["TYPEFLUX_LAUNCHER_SMOOTHNESS_SAMPLE"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "20", "1", "-mayDie", "-file", path]
            try process.run()
            sampler = process
        }
        defer { sampler?.waitUntilExit() }
        let environment = ProcessInfo.processInfo.environment
        let script = environment["TYPEFLUX_LAUNCHER_SMOOTHNESS_SCRIPT"].map { $0.components(separatedBy: ",") }
            ?? ["a", "al", "alp", "alph", "alpha", "alph", "alp", "al", "a", "", "c", "ca", "cal",
                "ca", "c", "", "alpha notes", "alpha", "al", ""]
        let rounds = environment["TYPEFLUX_LAUNCHER_SMOOTHNESS_ROUNDS"].flatMap(Int.init) ?? 3
        for round in 0 ..< rounds {
            for text in script {
                publications = 0
                let start = ContinuousClock.now
                let cpuStart = Self.threadCPUMilliseconds()
                editor.selectAll(nil)
                if text.isEmpty {
                    editor.deleteBackward(nil)
                } else {
                    editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                }
                content.layoutSubtreeIfNeeded()
                content.displayIfNeeded()
                let parts = start.duration(to: .now).components
                let elapsed = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
                if round > 0 {
                    keystrokes.append(elapsed)
                    keystrokeCPU.append(Self.threadCPUMilliseconds() - cpuStart)
                    slowest["'" + text + "'"] = max(slowest["'" + text + "'"] ?? 0, elapsed)
                }
                // A fast typist: about 110 ms between keys.
                for _ in 0 ..< 11 {
                    try await Task.sleep(for: .milliseconds(10))
                    heights.append(window.frame.height)
                }
                if round > 0 {
                    publicationsPerKey.append(publications)
                }
            }
        }
        try await Task.sleep(for: .milliseconds(600))
        probe.stop()
        let gaps = probe.gaps
        let frameBudget = 1000.0 / Double(max(60, window.screen?.maximumFramesPerSecond ?? 60))
        let report: [String: Any] = [
            "label": ProcessInfo.processInfo.environment["TYPEFLUX_LAUNCHER_SMOOTHNESS_LABEL"] ?? "",
            "frameBudgetMs": frameBudget,
            "keystrokeToPixelsMs": ["p50": Self.percentile(keystrokes, 0.5), "p95": Self.percentile(keystrokes, 0.95),
                                    "max": keystrokes.max() ?? 0],
            "keystrokeCPUMs": ["p50": Self.percentile(keystrokeCPU, 0.5), "p95": Self.percentile(keystrokeCPU, 0.95),
                               "max": keystrokeCPU.max() ?? 0],
            "mainThreadGapMs": ["p99": Self.percentile(gaps, 0.99), "max": gaps.max() ?? 0,
                                "overFrameBudget": gaps.filter { $0 > frameBudget }.count, "samples": gaps.count],
            "publicationsPerKeystroke": [
                "mean": Double(publicationsPerKey.reduce(0, +)) / Double(max(1, publicationsPerKey.count)),
                "max": publicationsPerKey.max() ?? 0
            ],
            "distinctPanelHeights": Set(heights).count,
            "slowestKeystrokesMs": Dictionary(uniqueKeysWithValues: slowest.sorted { $0.value > $1.value }.prefix(6)
                .map { ($0.key, $0.value) })
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: output))
        print(String(decoding: data, as: UTF8.self))
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap { scrollViews(in: $0) }
    }

    /// Scrolls the quick results with trackpad-like wheel events and moves the
    /// highlight with the arrow keys, measuring each step's main-thread cost.
    /// Opt-in: set `TYPEFLUX_LAUNCHER_SCROLL_BENCH` to an output JSON path.
    @Test func `measure result list scrolling when requested`() async throws {
        guard let output = ProcessInfo.processInfo.environment["TYPEFLUX_LAUNCHER_SCROLL_BENCH"] else { return }
        _ = NSApplication.shared
        let previousStore = KeychainTokenStore.useInMemoryStoreForTesting
        KeychainTokenStore.useInMemoryStoreForTesting = true
        _ = AuthState.shared
        KeychainTokenStore.useInMemoryStoreForTesting = previousStore
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let names = ["Alpha", "Albatross", "Alchemy", "Almanac", "Alpine", "Altitude", "Aluminium", "Always"]
        fixture.model.appIndex = AskTestAppIndex(names.enumerated().map { AskTestAppIndex.app($1, id: "scroll.\($0)") })
        fixture.model.fileIndex = AskTestFileIndex((0 ..< 40).map {
            ("/Users/test/Documents/Alpha Project/alpha notes \($0).txt", .file, Double($0))
        } + (0 ..< 10).map {
            ("/Users/test/Documents/Alpha Folder \($0)", .folder, Double($0))
        })
        let suite = "ask-scroll-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        await fixture.model.prepareLauncher()
        let controller = AskConversationWindowController(
            settings: settings, model: fixture.model,
            dockVisibility: DockVisibilityController(app: BenchActivationPolicy()),
            launcherInputSource: BenchInputSource()
        )
        defer { controller.dismissLauncher() }
        controller.showLauncher()
        let window = try #require(controller.launcherWindow)
        let content = try #require(window.contentView)
        try await fixture.wait { !fixture.model.capturing && !fixture.model.quickSearch.isSearching }
        let editor = try #require(Self.editor(in: content))
        editor.insertText("al", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await fixture.wait { !fixture.model.quickSearch.isSearching && !controller.launcherIsResizing }
        try await Task.sleep(for: .milliseconds(600))
        content.layoutSubtreeIfNeeded()
        let scroll = try #require(Self.scrollViews(in: content).filter {
            $0.documentView !== editor && ($0.documentView?.frame.height ?? 0) > $0.contentSize.height + 40
        }.max { $0.frame.height < $1.frame.height }, "the results must overflow their viewport")
        let probe = StallProbe()
        probe.start()
        var sampler: Process?
        if let path = ProcessInfo.processInfo.environment["TYPEFLUX_LAUNCHER_SMOOTHNESS_SAMPLE"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "20", "1", "-mayDie", "-file", path]
            try process.run()
            sampler = process
        }
        defer { sampler?.waitUntilExit() }
        let rounds = ProcessInfo.processInfo.environment["TYPEFLUX_LAUNCHER_SMOOTHNESS_ROUNDS"].flatMap(Int.init) ?? 4
        var scrollSteps: [Double] = []
        var keySteps: [Double] = []
        var keyCPU: [Double] = []
        var publications = 0
        let subscription = fixture.model.quickSearch.$results.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        func milliseconds(_ start: ContinuousClock.Instant) -> Double {
            let parts = start.duration(to: .now).components
            return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
        }
        for _ in 0 ..< rounds {
            for direction in [-1, 1] {
                for _ in 0 ..< 60 {
                    let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                                     wheel1: Int32(direction * 12), wheel2: 0, wheel3: 0))
                    let start = ContinuousClock.now
                    scroll.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
                    content.layoutSubtreeIfNeeded()
                    content.displayIfNeeded()
                    scrollSteps.append(milliseconds(start))
                    try await Task.sleep(for: .milliseconds(8))
                }
            }
            for key: UInt16 in [125, 125, 125, 125, 125, 125, 125, 125, 126, 126, 126, 126, 126, 126, 126, 126] {
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                          windowNumber: window.windowNumber, context: nil,
                                                          characters: "", charactersIgnoringModifiers: "",
                                                          isARepeat: false, keyCode: key))
                let start = ContinuousClock.now
                let cpuStart = Self.threadCPUMilliseconds()
                editor.keyDown(with: event)
                content.layoutSubtreeIfNeeded()
                content.displayIfNeeded()
                keySteps.append(milliseconds(start))
                keyCPU.append(Self.threadCPUMilliseconds() - cpuStart)
                try await Task.sleep(for: .milliseconds(60))
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        probe.stop()
        let gaps = probe.gaps
        let report: [String: Any] = [
            "label": ProcessInfo.processInfo.environment["TYPEFLUX_LAUNCHER_SMOOTHNESS_LABEL"] ?? "",
            "scrollStepMs": ["p50": Self.percentile(scrollSteps, 0.5), "p95": Self.percentile(scrollSteps, 0.95),
                             "max": scrollSteps.max() ?? 0],
            "arrowKeyMs": ["p50": Self.percentile(keySteps, 0.5), "p95": Self.percentile(keySteps, 0.95),
                           "max": keySteps.max() ?? 0],
            "arrowKeyCPUMs": ["p50": Self.percentile(keyCPU, 0.5), "p95": Self.percentile(keyCPU, 0.95)],
            "mainThreadGapMs": ["p99": Self.percentile(gaps, 0.99), "max": gaps.max() ?? 0,
                                "over16ms": gaps.filter { $0 > 16.7 }.count],
            "publicationsWhileScrollingAndKeys": publications,
            "contentHeight": scroll.documentView?.frame.height ?? 0,
            "viewportHeight": scroll.contentSize.height
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: output))
        print(String(decoding: data, as: UTF8.self))
    }
}

private final class BenchActivationPolicy: ActivationPolicyControlling {
    var currentActivationPolicy: NSApplication.ActivationPolicy = .accessory
    func applyActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        currentActivationPolicy = policy
    }
}

@MainActor
private struct BenchInputSource: AskLauncherInputSourceSelecting {
    func select(sourceID _: String) {}
}
