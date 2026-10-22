import SwiftUI

/// The frame shared by the conversion, meeting and timestamp cards.
private struct WorldClockCard<Content: View>: View {
    var caption: String
    var trailing: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(caption)
                Spacer()
                Text(trailing)
            }.font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
            content
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(StudioTheme.textPrimary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AskTheme.separator))
    }
}

private struct WorldClockCardButton: View {
    var title: String
    var symbol: String
    var shortcut: String?
    var primary = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(title)
                if let shortcut {
                    Text(shortcut).foregroundStyle(primary ? Color.white.opacity(0.75) : StudioTheme.textTertiary)
                }
            }
            .font(.system(size: 11.5)).padding(.horizontal, 9).frame(height: 24)
            .foregroundStyle(primary ? Color.white : StudioTheme.textPrimary)
            .background(primary ? AskTheme.accent : AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(primary ? Color.clear : AskTheme.separator))
        }.buttonStyle(.plain).fixedSize()
    }
}

/// "纽约 09:00 = 北京 21:00".
struct WorldClockConversionCard: View {
    @ObservedObject var model: WorldClockLauncherModel
    var conversion: WorldClockConversion
    var onEffect: (WorldClockEffect) -> Void

    var body: some View {
        WorldClockCard(caption: L("worldclock.convert.title"),
                       trailing: WorldClockFormat.relative(conversion.date, to: model.now)) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                side(conversion.source ?? model.localCity)
                if let target = conversion.target {
                    Text("=").font(.system(size: 18)).foregroundStyle(StudioTheme.textTertiary)
                    side(target)
                }
            }
            if conversion.adjusted {
                Text(L("worldclock.convert.adjusted")).font(.system(size: 11)).foregroundStyle(Color.orange)
            }
            HStack(spacing: 6) {
                WorldClockCardButton(title: L("worldclock.action.copyResult"), symbol: "doc.on.doc", shortcut: "↩",
                                     primary: true) { onEffect(model.handle(.enter, inputEmpty: false)) }
                WorldClockCardButton(title: L("worldclock.action.insert"), symbol: "text.insert", shortcut: "⌥↩") {
                    onEffect(model.handle(.optionEnter, inputEmpty: false))
                }
            }.padding(.top, 4)
        }
    }

    private func side(_ city: WorldClockCity) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(city.name(in: model.language)).font(.system(size: 13, weight: .semibold))
            Text(model.presenter.time(conversion.date, in: city.timeZone))
                .font(.system(size: 24, weight: .bold).monospacedDigit())
            Text(WorldClockFormat.day(conversion.date, in: city.timeZone, locale: model.locale) + " · "
                + WorldClockAbbreviations.abbreviation(city.timeZone, at: conversion.date))
                .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
        }.lineLimit(1)
    }
}

/// When several places can meet: the overlap, or three times that disturb them least.
struct WorldClockMeetingCard: View {
    @ObservedObject var model: WorldClockLauncherModel
    var cities: [WorldClockCity]
    var onEffect: (WorldClockEffect) -> Void

    var body: some View {
        let result = model.meeting
        WorldClockCard(caption: L("worldclock.meeting.title"),
                       trailing: cities.map { $0.name(in: model.language) }.joined(separator: " · ")) {
            Text(headline(result)).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary).lineLimit(2)
            HStack(spacing: 8) {
                ForEach(Array((result?.suggestions ?? []).enumerated()), id: \.offset) { index, slot in
                    suggestion(slot, index: index)
                }
            }
            HStack(spacing: 6) {
                WorldClockCardButton(title: L("worldclock.action.copyTimes"), symbol: "doc.on.doc", shortcut: "↩",
                                     primary: true) { onEffect(model.handle(.enter, inputEmpty: false)) }
                WorldClockCardButton(title: L("worldclock.action.insert"), symbol: "text.insert", shortcut: "⌥↩") {
                    onEffect(model.handle(.optionEnter, inputEmpty: false))
                }
                Spacer()
                Text(L("worldclock.meeting.keys")).font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
            }.padding(.top, 2)
        }
    }

    private func headline(_ result: MeetingSlotFinder.Result?) -> String {
        guard let result else { return "" }
        if let overlap = result.overlap {
            let local = model.localCity, presenter = model.presenter
            return L("worldclock.meeting.overlap", cities.count, local.name(in: model.language)
                + " " + WorldClockFormat.day(overlap.lowerBound, in: local.timeZone, locale: model.locale)
                + " " + presenter.time(overlap.lowerBound, in: local.timeZone)
                + "–" + presenter.time(overlap.upperBound, in: local.timeZone))
        }
        let start = model.preferences.workStart, end = model.preferences.workEnd
        return L("worldclock.meeting.none", cities.count,
                 String(format: "%02d:%02d–%02d:%02d", start / 60, start % 60, end / 60, end % 60))
    }

    private func suggestion(_ slot: MeetingSlotFinder.Slot, index: Int) -> some View {
        let chosen = index == model.suggestion
        let start = chosen ? model.chosenMeeting?.start ?? slot.start : slot.start
        let presenter = model.presenter
        let times = cities.map { presenter.time(start, in: $0.timeZone) }.joined(separator: " / ")
        let notes = cities.map { city -> String in
            let hour = WorldClockFormat.calendar(city.timeZone).component(.hour, from: start) * 60
            let suffix = hour < model.preferences.workStart ? L("worldclock.meeting.early")
                : hour >= model.preferences.workEnd ? L("worldclock.meeting.late") : ""
            return city.name(in: model.language) + suffix
        }.joined(separator: " · ")
        return Button { model.chooseSuggestion(index) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(times).font(.system(size: 12, weight: .semibold).monospacedDigit()).lineLimit(1)
                Text(notes + " · " + WorldClockFormat.dayWord(
                    delta: WorldClockFormat.dayDelta(start, in: model.localZone(), from: model.now,
                                                     in: model.localZone()),
                    date: start, in: model.localZone(), locale: model.locale
                )).font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
            }
            .padding(.horizontal, 9).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
            .background(chosen ? Color.green.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(chosen ? Color.green : AskTheme.separator,
                                                              lineWidth: chosen ? 1.5 : 1))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("worldclock.meeting.\(index)")
    }
}

/// A Unix timestamp or ISO time in every form worth copying.
struct WorldClockTimestampCard: View {
    private struct Line {
        var label: String
        var value: String
        var code: Bool
    }

    @ObservedObject var model: WorldClockLauncherModel
    var date: Date
    var kind: WorldClockTimestampKind
    var onEffect: (WorldClockEffect) -> Void

    var body: some View {
        let utc = TimeZone(identifier: "UTC") ?? .gmt
        let local = model.localCity
        let seconds = Int64(floor(date.timeIntervalSince1970))
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let rows: [Line] = [
            Line(label: L("worldclock.timestamp.seconds"), value: String(seconds), code: true),
            Line(label: L("worldclock.timestamp.milliseconds"), value: String(milliseconds), code: true),
            Line(label: "ISO 8601", value: WorldClockFormat.iso(date, in: utc), code: true),
            Line(label: local.name(in: model.language), value: model.presenter.line(local, at: date, format: .full)
                + " · " + WorldClockFormat.relative(date, to: model.now), code: false)
        ]
        WorldClockCard(caption: L("worldclock.timestamp.kind.\(kind)"),
                       trailing: "UTC " + model.presenter.time(date, in: utc)) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 12) {
                    Text(row.label).foregroundStyle(StudioTheme.textTertiary).frame(width: 92, alignment: .leading)
                    Text(row.value).font(row.code ? .system(size: 12, design: .monospaced) : .system(size: 12))
                        .textSelection(.enabled).lineLimit(1)
                    Spacer()
                    WorldClockCardButton(title: L("worldclock.action.copy"), symbol: "doc.on.doc", shortcut: nil) {
                        onEffect(.copy(row.code ? row.value : model.presenter.line(local, at: date, format: .full)))
                    }
                }.font(.system(size: 12)).frame(height: 24)
            }
        }
    }
}
