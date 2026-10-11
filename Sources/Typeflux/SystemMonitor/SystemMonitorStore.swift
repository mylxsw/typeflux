import AppKit
import Combine
import Foundation

/// CPU above the threshold long enough to say so, and who is using it.
struct SystemMonitorCPUAlertInfo: Equatable, Sendable {
    var seconds: Int
    var process: SystemProcess?
}

/// The monitor's one source of figures, shared by the launcher and the window.
/// It samples only while something that shows it is attached: nothing runs while
/// the monitor is out of sight.
@MainActor
final class SystemMonitorStore: ObservableObject {
    static let shared = SystemMonitorStore()

    /// How often an attached client that cannot be seen (a covered window) is updated.
    static let hiddenInterval: TimeInterval = 5
    /// Volumes, the network interface and the battery change slowly.
    static let slowInterval: TimeInterval = 10
    /// How long sampling outlives its last client: the keyword's row hands over to the
    /// monitor (one detaches as the other attaches) without losing the chart.
    static let stopDelay: TimeInterval = 1.5

    struct Client: Equatable {
        /// Shows a process list, which costs a few hundred system calls a sample.
        var processes: Bool
        /// On screen; covered or minimised clients are updated less often and never read processes.
        var visible = true
    }

    @Published private(set) var snapshot: SystemSnapshot?
    @Published private(set) var history = SystemMonitorHistory()
    @Published private(set) var cpuAlert: SystemMonitorCPUAlertInfo?
    /// Regular apps by PID: their names replace process names, and they can be switched to.
    @Published private(set) var apps: [Int32: String] = [:]
    /// Seconds between samples while something visible is attached.
    @Published var interval: TimeInterval = 1 {
        didSet { if interval != oldValue { reschedule() } }
    }

    private(set) lazy var machine: SystemMachineInfo = sampler.machineInfo()
    private(set) var clients: [UUID: Client] = [:]
    private let sampler: any SystemMetricsSampling
    private let queue = DispatchQueue(label: "typeflux.system-monitor", qos: .utility)
    private let runningApps: () -> [NSRunningApplication]
    private var timer: Timer?
    private var pendingStop: Timer?
    private var previous: SystemRawSample?
    private var lastSlow: TimeInterval?
    private var alert = SystemMonitorCPUAlert()
    private var inFlight = false
    /// Bumped whenever sampling stops, so a sample still being read is dropped.
    private var generation = 0

    init(sampler: any SystemMetricsSampling = DarwinSystemMetricsSampler(),
         runningApps: @escaping () -> [NSRunningApplication] = { NSWorkspace.shared.runningApplications }) {
        self.sampler = sampler
        self.runningApps = runningApps
    }

    var isSampling: Bool { timer != nil }
    var stopDelay = SystemMonitorStore.stopDelay
    var readsProcesses: Bool { clients.values.contains { $0.processes && $0.visible } }
    /// The interval in force: the user's while anything attached is visible, slower otherwise.
    var effectiveInterval: TimeInterval {
        clients.values.contains(where: \.visible) ? max(0.5, interval) : max(interval, Self.hiddenInterval)
    }

    // MARK: Clients

    @discardableResult
    func attach(_ client: Client) -> UUID {
        let id = UUID()
        clients[id] = client
        clientsChanged(starting: clients.count == 1)
        return id
    }

    func update(_ id: UUID, _ client: Client) {
        guard let old = clients[id], old != client else { return }
        clients[id] = client
        clientsChanged(starting: false)
    }

    func detach(_ id: UUID?) {
        guard let id, clients.removeValue(forKey: id) != nil else { return }
        clientsChanged(starting: false)
    }

    private func clientsChanged(starting: Bool) {
        if clients.isEmpty {
            scheduleStop()
            return
        }
        let resumed = pendingStop != nil
        pendingStop?.invalidate()
        pendingStop = nil
        if timer == nil || (starting && !resumed) {
            start()
        } else {
            reschedule()
        }
    }

    private func scheduleStop() {
        pendingStop?.invalidate()
        guard stopDelay > 0 else { stop(); return }
        let stop = Timer(timeInterval: stopDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.clients.isEmpty else { return }
                self.stop()
            }
        }
        RunLoop.main.add(stop, forMode: .common)
        pendingStop = stop
    }

    // MARK: Sampling

    private func start() {
        timer?.invalidate()
        generation += 1
        inFlight = false
        previous = nil
        // The first figures need two readings: take one now and the next shortly after.
        sampleNow()
        let soon = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sampleNow()
                self?.reschedule()
            }
        }
        RunLoop.main.add(soon, forMode: .common)
        timer = soon
    }

    private func reschedule() {
        guard !clients.isEmpty else { return }
        timer?.invalidate()
        let repeating = Timer(timeInterval: effectiveInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleNow() }
        }
        repeating.tolerance = effectiveInterval * 0.1
        RunLoop.main.add(repeating, forMode: .common)
        timer = repeating
    }

    /// Stops reading and forgets the figures: a chart from minutes ago would read as now.
    private func stop() {
        timer?.invalidate()
        timer = nil
        pendingStop?.invalidate()
        pendingStop = nil
        generation += 1
        inFlight = false
        previous = nil
        lastSlow = nil
        alert = SystemMonitorCPUAlert()
        cpuAlert = nil
        snapshot = nil
        history = SystemMonitorHistory()
    }

    /// Reads the machine off the main thread; skipped while the last read is still going.
    func sampleNow() {
        guard !inFlight, !clients.isEmpty else { return }
        inFlight = true
        let generation = generation, processes = readsProcesses
        let now = ProcessInfo.processInfo.systemUptime
        let slow = lastSlow.map { now - $0 >= Self.slowInterval } ?? true
        if slow { lastSlow = now }
        let sampler = sampler
        queue.async { [weak self] in
            let raw = sampler.sample(processes: processes, slow: slow)
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.inFlight = false
                self.receive(raw)
            }
        }
    }

    /// Works out the figures from a new reading and the one before.
    func receive(_ raw: SystemRawSample) {
        defer { previous = raw }
        guard let previous else {
            // Volumes and the battery can show before the first rates.
            return
        }
        var next = SystemMetricsCalculator.snapshot(previous: previous, current: raw, fallback: snapshot)
        if next.processes == nil, readsProcesses { next.processes = snapshot?.processes }
        if next.processes != nil { refreshApps(&next) }
        history.append(next)
        alert.record(cpu: next.cpu.total, at: raw.time)
        cpuAlert = alert.sustained(at: raw.time).map {
            SystemMonitorCPUAlertInfo(seconds: Int($0), process: SystemMonitorProcessList.busiest(next.processes))
        }
        snapshot = next
    }

    private func refreshApps(_ next: inout SystemSnapshot) {
        var names: [Int32: String] = [:]
        for app in runningApps() where app.activationPolicy == .regular {
            if let name = app.localizedName { names[app.processIdentifier] = name }
        }
        if names != apps { apps = names }
        guard let processes = next.processes else { return }
        next.processes = processes.map { process in
            var process = process
            if let name = names[process.pid] { process.name = name }
            return process
        }
    }
}
