import SwiftUI

/// Row content leaves selection, hover and focus drawing to List.
struct AskNotesListRow: View {
    let note: AskNote
    @ObservedObject var model: AskNotesViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: note.pinned ? "pin.fill" : note.source.symbol)
                .foregroundStyle(TypefluxColor.accent.color)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(note.title.isEmpty ? L("ask.notes.untitled") : note.title)
                        .font(.headline).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Self.shortDate(listDate)).font(.caption)
                        .foregroundStyle(TypefluxColor.secondaryLabel.color)
                }
                if !note.excerpt.isEmpty {
                    Text(note.excerpt).font(.callout).lineLimit(2)
                        .foregroundStyle(TypefluxColor.secondaryLabel.color)
                }
                if !note.tags.isEmpty {
                    Text(note.tags.prefix(3).map { "#" + $0 }.joined(separator: " "))
                        .font(.caption).foregroundStyle(TypefluxColor.secondaryLabel.color).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu { contextMenu }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ask.notes.row")
    }

    private var listDate: Date {
        if note.isDeleted { return note.deletedAt ?? note.updatedAt }
        return model.sort == .created ? note.createdAt : note.updatedAt
    }

    @ViewBuilder private var contextMenu: some View {
        if note.isDeleted {
            Button(L("ask.notes.trash.restore")) { act(model.restoreFromTrash) }
            Button(L("ask.notes.trash.deleteForever"), role: .destructive) { act(model.deleteForever) }
        } else {
            Button(L(note.pinned ? "ask.notes.unpin" : "ask.notes.pin")) { act(model.togglePin) }
            Button(L("ask.plugin.action.copy")) { act(model.copySelected) }
            Button(L("ask.plugin.action.openInWindow")) { act(model.openSelectedInWindow) }
            Divider()
            Button(L("ask.notes.delete"), role: .destructive) { act(model.deleteSelected) }
        }
    }

    private func act(_ action: () -> Void) {
        model.select(note.id)
        // A failed save leaves the previous note selected; never act on that note instead.
        guard model.selectedID == note.id else { return }
        action()
    }

    static func shortDate(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.defaultDigits).day())
    }
}
