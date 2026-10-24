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
            window.title = L("diagnostics.title")
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
         automaticRefresh: Bool = true, initialSection: String = "overview",
         initialRange: DiagnosticsTimeRange = .minute5, initialSelectedSample: UUID? = nil) {
        _report = State(initialValue: report)
        _bundle = State(initialValue: bundle)
        self.automaticRefresh = automaticRefresh
        _section = State(initialValue: initialSection)
        _range = State(initialValue: initialRange)
        _selected = State(initialValue: initialSelectedSample)
    }

    @State private var section = "overview"
    @State private var range: DiagnosticsTimeRange = .minute5
    @State private var rangeStart = Date().addingTimeInterval(-3600)
    @State private var rangeEnd = Date()
    @State private var bundle: DiagnosticsReport?
    @State private var collectedSelection = ""
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
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    Picker(L("diagnostics.section"), selection: $section) {
                        Text(L("diagnostics.overview")).tag("overview")
                        Text(L("diagnostics.shortcuts")).tag("shortcuts")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                    Spacer(minLength: 12)
                    Picker(L("diagnostics.range"), selection: $range) {
                        ForEach(DiagnosticsTimeRange.allCases, id: \.self) { value in
                            Text(L("diagnostics.range." + value.rawValue)).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    .help(L("diagnostics.timeNote"))
                    .accessibilityIdentifier("diagnostics.range")
                }
                if range == .custom {
                    HStack(spacing: 16) {
                        DatePicker(L("diagnostics.from"), selection: $rangeStart)
                        DatePicker(L("diagnostics.to"), selection: $rangeEnd)
                    }
                }
                if !validRange {
                    Text(L("diagnostics.invalidRange")).foregroundStyle(.red)
                }
                if section == "overview" {
                    DiagnosticsOverview(report: report, bundle: bundle, processCPU: processCPU)
                } else {
                    shortcutDetails
                }
            }
            .padding(20)
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "stethoscope")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
            Text(L("diagnostics.title")).font(.title2.weight(.semibold))
            Spacer()
            Button { Task { await refresh() } } label: {
                Image(systemName: "arrow.clockwise").frame(width: 18, height: 18)
            }
            .disabled(refreshing)
            .help(L("shortcutDiagnostics.refresh"))
            .accessibilityLabel(L("shortcutDiagnostics.refresh"))
            Button { NSWorkspace.shared.open(ShortcutLatency.directory) } label: {
                Image(systemName: "folder").frame(width: 18, height: 18)
            }
            .help(L("shortcutDiagnostics.folder"))
            .accessibilityLabel(L("shortcutDiagnostics.folder"))
            Button { export() } label: {
                Label(L("diagnostics.export"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .help(L("diagnostics.exportNote"))
            .disabled(bundle == nil || refreshing || !validRange || collectedSelection != selectionKey)
            .accessibilityIdentifier("diagnostics.export")
        }
        .controlSize(.large)
        .padding(20)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if failure || exportFailed {
                Label(L("shortcutDiagnostics.error"), systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
            } else if let bundle, !bundle.collectionFailures.isEmpty {
                Label(L("diagnostics.partial"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Spacer()
            if refreshing { ProgressView().controlSize(.small) }
            if let bundle {
                Text(L("diagnostics.updated") + " " + bundle.generatedAt.formatted(date: .omitted, time: .standard))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private var shortcutDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
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
            HStack(spacing: 12) {
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
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .help(L("shortcutDiagnostics.boundary") + " " + L("shortcutDiagnostics.summaryNote"))
    }

    private var validRange: Bool {
        range != .custom || rangeStart <= rangeEnd
    }

    private var selectionKey: String {
        "\(range)-\(rangeStart.timeIntervalSince1970)-\(rangeEnd.timeIntervalSince1970)"
    }

    private func interval(at now: Date) -> DateInterval? {
        range.interval(at: now, start: rangeStart, end: rangeEnd)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private func timeline(_ sample: ShortcutLatencySample) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("shortcutDiagnostics.timeline")).font(.headline)
            Text(sample.trace.id.uuidString).font(.caption.monospaced()).textSelection(.enabled)
            Text(sample.trace.date, style: .date).font(.caption)
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
        .help(L("shortcutDiagnostics.columns"))
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
        panel.nameFieldStringValue = DiagnosticsReport.exportFilename()
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
