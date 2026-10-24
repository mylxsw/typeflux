import AppKit
import SwiftUI

@MainActor
struct DiagnosticsOverview: View {
    let report: ShortcutLatencyReport
    let bundle: DiagnosticsReport?
    let processCPU: [String: Double]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                DiagnosticsCard(title: L("diagnostics.resources"), symbol: "cpu") {
                    if let processes = report.processes, !processes.isEmpty {
                        processTable(processes)
                    } else {
                        unavailable
                    }
                }
                .help(L("diagnostics.current") + " " + L("shortcutDiagnostics.processNote"))
                DiagnosticsCard(title: L("diagnostics.health"), symbol: "square.stack.3d.up") {
                    moduleTable
                }
                .help(L("diagnostics.current"))
                DiagnosticsCard(title: L("diagnostics.hangSamples"), symbol: "waveform.path.ecg",
                                folder: DiagnosticsReport.hangDirectory, folderLabel: L("diagnostics.hangFolder")) {
                    hangRecords
                }
                .help(L("diagnostics.hangNote"))
            }
            .padding(1)
        }
        .accessibilityIdentifier("diagnostics.overview")
    }

    private var unavailable: some View {
        Text(L("diagnostics.unavailable"))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
    }

    private func processTable(_ processes: [FeatureResourceSnapshot]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
            GridRow {
                Text(L("shortcutDiagnostics.process"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("PID")
                Text(L("shortcutDiagnostics.memory"))
                Text("CPU")
                Text(L("shortcutDiagnostics.operations"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(processes) { process in
                GridRow {
                    Text(L("shortcutDiagnostics.role." + process.role.rawValue)).fontWeight(.medium)
                    Text(String(process.pid)).foregroundStyle(.secondary)
                    Text(process.footprintBytes.map { String(format: "%.1f MiB", Double($0) / 1_048_576) } ?? "—")
                    Text(processCPU[process.id].map { String(format: "%.1f%%", $0) } ?? "—")
                    Text(String(process.managedOperations))
                }
                .monospacedDigit()
            }
        }
        .font(.callout)
    }

    @ViewBuilder private var moduleTable: some View {
        if let modules = bundle?.currentModules, !modules.isEmpty {
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                GridRow {
                    Text(L("diagnostics.module")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(L("diagnostics.status")).frame(width: 120, alignment: .leading)
                    Text(L("shortcutDiagnostics.operations"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(modules.keys.sorted(), id: \.self) { id in
                    if let health = modules[id] {
                        GridRow {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L("settings.services." + id)).fontWeight(.medium)
                                if let failure = health.failure {
                                    Text(L("diagnostics.failure." + String(describing: failure)))
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Label {
                                Text(L("diagnostics.state." + health.state.rawValue))
                            } icon: {
                                Circle().fill(stateColor(health.state)).frame(width: 6, height: 6)
                            }
                            Text(String(health.activeOperations)).monospacedDigit()
                        }
                    }
                }
            }
            .font(.callout)
        } else {
            unavailable
        }
    }

    private func stateColor(_ state: ModuleState) -> Color {
        switch state {
        case .ready: .green
        case .starting, .recovering, .circuitOpen, .degraded: .orange
        case .stopped, .disabled: .secondary
        }
    }

    private var hangRecords: some View {
        VStack(alignment: .leading, spacing: 12) {
            if bundle == nil || bundle?.collectionFailures.contains("hangs") == true {
                Text(L("diagnostics.unavailable")).foregroundStyle(.secondary)
            } else if bundle?.hangs.isEmpty == true {
                Text(L("diagnostics.noHangs")).foregroundStyle(.secondary)
            }
            ForEach(bundle?.hangs ?? []) { record in
                HStack {
                    Text(record.date.formatted())
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(record.bytes), countStyle: .file))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let count = bundle?.unreadableHangFiles, count > 0 {
                Text(L("diagnostics.unreadableHangs", count)).font(.caption).foregroundStyle(.orange)
            }
        }
        .font(.callout)
    }
}

@MainActor
private struct DiagnosticsCard<Content: View>: View {
    let title: String
    let symbol: String
    var folder: URL? = nil
    var folderLabel = ""
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(title, systemImage: symbol).font(.headline)
                Spacer()
                if let folder {
                    Button { NSWorkspace.shared.open(folder) } label: {
                        Image(systemName: "folder")
                    }
                    .help(folderLabel)
                    .accessibilityLabel(folderLabel)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.06))
        }
    }
}
