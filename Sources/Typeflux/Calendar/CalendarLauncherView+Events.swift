import SwiftUI

extension CalendarLauncherView {
    @ViewBuilder var agenda: some View {
        if model.access != .allowed {
            permission
        } else {
            HStack { Text(L("calendar.agenda")); Spacer(); Text(String(model.dayEvents.count)) }
                .font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary)
            if model.loading {
                ProgressView().controlSize(.small)
            } else if model.dayEvents.isEmpty {
                Text(L("calendar.empty")).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                Button(L("calendar.new")) { onEffect(.open(model.selected, event: nil, join: false)) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(.blue)
            } else {
                ScrollViewReader { proxy in
                    ScrollView { LazyVStack(spacing: 6) { ForEach(model.dayEvents) { eventRow($0) } } }
                        .onChange(of: model.selectedEventID) { id in
                            guard let id else { return }
                            proxy.scrollTo(id, anchor: .center)
                        }
                }
            }
        }
    }

    var permission: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "calendar.badge.clock").font(.system(size: 22)).foregroundStyle(AskTheme.accent)
            Text(L("calendar.permission.title")).font(.system(size: 13, weight: .semibold))
            Text(L("calendar.permission.body")).font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
            Button(L(model.access == .denied ? "calendar.permission.settings" : "calendar.permission.allow")) {
                if model.access == .denied {
                    onEffect(.settings)
                } else {
                    Task { await model.requestAccess() }
                }
            }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(.blue)
                .disabled(model.requesting).accessibilityIdentifier("calendar.allow")
            if let error = model.error {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange)
            }
            Button(L("calendar.permission.hide"), action: onHideEvents).buttonStyle(.plain)
                .font(.system(size: 10)).foregroundStyle(StudioTheme.textTertiary)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 10))
    }

    // One row includes its selected-state actions.
    // swiftlint:disable:next function_body_length
    func eventRow(_ event: CalendarEvent) -> some View {
        let chosen = model.eventFocus && event.id == model.selectedEventID
        return VStack(alignment: .leading, spacing: 6) {
            Button { model.selectEvent(event.id) } label: {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 1).fill(tint(event.calendar.color)).frame(width: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.allDay ? L("calendar.allDay") : model.dates.format(
                            event.start,
                            "HHmm",
                            locale: model.locale
                        ))
                        if !event.allDay {
                            Text(model.dates.format(event.end, "HHmm", locale: model.locale))
                        }
                    }.font(.system(size: 10)).foregroundStyle(StudioTheme.textTertiary).frame(
                        width: 40,
                        alignment: .leading
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        eventTitle(event.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                        if !event.allDay, event.end > model.now() {
                            Text(event.start <= model.now() ? L(
                                "calendar.ongoing",
                                Int(ceil(event.end.timeIntervalSince(model.now()) / 60))
                            )
                                : model.untilEvent(event))
                                .font(.system(size: 10)).foregroundStyle(event.start <= model.now() ? .green : .blue)
                        }
                        if !event.location.isEmpty {
                            Label(event.location, systemImage: event.meeting == nil ? "mappin" : "video")
                                .font(.system(size: 10)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(6).fixedSize(horizontal: false, vertical: true)
            }.buttonStyle(.plain)
            if chosen {
                if let count = event.attendees {
                    Text(L("calendar.attendees", count)).font(.system(size: 10)).padding(.horizontal, 9)
                }
                if let organizer = event.organizer {
                    Text(L("calendar.organizer", organizer)).font(.system(size: 10)).padding(.horizontal, 9)
                }
                if !event.notes
                    .isEmpty {
                    Text(event.notes).font(.system(size: 10)).lineLimit(2).padding(.horizontal, 9)
                }
                HStack {
                    Button(L(event.meeting == nil ? "calendar.open" : "calendar.join")) {
                        onEffect(.open(event.start, event: event, join: event.meeting != nil))
                    }
                    if event.meeting != nil {
                        Button { onEffect(.open(event.start, event: event, join: false)) } label: {
                            Image(systemName: "calendar")
                        }
                        .accessibilityLabel(L("calendar.open"))
                    }
                    Button { onEffect(.copy(event.copied(
                        dates: model.dates,
                        preferences: model.preferences,
                        locale: model.locale
                    ))) } label: {
                        Image(systemName: "doc.on.doc")
                    }.accessibilityLabel(L("calendar.copy"))
                }.buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(.blue).padding(.horizontal, 9).padding(
                    .bottom,
                    8
                )
            }
        }.background(chosen ? Color.blue.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .opacity(event.end <= model.now() ? 0.5 : 1).id(event.id)
    }

    private func eventTitle(_ title: String) -> Text {
        guard case let .search(query) = model.query,
              let range = title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
        else { return Text(title) }
        return Text(String(title[..<range.lowerBound])) + Text(String(title[range])).foregroundColor(.blue)
            + Text(String(title[range.upperBound...]))
    }
}
