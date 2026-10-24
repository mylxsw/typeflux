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
            TFFormRow(title: L("shortcutDiagnostics.inspect")) {
                TFButton(title: L("shortcutDiagnostics.open"), systemImage: "stopwatch") {
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
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
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
    init(report: ShortcutLatencyReport = ShortcutLatencyReport(events: [])) { _report = State(initialValue: report) }
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
                Button(L("shortcutDiagnostics.export")) { export() }.disabled(!report.canExport)
            }
            if let processes = report.processes, !processes.isEmpty {
                DisclosureGroup(L("shortcutDiagnostics.processes")) {
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
            Text(L("shortcutDiagnostics.boundary")).font(.callout).foregroundStyle(.secondary)
            HStack {
                Picker(L("shortcutDiagnostics.feature"), selection: $feature) {
                    Text(L("shortcutDiagnostics.all")).tag("all")
                    ForEach(FeatureRole.allCases.filter { $0 != .host && $0 != .shortcuts && $0 != .background }, id: \.rawValue) { role in
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
                metric("P50", milliseconds(ShortcutLatencyReport.percentile(samples.compactMap(\.visibleMilliseconds), fraction: 0.5)))
                metric("P95", milliseconds(ShortcutLatencyReport.percentile(samples.compactMap(\.visibleMilliseconds), fraction: 0.95)))
                metric(L("shortcutDiagnostics.other"), String(samples.filter { $0.outcome != "visible" }.count))
            }
            if failure || exportFailed {
                Text(L("shortcutDiagnostics.error")).foregroundStyle(.red)
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
            Text(ShortcutLatency.directory.path).font(.caption.monospaced()).textSelection(.enabled)
        }
        .padding(20)
        .accessibilityIdentifier("shortcutDiagnostics.dashboard")
        .task {
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
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
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let directory = ShortcutLatency.directory
        let result = await Task.detached(priority: .utility) { Result { try ShortcutLatencyReport.read(directory: directory) } }.value
        guard !Task.isCancelled else { return }
        switch result {
        case var .success(value):
            if FeatureProcess.enabled,
               let data = try? await FeatureProcess.route(.init(destination: .host, action: "resources")),
               let processes = try? JSONDecoder().decode([FeatureResourceSnapshot].self, from: data) {
                processCPU = Dictionary(uniqueKeysWithValues: processes.compactMap { current in
                    guard let previous = report.processes?.first(where: { $0.id == current.id }),
                          let cpu = current.cpuPercent(since: previous) else { return nil }
                    return (current.id, cpu)
                })
                value.processes = processes
            }
            report = value; failure = false
        case .failure: failure = true
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "typeflux-shortcut-diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snapshot = report.selecting(feature: feature, temperature: temperature)
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
