import AppKit
import SwiftUI

extension RingActionType {
    /// The tile colour of the type's card.
    var tint: Color {
        switch self {
        case .feature: Color(red: 0.36, green: 0.36, blue: 0.84)
        case .keyword: Color(red: 0.49, green: 0.23, blue: 0.93)
        case .system: Color(red: 0.28, green: 0.33, blue: 0.41)
        case .app: Color(red: 0.05, green: 0.65, blue: 0.91)
        case .keys: Color(red: 0.98, green: 0.45, blue: 0.09)
        case .shortcut: Color(red: 0.93, green: 0.28, blue: 0.6)
        case .url: Color(red: 0.09, green: 0.64, blue: 0.29)
        case .folder: Color(red: 0.15, green: 0.39, blue: 0.92)
        }
    }
}

/// Recommended items as wrapping chips.
struct RingLibraryChips: View {
    let items: [RingLibraryItem]
    let highlighted: Int?
    let onHover: (Int?, RingLibraryItem) -> Void
    let onPick: (RingLibraryItem) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Button { onPick(item) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.symbol).font(.system(size: 11, weight: .medium))
                            .frame(width: 20, height: 20).background(Circle().fill(TFColors.control))
                        Text(item.title).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(highlighted == index ? TFColors.accent : TFColors.textPrimary)
                    .padding(.leading, 4).padding(.trailing, 10).frame(height: 28)
                    .background(Capsule().fill(TFColors.control.opacity(0.6)))
                    .overlay(Capsule().strokeBorder(highlighted == index ? TFColors.accent : TFColors.border,
                                                    lineWidth: highlighted == index ? 1 : TFMetrics.borderWidth))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { inside in onHover(inside ? index : nil, item) }
                .accessibilityLabel(item.title)
                .accessibilityHint(item.subtitle)
            }
        }
    }
}

/// A type in the library's grid.
struct RingTypeCard: View {
    let type: RingActionType
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                TFIconTile(systemImage: type.symbol, tint: type.tint, size: 26, style: .filled)
                Text(type.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(TFColors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(RingCardButtonStyle())
        .accessibilityLabel(type.title)
        .accessibilityIdentifier("ring.library.type.\(type.rawValue)")
    }
}

private struct RingCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration)
    }

    private struct CardBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            configuration.label
                .background(shape.fill(TFColors.control.opacity(0.55)))
                .background(shape.fill(hovering ? TFColors.hoverOverlay : .clear))
                .overlay(shape.strokeBorder(hovering ? TFColors.accent.opacity(0.5) : TFColors.border,
                                            lineWidth: TFMetrics.borderWidth))
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .onHover { hovering = $0 }
        }
    }
}

/// An item in a library list.
struct RingLibraryRow: View {
    let item: RingLibraryItem
    let query: String
    let isHighlighted: Bool
    let isAdded: Bool
    let onPick: () -> Void

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 10) {
                RingIconTile(action: item.action(id: RingStudioSlot.placeholderID), size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(TFSearchMatcher.highlighted(item.title, query: query)).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TFColors.textPrimary).lineLimit(1)
                    if item.subtitleIdentifiesTarget, !item.subtitle.isEmpty {
                        Text(TFSearchMatcher.highlighted(item.subtitle, query: query)).font(.system(size: 11.5))
                            .foregroundStyle(TFColors.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if isAdded {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TFColors.textTertiary)
                        .accessibilityLabel(L("ring.library.added"))
                }
            }
            .padding(.horizontal, 8).frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(RingRowButtonStyle(isHighlighted: isHighlighted))
        .accessibilityLabel(item.title)
        .accessibilityHint(item.subtitle)
        .accessibilityIdentifier("ring.library.item.\(item.id)")
    }
}

/// Asks for a folder with the standard open panel.
enum RingFolderPicker {
    @MainActor
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// Records a key combination to send; picks it as soon as it is pressed.
struct RingKeysRecorderCard: View {
    let onRecord: (HotkeyBinding) -> Void
    @StateObject private var recorder = HotkeyRecorder()

    var body: some View {
        Button {
            if recorder.isRecording {
                recorder.stop()
            } else {
                recorder.start(onRecorded: onRecord)
            }
        } label: {
            Text(L(recorder.isRecording ? "ring.library.recording" : "ring.library.recordHint"))
                .foregroundStyle(recorder.isRecording ? TFColors.accent : TFColors.textSecondary)
                .font(.system(size: 12.5))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(TFColors.control))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(recorder.isRecording ? TFColors.accent : TFColors.border,
                                  lineWidth: recorder.isRecording ? 1 : TFMetrics.borderWidth))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDisappear { recorder.stop() }
        .accessibilityIdentifier("ring.library.recordKeys")
    }
}

/// A web address to open, checked as it is typed.
struct RingURLForm: View {
    @Binding var text: String
    let pickTitle: String
    let onChange: (RingLibraryItem?) -> Void
    let onPick: (RingLibraryItem) -> Void

    var body: some View {
        let typed = TFSearchMatcher.normalized(text)
        let item = RingActionLibrary.urlItem(typed)
        let invalid = !typed.isEmpty && item == nil
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("https://", text: $text)
                    .textFieldStyle(TFTextFieldStyle(monospaced: true, isError: invalid))
                    .onSubmit { item.map(onPick) }
                    .onChange(of: text) { value in onChange(RingActionLibrary.urlItem(value)) }
                    .accessibilityIdentifier("ring.library.url")
                TFButton(title: pickTitle, kind: .primary) { item.map(onPick) }
                    .disabled(item == nil)
            }
            if invalid {
                TFFieldMessage(text: L("ring.editor.urlInvalid"))
            }
        }
    }
}
