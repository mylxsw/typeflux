import SwiftUI

struct AskReferenceEditor: View {
    @State var reference: AskReference
    var save: (AskReference) -> Void
    var cancel: () -> Void
    var editing = false
    var byteBudget = 64000
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("ask.references.question"), systemImage: "text.bubble")
                .font(.system(size: 13, weight: .semibold))
            ScrollView {
                Text(reference.text).font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textSecondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 120)
            TextEditor(text: $reference.question)
                .font(.system(size: 13)).frame(height: 70).focused($focused)
                .accessibilityLabel(L("ask.references.optional"))
                .overlay(alignment: .topLeading) {
                    if reference.question.isEmpty {
                        Text(L("ask.references.optional")).font(.system(size: 12))
                            .foregroundStyle(StudioTheme.textTertiary).padding(5).allowsHitTesting(false)
                    }
                }
            if reference.text.utf8.count + reference.question.utf8.count > byteBudget {
                Text(L("ask.input.tooLarge")).font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
            }
            HStack {
                Button(L("ask.references.explain")) { reference.question = L("ask.references.explain") }
                Spacer()
                Button(L("common.cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(L(editing ? "ask.references.update" : "ask.references.save")) { save(reference) }
                    .buttonStyle(.borderedProminent)
                    .disabled(reference.text.utf8.count + reference.question.utf8.count > byteBudget)
            }.font(.system(size: 12))
        }
        .padding(16).frame(width: 360)
        .background(AskTheme.raisedSurface).tint(AskTheme.accent)
        .onAppear { focused = true }
    }
}

struct AskReferenceStrip: View {
    @Binding var references: [AskReference]?
    var locate: (String) -> Void
    @State private var sheet: Sheet?

    private enum Sheet: Identifiable {
        case manage
        case edit(AskReference)
        var id: String {
            switch self {
            case .manage: return "manage"
            case .edit(let reference): return reference.id
            }
        }
    }

    /// Quotes stack full width above the editor, each one readable over two
    /// lines. Up to three are visible at once; more scroll inside the strip, so
    /// a long list never pushes the editor off screen.
    static let chipHeight: CGFloat = 60
    static let chipSpacing: CGFloat = 6
    static func stripHeight(count: Int) -> CGFloat {
        let visible = CGFloat(min(max(count, 0), 3))
        return visible * chipHeight + max(0, visible - 1) * chipSpacing
    }

    var body: some View {
        let items = references ?? []
        HStack(alignment: .top, spacing: 6) {
            ScrollView(.vertical) {
                VStack(spacing: Self.chipSpacing) { ForEach(items) { chip($0) } }
            }
            .frame(height: Self.stripHeight(count: items.count))
            // "Manage (1)" was developer wording for a list the user can already
            // see. Only offer the list once there is more than one excerpt.
            if items.count > 1 {
                Button { sheet = .manage } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("ask.references.manage", items.count))
                .accessibilityLabel(L("ask.references.manage", items.count))
            }
        }
        .padding(.horizontal, 9).padding(.top, 9)
        .sheet(item: $sheet) { destination in
            switch destination {
            case .edit(let reference):
                AskReferenceEditor(reference: reference, save: { updated in
                    if let index = references?.firstIndex(where: { $0.id == updated.id }) { references?[index] = updated }
                    sheet = nil
                }, cancel: { sheet = nil }, editing: true,
                   byteBudget: 64000 - (references ?? []).filter { $0.id != reference.id }
                    .reduce(0) { $0 + $1.text.utf8.count + $1.question.utf8.count })
            case .manage:
                management
            }
        }
    }

    /// An accent rule plus a source label, so the excerpt reads as a quotation
    /// rather than an anonymous grey box.
    private func chip(_ reference: AskReference) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Button { sheet = .edit(reference) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(reference.question.isEmpty ? L("ask.references.source") : reference.question)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AskTheme.accentText).lineLimit(1)
                    Text(reference.text).font(.system(size: 12))
                        .foregroundStyle(StudioTheme.textSecondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(reference.text)
            Button { remove(reference.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudioTheme.textTertiary)
            .accessibilityLabel(L("ask.remove"))
        }
        .padding(.leading, 11)
        .padding(.trailing, 5)
        .padding(.vertical, 7)
        .frame(height: Self.chipHeight, alignment: .top)
        .background(AskTheme.controlSurface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AskTheme.border))
        .overlay(alignment: .leading) {
            Rectangle().fill(AskTheme.accent).frame(width: 2)
                .clipShape(RoundedRectangle(cornerRadius: 1, style: .continuous))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var management: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("ask.references.manage", (references ?? []).count)).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(references ?? []) { reference in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(reference.text).font(.system(size: 12)).lineLimit(3)
                            Text(reference.question).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                            HStack {
                                Button(L("ask.references.locate")) { sheet = nil; locate(reference.messageId) }
                                Button(L("ask.references.edit")) { sheet = .edit(reference) }
                                Button(L("ask.remove")) { remove(reference.id) }
                            }.font(.system(size: 11))
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(AskTheme.controlSurface, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.frame(height: 300)
            Button(L("ask.references.close")) { sheet = nil }.keyboardShortcut(.cancelAction)
        }.padding(18).frame(width: 420).background(AskTheme.raisedSurface)
    }

    private func remove(_ id: String) { references?.removeAll { $0.id == id } }
}

struct AskSentReferences: View {
    let references: [AskReference]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(references) { reference in
                DisclosureGroup {
                    Text(reference.text).font(.system(size: 12)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !reference.question.isEmpty {
                        Text(reference.question).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(reference.text, systemImage: "text.quote").lineLimit(1)
                        if !reference.question.isEmpty { Text(reference.question).lineLimit(2) }
                    }.font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                }
            }
        }.padding(10).background(AskTheme.controlSurface, in: RoundedRectangle(cornerRadius: 9))
    }
}
