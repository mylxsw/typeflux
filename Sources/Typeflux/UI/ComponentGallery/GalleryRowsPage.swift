import SwiftUI

/// Pane headers, icon rows, collapsible sections and the small pieces settings cards are built from.
struct GalleryRowsPage: View {
    @State private var expanded = true
    @State private var enabled = true
    @State private var position = "mouse"
    @State private var extensions = ["swift", "md", "py"]
    @State private var checked = true
    @State private var confirming = true
    @State private var advanced = false
    @State private var key = "sk-fixture"
    @State private var note = "Prefers concise answers"
    @State private var undo = true
    @State private var storage = "cloud"

    var body: some View {
        GalleryPage(title: "Rows & Panes",
                    summary: "A pane opens with a header, then form sections whose rows lead with a neutral icon " +
                        "tile. Hairlines start at the title.") {
            GallerySpecimen(title: "Pane header", component: "TFPaneHeader",
                            spec: "40pt soft accent tile, 17pt title, optional subtitle; actions on the right wrap " +
                                "below the title when the pane is narrow.") {
                TFPaneHeader(systemImage: "bolt.horizontal", title: "Workflows",
                             subtitle: "Run your own scripts from the launcher.") {
                    TFButton(title: "Gallery", systemImage: "square.grid.2x2") {}
                    TFMenuButton(title: "New", systemImage: "plus", kind: .primary, actions: [.action("Blank") {}])
                }
            }
            GallerySpecimen(title: "Icon rows", component: "TFFormRow(icon:) · TFDivider.formWithIcon · TFActionRow",
                            spec: "28pt neutral tile, 12pt gap; an app icon can take its place (image:). Descriptions " +
                                "show as a hover hint; current values (paths, sizes) use valueText. An action row " +
                                "in accent ends a list it adds to.") {
                TFFormSection(title: "Panel", footnote: "A footnote sits under the card.") {
                    TFFormRow(title: "Show Preview", detail: "Shows the selected item on the right", icon: "sidebar.right") {
                        TFSwitch(title: "Show Preview", isOn: $enabled)
                    }
                    TFDivider.formWithIcon
                    TFFormRow(title: "Position", icon: "macwindow") {
                        TFSegmentedControl(options: [TFOption("mouse", "Mouse"), TFOption("center", "Center")],
                                           selection: $position)
                    }
                    TFDivider.formWithIcon
                    TFFormRow(title: "Projects", valueText: "/Users/me/Documents/Projects/typeflux/Sources",
                              icon: "folder", valueLineLimit: 1) {
                        TFButton(title: "Remove", systemImage: "minus", size: .small, iconOnly: true) {}
                    }
                    TFDivider.formWithIcon
                    TFActionRow(systemImage: "plus", title: "Add Folder") {}
                }
            }
            GallerySpecimen(title: "Collapsible section", component: "TFFormSection(isExpanded:)",
                            spec: "The header becomes a disclosure button; the card and footnote hide together.") {
                TFFormSection(title: "System Commands", count: 3, isExpanded: $expanded) {
                    TFFormRow(title: "Lock Screen", icon: "lock") { TFCheckbox(title: "Lock Screen", isOn: $checked) }
                }
            }
            GallerySpecimen(title: "Tokens", component: "TFTokenInput · TFFlowLayout",
                            spec: "Removable monospaced tokens wrap onto new lines; the field adds on Return.") {
                TFCard {
                    TFTokenInput(values: extensions, placeholder: "ext",
                                 normalize: { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 },
                                 onChange: { extensions = $0 })
                }
            }
            GallerySpecimen(title: "Figures, notes and confirmations",
                            component: "TFMetric · TFMeter · TFCardNote · TFInlineConfirmation · TFFieldMessage") {
                TFCard {
                    HStack(spacing: 12) {
                        TFMetric(title: "Indexed", value: "12,408")
                        TFMetric(title: "Size", value: "86 MB")
                        TFMeter(value: 3, total: 4)
                    }
                    .padding(14)
                    TFDivider.form
                    TFCardNote(text: "No folders yet. Add one to search its files.")
                }
                if confirming {
                    TFInlineConfirmation(title: "Rebuild the index?", message: "Search is slower until it finishes.",
                                         confirmTitle: "Rebuild", onConfirm: { confirming = false },
                                         onCancel: { confirming = false })
                }
                TFFieldMessage(text: "Keyword “tr” is also used by Translate.", tone: .warning)
                TFFieldMessage(text: "Takes effect the next time the panel opens.", tone: .hint)
                HStack(spacing: 8) {
                    TFIconTile(systemImage: "sparkles", tint: .indigo)
                    TFIconTile(systemImage: "sparkles", tint: .indigo, style: .soft)
                    TFIconTile(systemImage: "sparkles", style: .neutral)
                    TFStatusLabel(text: "Selected", level: .accent)
                }
            }
            GallerySpecimen(title: "Fields in a card", component: "TFFormRow(isRequired:) · TFSecureField · TFTextArea · " +
                                "TFDisclosureRow · TFFootnote",
                            spec: "Credentials sit in a 280pt column with a red asterisk when required. Rarely " +
                                "needed fields hide behind a disclosure row.") {
                TFFormSection(title: "Connection") {
                    TFFormRow(title: "API Key", icon: "key", isRequired: true, controlWidth: .wide) {
                        TFSecureField(placeholder: "API Key", text: $key)
                    }
                    TFDivider.form
                    TFDisclosureRow(title: "Advanced Options", isExpanded: $advanced)
                    if advanced {
                        TFFormRow(title: "Note", controlWidth: .wide) { TFTextArea(label: "Note", text: $note) }
                    }
                }
                TFFootnote(text: "Keys are stored in the keychain.")
            }
            GallerySpecimen(title: "Notices and undo", component: "TFNotice · TFUndoBar · TFChecklist",
                            spec: "A notice explains a state or a result in its tone. The undo bar dismisses itself " +
                                "after five seconds.") {
                ForEach(TFNotice.Tone.allCases, id: \.self) { tone in
                    TFNotice(text: "Connection test: \(tone)", tone: tone)
                }
                if undo {
                    TFUndoBar(message: "Removed “Documents”", onUndo: { undo = false }, onDismiss: { undo = false })
                }
                HStack(alignment: .top, spacing: 12) {
                    ForEach(["cloud", "local"], id: \.self) { option in
                        TFChoiceCard(title: option == "cloud" ? "Cloud Sync" : "Only This Mac",
                                     isSelected: storage == option) { storage = option } preview: {
                            TFChecklist(systemImage: option == "cloud" ? "cloud" : "lock",
                                        items: [(true, "Private by default"), (option == "cloud", "Syncs devices")])
                        }
                    }
                }
            }
        }
    }
}
