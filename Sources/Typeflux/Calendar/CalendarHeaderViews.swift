import SwiftUI

struct CalendarKeywordChip: View {
    @ObservedObject var model: CalendarLauncherModel

    var body: some View {
        AskKeywordChip(title: L("calendar.title"), symbol: "calendar", detail: detail, tint: .red)
    }

    private var detail: String? {
        switch model.query {
        case .range: L("calendar.interval")
        case .search: L("calendar.searchTitle")
        case .year: model.dates.format(model.selected, "y", locale: model.locale)
        default: nil
        }
    }
}

struct CalendarHeaderAction: View {
    @ObservedObject var model: CalendarLauncherModel
    var onToday: () -> Void

    var body: some View {
        if model.query != .date(model.today) {
            Button(L("calendar.today") + " ⌘T", action: onToday)
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(AskTheme.separator))
                .accessibilityLabel(L("calendar.today"))
        }
    }
}
