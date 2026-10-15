import SwiftUI

/// Whole screens assembled from the components, to check how they combine.
struct GalleryCompositionsPage: View {
    var body: some View {
        GalleryPage(title: "Compositions",
                    summary: "Components assembled into the screens they are made for. Use Compact in the toolbar " +
                        "to see filters and panes fold, and Light/Dark and Glass/Classic to check every " +
                        "combination.") {
            GallerySpecimen(title: "List page", component: "TFTabBar + TFSearchField + TFFilterControl + TFButton " +
                "+ TFListGroup",
                            spec: "Toolbar order: search → filter → space → secondary → primary. One size per row. " +
                                "Search and filter combine; empty groups hide; no results shows the search empty " +
                                "state.") {
                GalleryListPageDemo()
            }
            GallerySpecimen(title: "List and detail", component: "TFSearchField(.container) + rows + TFCard") {
                GalleryListDetailDemo()
            }
            GallerySpecimen(title: "Sheet footer and confirmation", component: "TFButton",
                            spec: "Right-aligned [Cancel] [Primary]; a help circle may sit on the left. " +
                                "Destructive confirmations fill red and keep the default focus on Cancel.") {
                GalleryDialogDemo()
            }
        }
    }
}

private struct GalleryListPageDemo: View {
    @State private var tab = "asr"
    @State private var query = ""
    @State private var filter = "all"

    var body: some View {
        let hits = GallerySamples.providers.filter { TFSearchMatcher.matches(query, $0.name, $0.detail) }
        let shown = hits.filter { filter == "all" || ($0.configured == (filter == "on")) }
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: "Models").font(.system(size: 22, weight: .bold))
            TFTabBar(options: [TFOption("asr", "Speech Recognition"), TFOption("llm", "Language Models")], selection: $tab)
            HStack(spacing: TFMetrics.toolbarSpacing) {
                TFSearchField(placeholder: "Search models or providers", text: $query, resultCount: shown.count)
                TFFilterControl(title: "Status", options: [
                    TFOption("all", "All", count: hits.count),
                    TFOption("on", "Configured", count: hits.filter(\.configured).count),
                    TFOption("off", "Not Configured", count: hits.filter { !$0.configured }.count)
                ], selection: $filter, defaultValue: "all")
                Spacer(minLength: 0)
                TFButton(title: "Add Provider", systemImage: "plus", kind: .primary) {}
            }
            if shown.isEmpty {
                TFSearchEmptyState(query: query, onClear: { query = "" },
                                   onSearchAll: filter == "all" ? nil : { filter = "all" })
            } else {
                group("Configured", shown.filter(\.configured))
                group("Not Configured", shown.filter { !$0.configured })
            }
        }
    }

    @ViewBuilder private func group(_ title: String, _ providers: [GallerySamples.Provider]) -> some View {
        if !providers.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                TFSectionHeader(title: title, count: providers.count)
                TFListGroup(providers) { provider in
                    TFListRow(title: provider.name, subtitle: provider.detail, query: query, action: {}) {
                        TFIconTile(letter: provider.name, tint: provider.tint)
                    } accessory: {
                        TFStatusLabel(text: provider.configured ? "Configured" : "Not configured",
                                      level: provider.configured ? .success : .neutral)
                        TFChevron()
                    }
                }
            }
        }
    }
}

private struct GalleryListDetailDemo: View {
    @State private var query = ""
    @State private var selection = "Typeflux"
    private let personas = ["Candidate: Casual English", "Candidate: Structured", "Workplace Assistant", "Typeflux",
                            "English Translator"]

    var body: some View {
        let hits = personas.filter { TFSearchMatcher.matches(query, $0) }
        HStack(alignment: .top, spacing: 14) {
            TFCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(verbatim: "Personas").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        TFButton(title: "New", systemImage: "plus", size: .small) {}
                    }
                    TFSearchField(placeholder: "Search names or content", text: $query, placement: .container,
                                  resultCount: hits.count)
                    VStack(spacing: 0) {
                        ForEach(hits, id: \.self) { name in
                            Button { selection = name } label: {
                                TFHighlightedText(text: name, query: query)
                                    .font(.system(size: 12.5, weight: selection == name ? .semibold : .regular))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .frame(height: 30)
                                    .background(selection == name ? TFColors.selection : .clear,
                                                in: RoundedRectangle(cornerRadius: TFMetrics.itemCornerRadius,
                                                                     style: .continuous))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(TFRowHoverStyle(selected: selection == name))
                        }
                    }
                }
                .padding(10)
            }
            .frame(width: 248)
            TFCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(verbatim: selection).font(.system(size: 16, weight: .semibold))
                        TFTag(text: "Built-in")
                        Spacer()
                        TFButton(title: "Duplicate to Edit", systemImage: "doc.on.doc", size: .small) {}
                    }
                    Text(verbatim: "Built-in personas are maintained by Typeflux. Duplicate one to change it.")
                        .font(.system(size: 12)).foregroundStyle(TFColors.textSecondary)
                    RoundedRectangle(cornerRadius: TFMetrics.textAreaCornerRadius, style: .continuous)
                        .fill(TFColors.control).frame(height: 120)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct GalleryDialogDemo: View {
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            TFCard {
                HStack(spacing: 8) {
                    TFButton(title: "Help", systemImage: "questionmark", iconOnly: true) {}
                    Spacer()
                    TFButton(title: "Cancel") {}
                    TFButton(title: "Save", kind: .primary) {}
                }
                .padding(14)
            }
            TFCard {
                VStack(alignment: .leading, spacing: 6) {
                    TFIconTile(systemImage: "exclamationmark.triangle", tint: TFColors.danger, size: 36)
                        .padding(.bottom, 6)
                    Text(verbatim: "Reset all settings?").font(.system(size: 14, weight: .semibold))
                    Text(verbatim: "Every setting returns to its default. History, vocabulary and personas are kept.")
                        .font(.system(size: 12.5)).foregroundStyle(TFColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Spacer()
                        TFButton(title: "Cancel") {}
                        TFButton(title: "Reset", kind: .primary, destructive: true) {}
                    }
                    .padding(.top, 12)
                }
                .padding(20)
            }
            .frame(width: 360)
        }
    }
}
