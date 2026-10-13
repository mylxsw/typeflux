import SwiftUI

struct AskCommandRow: View {
    let match: AskCommandMatcher.Match
    var highlighted: Bool
    @Environment(\.interfaceStyle) private var style

    private var command: AskCommand { match.command }
    private var selected: Bool { highlighted && command.enabled }
    private var label: Color { TypefluxSpotlightRow.labelColor(selected: selected) }
    private var secondaryLabel: Color { TypefluxSpotlightRow.labelColor(selected: selected, secondary: true) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: command.symbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(selected ? label : TypefluxColor.accent.color)
                .frame(width: 28, height: 28)
                .background(
                    highlighted ? TypefluxColor.accent.color.opacity(0.16) : TypefluxColor.label.color.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: TypefluxRadius.navigationIcon.value(for: style))
                )
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    name
                    if !command.title.isEmpty {
                        Text(command.title).font(.callout).foregroundStyle(secondaryLabel).lineLimit(1)
                    }
                    if let badge = command.badge {
                        Text(badge).font(.footnote.weight(.medium))
                            .foregroundStyle(secondaryLabel)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(TypefluxColor.label.color.opacity(0.06), in: RoundedRectangle(
                                cornerRadius: TypefluxRadius.menuHighlight.value(for: style)
                            ))
                    }
                }
                if let detail = command.detail, !detail.isEmpty {
                    Text(detail).font(.subheadline).foregroundStyle(secondaryLabel).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing.font(.subheadline).foregroundStyle(secondaryLabel)
        }
        .padding(.horizontal, 8)
        .frame(height: AskCommandPaletteView.rowHeight)
        .modifier(TypefluxSpotlightRow(selected: selected))
        .opacity(command.enabled ? 1 : 0.45)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    /// The name with the typed letters underlined; submenu rows have no slash.
    private var name: some View {
        var text = AttributedString(command.plain ? command.name : "/" + command.name)
        let offset = command.plain ? 0 : 1
        let characters = Array(text.characters.indices)
        for index in match.highlights where index + offset < characters.count {
            let start = characters[index + offset]
            let end = text.characters.index(after: start)
            text[start ..< end].underlineStyle = .single
            text[start ..< end].foregroundColor = selected ? label : TypefluxColor.accent.color
        }
        return Text(text)
            .font(.system(.body, design: command.plain ? .default : .monospaced, weight: .semibold))
            .foregroundStyle(label)
            .lineLimit(1)
    }

    @ViewBuilder private var trailing: some View {
        if let reason = command.disabledReason {
            Text(reason).lineLimit(1)
        } else if command.selected {
            Image(systemName: "checkmark").foregroundStyle(selected ? label : TypefluxColor.accent.color)
        } else {
            switch command.kind {
            case let .toggle(isOn):
                Text(L(isOn ? "ask.command.on" : "ask.command.off"))
                    .foregroundStyle(isOn && !selected ? TypefluxColor.accent.color : secondaryLabel)
            case .submenu:
                HStack(spacing: 4) {
                    if let value = command.trailing { Text(value).lineLimit(1) }
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                }
            case .argument:
                Text((command.trailing ?? "") + " ⇥").lineLimit(1)
            default:
                if let value = command.trailing { AskKeyHint(text: value) }
            }
        }
    }
}
