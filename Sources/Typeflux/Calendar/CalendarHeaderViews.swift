import SwiftUI

struct CalendarKeywordChip: View {
    @ObservedObject var model: CalendarLauncherModel

    var body: some View {
        AskKeywordChip(title: L("calendar.title"), symbol: "calendar", detail: detail, tint: AskTheme.accent)
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

/// The month toolbar's buttons: the whole frame is clickable and highlights on hover.
struct CalendarToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CalendarToolbarButton(configuration: configuration)
    }
}

private struct CalendarToolbarButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        configuration.label
            .foregroundStyle(isEnabled ? StudioTheme.textPrimary : StudioTheme.textTertiary)
            .background((hovering || configuration.isPressed) && isEnabled ? AskTheme.hoverFill : .clear, in: shape)
            .overlay(shape.stroke(AskTheme.separator))
            .contentShape(shape)
            .onHover { hovering = $0 }
    }
}
