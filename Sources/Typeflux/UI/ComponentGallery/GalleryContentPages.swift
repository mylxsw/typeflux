import SwiftUI

/// Sample data shared by the gallery pages.
enum GallerySamples {
    struct Provider: Identifiable, Hashable {
        var id: String { name }
        var name: String
        var detail: String
        var configured: Bool
        var tint: Color
    }

    static let providers: [Provider] = [
        Provider(name: "Typeflux Cloud", detail: "Available after signing in", configured: true, tint: .blue),
        Provider(name: "Local Model", detail: "SenseVoice · downloaded", configured: true, tint: .green),
        Provider(name: "Alibaba Cloud ASR", detail: "Realtime streaming", configured: true, tint: .orange),
        Provider(name: "Soniox", detail: "Needs an API key", configured: false, tint: .gray),
        Provider(name: "OpenAI", detail: "Needs an API key", configured: false, tint: .mint),
        Provider(name: "Groq", detail: "Needs an API key", configured: false, tint: .pink)
    ]

    static let models: [TFRichSection<String>] = [
        TFRichSection("Configured", options: [
            TFRichOption("cloud", "Typeflux Cloud", subtitle: "Default · available after signing in", tint: .blue),
            TFRichOption("fable", "Claude Fable 5.1", subtitle: "Anthropic · configured", tint: .orange),
            TFRichOption("qwen", "Qwen3 Local", subtitle: "Ollama · downloaded", tint: .purple)
        ]),
        TFRichSection("Not configured", options: [
            TFRichOption("gpt", "GPT-5.5", subtitle: "OpenAI · missing API key", tint: .green, trailing: "Set up")
        ])
    ]

    static let languages = [TFOption("zh", "简体中文"), TFOption("en", "English"), TFOption("ja", "日本語"),
                            TFOption("system", "Follow System")]
}

// MARK: - Menus

struct GalleryMenusPage: View {
    @State private var language = "zh"
    @State private var engine = "cloud"
    @State private var segment = "1"
    @State private var kind = "all"
    @State private var source = "all"
    @State private var model = "cloud"
    @State private var lastAction = "—"

    private let kinds = [TFOption("all", "All", count: 11), TFOption("translate", "Translate", count: 2),
                         TFOption("ai", "AI Commands", count: 3), TFOption("web", "Web Search", count: 2),
                         TFOption("system", "System", count: 2), TFOption("workflow", "Workflows", count: 2)]
    private let sources = [TFOption("all", "All", count: 129), TFOption("auto", "Automatic", count: 65),
                           TFOption("manual", "Manual", count: 0), TFOption("other", "Other Apps", count: 64)]

    var body: some View {
        GalleryPage(title: "Menus",
                    summary: "Three dropdowns: a pop-up button chooses a value, a menu button runs actions, a " +
                        "filter menu narrows a list. They open native menus; only rich options (subtitle, status) " +
                        "or searchable lists use the custom panel.") {
            GallerySpecimen(title: "Pop-up button", component: "TFPopUpButton",
                            spec: "Current value + ⌃⌄. Regular 30pt (was 36pt) so it lines up with buttons; forms " +
                                "use the 220pt column. The native menu opens over the selected row.") {
                TFPopUpButton(title: "Language", options: GallerySamples.languages, selection: $language,
                              width: TFMetrics.formControlWidth)
                GalleryCaption("regular · form width 220")
                TFPopUpButton(title: "Search Service",
                              sections: [TFPopUpSection(title: "Built-in", options: [TFOption("cloud", "Typeflux Cloud")]),
                                         TFPopUpSection(title: "Bring your own key", options: [
                                             TFOption("cloudflare", "Cloudflare"), TFOption("google", "Google")])],
                              selection: $engine, width: TFMetrics.formControlWidth,
                              leading: { _ in AnyView(TFStatusDot(level: .success)) })
                GalleryCaption("sections and a leading status dot")
                TFPopUpButton(title: "Segment", options: [TFOption("1", "Segment 1"), TFOption("2", "Segment 2")],
                              selection: $segment, size: .small)
                GalleryCaption("small 24 · inside rows and card headers")
            }
            GallerySpecimen(title: "Menu button", component: "TFMenuButton",
                            spec: "A button with ⌄, or the icon-only “⋯” circle. Verbs only; destructive items go " +
                                "last after a separator.") {
                HStack(spacing: 10) {
                    TFMenuButton(title: "More", systemImage: "ellipsis", actions: actions)
                    TFMenuButton(title: "Add Keyword", systemImage: "plus", kind: .primary, actions: [
                        .action("Translate") { lastAction = "Translate" }, .action("AI Command") { lastAction = "AI Command" },
                        .action("Web Search") { lastAction = "Web Search" }
                    ])
                    TFMenuButton(title: "More Actions", systemImage: "ellipsis", kind: .plain, size: .small, iconOnly: true,
                                 actions: actions)
                }
                GalleryCaption("last action: \(lastAction)")
            }
            GallerySpecimen(title: "Filter menu", component: "TFFilterMenu",
                            spec: "“Option · count ⌄”. Tinted with the accent while a non-default option is chosen.") {
                HStack(spacing: 10) {
                    TFFilterMenu(title: "Type", options: kinds, selection: $kind, defaultValue: "all")
                    GalleryCaption(kind == "all" ? "default" : "active → tinted")
                }
            }
            GallerySpecimen(title: "Adaptive filter", component: "TFFilterControl",
                            spec: "Segmented while it fits (≤4 options, regular layout); otherwise a filter menu. " +
                                "Toggle Compact in the toolbar to see the 4-option filter fold.") {
                TFFilterControl(title: "Source", options: sources, selection: $source, defaultValue: "all")
                GalleryCaption("4 options")
                TFFilterControl(title: "Type", options: kinds, selection: $kind, defaultValue: "all")
                GalleryCaption("6 options → always a menu")
            }
            GallerySpecimen(title: "Rich picker and menu panel", component: "TFRichPicker · TFMenuPanel",
                            spec: "Icon + subtitle rows (44pt), section headers, accent highlight, ↑↓ / Return. A " +
                                "search field appears above 12 options (forced on here).") {
                HStack(alignment: .top, spacing: 24) {
                    TFRichPicker(title: "Default Model", sections: GallerySamples.models, selection: $model, searchable: true)
                    TFMenuPanel(sections: GallerySamples.models, selection: model, searchable: true, focusesSearch: false) { model = $0 }
                        .frame(width: 300)
                        .background(TFColors.card, in: RoundedRectangle(cornerRadius: TFMetrics.cardCornerRadius,
                                                                       style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: TFMetrics.cardCornerRadius, style: .continuous)
                            .strokeBorder(TFColors.border, lineWidth: TFMetrics.borderWidth))
                }
            }
        }
    }

    private var actions: [TFMenuAction] {
        [.action("Import…", systemImage: "square.and.arrow.down") { lastAction = "Import" },
         .action("Export All", systemImage: "square.and.arrow.up") { lastAction = "Export" },
         .separator,
         .action("Clear Automatic Entries", systemImage: "trash", destructive: true) { lastAction = "Clear" }]
    }
}

// MARK: - Search & fields

struct GalleryInputsPage: View {
    @State private var query = ""
    @State private var listQuery = "cloud"
    @State private var name = ""
    @State private var url = "https://api.openai.com/v1"
    @State private var key = ""

    private var urlError: Bool { !url.isEmpty && !(url.hasPrefix("http://") || url.hasPrefix("https://")) }

    var body: some View {
        let hits = GallerySamples.providers.filter { TFSearchMatcher.matches(query, $0.name, $0.detail) }
        GalleryPage(title: "Search & Fields",
                    summary: "One search field (30pt capsule) in two placements, and text fields that share its " +
                        "fill and focus ring.") {
            GallerySpecimen(title: "Toolbar search", component: "TFSearchField(placement: .toolbar)",
                            spec: "200–320pt. ⌘F focuses it; Esc clears, then leaves; ↓ moves into results. Shows " +
                                "“N items” and a clear button while there is text.") {
                TFSearchField(placeholder: "Search models or providers", text: $query, resultCount: hits.count)
                ForEach(hits) { provider in
                    TFHighlightedText(text: provider.name, query: query).font(.system(size: 12.5))
                }
            }
            GallerySpecimen(title: "Container search", component: "TFSearchField(placement: .container)",
                            spec: "Fills a list column, sheet or menu.") {
                TFSearchField(placeholder: "Search personas", text: $listQuery, placement: .container, resultCount: 2)
                    .frame(width: 248)
            }
            GallerySpecimen(title: "Text fields", component: "TFTextFieldStyle · TFFieldMessage",
                            spec: "30pt, 8pt corners. Keys, URLs and model IDs are monospaced. Errors outline the " +
                                "field in red with a message below.") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Name", text: $name).textFieldStyle(TFTextFieldStyle())
                    TextField("sk-…", text: $key).textFieldStyle(TFTextFieldStyle(monospaced: true))
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("https://", text: $url).textFieldStyle(TFTextFieldStyle(monospaced: true, isError: urlError))
                        if urlError { TFFieldMessage(text: "Enter an address that starts with http:// or https://") }
                    }
                    GalleryCaption("edit the URL to see validation")
                }
                .frame(width: TFMetrics.formControlWideWidth)
            }
        }
    }
}

// MARK: - Lists & forms

struct GalleryListsPage: View {
    @State private var skills: [String: Bool] = ["data-analysis": true, "email-reply": true, "pdf-report": false]
    @State private var selected = "Typeflux"
    @State private var launch = true
    @State private var appearance = "auto"
    @State private var language = "zh"

    var body: some View {
        GalleryPage(title: "Lists & Forms",
                    summary: "Grouped cards like System Settings. Rows: icon tile, title with tags, one-line " +
                        "subtitle, up to two trailing accessories. Forms: label on the left, control in a 220pt " +
                        "column.") {
            GallerySpecimen(title: "Row heights", component: "TFListRow · TFListGroup",
                            spec: "Two lines 52pt, single line 36pt, compact 30pt. Hairlines start at the title.") {
                TFSectionHeader(title: "Skills", count: skills.count) {
                    TFButton(title: "Manage") {}
                    TFButton(title: "New", systemImage: "plus") {}
                }
                TFListGroup(skills.keys.sorted(), id: \.self) { name in
                    TFListRow(title: name, subtitle: "Analyze tables and report verified results.", tags: ["Built-in"]) {
                        TFIconTile(systemImage: "sparkles", tint: .indigo)
                    } accessory: {
                        TFSwitch(title: name, isOn: Binding(get: { skills[name] ?? false }, set: { skills[name] = $0 }))
                        TFChevron()
                    }
                }
                TFListGroup(["Typeflux", "English Translator"], id: \.self, separatorInset: TFListGroupInset.plain) { name in
                    TFListRow(title: name, isSelected: selected == name, action: { selected = name }) {
                        TFStatusLabel(text: "Configured", level: .success)
                        TFChevron()
                    }
                }
                TFListGroup(["Raycast", "PGVector"], id: \.self, separatorInset: TFListGroupInset.plain) { word in
                    TFListRow(title: word, tags: ["Automatic"], density: .compact) {
                        TFMenuButton(title: "More Actions", systemImage: "ellipsis", kind: .plain, iconOnly: true, actions: [
                            .action("Edit") {}, .separator, .action("Delete", destructive: true) {}
                        ])
                    }
                }
            }
            GallerySpecimen(title: "Accessories", spec: "Status, switch, chevron, small button, “⋯” menu — at most " +
                "two per row.") {
                TFListGroup(["1Password"], id: \.self) { name in
                    TFListRow(title: name, subtitle: "com.1password.1password") {
                        TFIconTile(letter: name, tint: .blue)
                    } accessory: {
                        TFStatusLabel(text: "Running", level: .success, tintsText: true)
                        TFButton(title: "Choose") {}
                    }
                }
            }
            GallerySpecimen(title: "Form", component: "TFFormRow · TFCard · TFDivider",
                            spec: "Rows at least 52pt; controls regular size in a 220pt (or 280pt) column; " +
                                "switches are mini.") {
                TFCard {
                    TFFormRow(title: "Appearance") {
                        TFSegmentedControl(options: [TFOption("light", "Light"), TFOption("dark", "Dark"), TFOption("auto", "Auto")],
                                           selection: $appearance, fillsWidth: true)
                    }
                    TFDivider(inset: TFListGroupInset.form)
                    TFFormRow(title: "Interface Language", detail: "Takes effect when windows reopen") {
                        TFPopUpButton(title: "Language", options: GallerySamples.languages, selection: $language,
                                      width: TFMetrics.formControlWidth)
                    }
                    TFDivider(inset: TFListGroupInset.form)
                    TFFormRow(title: "Open at Login") { TFSwitch(title: "Open at Login", isOn: $launch) }
                    TFDivider(inset: TFListGroupInset.form)
                    TFFormRow(title: "Reset All Settings", detail: "History and vocabulary are kept") {
                        TFButton(title: "Reset…", destructive: true) {}
                    }
                }
            }
        }
    }
}

// MARK: - Feedback

struct GalleryFeedbackPage: View {
    @State private var query = "zzz"

    var body: some View {
        GalleryPage(title: "Feedback",
                    summary: "Empty states, status, tags and small indicators.") {
            GallerySpecimen(title: "Empty list", component: "TFEmptyState",
                            spec: "A full-page empty state gets one large primary button and an optional link.") {
                TFEmptyState(systemImage: "server.rack", title: "No MCP Servers",
                             message: "Connect an MCP server to let the agent use its tools.") {
                    TFButton(title: "Add MCP Server", systemImage: "plus", kind: .primary, size: .large) {}
                    TFButton(title: "Learn About MCP", kind: .link) {}
                }
            }
            GallerySpecimen(title: "No search results", component: "TFSearchEmptyState",
                            spec: "Clear Search; plus Search All while a filter is active.") {
                TFSearchEmptyState(query: query, onClear: { query = "" }, onSearchAll: {})
            }
            GallerySpecimen(title: "Status, tags, tiles, key caps", component: "TFStatusLabel · TFTag · TFIconTile · TFKeyCap") {
                HStack(spacing: 14) {
                    TFStatusLabel(text: "Configured", level: .success)
                    TFStatusLabel(text: "Not configured")
                    TFStatusLabel(text: "Quota low", level: .warning)
                    TFStatusLabel(text: "Failed", level: .danger, tintsText: true)
                }
                HStack(spacing: 8) {
                    TFTag(text: "Built-in")
                    TFTag(text: "translate", monospaced: true)
                    TFTag(text: "New", tint: TFColors.accent)
                    TFIconTile(systemImage: "sparkles", tint: .indigo)
                    TFIconTile(letter: "Groq", tint: .orange)
                    TFKeyCap(text: "⌘F")
                    TFSpinner()
                }
            }
        }
    }
}
