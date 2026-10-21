import SwiftUI

/// One background task: what it is, how far it got, and what can be done with it.
struct BackgroundActivityRowView: View {
    static let height: CGFloat = 48

    let activity: BackgroundActivity
    /// In the menu, buttons appear on hover unless the task needs the user.
    var revealsActionsOnHover = true
    let perform: (BackgroundActivity.Action) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(activity.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if activity.showsProgress {
                    progress
                }
                Text(activity.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(detailColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            actions
                .opacity(actionsVisible ? 1 : 0)
                .allowsHitTesting(actionsVisible)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering && activity.route != nil ? Color.primary.opacity(0.07) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if activity.route != nil {
                perform(.open)
            }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(activity.title), \(activity.detail)"))
        .accessibilityIdentifier("activity.row.\(activity.id)")
    }

    private var actionsVisible: Bool {
        !revealsActionsOnHover || hovering || activity.needsUser
    }

    private var icon: some View {
        let (symbol, color) = iconStyle
        return Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(0.16)))
    }

    private var iconStyle: (String, Color) {
        switch activity.state {
        case .attention: return ("hand.raised.fill", .orange)
        case .failed: return ("exclamationmark", .red)
        default: break
        }
        switch activity.kind {
        case .agent: return ("sparkles", StudioTheme.aiIcon)
        case .download: return ("arrow.down", .blue)
        case .index: return ("doc.text.magnifyingglass", .indigo)
        }
    }

    private var progress: some View {
        Group {
            if let value = activity.progress {
                ProgressView(value: value)
            } else {
                ProgressView()
            }
        }
        .progressViewStyle(.linear)
        .controlSize(.small)
        .tint(activity.state == .running ? .accentColor : .secondary)
        .frame(height: 4)
    }

    private var detailColor: Color {
        switch activity.state {
        case .attention: .orange
        case .failed: .red
        default: .secondary
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            ForEach(activity.actions, id: \.self) { action in
                button(action)
            }
        }
    }

    @ViewBuilder private func button(_ action: BackgroundActivity.Action) -> some View {
        if let title = textTitle(action) {
            Button { perform(action) } label: {
                Text(title).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 8).frame(height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(activity.state == .attention ? Color.white : Color.primary)
            .background(Capsule().fill(activity.state == .attention ? Color.orange : Color.primary.opacity(0.1)))
            .accessibilityIdentifier("activity.action.\(action.rawValue)")
        } else {
            Button { perform(action) } label: {
                Image(systemName: Self.symbol(action))
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help(Self.label(action))
            .accessibilityLabel(Text(Self.label(action)))
            .accessibilityIdentifier("activity.action.\(action.rawValue)")
        }
    }

    /// Actions shown as words rather than symbols.
    private func textTitle(_ action: BackgroundActivity.Action) -> String? {
        switch action {
        case .open where activity.state == .attention: L("activity.action.review")
        case .retry: L("activity.action.retry")
        default: nil
        }
    }

    static func symbol(_ action: BackgroundActivity.Action) -> String {
        switch action {
        case .open: "arrow.up.right"
        case .stop: "stop.fill"
        case .pause: "pause.fill"
        case .resume: "play.fill"
        case .cancel, .dismiss: "xmark"
        case .retry: "arrow.clockwise"
        }
    }

    static func label(_ action: BackgroundActivity.Action) -> String {
        L("activity.action.\(action.rawValue)")
    }
}
