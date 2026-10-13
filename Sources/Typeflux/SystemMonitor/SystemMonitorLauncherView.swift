// swiftlint:disable file_length
import AppKit
import SwiftUI

/// The monitor inside the launcher (`top`): four cards, a focused card's details,
/// and the process list the editor filters. Its height is fixed, so the launcher
/// does not jump as cards focus or rows come and go.
struct SystemMonitorLauncherView: View {
    @Environment(\.interfaceStyle) private var interfaceStyle

    @ObservedObject var store: SystemMonitorStore
    @ObservedObject var model: SystemMonitorLauncherModel
    /// What the editor holds after the keyword: a name or PID.
    var filter: String
    /// Whether the window is already open: ⌘O then goes to it.
    var windowOpen: Bool
    var onEffect: (SystemMonitorEffect) -> Void

    @State private var client: UUID?

    static let height: CGFloat = 520
    static let padding: CGFloat = 14
    static let tileHeight: CGFloat = 92
    static let detailHeight: CGFloat = 136
    static let rowHeight: CGFloat = 32
    static let columns: (cpu: CGFloat, memory: CGFloat, disk: CGFloat, pid: CGFloat) = (70, 78, 84, 56)

    var body: some View {
        let rows = model.rows(store.snapshot, filter: filter)
        VStack(spacing: 0) {
            Rectangle().fill(TypefluxColor.separator.color).frame(height: 1).padding(.horizontal, 12)
            VStack(alignment: .leading, spacing: 8) {
                statusLine
                HStack(spacing: 8) {
                    ForEach(SystemMonitorMetric.allCases, id: \.self) { tile($0) }
                }
                .frame(height: Self.tileHeight)
                if let alert = store.cpuAlert { alertRow(alert) }
                if let focus = model.focus {
                    SystemMonitorDetailView(metric: focus, store: store) { model.setFocus(nil) }
                        .frame(height: Self.detailHeight)
                }
                processHeader(count: rows.count)
                processList(rows)
                footer(rows)
            }
            .padding(.horizontal, Self.padding)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .frame(height: Self.height, alignment: .top)
        .onAppear { client = store.attach(.init(processes: true)) }
        .onDisappear {
            store.detach(client)
            client = nil
            // The next time starts as it first did.
            model.reset()
        }
        .accessibilityIdentifier("system.monitor.launcher")
    }

    // MARK: Header and cards

    private var statusLine: some View {
        let snapshot = store.snapshot
        return HStack(spacing: 12) {
            HStack(spacing: 5) {
                Circle().fill(TypefluxColor.success.color).frame(width: 6, height: 6)
                Text(L("system.monitor.live", SystemMonitorFormat.interval(store.interval)))
            }
            Text(SystemMonitorMetricDisplay.machineLine(store.machine)).lineLimit(1)
            Spacer(minLength: 8)
            if let snapshot {
                Text(L("system.monitor.uptime", SystemMonitorFormat.uptime(snapshot.uptime)))
                if let battery = snapshot.battery {
                    Text(L(battery.charging ? "system.monitor.battery.charging" : "system.monitor.battery",
                           battery.percent))
                }
                HStack(spacing: 3) {
                    Text(L("system.monitor.thermal"))
                    Text(SystemMonitorMetricDisplay.thermalTitle(snapshot.thermal))
                        .foregroundStyle(SystemMonitorMetricDisplay.thermalLevel(snapshot.thermal).color
                            ?? TypefluxColor.success.color)
                }
            }
        }
        .font(.system(.subheadline))
        .foregroundStyle(TypefluxColor.tertiaryLabel.color)
        .frame(height: 18)
    }

    private func tile(_ metric: SystemMonitorMetric) -> some View {
        let display = SystemMonitorMetricDisplay.make(metric, snapshot: store.snapshot, machine: store.machine)
        let focused = model.focus == metric
        let accent = metric.color
        let warning = display.level.color
        return Button { model.toggleFocus(metric) } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Image(systemName: SystemMonitorMetricDisplay.symbol(metric)).font(.system(.subheadline,
                                                                                              weight: .semibold))
                        .foregroundStyle(accent)
                    Text(SystemMonitorMetricDisplay.title(metric)).font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(TypefluxColor.secondaryLabel.color)
                    if metric == .memory, let pressure = store.snapshot?.memory.pressure {
                        Circle().fill(pressure.color).frame(width: 6, height: 6)
                            .help(L("system.monitor.pressure", SystemMonitorMetricDisplay.pressureTitle(pressure)))
                    }
                    Spacer(minLength: 0)
                    Text("⌘\(metric.number)").font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(TypefluxColor.tertiaryLabel.color)
                }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(display.value).font(.system(.title, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(warning ?? TypefluxColor.label.color)
                    Text(display.unit).font(.system(.subheadline)).foregroundStyle(TypefluxColor.tertiaryLabel.color)
                }
                Text(display.detail).font(.system(.subheadline)).monospacedDigit()
                    .foregroundStyle(TypefluxColor.tertiaryLabel.color).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(alignment: .bottom) {
                SystemMonitorChart(series: .make(metric, history: store.history)).frame(height: 28)
            }
            .background(display.level == .critical ? TypefluxColor.danger.color.opacity(0.12) : TypefluxColor.label
                .color.opacity(0.06).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle),
                                        style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
                    .strokeBorder(focused ? accent : TypefluxColor.separator.color, lineWidth: focused ? 1.5 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SystemMonitorMetricDisplay.title(metric) + " " + display.value + display.unit)
        .accessibilityAddTraits(focused ? .isSelected : [])
        .accessibilityIdentifier("system.monitor.tile.\(metric.rawValue)")
    }

    private func alertRow(_ alert: SystemMonitorCPUAlertInfo) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(TypefluxColor.danger.color)
            Text(Self.alertText(alert)).foregroundStyle(TypefluxColor.label.color).lineLimit(1)
            Spacer(minLength: 8)
            if let process = alert.process {
                Button(L("system.monitor.alert.show")) {
                    model.sort = .cpu
                    model.select(process.pid)
                }
                .buttonStyle(.plain).foregroundStyle(TypefluxColor.danger.color)
            }
        }
        .font(.system(.callout))
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(TypefluxColor.danger.color.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle),
                                         style: .continuous))
        .accessibilityIdentifier("system.monitor.alert")
    }

    static func alertText(_ alert: SystemMonitorCPUAlertInfo) -> String {
        guard let process = alert.process else { return L("system.monitor.alert", alert.seconds) }
        // PIDs are written as is: a grouping separator ("4,821") would make them unrecognisable.
        return L("system.monitor.alert.process", alert.seconds, process.name, String(process.pid),
                 SystemMonitorFormat.processCPU(process.cpu))
    }

    // MARK: Processes

    private func processHeader(count: Int) -> some View {
        HStack(spacing: 8) {
            Text(L("system.monitor.processes")).font(.system(.subheadline, weight: .semibold))
            Text(filter.trimmingCharacters(in: .whitespaces).isEmpty
                ? L("system.monitor.processes.count", store.snapshot?.processCount ?? count)
                : L("system.monitor.processes.matching", count))
                .font(.system(.subheadline))
            if model.isFrozen, count > 0 {
                Label(L("system.monitor.frozen"), systemImage: "pause.fill").font(.system(.subheadline))
                    .labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 8)
            SystemMonitorSortPicker(sort: $model.sort, options: SystemMonitorSort.allCases)
        }
        .foregroundStyle(TypefluxColor.tertiaryLabel.color)
        .frame(height: 22)
        .padding(.top, 2)
    }

    private func processList(_ rows: [SystemProcess]) -> some View {
        VStack(spacing: 0) {
            columnHeader
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if rows.isEmpty {
                            Text(store.snapshot == nil ? L("system.monitor.summary.loading")
                                : L("system.monitor.processes.none", filter))
                                .font(.system(.callout)).foregroundStyle(TypefluxColor.tertiaryLabel.color)
                                .frame(maxWidth: .infinity).padding(.top, 18)
                        }
                        ForEach(rows) { process in
                            row(process).id(process.pid)
                        }
                    }
                }
                .onChange(of: model.selection) { pid in
                    guard let pid else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(pid) }
                }
            }
            .onHover { model.hoveringList = $0 }
        }
        .frame(maxHeight: .infinity)
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text(L("system.monitor.column.name")).frame(maxWidth: .infinity, alignment: .leading)
            sortColumn(.cpu, title: SystemMonitorMetricDisplay.title(.cpu), width: Self.columns.cpu)
            sortColumn(.memory, title: SystemMonitorMetricDisplay.title(.memory), width: Self.columns.memory)
            sortColumn(.disk, title: SystemMonitorMetricDisplay.title(.disk), width: Self.columns.disk)
            Text("PID").frame(width: Self.columns.pid, alignment: .trailing)
        }
        .font(.system(.subheadline))
        .foregroundStyle(TypefluxColor.tertiaryLabel.color)
        .padding(.horizontal, 10)
        .frame(height: 18)
    }

    private func sortColumn(_ sort: SystemMonitorSort, title: String, width: CGFloat) -> some View {
        Button { model.sort = sort } label: {
            Text(title).fontWeight(model.sort == sort ? .semibold : .regular)
                .foregroundStyle(model.sort == sort ? TypefluxColor.label.color : TypefluxColor.tertiaryLabel.color)
                .frame(width: width, alignment: .trailing)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func row(_ process: SystemProcess) -> some View {
        if let confirming = model.confirming, confirming.pid == process.pid {
            confirmRow(process, force: confirming.force)
        } else if model.selection == process.pid {
            selectedRow(process)
        } else {
            plainRow(process)
        }
    }

    private func plainRow(_ process: SystemProcess) -> some View {
        HStack(spacing: 8) {
            name(process)
            Text(SystemMonitorFormat.processCPU(process.cpu) + "%")
                .foregroundStyle(SystemMonitorLevel.processCPU(process.cpu).color ?? TypefluxColor.label.color)
                .frame(width: Self.columns.cpu, alignment: .trailing)
            Text(SystemMonitorFormat.memory(process.memory)).frame(width: Self.columns.memory, alignment: .trailing)
            Text(process.disk.map { $0 < 1 ? "—" : SystemMonitorFormat.rate($0) } ?? "—")
                .frame(width: Self.columns.disk, alignment: .trailing)
            Text(String(process.pid)).foregroundStyle(TypefluxColor.tertiaryLabel.color)
                .frame(width: Self.columns.pid, alignment: .trailing)
        }
        .font(.system(.callout)).monospacedDigit()
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture { model.select(process.pid) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("system.monitor.process")
    }

    private func selectedRow(_ process: SystemProcess) -> some View {
        let eligible = model.terminator.eligibility(of: process) == .allowed
        return HStack(spacing: 8) {
            name(process)
            Text("PID \(process.pid)").font(.system(.footnote)).foregroundStyle(TypefluxColor.tertiaryLabel.color)
            Text(SystemMonitorFormat.processCPU(process.cpu) + "% · " + SystemMonitorFormat.memory(process.memory))
                .font(.system(.subheadline)).foregroundStyle(TypefluxColor.tertiaryLabel.color).lineLimit(1)
            Spacer(minLength: 6)
            actionButton(isApp(process) ? L("system.monitor.action.switch") : L("system.monitor.action.reveal"), "↩") {
                onEffect(.activate(process))
            }
            actionButton(L("system.monitor.action.copyPID"), "⌘C") { onEffect(.copy(String(process.pid))) }
            actionButton(L("system.monitor.action.quit"), "⌘⌫", role: .destructive) {
                onEffect(model.handle(.terminate(force: NSEvent.modifierFlags.contains(.option)), rows: [process]))
            }
            .disabled(!eligible)
            .help(eligible ? "" : L("system.monitor.refused.system", process.name))
        }
        .font(.system(.callout)).monospacedDigit()
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(TypefluxColor.accent.color.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle),
                                         style: .continuous))
        .accessibilityIdentifier("system.monitor.process.selected")
    }

    private func confirmRow(_ process: SystemProcess, force: Bool) -> some View {
        HStack(spacing: 9) {
            icon(process)
            Text(L(force ? "system.monitor.confirm.force" : "system.monitor.confirm", process.name))
                .font(.system(.callout, weight: .semibold)).lineLimit(1)
            Text(L(isApp(process) ? (force ? "system.monitor.confirm.app.force" : "system.monitor.confirm.app")
                    : "system.monitor.confirm.process", String(process.pid)))
                .font(.system(.subheadline)).foregroundStyle(TypefluxColor.tertiaryLabel.color).lineLimit(1)
            Spacer(minLength: 6)
            actionButton(L("system.monitor.action.cancel"), "esc") { model.cancelConfirmation() }
            actionButton(L(force ? "system.monitor.action.forceQuit" : "system.monitor.action.quit"), "↩",
                         role: .destructive, prominent: true) {
                onEffect(model.handle(.enter, rows: [process]))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight + 4)
        .background(TypefluxColor.danger.color.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle),
                                         style: .continuous))
        .accessibilityIdentifier("system.monitor.process.confirm")
    }

    private func name(_ process: SystemProcess) -> some View {
        HStack(spacing: 8) {
            icon(process)
            Text(process.name).lineLimit(1).truncationMode(.middle)
            if model.terminator.eligibility(of: process) == .system {
                Text(L("system.monitor.system")).font(.system(.footnote))
                    .foregroundStyle(TypefluxColor.tertiaryLabel.color)
                    .padding(.horizontal, 4).frame(height: 15)
                    .overlay(RoundedRectangle(cornerRadius: TypefluxRadius.textField.value(for: interfaceStyle))
                        .strokeBorder(TypefluxColor.separator.color))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func icon(_ process: SystemProcess) -> some View {
        Group {
            if isApp(process), let image = SystemProcessIcons.icon(for: process.pid) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "gearshape").font(.system(.footnote))
                    .foregroundStyle(TypefluxColor.tertiaryLabel.color)
                    .frame(width: 18, height: 18)
                    .background(TypefluxColor.label.color.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: TypefluxRadius.textField.value(for: interfaceStyle),
                                                     style: .continuous))
            }
        }
        .frame(width: 18, height: 18)
    }

    private func isApp(_ process: SystemProcess) -> Bool { store.apps[process.pid] != nil }

    private func actionButton(_ title: String, _ key: String, role: ButtonRole? = nil, prominent: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 4) {
                Text(title)
                Text(key).font(.system(.footnote)).opacity(0.65)
            }
            .font(.system(.subheadline))
            .foregroundStyle(prominent ? Color.white : role == .destructive ? TypefluxColor.danger.color : TypefluxColor
                .secondaryLabel.color)
            .padding(.horizontal, 7).frame(height: 22)
            .background(prominent ? TypefluxColor.danger.color : TypefluxColor.label.color.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: TypefluxRadius.navigationIcon.value(for: interfaceStyle),
                                             style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func footer(_ rows: [SystemProcess]) -> some View {
        Text(Self.hint(model: model, rows: rows, windowOpen: windowOpen))
            .font(.system(.subheadline)).foregroundStyle(TypefluxColor.tertiaryLabel.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 16)
    }

    /// What the keys do now.
    @MainActor
    static func hint(model: SystemMonitorLauncherModel, rows: [SystemProcess], windowOpen: Bool) -> String {
        if let confirming = model.confirming {
            return L(confirming.force ? "system.monitor.hint.confirm.force" : "system.monitor.hint.confirm")
        }
        let window = L(windowOpen ? "system.monitor.hint.goToWindow" : "system.monitor.hint.popOut")
        if model.selected(in: rows) != nil { return L("system.monitor.hint.selected", window) }
        return L("system.monitor.hint", window)
    }
}

/// The CPU / Memory / Disk segmented control above process lists.
struct SystemMonitorSortPicker: View {
    @Environment(\.interfaceStyle) private var interfaceStyle

    @Binding var sort: SystemMonitorSort
    var options: [SystemMonitorSort]

    var body: some View {
        TypefluxSegmentedControl(L("system.monitor.processes"), selection: $sort) {
            ForEach(options, id: \.self) { option in
                Text(SystemMonitorMetricDisplay.sortTitle(option)).tag(option)
            }
        }.controlSize(.small)
    }
}

/// A focused card's details: a 60-second chart and the figures behind it.
struct SystemMonitorDetailView: View {
    @Environment(\.interfaceStyle) private var interfaceStyle

    var metric: SystemMonitorMetric
    @ObservedObject var store: SystemMonitorStore
    var onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: SystemMonitorMetricDisplay.symbol(metric)).foregroundStyle(metric.color)
                    Text(chartTitle).font(.system(.callout, weight: .semibold))
                        .foregroundStyle(TypefluxColor.secondaryLabel.color)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Button(L("system.monitor.detail.close"), action: onClose).buttonStyle(.plain)
                        .font(.system(.subheadline)).foregroundStyle(TypefluxColor.tertiaryLabel.color)
                }
                // Two-line charts name their lines (and current rates) under the title.
                if metric == .disk || metric == .network {
                    HStack(spacing: 12) { legend }
                }
                SystemMonitorChart(series: .make(metric, history: store.history), lineWidth: 1.6)
                    .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 6) { figures }
                .frame(width: 236, alignment: .topLeading)
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(TypefluxColor.label.color.opacity(0.06).opacity(0.6),
                    in: RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle),
                                         style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: interfaceStyle), style: .continuous)
            .strokeBorder(TypefluxColor.separator.color))
        .accessibilityIdentifier("system.monitor.detail.\(metric.rawValue)")
    }

    private var chartTitle: String { L("system.monitor.detail.\(metric.rawValue)") }

    @ViewBuilder private var legend: some View {
        if let snapshot = store.snapshot {
            switch metric {
            case .disk:
                legendItem(L("system.monitor.read", SystemMonitorFormat.rate(snapshot.diskRead)),
                           SystemMonitorMetric.disk.color)
                legendItem(L("system.monitor.write", SystemMonitorFormat.rate(snapshot.diskWrite)),
                           TypefluxColor.warning.color)
            case .network:
                legendItem(L("system.monitor.download", SystemMonitorFormat.rate(snapshot.networkDown)),
                           SystemMonitorMetric.network.color)
                legendItem(L("system.monitor.upload", SystemMonitorFormat.rate(snapshot.networkUp)),
                           TypefluxColor.warning.color)
            case .cpu, .memory: EmptyView()
            }
        }
    }

    private func legendItem(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(.subheadline)).monospacedDigit().foregroundStyle(color)
        }
    }

    @ViewBuilder private var figures: some View {
        if let snapshot = store.snapshot {
            switch metric {
            case .cpu: cpuFigures(snapshot)
            case .memory: memoryFigures(snapshot.memory)
            case .disk: diskFigures(snapshot.volumes)
            case .network: networkFigures(snapshot)
            }
        }
    }

    private func cpuFigures(_ snapshot: SystemSnapshot) -> some View {
        let machine = store.machine
        return VStack(alignment: .leading, spacing: 4) {
            Text(L("system.monitor.cores.each")).font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(TypefluxColor.secondaryLabel.color)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(snapshot.cpu.cores.enumerated()), id: \.offset) { index, usage in
                    GeometryReader { geometry in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: TypefluxRadius.textField.value(for: interfaceStyle))
                                .fill(TypefluxColor.label.color.opacity(0.06))
                            RoundedRectangle(cornerRadius: TypefluxRadius.textField.value(for: interfaceStyle))
                                .fill(SystemMonitorMetric.cpu.color)
                                .frame(height: geometry.size.height * CGFloat(min(100, usage)) / 100)
                        }
                    }
                    .help(L("system.monitor.core", index + 1, SystemMonitorFormat.percent(usage)))
                }
            }
            .frame(height: 28)
            if let performance = machine.performanceCores, let efficiency = machine.efficiencyCores {
                Text(L("system.monitor.cores.kinds", performance, efficiency)).font(.system(.footnote))
                    .foregroundStyle(TypefluxColor.tertiaryLabel.color)
            }
            figure(L("system.monitor.cpu.split"),
                   SystemMonitorFormat.percent(snapshot.cpu.user) + "% / " + SystemMonitorFormat
                       .percent(snapshot.cpu.system) + "%")
            figure(L("system.monitor.load"), SystemMonitorFormat.load(snapshot.loadAverage))
            if let count = snapshot.processCount { figure(L("system.monitor.processes"), String(count)) }
        }
    }

    private func memoryFigures(_ memory: SystemMemoryUsage) -> some View {
        let counters = memory.counters
        let parts: [(String, UInt64, Color)] = [
            (L("system.monitor.memory.app"), counters.app, SystemMonitorMetric.memory.color),
            (L("system.monitor.memory.wired"), counters.wired, Color.orange),
            (L("system.monitor.memory.compressed"), counters.compressed, Color.pink),
            (L("system.monitor.memory.cached"), counters.cached, SystemMonitorMetric.memory.color.opacity(0.35))
        ]
        let total = Double(max(1, memory.total))
        return VStack(alignment: .leading, spacing: 5) {
            Text(L("system.monitor.memory.used", SystemMonitorFormat.memory(memory.used),
                   SystemMonitorFormat.memory(memory.total)))
                .font(.system(.subheadline, weight: .semibold)).foregroundStyle(TypefluxColor.secondaryLabel.color)
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        Rectangle().fill(part.2).frame(width: geometry.size.width * CGFloat(min(1,
                                                                                                Double(part.1) /
                                                                                                    total)))
                    }
                    Spacer(minLength: 0)
                }
                .background(TypefluxColor.label.color.opacity(0.06))
                .clipShape(Capsule())
            }
            .frame(height: 10)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: TypefluxRadius.textField.value(for: interfaceStyle)).fill(part.2)
                            .frame(width: 7,
                                   height: 7)
                        Text(part.0 + " " + SystemMonitorFormat.memory(part.1)).lineLimit(1)
                    }
                    .font(.system(.footnote)).foregroundStyle(TypefluxColor.secondaryLabel.color)
                }
            }
            figure(L("system.monitor.pressure.title"), SystemMonitorMetricDisplay.pressureTitle(memory.pressure),
                   color: memory.pressure.color)
            figure(L("system.monitor.swap"), SystemMonitorFormat.memory(counters.swapUsed))
        }
    }

    private func diskFigures(_ volumes: [SystemVolume]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("system.monitor.volumes")).font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(TypefluxColor.secondaryLabel.color)
            ForEach(volumes.prefix(3)) { volume in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(volume.name).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(L("system.monitor.free", SystemMonitorFormat.storage(volume.available)))
                            .foregroundStyle(TypefluxColor.tertiaryLabel.color)
                    }
                    .font(.system(.subheadline))
                    GeometryReader { geometry in
                        Capsule().fill(TypefluxColor.label.color.opacity(0.06)).overlay(alignment: .leading) {
                            Capsule().fill(SystemMonitorMetric.disk.color)
                                .frame(width: geometry.size.width * CGFloat(volume.usedPercent / 100))
                        }
                    }
                    .frame(height: 5)
                }
            }
        }
    }

    private func networkFigures(_ snapshot: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snapshot.interface?.displayName ?? L("system.monitor.network.none"))
                .font(.system(.subheadline, weight: .semibold)).foregroundStyle(TypefluxColor.secondaryLabel.color)
            if let address = snapshot.interface?.address { figure(L("system.monitor.address"), address) }
            figure(L("system.monitor.peak.down"), SystemMonitorFormat.rate(store.history.networkDown.peak))
            figure(L("system.monitor.peak.up"), SystemMonitorFormat.rate(store.history.networkUp.peak))
        }
    }

    private func figure(_ title: String, _ value: String, color: Color? = nil) -> some View {
        HStack {
            Text(title).foregroundStyle(TypefluxColor.tertiaryLabel.color)
            Spacer(minLength: 6)
            Text(value).monospacedDigit().foregroundStyle(color ?? TypefluxColor.label.color).lineLimit(1)
        }
        .font(.system(.subheadline))
    }
}

/// The live summary on the keyword's row, before the monitor is entered:
/// "CPU 23% · Memory 65% · Disk 62% · ↓ 6.3 MB/s ↑ 181 KB/s".
struct SystemMonitorHintSummary: View {
    @ObservedObject var store: SystemMonitorStore
    @State private var client: UUID?

    var body: some View {
        HStack(spacing: 8) {
            Text(SystemMonitorMetricDisplay.summary(store.snapshot))
                .font(.system(.callout)).monospacedDigit()
                .foregroundStyle(TypefluxColor.tertiaryLabel.color)
                .lineLimit(1)
            SystemMonitorChart(series: .make(.cpu, history: store.history), lineWidth: 1.2, filled: false)
                .frame(width: 64, height: 16)
        }
        .onAppear { client = store.attach(.init(processes: false)) }
        .onDisappear { store.detach(client); client = nil }
        .accessibilityIdentifier("system.monitor.summary")
    }
}
