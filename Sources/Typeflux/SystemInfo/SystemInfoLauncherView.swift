// swiftlint:disable file_length
import SwiftUI

/// `sys` inside the launcher: sections on the left; the overview, a section's rows or
/// what the editor's text matches on the right. Its height is fixed, so the launcher
/// does not jump between sections.
struct SystemInfoLauncherView: View {
    @ObservedObject var store: SystemInfoStore
    @ObservedObject var model: SystemInfoLauncherModel
    /// What the editor holds after the keyword: words to find rows by.
    var filter: String
    var feedback: String? = nil
    var onEffect: (SystemInfoEffect) -> Void

    @State private var hovered: String?

    static let height: CGFloat = 520
    static let sidebarWidth: CGFloat = 170
    static let labelWidth: CGFloat = 132

    private var searching: Bool {
        !filter.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(AskTheme.separator).frame(height: 1).padding(.horizontal, 12)
            HStack(spacing: 0) {
                sidebar.frame(width: Self.sidebarWidth)
                Rectangle().fill(AskTheme.separator).frame(width: 1)
                pane.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Rectangle().fill(AskTheme.separator).frame(height: 1).padding(.horizontal, 12)
            footer
        }
        .frame(height: Self.height, alignment: .top)
        .onAppear { store.refresh() }
        .onDisappear {
            // The next time starts as it first did, hidden values hidden again.
            model.reset()
        }
        .accessibilityIdentifier("system.info.launcher")
    }

    // MARK: Sidebar

    private var sidebar: some View {
        let sections = store.snapshot?.sections ?? SystemInfoSection.allCases
        let counts = searching ? Dictionary(grouping: model.rows(store.snapshot, filter: filter), by: \.section)
            .mapValues(\.count) : [:]
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(sections.enumerated()), id: \.element) { index, section in
                let count = counts[section] ?? 0
                Button {
                    if searching {
                        onEffect(.showSection(section))
                    } else {
                        model.show(section)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: section.symbol).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(SystemInfoTheme.color(section), in: RoundedRectangle(cornerRadius: 5))
                        Text(section.title).font(.system(size: 12.5, weight: !searching && model.section == section
                                ? .semibold : .regular))
                            .foregroundStyle(StudioTheme.textPrimary).lineLimit(1)
                        Spacer(minLength: 4)
                        if searching {
                            if count > 0 {
                                Text(String(count)).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 16)
                                    .background(AskTheme.accent, in: Capsule())
                            }
                        } else {
                            Text("⌘\(index + 1)").font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(StudioTheme.textTertiary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(!searching && model.section == section ? AskTheme.accentSoft : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                    .opacity(searching && section != .overview && count == 0 ? 0.4 : 1)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(!searching && model.section == section ? .isSelected : [])
                .accessibilityIdentifier("system.info.section.\(section.rawValue)")
            }
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Circle().fill(store.isReading ? StudioTheme.warning : StudioTheme.success).frame(width: 6, height: 6)
                Text(L(store.isReading ? "system.info.reading" : "system.info.ready"))
            }
            .font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
            .padding(.horizontal, 8)
            Button { onEffect(.openApp) } label: {
                Label(L("system.info.openApp"), systemImage: "arrow.up.forward.app")
                    .font(.system(size: 11)).foregroundStyle(AskTheme.accentText).lineLimit(1)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8).padding(.bottom, 4)
            .accessibilityIdentifier("system.info.openApp")
        }
        .padding(.horizontal, 6).padding(.vertical, 8)
    }

    // MARK: Content

    @ViewBuilder
    private var pane: some View {
        if let snapshot = store.snapshot {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if searching {
                            results(snapshot)
                        } else if model.section == .overview {
                            overview(snapshot)
                        } else {
                            section(model.section, snapshot: snapshot)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
                .onChange(of: model.selection) { id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
                }
            }
        } else {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("system.info.reading")).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func overview(_ snapshot: SystemInfoSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Image(systemName: snapshot.hasBattery ? "laptopcomputer" : "desktopcomputer")
                    .font(.system(size: 34, weight: .light)).foregroundStyle(StudioTheme.textSecondary)
                    .frame(width: 60)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.title).font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary).lineLimit(1).minimumScaleFactor(0.75)
                    Text(snapshot.subtitle).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                        .lineLimit(1)
                    Text(snapshot.system).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                AskHeaderIconButton(symbol: "doc.on.doc", label: L("system.info.copySummary")) {
                    onEffect(.copy(SystemInfoReport.summary(snapshot)))
                }
                .accessibilityIdentifier("system.info.copySummary")
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(AskTheme.hoverFill.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AskTheme.separator) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(snapshot.cards, id: \.section) { item in
                    cardView(item, number: (snapshot.sections.firstIndex(of: item.section) ?? 0) + 1)
                }
            }
        }
    }

    private func cardView(_ card: SystemInfoCard, number: Int) -> some View {
        Button { model.show(card.section) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: card.section.symbol).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SystemInfoTheme.color(card.section))
                    Text(card.section.title).font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(StudioTheme.textSecondary).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("⌘\(number)").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(StudioTheme.textTertiary)
                }
                Text(card.value).font(.system(size: 15, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.75).truncationMode(.tail)
                Text(card.detail).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let fraction = card.fraction {
                    SystemInfoBar(fraction: fraction, color: SystemInfoTheme.color(card.section)).padding(.top, 3)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
            .background(AskTheme.hoverFill.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AskTheme.separator) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(card.section.title + " " + card.value + " " + card.detail)
        .accessibilityIdentifier("system.info.card.\(card.section.rawValue)")
    }

    private func section(_ section: SystemInfoSection, snapshot: SystemInfoSnapshot) -> some View {
        let fields = snapshot.fields(in: section)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: section.symbol).foregroundStyle(SystemInfoTheme.color(section))
                Text(section.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
                Text(L("system.info.count", fields.count)).font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textTertiary)
            }
            .padding(.bottom, 2)
            ForEach(Self.groups(fields), id: \.title) { group in
                Text(group.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioTheme.textTertiary)
                    .padding(.top, 6).padding(.leading, 2)
                rows(group.fields, showsGroup: false)
            }
        }
    }

    @ViewBuilder
    private func results(_ snapshot: SystemInfoSnapshot) -> some View {
        let fields = model.rows(snapshot, filter: filter)
        if fields.isEmpty {
            VStack(spacing: 6) {
                Text(L("system.info.search.none", filter.trimmingCharacters(in: .whitespaces)))
                    .font(.system(size: 13.5)).foregroundStyle(StudioTheme.textSecondary)
                Text(L("system.info.search.tip")).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
            }
            .frame(maxWidth: .infinity).padding(.top, 70)
        } else {
            Text(L("system.info.search.count", fields.count)).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
            ForEach(SystemInfoSection.allCases.filter { section in fields.contains { $0.section == section } },
                    id: \.self) { section in
                Label(section.title, systemImage: section.symbol).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StudioTheme.textTertiary).padding(.top, 6).padding(.leading, 2)
                rows(fields.filter { $0.section == section }, showsGroup: true)
            }
        }
    }
}

// MARK: Rows and footer

extension SystemInfoLauncherView {
    private func rows(_ fields: [SystemInfoField], showsGroup: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                if index > 0 {
                    Rectangle().fill(AskTheme.separator).frame(height: 1)
                }
                row(field, showsGroup: showsGroup).id(field.id)
            }
        }
        .background(AskTheme.hoverFill.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AskTheme.separator) }
    }

    private func row(_ field: SystemInfoField, showsGroup: Bool) -> some View {
        let selected = model.selection == field.id
        let visible = model.isRevealed(field)
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(field.label).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
                if showsGroup {
                    Text(field.group).font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary.opacity(0.8))
                        .lineLimit(1)
                }
            }
            .frame(width: Self.labelWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                value(field, visible: visible)
                if let fraction = field.fraction {
                    SystemInfoBar(fraction: fraction, color: SystemInfoTheme.color(field.section)).frame(maxWidth: 260)
                }
            }
            Spacer(minLength: 4)
            if selected || hovered == field.id {
                if field.sensitive {
                    let help = L(visible ? "system.info.hide" : "system.info.show")
                    iconButton(visible ? "eye.slash" : "eye", help: help) {
                        model.toggleReveal(field.id)
                    }
                }
                iconButton("doc.on.doc", help: L("system.info.copy")) {
                    model.select(field.id)
                    onEffect(.copy(field.value))
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(minHeight: 34)
        .background(selected ? AskTheme.accentSoft : Color.clear)
        .overlay(alignment: .leading) {
            if selected {
                Rectangle().fill(AskTheme.accent).frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? field.id : hovered == field.id ? nil : hovered }
        .onTapGesture(count: 2) {
            model.select(field.id)
            onEffect(.copy(field.value))
        }
        .onTapGesture { model.select(field.id) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(field.label + ", " + (visible ? field.text : L("system.info.hidden")))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("system.info.row.\(field.id)")
    }

    @ViewBuilder
    private func value(_ field: SystemInfoField, visible: Bool) -> some View {
        if !visible {
            Text("••••••••••").font(.system(size: 12.5)).foregroundStyle(StudioTheme.textTertiary)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let badge = field.badge {
                    Text(field.value).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SystemInfoTheme.color(badge))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(SystemInfoTheme.fill(badge),
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    Text(field.value).font(.system(size: 12.5)).monospacedDigit()
                        .foregroundStyle(StudioTheme.textPrimary).lineLimit(2)
                }
                if let detail = field.detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
                }
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Text(feedback ?? L(searching ? "system.info.keys.search" : "system.info.keys.browse",
                               store.snapshot?.sections.count ?? SystemInfoSection.allCases.count))
            Spacer(minLength: 8)
            Button {
                if let snapshot = store.snapshot {
                    onEffect(.copyReport(SystemInfoReport.markdown(snapshot)))
                }
            } label: {
                Text(L("system.info.copyReport"))
            }
            .buttonStyle(.plain)
            .disabled(store.snapshot == nil)
            .accessibilityIdentifier("system.info.copyReport")
        }
        .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
        .lineLimit(1)
        .padding(.horizontal, 14).frame(height: 30)
    }

    /// Fields by group, in the order the groups first appear.
    static func groups(_ fields: [SystemInfoField]) -> [(title: String, fields: [SystemInfoField])] {
        var groups: [(title: String, fields: [SystemInfoField])] = []
        for field in fields {
            if let index = groups.firstIndex(where: { $0.title == field.group }) {
                groups[index].fields.append(field)
            } else {
                groups.append((field.group, [field]))
            }
        }
        return groups
    }
}

/// A thin capacity or charge bar.
struct SystemInfoBar: View {
    var fraction: Double
    var color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(AskTheme.hoverFill)
                Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

/// The colors `sys` draws sections and badges with.
enum SystemInfoTheme {
    static func color(_ section: SystemInfoSection) -> Color {
        switch section {
        case .overview: AskTheme.accent
        case .processor: SystemMonitorTheme.cpu
        case .memory: SystemMonitorTheme.memory
        case .storage: SystemMonitorTheme.disk
        case .display: Color(nsColor: .systemPink)
        case .network: SystemMonitorTheme.network
        case .battery: Color(nsColor: .systemOrange)
        case .system: Color(nsColor: .systemGray)
        }
    }

    static func color(_ badge: SystemInfoBadge) -> Color {
        switch badge {
        case .good: StudioTheme.success
        case .warning: StudioTheme.warning
        case .off: StudioTheme.textTertiary
        }
    }

    static func fill(_ badge: SystemInfoBadge) -> Color {
        switch badge {
        case .good: AskTheme.successSoft
        case .warning: AskTheme.warningSoft
        case .off: AskTheme.hoverFill
        }
    }
}

/// The keyword's row before Return: one line about this Mac.
struct SystemInfoHintSummary: View {
    @ObservedObject var store: SystemInfoStore

    var body: some View {
        Text(store.snapshot.map(SystemInfoReport.summary) ?? L("system.info.reading"))
            .font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
            .onAppear { store.refresh() }
    }
}
