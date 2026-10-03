import AppKit
import SwiftUI

struct AskProjectReviewView: View {
    let review: AskProjectReview
    var exportPatch: ((AskWorkspaceRef) throws -> Data)?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L("ask.project.review"), systemImage: "doc.text.magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(L("ask.project.export")) { save() }.disabled(exportPatch == nil)
            }
            Text(L("ask.project.staged")).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
            ForEach(review.files, id: \.self) {
                Text($0).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            }
            if review.truncated {
                Text(L("ask.project.truncated")).foregroundStyle(StudioTheme.textSecondary)
            }
            if !review.patch.isEmpty {
                AskMonoBlock(title: "", text: review.patch)
            }
            if let error {
                Text(error).foregroundStyle(StudioTheme.danger).font(.system(size: 12))
            }
        }
        .padding(12)
        .background(AskTheme.monoSurface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Typeflux-changes.patch"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let exportPatch else { throw AskProjectError.unavailable }
            // Revalidate after the save dialog: source/authorization may have
            // changed while the user chose a destination.
            let data = try exportPatch(review.workspace)
            guard AskToolPolicy.digest(data) == review.patchHash else { throw AskProjectError.conflict }
            try data.write(to: url, options: .atomic)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
