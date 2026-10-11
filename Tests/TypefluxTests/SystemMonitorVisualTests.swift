import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

/// Draws the monitor in the real launcher and in its window, dark and light. With
/// `TYPEFLUX_MONITOR_SNAPSHOTS=<dir>` the PNGs are written there for review.
@Suite("System monitor visuals", .serialized, .exclusiveUIState)
@MainActor
struct SystemMonitorVisualTests {
    static let directory = ProcessInfo.processInfo.environment["TYPEFLUX_MONITOR_SNAPSHOTS"]

    /// Readings that look like a working Mac: a busy `node`, a browser, an editor.
    static func readings(count: Int, busy: (Int) -> Double = { 22 + 9 * sin(Double($0) / 4) }) -> [SystemRawSample] {
        let programs: [(Int32, String, Double, UInt64, UInt32)] = [
            (4821, "node", 0.42, 1200 << 20, 501), (912, "Google Chrome", 0.18, 3400 << 20, 501),
            (1288, "Xcode", 0.095, 2800 << 20, 501), (344, "WindowServer", 0.08, 640 << 20, 88),
            (0, "kernel_task", 0.064, 2100 << 20, 0), (2210, "Slack", 0.042, 980 << 20, 501),
            (1502, "Docker Desktop", 0.034, 2240 << 20, 501), (1777, "Figma", 0.028, 1460 << 20, 501),
            (511, "mds_stores", 0.022, 180 << 20, 0), (3301, "Typeflux", 0.016, 310 << 20, 501),
            (4410, "Spotify", 0.011, 540 << 20, 501), (5233, "python3", 0.003, 260 << 20, 501)
        ]
        var cpuTimes = programs.map { _ in UInt64(0) }
        var reads = programs.map { _ in UInt64(0) }
        var cores = Array(repeating: SystemCPUTicks(user: 0, system: 0, idle: 0, nice: 0), count: 12)
        var disk: (UInt64, UInt64) = (0, 0), network: (UInt64, UInt64) = (0, 0)
        return (0..<count).map { index in
            let load = busy(index)
            for core in cores.indices {
                let share = min(100, max(1, load + Double((core * 7 + index * 3) % 11) - 5))
                cores[core].user += UInt64(share * 0.7)
                cores[core].system += UInt64(share * 0.3)
                cores[core].idle += UInt64(100 - share)
            }
            for program in programs.indices {
                let wobble = 1 + 0.3 * sin(Double(index + program) / 3)
                cpuTimes[program] += UInt64(programs[program].2 * wobble * (load / 25) * 1_000_000_000)
                reads[program] += UInt64(program % 3 == 2 ? 300_000 * wobble : 20_000)
            }
            let burst = index % 9 == 0 ? 180_000_000.0 : 0
            disk.0 += UInt64(12_000_000 + burst + 6_000_000 * sin(Double(index)))
            disk.1 += UInt64(3_500_000 + 2_000_000 * cos(Double(index) / 2))
            network.0 += UInt64(2_400_000 + 1_800_000 * max(0, sin(Double(index) / 2)) + (index % 13 == 0 ? 9_000_000 : 0))
            network.1 += UInt64(180_000 + 90_000 * cos(Double(index) / 3))
            let processes = programs.indices.map { program in
                SystemProcessCounters(pid: programs[program].0, name: programs[program].1, uid: programs[program].4,
                                      cpuTime: cpuTimes[program], memory: programs[program].3,
                                      diskRead: reads[program], diskWritten: reads[program] / 3)
            }
            return SystemRawSample(
                time: Double(index), cores: cores,
                memory: SystemMemoryCounters(total: 36 << 30, app: 15 << 30, wired: 4 << 30, compressed: 5 << 30,
                                             cached: 7 << 30, swapUsed: 400 << 20,
                                             pressure: load > 80 ? .warning : .normal, availablePercent: 58),
                loadAverage: [3.05 + load / 20, 2.88, 2.6], diskRead: disk.0, diskWritten: disk.1,
                networkIn: network.0, networkOut: network.1, processes: processes, processTotal: 412,
                slow: index == 0 ? SystemSlowInfo(
                    volumes: [SystemVolume(name: "Macintosh HD", path: "/", total: 994_000_000_000,
                                           available: 382_000_000_000, isRoot: true),
                              SystemVolume(name: "T7 Shield", path: "/Volumes/T7", total: 2_000_000_000_000,
                                           available: 1_200_000_000_000, isRoot: false)],
                    interface: SystemNetworkInterface(name: "en0", displayName: "Wi-Fi", address: "192.168.1.23"),
                    battery: SystemBattery(percent: 82, charging: true)
                ) : nil,
                uptime: 3 * 86400 + 4 * 3600, thermal: load > 80 ? .serious : .nominal
            )
        }
    }

    /// A store already holding a minute of readings; further readings continue the same story.
    static func store(busy: @escaping (Int) -> Double = { 22 + 9 * sin(Double($0) / 4) }) -> SystemMonitorStore {
        let all = readings(count: 400, busy: busy)
        let store = SystemMonitorStore(sampler: FakeSystemMetricsSampler(Array(all.dropFirst(62))), runningApps: { [] })
        store.stopDelay = 60
        all.prefix(62).forEach(store.receive)
        return store
    }

    private func snapshot(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        guard let directory = Self.directory else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }

    private func launcher(_ name: String, light: Bool = false, store given: SystemMonitorStore? = nil,
                          prepare: (AskConversationModel) -> Void) async throws {
        let store = given ?? Self.store()
        let previousStore = KeychainTokenStore.useInMemoryStoreForTesting
        KeychainTokenStore.useInMemoryStoreForTesting = true
        _ = AuthState.shared
        KeychainTokenStore.useInMemoryStoreForTesting = previousStore
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let model = fixture.model
        let defaults = try #require(UserDefaults(suiteName: "system-monitor-visual-" + UUID().uuidString))
        model.systemMonitorWindow = SystemMonitorWindowController(defaults: defaults, store: store)
        model.openSystemMonitorInLauncher(focus: nil)
        prepare(model)
        let size = NSSize(width: AskMetrics.launcherWidth, height: 660)
        let window = AskTestVoiceWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                                        backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        let hosting = NSHostingView(rootView: AskLauncherView(model: model, onDismiss: {}, onHeightChange: { _ in })
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(AskTheme.surface))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(400))
        try snapshot(hosting, name: name)
    }

    @Test func launcherStates() async throws {
        try await withSystemMonitorLanguageAsync(.simplifiedChinese) {
            try await launcher("launcher-overview") { _ in }
            try await launcher("light-launcher-overview", light: true) { _ in }
            try await launcher("launcher-cpu") { $0.systemMonitor.setFocus(.cpu) }
            try await launcher("launcher-memory") { $0.systemMonitor.setFocus(.memory) }
            try await launcher("launcher-disk") { $0.systemMonitor.setFocus(.disk) }
            try await launcher("launcher-network") { $0.systemMonitor.setFocus(.network) }
            try await launcher("launcher-kill") { model in
                model.systemMonitor.terminator = SystemProcessTerminator(currentUID: 501, ownPID: 1)
                let rows = model.systemMonitor.rows(model.systemMonitorWindow.store.snapshot, filter: "")
                model.systemMonitor.select(912)
                _ = model.systemMonitor.handle(.terminate(force: false), rows: rows)
            }
            try await launcher("launcher-alert", store: Self.store(busy: { $0 > 20 ? 95 : 30 })) { _ in }
        }
    }

    @Test func windowModes() async throws {
        try await withSystemMonitorLanguageAsync(.simplifiedChinese) {
            for light in [false, true] {
                for mode in SystemMonitorWindowMode.allCases {
                    let defaults = try #require(UserDefaults(suiteName: "system-monitor-visual-" + UUID().uuidString))
                    var settings = SystemMonitorWindowSettings()
                    settings.mode = mode
                    settings.save(to: defaults)
                    let store = Self.store()
                    let controller = SystemMonitorWindowController(defaults: defaults, store: store)
                    let view = SystemMonitorWindowView(controller: controller, model: controller.model, store: store)
                    let hosting = NSHostingView(rootView: view.padding(24).background(Color(nsColor: light
                        ? NSColor(srgbRed: 0.78, green: 0.83, blue: 0.92, alpha: 1)
                        : NSColor(srgbRed: 0.13, green: 0.16, blue: 0.24, alpha: 1))))
                    let size = hosting.fittingSize
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                                          backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
                    hosting.frame = NSRect(origin: .zero, size: size)
                    window.contentView = hosting
                    window.orderFront(nil)
                    try await Task.sleep(for: .milliseconds(250))
                    try snapshot(hosting, name: (light ? "light-" : "") + "window-" + mode.rawValue)
                    window.orderOut(nil)
                    window.close()
                    controller.close()
                }
            }
        }
    }
}
