import SwiftUI

/// The world clock in the launcher: a toolbar, then the cities with aligned 24-hour bars,
/// under a conversion, meeting or timestamp card when the input asks for one.
struct WorldClockLauncherView: View {
    @ObservedObject var model: WorldClockLauncherModel
    var onEffect: (WorldClockEffect) -> Void
    var feedback: String?
    static let height: CGFloat = 448
    var viewportHeight: CGFloat = Self.height

    var body: some View {
        let rows = model.rows()
        VStack(spacing: 0) {
            Divider().overlay(AskTheme.separator)
            VStack(alignment: .leading, spacing: 6) {
                toolbar
                card
                if case let .unknown(text) = model.query {
                    WorldClockEmptyView(text: text)
                } else {
                    WorldClockRulerView(model: model)
                    list(rows)
                    WorldClockLegendView(meeting: model.meeting != nil)
                }
            }
            .padding(.horizontal, 16).padding(.top, 8)
            .frame(maxHeight: .infinity, alignment: .top)
            Divider().overlay(AskTheme.separator)
            Text(feedback ?? keyHint)
                .font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(height: 32)
        }
        .foregroundStyle(StudioTheme.textPrimary)
        .frame(height: viewportHeight, alignment: .top)
        .accessibilityIdentifier("worldclock.launcher")
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(L("worldclock.title")).font(.system(size: 17, weight: .bold))
            Text(subtitle).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
            Spacer()
            if model.query == .list {
                HStack(spacing: 6) {
                    Button { model.returnToNow() } label: {
                        HStack(spacing: 4) {
                            Text(L("worldclock.now"))
                            Text("⌘T").foregroundStyle(StudioTheme.textTertiary)
                        }.padding(.horizontal, 10).frame(height: 26)
                    }
                    .disabled(model.isAtNow)
                    .accessibilityIdentifier("worldclock.now")
                    Button { model.step(-1) } label: {
                        Image(systemName: "chevron.left").frame(width: 28, height: 26)
                    }
                    .help(L("worldclock.earlier")).accessibilityLabel(L("worldclock.earlier"))
                    .accessibilityIdentifier("worldclock.earlier")
                    Button { model.step(1) } label: {
                        Image(systemName: "chevron.right").frame(width: 28, height: 26)
                    }
                    .help(L("worldclock.later")).accessibilityLabel(L("worldclock.later"))
                    .accessibilityIdentifier("worldclock.later")
                }.font(.system(size: 11.5)).buttonStyle(CalendarToolbarButtonStyle())
            }
        }.frame(height: 30)
    }

    private var subtitle: String {
        let local = model.localCity, moment = model.moment, presenter = model.presenter
        let line = local.name(in: model.language) + " " + WorldClockFormat.day(moment, in: local.timeZone,
                                                                              locale: model.locale)
            + " " + presenter.time(moment, in: local.timeZone)
        switch model.query {
        case .list:
            return model.pinned == nil ? line + " · " + L("worldclock.cityCount", model.listCities.count)
                : line + " · " + WorldClockFormat.relative(moment, to: model.now)
        case let .search(cities): return L("worldclock.results", cities.count)
        default: return line
        }
    }

    @ViewBuilder private var card: some View {
        switch model.query {
        case let .convert(conversion):
            WorldClockConversionCard(model: model, conversion: conversion, onEffect: onEffect)
        case let .meeting(cities): WorldClockMeetingCard(model: model, cities: cities, onEffect: onEffect)
        case let .timestamp(date, kind):
            WorldClockTimestampCard(model: model, date: date, kind: kind, onEffect: onEffect)
        default: EmptyView()
        }
    }

    private func list(_ rows: [WorldClockRow]) -> some View {
        let selectable = model.query == .list || !model.searchResults.isEmpty
        let band: (start: Double, width: Double)? = model.chosenMeeting.map { slot in
            (start: model.timeline.fraction(of: slot.start), width: 3600.0 / 86400)
        }
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    if case .search = model.query {
                        rowView(model.presenter.row(model.localCity, isLocal: true, at: model.now,
                                                    timeline: model.timeline), index: nil, dimmed: true, band: nil)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, index: selectable ? index : nil, dimmed: false, band: band).id(row.id)
                    }
                }
            }
            .onChange(of: model.selection) { index in
                guard rows.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(rows[index].id) }
            }
        }
    }

    private func rowView(_ row: WorldClockRow, index: Int?, dimmed: Bool,
                         band: (start: Double, width: Double)?) -> some View {
        let selected = index != nil && index == model.selection
        let source: Bool = {
            guard case let .convert(conversion) = model.query else { return false }
            return row.city.id == (conversion.source ?? model.localCity).id
        }()
        return WorldClockRowView(
            row: row, selected: selected, dimmed: dimmed, source: source,
            added: dimmed || model.searchResults.isEmpty ? false : model.listContains(row.city),
            cursor: model.timeline.fraction(of: model.shownMoment), moved: model.shownMoment != model.now,
            band: band, actions: selected ? actions(for: row) : [],
            onSelect: { if let index { model.select(index) } },
            onBar: { fraction in if model.query == .list { model.moveTo(fraction: fraction) } },
            onAction: { onEffect(model.handle($0, inputEmpty: model.query == .list)) }
        )
    }

    private func actions(for row: WorldClockRow) -> [WorldClockRowView.Action] {
        if case .search = model.query, !model.listContains(row.city) {
            return [.init(key: .enter, title: L("worldclock.action.add"), symbol: "plus", shortcut: "↩", primary: true),
                    .init(key: .commandC, title: L("worldclock.action.copy"), symbol: "doc.on.doc", shortcut: "⌘C")]
        }
        var actions: [WorldClockRowView.Action] = [
            .init(key: .commandC, title: L("worldclock.action.copy"), symbol: "doc.on.doc", shortcut: "⌘C"),
            .init(key: .optionEnter, title: L("worldclock.action.insert"), symbol: "text.insert", shortcut: "⌥↩")
        ]
        if model.query == .list, !row.isLocal {
            actions.append(.init(key: .commandDelete, title: L("worldclock.action.remove"), symbol: "minus",
                                 shortcut: "⌘⌫"))
        }
        return actions
    }

    private var keyHint: String {
        switch model.query {
        case .list: L("worldclock.keys.list")
        case .search: L("worldclock.keys.search")
        case .convert: L("worldclock.keys.convert")
        case .meeting: L("worldclock.keys.meeting")
        case .timestamp: L("worldclock.keys.timestamp")
        case .unknown: L("worldclock.keys.unknown")
        }
    }
}

/// The local hours above the bars, with the shown moment tagged.
struct WorldClockRulerView: View {
    @ObservedObject var model: WorldClockLauncherModel

    var body: some View {
        HStack(spacing: 10) {
            Text(L("worldclock.column.city")).padding(.leading, 38)
            Spacer()
            Text(L("worldclock.column.time")).frame(width: 96, alignment: .trailing)
            ZStack(alignment: .topLeading) {
                let fraction = max(0, min(1, model.timeline.fraction(of: model.shownMoment)))
                // Hours under the time tag would show through it.
                let hours = [3, 6, 9, 12, 15, 18, 21].filter { abs(Double($0) / 24 - fraction) > 0.1 }
                ForEach(hours, id: \.self) { hour in
                    Text(String(hour)).font(.system(size: 10).monospacedDigit())
                        .frame(width: 24).offset(x: WorldClockRowView.barWidth * Double(hour) / 24 - 12, y: 4)
                }
                let moved = model.shownMoment != model.now
                Text(model.presenter.time(model.shownMoment, in: model.localZone()))
                    .font(.system(size: 10.5, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 6).frame(height: 17)
                    .background(moved ? Color.orange : AskTheme.accent, in: RoundedRectangle(cornerRadius: 5))
                    .fixedSize()
                    .frame(width: 70)
                    .offset(x: max(-12, min(WorldClockRowView.barWidth - 58,
                                            WorldClockRowView.barWidth * fraction - 35)),
                            y: 1)
            }.frame(width: WorldClockRowView.barWidth, height: 20, alignment: .topLeading)
        }
        .font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary)
        .padding(.horizontal, 10).frame(height: 22)
    }
}

struct WorldClockLegendView: View {
    var meeting: Bool

    var body: some View {
        HStack(spacing: 12) {
            item(WorldClockRowView.color(.work), L("worldclock.legend.work"))
            item(WorldClockRowView.color(.awake), L("worldclock.legend.awake"))
            item(WorldClockRowView.color(.night), L("worldclock.legend.night"))
            item(WorldClockRowView.color(.rest), L("worldclock.legend.weekend"))
            Spacer()
            if meeting { item(Color.green.opacity(0.25), L("worldclock.legend.meeting")) }
        }
        .font(.system(size: 10)).foregroundStyle(StudioTheme.textTertiary)
        .padding(.horizontal, 12).frame(height: 18)
    }

    private func item(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 8)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(AskTheme.separator))
            Text(title)
        }
    }
}

struct WorldClockEmptyView: View {
    var text: String

    var body: some View {
        VStack(spacing: 10) {
            Text(L("worldclock.empty", text)).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textTertiary)
            Text(L("worldclock.empty.examples")).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textSecondary)
        }.frame(maxWidth: .infinity).padding(.top, 40)
    }
}
