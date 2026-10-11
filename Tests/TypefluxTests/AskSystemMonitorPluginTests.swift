import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

@Suite("System monitor keyword", .serialized, .exclusiveUIState)
@MainActor
struct AskSystemMonitorPluginTests {
    typealias F = SystemMonitorFixtures

    private func request(_ text: String, origin: AskPluginRequest.Origin = .argument) -> AskPluginRequest {
        AskPluginRequest(text: text, origin: origin, keyword: AskSystemMonitorPlugin.keywords[0], options: [:],
                         interfaceLanguage: .english)
    }

    @Test func keywordsAndRegistration() {
        withSystemMonitorLanguage {
            #expect(AskSystemMonitorPlugin.keywords.map(\.keyword) == ["top", "监控"])
            #expect(AskPluginRegistry.pluginIDs.contains(AskSystemMonitorPlugin.id))
            let defaults = AskPluginRegistry.defaultKeywords.filter { $0.pluginID == AskSystemMonitorPlugin.id }
            // `top` and `监控` do the same thing: one entry, with the English name as another alias.
            #expect(defaults.map(\.allKeywords) == [["top", "监控", "systemmonitor"]])
            #expect(AskKeywordAliases.englishName(for: AskSystemMonitorPlugin.keywords[0]) == "systemmonitor")
            let plugin = AskSystemMonitorPlugin()
            #expect(plugin.runsWithoutInput && !plugin.usesSelectionInput && plugin.entersOnReturn)
            #expect(plugin.title == "System Monitor" && plugin.symbol == "gauge.medium")
            #expect(plugin.placeholder(selectionLines: 3) == "Filter processes by name or PID")
            #expect(plugin.chipDetail(for: AskSystemMonitorPlugin.keywords[0], language: .english) == nil)
            #expect(plugin.optionName == nil)
            #expect(plugin.defaultKeywords == AskSystemMonitorPlugin.keywords)
        }
    }

    @Test func savedKeywordListsGainTheMonitor() {
        let saved = [AskKeyword(keyword: "fy", pluginID: AskTranslatePlugin.id)]
        let known = AskPluginRegistry.coveredGroups.filter { $0 != AskSystemMonitorPlugin.id }
        let keywords = AskPluginRegistry.keywords(saved: saved, known: known)
        #expect(keywords.contains { $0.pluginID == AskSystemMonitorPlugin.id && $0.contains("top") })
        if case let .hint(found)? = AskKeywordMatcher.match("top", keywords: keywords) {
            #expect(found.pluginID == AskSystemMonitorPlugin.id)
        } else {
            Issue.record("`top` should offer the monitor")
        }
    }

    @Test func runsLiveAndCarriesTheFilter() async throws {
        let plugin = AskSystemMonitorPlugin()
        let plan = await plugin.plan(request("chrome"))
        #expect(plan.mode == .live && plan.debounce == .zero)
        let output = try await plugin.run(request("chrome"), plan: plan, progress: { _ in })
        #expect(output.body == "chrome" && output.items.isEmpty)
        let selection = try await plugin.run(request("selected words", origin: .selection), plan: plan, progress: { _ in })
        #expect(selection.body.isEmpty)
        #expect(plugin.nextOptions(after: plan, request: request(""), step: 1) == nil)
    }

    // MARK: The conversation model

    private func makeWindow() throws -> (SystemMonitorWindowController, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: "system-monitor-" + UUID().uuidString))
        let store = SystemMonitorStore(sampler: FakeSystemMetricsSampler(), runningApps: { [] })
        return (SystemMonitorWindowController(defaults: defaults, store: store), defaults)
    }

    @Test func openingFromTheWindowEntersTheKeywordFocused() throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let model = fixture.model
        model.launcherDraft.text = "leftover"
        model.openSystemMonitorInLauncher(focus: .memory)
        #expect(model.showsSystemMonitor)
        #expect(model.launcherDraft.text.isEmpty)
        #expect(model.systemMonitor.focus == .memory && model.systemMonitor.sort == .memory)
        // Again while it shows: only the focus changes.
        model.openSystemMonitorInLauncher(focus: nil)
        #expect(model.showsSystemMonitor && model.systemMonitor.focus == nil)

        var shown = 0
        model.onShowLauncher = { then in shown += 1; then() }
        model.openSystemMonitorInLauncher(focus: .cpu)
        #expect(shown == 1 && model.systemMonitor.focus == .cpu)
    }

    @Test func effectsDoWhatTheKeysAsk() throws {
        try withSystemMonitorLanguage {
            let fixture = try AskTestFixture()
            defer { fixture.model.resetSession() }
            let model = fixture.model
            let (window, _) = try makeWindow()
            defer { window.close() }
            model.systemMonitorWindow = window
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("system.monitor.\(UUID().uuidString)"))
            let previous = AskQuickResults.pasteboard
            AskQuickResults.pasteboard = pasteboard
            defer { AskQuickResults.pasteboard = previous; pasteboard.releaseGlobally() }

            let gone = F.systemProcess(Int32.max - 7, "vanished", cpu: 0)
            #expect(model.performSystemMonitorEffect(.handled) == .stay)
            #expect(model.performSystemMonitorEffect(.unhandled) == .stay)
            #expect(model.performSystemMonitorEffect(.activate(gone)) == .stay)
            #expect(model.commandFeedback == "“vanished” is no longer running.")
            #expect(model.performSystemMonitorEffect(.copy("912")) == .stay)
            #expect(pasteboard.string(forType: .string) == "912")
            #expect(model.performSystemMonitorEffect(.terminated(gone, success: true)) == .stay)
            #expect(model.commandFeedback == "Quit “vanished”.")
            _ = model.performSystemMonitorEffect(.terminated(gone, success: false))
            #expect(model.commandFeedback == "Couldn’t quit “vanished”.")
            _ = model.performSystemMonitorEffect(.refused(gone, .system))
            #expect(model.commandFeedback == "“vanished” is a system process and can’t be quit here.")
            _ = model.performSystemMonitorEffect(.refused(gone, .typeflux))
            #expect(model.commandFeedback == "Typeflux can’t quit itself here.")

            model.openSystemMonitorInLauncher(focus: .memory)
            #expect(model.performSystemMonitorEffect(.popOut) == .close)
            #expect(window.isOpen && window.settings.sort == .memory)
            #expect(!model.showsSystemMonitor, "the next launch starts out of the keyword")
        }
    }

    // MARK: Views

    /// Lays a view out in a window so its body runs, as on screen.
    private func render<V: View>(_ view: V, width: CGFloat = AskMetrics.launcherWidth) {
        let hosting = NSHostingView(rootView: view.frame(width: width))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        window.close()
    }

    private func filledStore(cpu busy: Double = 30) -> SystemMonitorStore {
        let store = SystemMonitorStore(sampler: FakeSystemMetricsSampler(), runningApps: { [NSRunningApplication.current] })
        let counters = F.processes.map { F.process($0.pid, $0.name, cpu: 0, memory: $0.memory, uid: $0.uid) }
        let slow = SystemSlowInfo(volumes: [F.volume(), F.volume("Backup", root: false)],
                                  interface: SystemNetworkInterface(name: "en0", displayName: "Wi-Fi", address: "10.0.0.2"),
                                  battery: SystemBattery(percent: 82, charging: true))
        store.receive(F.raw(time: 0, processes: counters, slow: slow))
        for second in 1...31 {
            let busier = counters.map { process in
                var process = process
                process.cpuTime = UInt64(second) * UInt64(process.pid % 7 + 1) * 100_000_000
                return process
            }
            store.receive(F.raw(time: Double(second), busy: busy, processes: busier))
        }
        return store
    }

    @Test func launcherViewDrawsEveryState() {
        withSystemMonitorLanguage {
            let store = filledStore(cpu: 95)
            #expect(store.cpuAlert != nil)
            let monitor = SystemMonitorLauncherModel()
            var effects: [SystemMonitorEffect] = []
            let view = { (filter: String) in
                SystemMonitorLauncherView(store: store, model: monitor, filter: filter, windowOpen: false,
                                          onEffect: { effects.append($0) })
            }
            render(view(""))
            for metric in SystemMonitorMetric.allCases {
                monitor.setFocus(metric)
                render(view(""))
            }
            monitor.setFocus(nil)
            monitor.select(4821)
            render(view(""))
            _ = monitor.handle(.terminate(force: true), rows: monitor.rows(store.snapshot, filter: ""))
            render(view(""))
            monitor.cancelConfirmation()
            render(view("no such process"))
            render(SystemMonitorLauncherView(store: SystemMonitorStore(sampler: FakeSystemMetricsSampler()),
                                             model: SystemMonitorLauncherModel(), filter: "", windowOpen: true,
                                             onEffect: { _ in }))
            render(SystemMonitorHintSummary(store: store), width: 400)
            render(SystemMonitorChart(series: .make(.network, history: store.history)), width: 120)
            #expect(effects.isEmpty)
        }
    }

    @Test func footerNamesTheKeys() {
        withSystemMonitorLanguage {
            let monitor = SystemMonitorLauncherModel()
            let rows = F.processes
            #expect(SystemMonitorLauncherView.hint(model: monitor, rows: rows, windowOpen: false)
                == "↑↓ Choose · ⇥ Cards · ⌘O Own window · esc Back")
            #expect(SystemMonitorLauncherView.hint(model: monitor, rows: rows, windowOpen: true)
                == "↑↓ Choose · ⇥ Cards · ⌘O Go to window · esc Back")
            monitor.select(912)
            #expect(SystemMonitorLauncherView.hint(model: monitor, rows: rows, windowOpen: false)
                == "↩ Switch · ⌘C Copy PID · ⌘⌫ Quit (⌥ to force) · ⌘O Own window")
            monitor.terminator = SystemProcessTerminator(currentUID: 501, ownPID: 1)
            _ = monitor.handle(.terminate(force: false), rows: rows)
            #expect(SystemMonitorLauncherView.hint(model: monitor, rows: rows, windowOpen: false) == "↩ Quit · esc Cancel")
            monitor.cancelConfirmation()
            _ = monitor.handle(.terminate(force: true), rows: rows)
            #expect(SystemMonitorLauncherView.hint(model: monitor, rows: rows, windowOpen: false)
                == "↩ Force quit · esc Cancel")
        }
    }

    @Test func resultsAreaGivesTheMonitorItsHeight() {
        let display = AskPluginDisplay(hint: nil, title: "System Monitor", symbol: AskSystemMonitorPlugin.symbol,
                                       phase: .waiting, offersAskAI: false, systemMonitor: true)
        #expect(AskPluginResultsView.height(for: display) == SystemMonitorLauncherView.height)
        #expect(AskPluginResultsView.hint(for: display).isEmpty)
    }
}

@Suite("System monitor window", .serialized, .exclusiveUIState)
@MainActor
struct SystemMonitorWindowControllerTests {
    typealias F = SystemMonitorFixtures

    private func makeController(_ settings: SystemMonitorWindowSettings? = nil) throws
        -> (SystemMonitorWindowController, UserDefaults) {
        _ = NSApplication.shared
        let defaults = try #require(UserDefaults(suiteName: "system-monitor-window-" + UUID().uuidString))
        settings?.save(to: defaults)
        let store = SystemMonitorStore(sampler: FakeSystemMetricsSampler(), runningApps: { [] })
        return (SystemMonitorWindowController(defaults: defaults, store: store), defaults)
    }

    @Test func opensFloatingOnEveryDesktopAndCloses() throws {
        let (controller, defaults) = try makeController()
        defer { controller.close() }
        #expect(!controller.isOpen)
        controller.close()
        controller.show(sort: .memory, animated: false)
        let panel = try #require(controller.panel)
        #expect(controller.isOpen)
        #expect(panel.level == .floating && panel.isFloatingPanel)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.canBecomeMain && panel.canBecomeKey)
        #expect(controller.store.clients.count == 1 && controller.store.readsProcesses)
        #expect(SystemMonitorWindowSettings.load(from: defaults).isOpen)
        #expect(controller.settings.sort == .memory)

        controller.close()
        #expect(!controller.isOpen && controller.panel == nil)
        #expect(controller.store.clients.isEmpty)
        let saved = SystemMonitorWindowSettings.load(from: defaults)
        #expect(!saved.isOpen && saved.frame(for: .full) != nil)
    }

    @Test func showingAgainPointsAtTheWindow() async throws {
        let (controller, _) = try makeController()
        defer { controller.close() }
        controller.show(animated: true)
        let panel = controller.panel
        controller.show(sort: .disk)
        #expect(controller.panel === panel)
        #expect(controller.model.flashing)
        #expect(controller.settings.sort == .cpu, "the window has no disk order")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(!controller.model.flashing)
    }

    @Test func optionsApplyToThePanel() throws {
        let (controller, defaults) = try makeController()
        defer { controller.close() }
        controller.show(animated: false)
        let panel = try #require(controller.panel)
        controller.togglePinned()
        #expect(panel.level == .normal && !controller.settings.pinned)
        controller.toggleAllSpaces()
        #expect(!panel.collectionBehavior.contains(.canJoinAllSpaces))
        controller.toggleRestore()
        controller.setOpacity(0.7)
        #expect(panel.alphaValue == 0.7)
        controller.setInterval(5)
        #expect(controller.store.interval == 5)
        controller.toggleMetric(.disk)
        controller.setSort(.memory)
        let saved = SystemMonitorWindowSettings.load(from: defaults)
        #expect(!saved.pinned && !saved.allSpaces && !saved.restore && saved.opacity == 0.7 && saved.interval == 5)
        #expect(saved.metrics == [.cpu, .memory, .network] && saved.sort == .memory)
    }

    @Test func modesResizeAndStopReadingProcesses() async throws {
        try await withSystemMonitorLanguageAsync {
            let (controller, _) = try makeController()
            defer { controller.close() }
            controller.show(animated: false)
            let panel = try #require(controller.panel)
            try await Task.sleep(nanoseconds: 100_000_000)
            let full = panel.frame
            #expect(full.width == SystemMonitorWindowView.fullWidth)
            controller.setMode(.compact)
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(panel.frame.width == SystemMonitorWindowView.compactWidth)
            #expect(abs(panel.frame.maxY - full.maxY) < 1, "the top edge stays put")
            #expect(!controller.store.readsProcesses)
            controller.setMode(.compact)
            controller.setMode(.mini)
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(panel.frame.height < 60)
            controller.setMode(.full)
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(panel.frame.width == SystemMonitorWindowView.fullWidth)
            #expect(SystemMonitorWindowView.title(.mini) == "Mini Bar")
            #expect(Set(SystemMonitorWindowMode.allCases.map(SystemMonitorWindowView.symbol)).count == 3)
        }
    }

    @Test func restoresOnlyWhatWasOpen() throws {
        var settings = SystemMonitorWindowSettings()
        settings.isOpen = true
        settings.interval = 2
        let (opened, _) = try makeController(settings)
        defer { opened.close() }
        opened.restoreIfNeeded()
        #expect(opened.isOpen && opened.store.interval == 2)

        settings.restore = false
        let (kept, _) = try makeController(settings)
        kept.restoreIfNeeded()
        #expect(!kept.isOpen)
    }

    @Test func commandWClosesAndEscapeDoesNot() throws {
        let (controller, _) = try makeController()
        defer { controller.close() }
        controller.show(animated: false)
        let panel = try #require(controller.panel)
        panel.cancelOperation(nil)
        #expect(controller.isOpen)
        let other = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                  windowNumber: panel.windowNumber, context: nil, characters: "q",
                                                  charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12))
        #expect(!panel.performKeyEquivalent(with: other))
        let close = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                  windowNumber: panel.windowNumber, context: nil, characters: "w",
                                                  charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        #expect(panel.performKeyEquivalent(with: close))
        #expect(!controller.isOpen)
    }

    @Test func windowRowsOpenTheLauncher() throws {
        let (controller, _) = try makeController()
        var opened: [SystemMonitorMetric?] = []
        controller.openInLauncher = { opened.append($0) }
        controller.openInLauncher(.disk)
        #expect(opened == [.disk])
    }

    @Test func everyModeDraws() throws {
        try withSystemMonitorLanguage {
            let (controller, _) = try makeController()
            defer { controller.close() }
            let store = controller.store
            store.receive(F.raw(time: 0, processes: [F.process(1, "one")]))
            store.receive(F.raw(time: 1, busy: 95, processes: [F.process(1, "one", cpu: 500_000_000)]))
            for mode in SystemMonitorWindowMode.allCases {
                controller.model.settings.mode = mode
                let hosting = NSHostingView(rootView: SystemMonitorWindowView(controller: controller,
                                                                               model: controller.model, store: store))
                hosting.layoutSubtreeIfNeeded()
                #expect(hosting.fittingSize.width > 0)
            }
            controller.model.flashing = true
            controller.model.settings.metrics = [.network]
            let hosting = NSHostingView(rootView: SystemMonitorWindowView(controller: controller, model: controller.model,
                                                                           store: store))
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.fittingSize.height > 0)
            controller.contentSizeChanged()
        }
    }
}

@MainActor
func withSystemMonitorLanguageAsync(_ language: AppLanguage = .english, _ body: () async throws -> Void) async rethrows {
    let original = AppLocalization.shared.language
    AppLocalization.shared.setLanguage(language)
    defer { AppLocalization.shared.setLanguage(original) }
    try await body()
}
