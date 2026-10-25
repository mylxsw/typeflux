import SwiftUI

/// File rows that matched by content rather than by name.
extension AskQuickResultsView {
    /// Name and "Content match", then folder and page; passages stay in the preview.
    func contentMatch(_ file: AskFileHit, evidence: AskFileHit.Evidence, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Self.marked(file.name, file.highlights).font(.system(size: 13.5))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                ModelUsageBadge(text: L("semantic.result"))
                Spacer(minLength: 8)
                fileTrailing(file, highlighted: highlighted)
            }
            Text(AskLauncherSearchSettings.abbreviate(file.folder)
                + (evidence.page.map { " · " + L(evidence.pageLocalizationKey, $0) } ?? ""))
                .font(.system(size: AskTheme.launcherResultDetailSize)).foregroundStyle(AskTheme.launcherResultDetail)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    func fileTrailing(_ file: AskFileHit, highlighted: Bool) -> some View {
        Text(highlighted ? L("ask.quick.file.actions") : Self.relative(file.modified))
            .font(.system(size: AskTheme.launcherResultDetailSize))
            .foregroundStyle(AskTheme.launcherResultDetail)
            .lineLimit(1)
            .fixedSize()
    }
}
