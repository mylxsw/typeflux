import AppKit
import Foundation
import Testing
@testable import Typeflux

@Suite("System monitor store", .serialized)
@MainActor
struct SystemMonitorStoreTests {
    typealias F = SystemMonitorFixtures

    private func makeStore(_ sampler: FakeSystemMetricsSampler = .init()) -> SystemMonitorStore {
        SystemMonitorStore(sampler: sampler, runningApps: { [] })
    }

    @Test func receivingTwoReadingsMakesASnapshot() {
        let store = makeStore()
        store.receive(F.raw(time: 1, busy: 50, processes: [F.process(1, "one")]))
        #expect(store.snapshot == nil)
        store.receive(F.raw(time: 2, busy: 50, processes: [F.process(1, "one", cpu: 500_000_000)]))
        #expect(store.snapshot?.cpu.total == 50)
        #expect(store.snapshot?.processes?.first?.cpu == 50)
        #expect(store.history.cpu.values == [50])
        #expect(store.cpuAlert == nil)
        #expect(store.machine.chip == "Apple M3 Pro")
    }

    @Test func sustainedCPUNamesTheBusiestProcess() {
        let store = makeStore()
        store.receive(F.raw(time: 0, processes: [F.process(9, "hog"), F.process(8, "calm")]))
        for second in 1...31 {
            store.receive(F.raw(time: Double(second), busy: 95,
                                processes: [F.process(9, "hog", cpu: UInt64(second) * 900_000_000),
                                            F.process(8, "calm", cpu: UInt64(second) * 10_000_000)]))
        }
        #expect(store.cpuAlert?.seconds == 30)
        #expect(store.cpuAlert?.process?.name == "hog")
        store.receive(F.raw(time: 32, busy: 10))
        #expect(store.cpuAlert == nil)
    }

    @Test func processesCarryOverWhileAListIsShown() {
        let store = makeStore()
        let id = store.attach(.init(processes: true))
        defer { store.detach(id) }
        store.receive(F.raw(time: 1, processes: [F.process(1, "one")]))
        store.receive(F.raw(time: 2, processes: [F.process(1, "one")]))
        // A reading started before the list appeared has no processes: keep the last ones.
        store.receive(F.raw(time: 3))
        #expect(store.snapshot?.processes?.map(\.pid) == [1])
    }

    @Test func appNamesReplaceProcessNames() {
        let me = NSRunningApplication.current
        let store = SystemMonitorStore(sampler: FakeSystemMetricsSampler(), runningApps: { [me] })
        let pid = me.processIdentifier
        store.receive(F.raw(time: 1, processes: [F.process(pid, "xctest")]))
        store.receive(F.raw(time: 2, processes: [F.process(pid, "xctest")]))
        if me.activationPolicy == .regular, let name = me.localizedName {
            #expect(store.apps[pid] == name)
            #expect(store.snapshot?.processes?.first?.name == name)
        } else {
            #expect(store.apps.isEmpty)
            #expect(store.snapshot?.processes?.first?.name == "xctest")
        }
    }

    @Test func samplesOnlyWhileSomethingIsAttached() async throws {
        let sampler = FakeSystemMetricsSampler()
        let store = makeStore(sampler)
        store.stopDelay = 0
        #expect(!store.isSampling)
        store.sampleNow()
        #expect(sampler.requestCount == 0)

        let list = store.attach(.init(processes: true))
        #expect(store.isSampling && store.readsProcesses)
        try await waitUntil { store.snapshot != nil }
        #expect(sampler.firstRequest?.processes == true)
        #expect(sampler.firstRequest?.slow == true)

        store.update(list, .init(processes: true, visible: false))
        #expect(!store.readsProcesses)
        #expect(store.effectiveInterval == SystemMonitorStore.hiddenInterval)
        let summary = store.attach(.init(processes: false))
        #expect(store.effectiveInterval == 1)
        store.interval = 2
        #expect(store.effectiveInterval == 2)
        store.update(summary, .init(processes: false))
        store.detach(summary)
        store.detach(list)
        store.detach(nil)
        #expect(!store.isSampling && store.clients.isEmpty)
        #expect(store.cpuAlert == nil && store.snapshot == nil && store.history.cpu.values.isEmpty)
    }

    @Test func aClientArrivingSoonAfterTheLastLeftKeepsTheFigures() async throws {
        let store = makeStore()
        let hint = store.attach(.init(processes: false))
        try await waitUntil { store.snapshot != nil }
        store.detach(hint)
        #expect(store.isSampling, "sampling outlives its last client for a moment")
        let monitor = store.attach(.init(processes: true))
        #expect(store.snapshot != nil)
        store.stopDelay = 0.05
        store.detach(monitor)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!store.isSampling && store.snapshot == nil)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(condition())
    }
}

@Suite("System monitor window settings")
struct SystemMonitorWindowSettingsTests {
    @Test func defaultsFloatOnEveryDesktop() {
        let settings = SystemMonitorWindowSettings()
        #expect(settings.mode == .full && settings.pinned && settings.allSpaces && settings.restore && !settings.isOpen)
        #expect(settings.interval == 1 && settings.opacity == 1 && settings.sort == .cpu)
        #expect(settings.metrics == SystemMonitorMetric.allCases)
    }

    @Test func savedAndLoaded() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        #expect(SystemMonitorWindowSettings.load(from: defaults) == SystemMonitorWindowSettings())
        var settings = SystemMonitorWindowSettings()
        settings.mode = .mini
        settings.pinned = false
        settings.isOpen = true
        settings.interval = 5
        settings.opacity = 0.7
        settings.sort = .memory
        settings.toggle(.disk)
        settings.setFrame(CGRect(x: 10, y: 20, width: 300, height: 32), for: .mini)
        settings.save(to: defaults)
        let loaded = SystemMonitorWindowSettings.load(from: defaults)
        #expect(loaded == settings)
        #expect(loaded.frame(for: .mini) == CGRect(x: 10, y: 20, width: 300, height: 32))
        #expect(loaded.frame(for: .full) == nil)
        defaults.set(Data("not json".utf8), forKey: SystemMonitorWindowSettings.defaultsKey)
        #expect(SystemMonitorWindowSettings.load(from: defaults) == SystemMonitorWindowSettings())
    }

    @Test func unknownValuesFallBackInsteadOfFailing() throws {
        let json = #"{"mode":"huge","interval":3,"opacity":0.5,"metrics":["gpu","network","cpu"],"pinned":false}"#
        let settings = try JSONDecoder().decode(SystemMonitorWindowSettings.self, from: Data(json.utf8))
        #expect(settings.mode == .full && settings.interval == 1 && settings.opacity == 1)
        #expect(settings.metrics == [.cpu, .network])
        #expect(!settings.pinned && settings.allSpaces)
    }

    @Test func theLastMetricStays() {
        var settings = SystemMonitorWindowSettings()
        for metric in [SystemMonitorMetric.cpu, .memory, .disk, .network] { settings.toggle(metric) }
        #expect(settings.metrics == [.network])
        settings.toggle(.memory)
        #expect(settings.metrics == [.memory, .network])
        #expect(SystemMonitorWindowSettings.ordered([.network, .cpu, .cpu]) == [.cpu, .network])
    }

    @Test func placementKeepsSavedPlacesOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let size = CGSize(width: 380, height: 400)
        let fresh = SystemMonitorWindowPlacement.frame(size: size, saved: nil, screens: [screen], main: screen)
        #expect(fresh == CGRect(x: 1440 - 380 - 16, y: 875 - 400 - 16, width: 380, height: 400))
        let saved = CGRect(x: 100, y: 200, width: 10, height: 10)
        #expect(SystemMonitorWindowPlacement.frame(size: size, saved: saved, screens: [screen], main: screen)
            == CGRect(origin: saved.origin, size: size))
        let gone = CGRect(x: 5000, y: 5000, width: 10, height: 10)
        #expect(SystemMonitorWindowPlacement.frame(size: size, saved: gone, screens: [screen], main: nil) == fresh)
        #expect(SystemMonitorWindowPlacement.frame(size: size, saved: nil, screens: [], main: nil)
            == CGRect(origin: .zero, size: size))
    }
}

@Suite("Reading this Mac")
struct DarwinSystemMetricsSamplerTests {
    @Test func readsTheMachine() async throws {
        let sampler = DarwinSystemMetricsSampler()
        let machine = sampler.machineInfo()
        #expect(machine.cores > 0 && machine.memory > 0 && !machine.chip.isEmpty)

        let first = sampler.sample(processes: true, slow: true)
        try await Task.sleep(nanoseconds: 200_000_000)
        let second = sampler.sample(processes: true, slow: false)
        #expect(!first.cores.isEmpty)
        #expect(first.memory.total == ProcessInfo.processInfo.physicalMemory)
        #expect(first.memory.used > 0)
        #expect(first.loadAverage.count == 3)
        #expect(second.time > first.time)
        #expect(second.diskRead >= first.diskRead && second.networkIn >= first.networkIn)
        #expect(second.slow == nil)
        let slow = try #require(first.slow)
        #expect(slow.volumes.contains { $0.isRoot })

        let processes = try #require(first.processes)
        let me = try #require(processes.first { $0.pid == getpid() })
        #expect(me.uid == getuid() && me.memory > 0 && !me.name.isEmpty)
        #expect((first.processTotal ?? 0) >= processes.count)
        let snapshot = SystemMetricsCalculator.snapshot(previous: first, current: second)
        #expect((0...100).contains(snapshot.cpu.total))
        #expect(sampler.sample(processes: false, slow: false).processes == nil)
        #expect(sampler.process(-1) == nil)
    }

    @Test func helpers() {
        let sampler = DarwinSystemMetricsSampler()
        #expect(sampler.nanoseconds(0) == 0)
        #expect(sampler.nanoseconds(1_000_000) > 0)
        #expect(DarwinSystemMetricsSampler.countsTraffic(name: "en0", flags: IFF_UP))
        #expect(DarwinSystemMetricsSampler.countsTraffic(name: "pdp_ip0", flags: IFF_UP | IFF_RUNNING))
        #expect(!DarwinSystemMetricsSampler.countsTraffic(name: "en0", flags: 0))
        #expect(!DarwinSystemMetricsSampler.countsTraffic(name: "lo0", flags: IFF_UP | IFF_LOOPBACK))
        #expect(!DarwinSystemMetricsSampler.countsTraffic(name: "utun3", flags: IFF_UP))
        #expect(!DarwinSystemMetricsSampler.countsTraffic(name: nil, flags: IFF_UP))
        #expect(DarwinSystemMetricsSampler.sysctl("hw.ncpu", Int32.self) ?? 0 > 0)
        #expect(DarwinSystemMetricsSampler.sysctl("no.such.name", Int32.self) == nil)
        #expect(DarwinSystemMetricsSampler.sysctlString("no.such.name") == nil)
        #expect(DarwinSystemMetricsSampler.ipv4Address(of: "no-such-interface") == nil)
        #expect(DarwinSystemMetricsSampler.ipv4Address(of: "lo0") == "127.0.0.1")
        _ = sampler.primaryInterface()
        _ = sampler.battery()
    }
}
