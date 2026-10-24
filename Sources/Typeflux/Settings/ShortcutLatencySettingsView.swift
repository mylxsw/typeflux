import AppKit
import SwiftUI

@MainActor
struct ShortcutLatencySettingsView: View {
    @AppStorage(ShortcutLatency.enabledKey) private var enabled = true

    var body: some View {
        TFFormSection(title: L("shortcutDiagnostics.title"), footnote: L("shortcutDiagnostics.privacy")) {
            TFFormRow(title: L("shortcutDiagnostics.record"), detail: L("shortcutDiagnostics.scope")) {
                TFSwitch(title: L("shortcutDiagnostics.record"), isOn: $enabled)
            }
            TFDivider.form
            TFFormRow(title: L("diagnostics.overview")) {
                TFButton(title: L("shortcutDiagnostics.open"), systemImage: "stethoscope") {
                    ShortcutLatencyWindowController.shared.show()
                }
                .accessibilityIdentifier("shortcutDiagnostics.open")
            }
        }
        .accessibilityIdentifier("shortcutDiagnostics.settings")
    }
}

@MainActor
final class ShortcutLatencyWindowController: NSObject, NSWindowDelegate {
    static let shared = ShortcutLatencyWindowController()
    private(set) var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1080, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
                                  defer: false)
            window.title = L("shortcutDiagnostics.title")
            window.identifier = .init("shortcutDiagnostics.window")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.minSize = .init(width: 900, height: 580)
            window.contentView = NSHostingView(rootView: ShortcutLatencyDashboard())
            window.center(); self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_: Notification) {
        window?.contentView = nil
        window = nil
    }
}

@MainActor
struct ShortcutLatencyDashboard: View {
    @State private var processCPU: [String: Double] = [:]
    @State private var report = ShortcutLatencyReport(events: [])
    private let automaticRefresh: Bool
    init(report: ShortcutLatencyReport = ShortcutLatencyReport(events: []), bundle: DiagnosticsReport? = nil,
         automaticRefresh: Bool = true, initialSection: String = "overview") {
        _report = State(initialValue: report)
        _bundle = State(initialValue: bundle)
        self.automaticRefresh = automaticRefresh
        _section = State(initialValue: initialSection)
    }

    @State private var section = "overview"
    @State private var range = "day"
    @State private var rangeStart = Date().addingTimeInterval(-3600)
    @State private var rangeEnd = Date()
    @State private var bundle: DiagnosticsReport?
    @State private var collectedSelection = ""
    @State private var processesExpanded = true
    @State private var selected: UUID?
    @State private var feature = "all"
    @State private var temperature = "all"
    @State private var failure = false
    @State private var refreshing = false
    @State private var exportFailed = false

    private var samples: [ShortcutLatencySample] {
        report.filteredSamples(feature: feature, temperature: temperature)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("shortcutDiagnostics.title")).font(.title2.bold())
                Spacer()
                Button(L("shortcutDiagnostics.refresh")) { Task { await refresh() } }.disabled(refreshing)
                Button(L("shortcutDiagnostics.folder")) { NSWorkspace.shared.open(ShortcutLatency.directory) }
                Button(L("diagnostics.export")) { export() }
                    .disabled(bundle == nil || refreshing || !validRange || collectedSelection != selectionKey)
            }
            HStack {
                Picker(L("diagnostics.range"), selection: $range) {
                    ForEach(["hour", "day", "all", "custom"], id: \.self) { value in
                        Text(L("diagnostics.range." + value)).tag(value)
                    }
                }.frame(maxWidth: 320)
                if range == "custom" {
                    DatePicker(L("diagnostics.from"), selection: $rangeStart)
                    DatePicker(L("diagnostics.to"), selection: $rangeEnd)
                }
            }
            if !validRange {
                Text(L("diagnostics.invalidRange")).foregroundStyle(.red)
            }
            Text(L("diagnostics.timeNote")).font(.caption).foregroundStyle(.secondary)
            Picker(L("diagnostics.section"), selection: $section) {
                Text(L("diagnostics.overview")).tag("overview")
                Text(L("diagnostics.shortcuts")).tag("shortcuts")
            }.pickerStyle(.segmented)
            if section == "overview" {
                overview
            } else {
                shortcutDetails
            }
            if failure || exportFailed {
                Text(L("shortcutDiagnostics.error")).foregroundStyle(.red)
            }
            if let bundle, !bundle.collectionFailures.isEmpty {
                Text(L("diagnostics.partial")).font(.caption).foregroundStyle(.orange)
            }
            if let bundle {
                Text(L("diagnostics.updated") + " " + bundle.generatedAt.formatted()).font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .accessibilityIdentifier("shortcutDiagnostics.dashboard")
        .task(id: selectionKey) {
            guard automaticRefresh else { return }
            bundle = nil
            var empty = ShortcutLatencyReport(events: [])
            empty.processes = report.processes
            report = empty
            selected = nil
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    private var shortcutDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("shortcutDiagnostics.boundary")).font(.callout).foregroundStyle(.secondary)
            HStack {
                Picker(L("shortcutDiagnostics.feature"), selection: $feature) {
                    Text(L("shortcutDiagnostics.all")).tag("all")
                    ForEach(
                        FeatureRole.allCases.filter { $0 != .host && $0 != .shortcuts && $0 != .background },
                        id: \.rawValue
                    ) { role in
                        Text(L("shortcutDiagnostics.role." + role.rawValue)).tag(role.rawValue)
                    }
                }.frame(maxWidth: 280)
                Picker(L("shortcutDiagnostics.temperature"), selection: $temperature) {
                    ForEach(["all", "cold", "warm"], id: \.self) { value in
                        Text(L("shortcutDiagnostics." + value)).tag(value)
                    }
                }.frame(maxWidth: 280)
                Spacer()
            }
            HStack(spacing: 24) {
                metric(L("shortcutDiagnostics.samples"), String(samples.count))
                metric(L("shortcutDiagnostics.visible"), String(samples.filter { $0.outcome == "visible" }.count))
                metric(
                    "P50",
                    milliseconds(ShortcutLatencyReport.percentile(
                        samples.compactMap(\.visibleMilliseconds),
                        fraction: 0.5
                    ))
                )
                metric(
                    "P95",
                    milliseconds(ShortcutLatencyReport.percentile(
                        samples.compactMap(\.visibleMilliseconds),
                        fraction: 0.95
                    ))
                )
                metric(L("shortcutDiagnostics.other"), String(samples.filter { $0.outcome != "visible" }.count))
            }
            if report.invalidLines + report.unreadableFiles + report.droppedEvents > 0 {
                Text(L("shortcutDiagnostics.gaps", report.unreadableFiles, report.invalidLines, report.droppedEvents))
                    .font(.caption).foregroundStyle(.orange)
            }
            HSplitView {
                List(samples, selection: $selected) { sample in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(L("shortcutDiagnostics.role." + sample.trace.feature.rawValue)).fontWeight(.medium)
                            Spacer()
                            Text(milliseconds(sample.visibleMilliseconds)).monospacedDigit()
                        }
                        Text(sample.trace.date, style: .time).font(.caption).foregroundStyle(.secondary)
                        Text(L("shortcutDiagnostics.outcome." + sample.outcome) + " · " +
                            L("shortcutDiagnostics." + (sample.cold.map { $0 ? "cold" : "warm" } ?? "unknown")))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4).tag(sample.id)
                }.frame(minWidth: 290, idealWidth: 340)
                ScrollView {
                    if let sample = samples.first(where: { $0.id == selected }) {
                        timeline(sample).padding()
                    } else {
                        Text(L(samples.isEmpty ? "shortcutDiagnostics.empty" : "shortcutDiagnostics.select"))
                            .foregroundStyle(.secondary).padding(30)
                    }
                }.frame(minWidth: 470, maxWidth: .infinity)
            }
            Text(L("shortcutDiagnostics.summaryNote")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var validRange: Bool {
        range != "custom" || rangeStart <= rangeEnd
    }

    private var selectionKey: String {
        "\(range)-\(rangeStart.timeIntervalSince1970)-\(rangeEnd.timeIntervalSince1970)"
    }

    private func interval(at now: Date) -> DateInterval? {
        switch range {
        case "hour": DateInterval(start: now.addingTimeInterval(-3600), end: now)
        case "day": DateInterval(start: now.addingTimeInterval(-86400), end: now)
        case "custom": validRange ? DateInterval(start: rangeStart, end: rangeEnd) : nil
        default: nil
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("diagnostics.current")).font(.headline)
                if let processes = report.processes, !processes.isEmpty {
                    DisclosureGroup(L("shortcutDiagnostics.processes"), isExpanded: $processesExpanded) {
                        Grid(alignment: .leading, horizontalSpacing: 20) {
                            GridRow {
                                Text(L("shortcutDiagnostics.process")); Text("PID")
                                Text(L("shortcutDiagnostics.memory")); Text("CPU")
                                Text(L("shortcutDiagnostics.operations"))
                            }.fontWeight(.medium)
                            ForEach(processes) { process in
                                GridRow {
                                    Text(L("shortcutDiagnostics.role." + process.role.rawValue))
                                    Text(String(process.pid))
                                    Text(process.footprintBytes
                                        .map { String(format: "%.1f MiB", Double($0) / 1_048_576) } ?? "—")
                                    Text(processCPU[process.id].map { String(format: "%.1f%%", $0) } ?? "—")
                                    Text(String(process.managedOperations))
                                }.monospacedDigit()
                            }
                        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                        Text(L("shortcutDiagnostics.processNote")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if report.processes?.isEmpty ?? true {
                    Text(L("diagnostics.unavailable"))
                }
                Text(L("diagnostics.modules")).font(.headline)
                if let modules = bundle?.currentModules, !modules.isEmpty {
                    ForEach(modules.keys.sorted(), id: \.self) { id in
                        if let health = modules[id] {
                            HStack {
                                Text(L("settings.services." + id))
                                Spacer()
                                Text(L("diagnostics.state." + health.state.rawValue))
                                Text(String(health.activeOperations)).monospacedDigit()
                            }
                            if let failure = health.failure {
                                Text(L("diagnostics.failure") + " " +
                                    L("diagnostics.failure." + String(describing: failure)))
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                } else {
                    Text(L("diagnostics.unavailable"))
                }
                Text(L("diagnostics.hangs")).font(.headline)
                Button(L("diagnostics.hangFolder")) { NSWorkspace.shared.open(DiagnosticsReport.hangDirectory) }
                Text(L("diagnostics.hangNote")).font(.caption).foregroundStyle(.secondary)
                if bundle == nil || bundle?.collectionFailures.contains("hangs") == true {
                    Text(L("diagnostics.unavailable"))
                } else if bundle?.hangs.isEmpty == true {
                    Text(L("diagnostics.noHangs"))
                }
                ForEach(bundle?.hangs ?? []) { record in
                    HStack {
                        Text(record.date.formatted())
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(record.bytes), countStyle: .file))
                    }
                }
                if let count = bundle?.unreadableHangFiles, count > 0 {
                    Text(L("diagnostics.unreadableHangs", count)).foregroundStyle(.orange)
                }
                Text(L("diagnostics.exportNote")).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit())
        }
    }

    private func timeline(_ sample: ShortcutLatencySample) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("shortcutDiagnostics.timeline")).font(.headline)
            Text(sample.trace.id.uuidString).font(.caption.monospaced()).textSelection(.enabled)
            Text(sample.trace.date, style: .date).font(.caption)
            Text(L("shortcutDiagnostics.columns")).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(sample.events.enumerated()), id: \.offset) { index, event in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("shortcutDiagnostics.stage." + event.stage.rawValue))
                        if let index = event.itemIndex, let count = event.itemCount {
                            Text(L("shortcutDiagnostics.item", index, count)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(L("shortcutDiagnostics.role." + event.role.rawValue) + " · PID " + String(event.pid) +
                            " · " + event.build)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(milliseconds(event.milliseconds))
                        let previous = index > 0 ? sample.events[index - 1].milliseconds : 0
                        Text("+" + milliseconds(event.milliseconds - previous)).foregroundStyle(.secondary)
                    }.font(.callout.monospacedDigit())
                }
                Divider()
            }
        }
    }

    private func milliseconds(_ value: Double?) -> String {
        value.map { String(format: "%.1f ms", $0) } ?? "—"
    }

    private func refresh() async {
        guard !refreshing, validRange else { return }
        refreshing = true
        defer { refreshing = false }
        let key = selectionKey
        let now = Date()
        do {
            let value = try await DiagnosticsCollector().collect(
                now: now,
                interval: interval(at: now),
                previousProcesses: report.processes
            )
            guard !Task.isCancelled, key == selectionKey else { return }
            processCPU = Dictionary(uniqueKeysWithValues: (value.shortcuts.processes ?? []).compactMap { current in
                guard let previous = report.processes?.first(where: { $0.id == current.id }),
                      let cpu = current.cpuPercent(since: previous) else { return nil }
                return (current.id, cpu)
            })
            report = value.shortcuts; bundle = value; failure = false; collectedSelection = key
        } catch {
            guard !Task.isCancelled, key == selectionKey else { return }
            failure = true; bundle = nil
        }
    }

    private func export() {
        guard let snapshot = bundle, validRange, collectedSelection == selectionKey else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "typeflux-diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            exportFailed = await Task.detached(priority: .utility) {
                do {
                    try snapshot.encodedForExport().write(to: url, options: .atomic)
                    return false
                } catch { return true }
            }.value
        }
    }
}
