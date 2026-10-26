import SwiftUI

/// Results have their own identity and stay mounted while subsequent messages stream.
/// Deliverables are separate from filesystem changes: a retained copy is not another write.
struct AskTaskOutcomeView: View {
    let outcome: AskTaskOutcome
    let outputs: AskRunOutputs
    let active: Bool
    let actions: AskSidePanelActions
    @State private var expanded = true
    @Environment(\.askInspectTranscript) private var inspectTranscript

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !outputs.isEmpty {
                Button { inspectTranscript(); expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "shippingbox")
                        Text(L("ask.activity.results"))
                        if active { Text(L("ask.activity.resultsWorking")).foregroundStyle(StudioTheme.textTertiary) }
                        Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                }
                .buttonStyle(.plain)
                if expanded {
                    AskPagedRunOutputs(outputs: outputs)
                }
            }
            if !outcome.changes.isEmpty {
                AskFileChangesView(list: AskFileChangeList(changes: outcome.changes), actions: actions)
            }
        }
        .accessibilityIdentifier(outcome.id)
    }
}

/// Rich artifacts can contain images and web previews. Bound those just like tool details.
private struct AskPagedRunOutputs: View {
    let outputs: AskRunOutputs
    @State private var page = 0
    private var count: Int { outputs.generatedImages.count + outputs.storedArtifacts.count + outputs.artifacts.count }

    private var visible: AskRunOutputs {
        let range = AskActivityPage.range(count: count, page: page)
        var result = AskRunOutputs()
        var offset = 0
        for image in outputs.generatedImages {
            if range.contains(offset) { result.generatedImages.append(image) }
            offset += 1
        }
        for artifact in outputs.storedArtifacts {
            if range.contains(offset) { result.storedArtifacts.append(artifact) }
            offset += 1
        }
        for artifact in outputs.artifacts {
            if range.contains(offset) { result.artifacts.append(artifact) }
            offset += 1
        }
        result.sources = outputs.sources
        result.storedArtifactNames = outputs.storedArtifactNames
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if count > AskActivityPage.size {
                HStack {
                    Button(L("ask.activity.previous")) { page = max(0, page - 1) }.disabled(page == 0)
                    Button(L("ask.activity.next")) { page += 1 }.disabled(page >= AskActivityPage.last(count: count))
                }
                .buttonStyle(.plain)
            }
            AskRunOutputsView(outputs: visible)
        }
    }
}
