import AppKit
import SwiftUI

/// The monitor window's content in its three shapes. It sizes itself; the
/// controller fits the panel around it.
struct SystemMonitorWindowView: View {
    let controller: SystemMonitorWindowController
    @ObservedObject var model: SystemMonitorWindowModel
    @ObservedObject var store: SystemMonitorStore
    @State private var hovering = false

    static let fullWidth: CGFloat = 380
    static let compactWidth: CGFloat = 272
    static let processRows = 6

    private var settings: SystemMonitorWindowSettings { model.settings }

    var body: some View {
        content
            // Empty space moves the window; a double-click opens the mini bar up.
            .background(AskWindowDragArea(handlers: AskWindowDragHandlers(reset: {
                if settings.mode == .mini { controller.setMode(.full) }
            })))
            .background(SystemMonitorWindowBackground())
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(model.flashing ? AskTheme.accent : AskTheme.border,
                                   lineWidth: model.flashing ? 2.5 : 1)
                    .animation(.easeOut(duration: 0.2), value: model.flashing)
            }
            .fixedSize()
            .onHover { hovering = $0 }
            .background(GeometryReader { geometry in
                Color.clear.onChange(of: geometry.size) { _ in controller.contentSizeChanged() }
            })
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: settings.mode == .mini ? 16 : 14, style: .continuous)
    }

    @ViewBuilder private var content: some View {
        switch settings.mode {
        case .full: full
        case .compact: compact
        case .mini: mini
        }
    }

    // MARK: Full

    private var full: some View {
        VStack(spacing: 0) {
            titleBar(showsTitle: true)
            VStack(spacing: 0) {
                ForEach(Array(settings.metrics.enumerated()), id: \.element) { index, metric in
                    if index > 0 { Divider().opacity(0.5) }
                    metricRow(metric)
                }
            }
            .padding(.horizontal, 12)
            processSection
        }
        .frame(width: Self.fullWidth)
        .padding(.bottom, 10)
    }

    private func metricRow(_ metric: SystemMonitorMetric) -> some View {
        let display = SystemMonitorMetricDisplay.make(metric, snapshot: store.snapshot, machine: store.machine)
        return Button { controller.openInLauncher(metric) } label: {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: SystemMonitorMetricDisplay.symbol(metric)).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SystemMonitorTheme.color(metric))
                    Text(SystemMonitorMetricDisplay.title(metric)).font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(StudioTheme.textSecondary)
                }
                .frame(width: 64, alignment: .leading)
                SystemMonitorChart(series: .make(metric, history: store.history)).frame(height: 30)
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(display.value).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(SystemMonitorTheme.color(display.level) ?? StudioTheme.textPrimary)
                        Text(display.unit.replacingOccurrences(of: " ↓", with: "")).font(.system(size: 10.5))
                            .foregroundStyle(StudioTheme.textTertiary)
                    }
                    Text(display.detail).font(.system(size: 10.5)).monospacedDigit()
                        .foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
                }
                .frame(width: 118, alignment: .trailing)
            }
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("system.monitor.window.openInLauncher"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SystemMonitorMetricDisplay.title(metric) + " " + display.value + display.unit)
        .accessibilityIdentifier("system.monitor.window.row.\(metric.rawValue)")
    }

    private var processSection: some View {
        let processes = SystemMonitorProcessList.sorted(store.snapshot?.processes ?? [], by: settings.sort)
            .prefix(Self.processRows)
        return VStack(spacing: 2) {
            Divider().opacity(0.5)
            HStack {
                Text(L("system.monitor.processes")).font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(StudioTheme.textTertiary)
                Spacer()
                SystemMonitorSortPicker(sort: Binding(get: { settings.sort }, set: { controller.setSort($0) }),
                                        options: [.cpu, .memory])
            }
            .padding(.top, 6).padding(.bottom, 2)
            ForEach(Array(processes)) { process in
                HStack(spacing: 8) {
                    Group {
                        if store.apps[process.pid] != nil, let icon = SystemProcessIcons.icon(for: process.pid) {
                            Image(nsImage: icon).resizable()
                        } else {
                            Image(systemName: "gearshape").font(.system(size: 9)).foregroundStyle(StudioTheme.textTertiary)
                        }
                    }
                    .frame(width: 16, height: 16)
                    Text(process.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(SystemMonitorFormat.processCPU(process.cpu) + "%")
                        .foregroundStyle(SystemMonitorTheme.color(.processCPU(process.cpu)) ?? StudioTheme.textPrimary)
                        .frame(width: 56, alignment: .trailing)
                    Text(SystemMonitorFormat.memory(process.memory)).frame(width: 66, alignment: .trailing)
                }
                .font(.system(size: 12)).monospacedDigit()
                .frame(height: 26)
            }
            // Rows still to come keep the window from growing once figures arrive.
            ForEach(processes.count..<Self.processRows, id: \.self) { _ in Color.clear.frame(height: 26) }
        }
        .padding(.horizontal, 12)
    }

    // MARK: Compact

    private var compact: some View {
        ZStack(alignment: .top) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(settings.metrics, id: \.self) { metric in compactTile(metric) }
            }
            .padding(8)
            titleBar(showsTitle: false)
                .background(SystemMonitorWindowBackground())
                .opacity(hovering ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .frame(width: Self.compactWidth)
    }

    private func compactTile(_ metric: SystemMonitorMetric) -> some View {
        let display = SystemMonitorMetricDisplay.make(metric, snapshot: store.snapshot, machine: store.machine)
        return VStack(alignment: .leading, spacing: 0) {
            Text(SystemMonitorMetricDisplay.title(metric)).font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(SystemMonitorTheme.color(metric))
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(display.value).font(.system(size: 18, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(SystemMonitorTheme.color(display.level) ?? StudioTheme.textPrimary)
                Text(display.unit.replacingOccurrences(of: " ↓", with: "")).font(.system(size: 10.5))
                    .foregroundStyle(StudioTheme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9).padding(.top, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 76)
        .background(alignment: .bottom) {
            SystemMonitorChart(series: .make(metric, history: store.history)).frame(height: 24)
        }
        .background(display.level == .critical ? AskTheme.dangerSoft : AskTheme.hoverFill)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SystemMonitorMetricDisplay.title(metric) + " " + display.value + display.unit)
    }

    // MARK: Mini

    private var mini: some View {
        HStack(spacing: 12) {
            ForEach(Array(settings.metrics.enumerated()), id: \.element) { index, metric in
                if index > 0 { Rectangle().fill(AskTheme.border).frame(width: 1, height: 14) }
                miniItem(metric)
            }
            if hovering {
                HStack(spacing: 2) {
                    iconButton("arrow.up.left.and.arrow.down.right", help: L("system.monitor.window.mode.full")) {
                        controller.setMode(.full)
                    }
                    optionsMenu
                }
            }
        }
        .padding(.leading, 14).padding(.trailing, hovering ? 6 : 14)
        .frame(height: 32)
    }

    @ViewBuilder
    private func miniItem(_ metric: SystemMonitorMetric) -> some View {
        let snapshot = store.snapshot
        let display = SystemMonitorMetricDisplay.make(metric, snapshot: snapshot, machine: store.machine)
        HStack(spacing: 5) {
            switch metric {
            case .network:
                Text("↓").foregroundStyle(StudioTheme.textTertiary)
                Text(snapshot.map { SystemMonitorFormat.shortRate($0.networkDown) } ?? "—").fontWeight(.semibold)
                Text("↑").foregroundStyle(StudioTheme.textTertiary)
                Text(snapshot.map { SystemMonitorFormat.shortRate($0.networkUp) } ?? "—").fontWeight(.semibold)
            case .disk:
                Text(SystemMonitorMetricDisplay.title(metric)).foregroundStyle(StudioTheme.textTertiary)
                Text(snapshot.map { SystemMonitorFormat.shortRate($0.diskRead + $0.diskWrite) + "/s" } ?? "—")
                    .fontWeight(.semibold)
            case .cpu, .memory:
                Text(SystemMonitorMetricDisplay.title(metric)).foregroundStyle(StudioTheme.textTertiary)
                Text(display.value + "%").fontWeight(.semibold)
                    .foregroundStyle(SystemMonitorTheme.color(display.level) ?? StudioTheme.textPrimary)
                if metric == .cpu {
                    SystemMonitorChart(series: .make(.cpu, history: store.history), lineWidth: 1.2, filled: false)
                        .frame(width: 40, height: 14)
                }
            }
        }
        .font(.system(size: 12)).monospacedDigit()
        .fixedSize()
    }

    // MARK: Title bar and options

    private func titleBar(showsTitle: Bool) -> some View {
        HStack(spacing: 6) {
            Button { controller.close() } label: {
                Image(systemName: "xmark").font(.system(size: 7.5, weight: .heavy))
                    .foregroundStyle(Color.black.opacity(hovering ? 0.55 : 0))
                    .frame(width: 12, height: 12)
                    .background(Color(nsColor: .systemRed), in: Circle())
            }
            .buttonStyle(.plain)
            .help(L("system.monitor.window.close"))
            .accessibilityLabel(L("system.monitor.window.close"))
            if showsTitle {
                Text(L("system.monitor.title")).font(.system(size: 12.5, weight: .semibold)).padding(.leading, 6)
            }
            Spacer(minLength: 6)
            modePicker
            iconButton(settings.pinned ? "pin.fill" : "pin", help: L(settings.pinned ? "system.monitor.window.unpin"
                    : "system.monitor.window.pin"), active: settings.pinned) { controller.togglePinned() }
            optionsMenu
        }
        .padding(.leading, 12).padding(.trailing, 8)
        .frame(height: showsTitle ? 36 : 30)
    }

    private var modePicker: some View {
        HStack(spacing: 1) {
            ForEach(SystemMonitorWindowMode.allCases, id: \.self) { mode in
                Button { controller.setMode(mode) } label: {
                    Image(systemName: Self.symbol(mode)).font(.system(size: 10.5))
                        .foregroundStyle(settings.mode == mode ? StudioTheme.textPrimary : StudioTheme.textTertiary)
                        .frame(width: 24, height: 18)
                        .background(settings.mode == mode ? AskTheme.pressFill : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(Self.title(mode))
                .accessibilityLabel(Self.title(mode))
                .accessibilityAddTraits(settings.mode == mode ? .isSelected : [])
            }
        }
        .padding(2)
        .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    static func symbol(_ mode: SystemMonitorWindowMode) -> String {
        switch mode {
        case .full: "list.bullet.rectangle"
        case .compact: "square.grid.2x2"
        case .mini: "capsule"
        }
    }

    static func title(_ mode: SystemMonitorWindowMode) -> String {
        L("system.monitor.window.mode.\(mode.rawValue)")
    }

    private func iconButton(_ symbol: String, help: String, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11.5))
                .foregroundStyle(active ? AskTheme.accent : StudioTheme.textSecondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var optionsMenu: some View {
        Menu {
            Toggle(L("system.monitor.window.pinned"), isOn: Binding(get: { settings.pinned },
                                                                    set: { _ in controller.togglePinned() }))
            Toggle(L("system.monitor.window.allSpaces"), isOn: Binding(get: { settings.allSpaces },
                                                                       set: { _ in controller.toggleAllSpaces() }))
            Toggle(L("system.monitor.window.restore"), isOn: Binding(get: { settings.restore },
                                                                     set: { _ in controller.toggleRestore() }))
            Divider()
            Section(L("system.monitor.window.metrics")) {
                ForEach(SystemMonitorMetric.allCases, id: \.self) { metric in
                    Toggle(SystemMonitorMetricDisplay.title(metric), isOn: Binding(
                        get: { settings.metrics.contains(metric) }, set: { _ in controller.toggleMetric(metric) }
                    ))
                    .disabled(settings.metrics == [metric])
                }
            }
            Picker(L("system.monitor.window.interval"), selection: Binding(get: { settings.interval },
                                                                           set: { controller.setInterval($0) })) {
                ForEach(SystemMonitorWindowSettings.intervals, id: \.self) { seconds in
                    Text(L("system.monitor.window.seconds", SystemMonitorFormat.interval(seconds))).tag(seconds)
                }
            }
            Picker(L("system.monitor.window.opacity"), selection: Binding(get: { settings.opacity },
                                                                          set: { controller.setOpacity($0) })) {
                ForEach(SystemMonitorWindowSettings.opacities, id: \.self) { opacity in
                    Text("\(Int((opacity * 100).rounded()))%").tag(opacity)
                }
            }
            Divider()
            Button(L("system.monitor.window.openInLauncher")) { controller.openInLauncher(nil) }
            Button(L("system.monitor.window.activityMonitor")) { controller.openActivityMonitor() }
            Button(L("system.monitor.window.close")) { controller.close() }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("system.monitor.window.options"))
        .accessibilityLabel(L("system.monitor.window.options"))
    }
}

/// Frosted glass behind the window's content, like a HUD.
struct SystemMonitorWindowBackground: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_: NSVisualEffectView, context _: Context) {}
}
