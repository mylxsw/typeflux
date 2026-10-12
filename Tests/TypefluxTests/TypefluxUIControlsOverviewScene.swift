import SwiftUI
@testable import Typeflux
import TypefluxUI

/// A compact export of the same native components used in the developer gallery.
struct TypefluxUIControlsOverviewScene: View {
    @State private var selection = 0
    @State private var enabled = true
    @State private var value = 0.7
    @State private var text = "https://example.com/v1"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("TypefluxUI · Content controls").font(.title2)
            Text("System controls · solid content · native macOS sizing").font(.subheadline)
                .foregroundStyle(TypefluxColor.secondaryLabel.color)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 20) {
                    panel("Buttons") {
                        HStack {
                            TypefluxButton("Cancel") {}
                            TypefluxButton("Save", kind: .primary) {}
                            TypefluxButton("Delete…", kind: .destructive) {}
                            TypefluxButton("Disabled") {}.disabled(true)
                        }
                        HStack {
                            TypefluxButton("Start", kind: .primary, size: .large) {}
                            TypefluxButton("Learn more", kind: .link) {}
                            TypefluxIconButton("Copy", systemImage: "doc.on.doc", kind: .regular) {}
                        }
                    }
                    panel("Switch · checkbox · radio") {
                        HStack {
                            TypefluxSwitch("On", isOn: $enabled)
                            TypefluxSwitch("Off", isOn: .constant(false))
                            TypefluxCheckbox("Restore clipboard", isOn: $enabled)
                        }
                        TypefluxRadioGroup("Placement", selection: $selection) {
                            Text("Floating").tag(0); Text("Docked").tag(1)
                        }
                    }
                    panel("Text field · slider · progress") {
                        TypefluxSettingsRow("Base URL") { TypefluxTextField("Base URL", text: $text) }
                        TypefluxSettingsRow("Invalid URL") {
                            TypefluxTextField("Invalid URL", text: .constant(""), error: "Enter a valid URL.")
                        }
                        TypefluxSlider("Amount", value: $value)
                        TypefluxProgress("Downloading", value: value)
                    }
                    panel("Table · sorting · row actions") { TypefluxGalleryTable().frame(height: 180) }
                }
                VStack(alignment: .leading, spacing: 20) {
                    panel("Pop-up · pull-down · segmented") {
                        HStack {
                            TypefluxPopup("Language", selection: $selection) { choices }
                            TypefluxPopup("Borderless", selection: $selection, borderless: true) { choices }
                            TypefluxMenu { TypefluxButton("Import file") {} } label: { Text("Import") }
                        }
                        TypefluxSegmentedControl("Source", selection: $selection) { choices }
                        TypefluxSegmentedControl("View", selection: $selection, iconsOnly: true) {
                            Label("List", systemImage: "list.bullet").tag(0)
                            Label("Grid", systemImage: "square.grid.2x2").tag(1)
                        }.frame(width: 100)
                    }
                    panel("Status · tag · token · key hint · help") {
                        HStack {
                            TypefluxStatus("Connected", tone: .success)
                            TypefluxStatus("Low credit", tone: .warning)
                            TypefluxStatus("Not configured", tone: .inactive)
                        }
                        HStack {
                            TypefluxTag("Local"); TypefluxTag("Default", tone: .accent)
                            TypefluxTag("Enabled", tone: .success); TypefluxTag("Beta", tone: .warning)
                        }
                        HStack {
                            TypefluxToken("Report.pdf", removeLabel: "Remove Report.pdf") {}
                            TypefluxKeyHint("⌘K", accessibilityLabel: "Command K")
                            TypefluxIconButton("Help", systemImage: "questionmark.circle") {}
                        }
                    }
                    panel("Grouped form · navigation") {
                        TypefluxForm {
                            TypefluxFormSection("Voice input", footer: "Changes apply to the next recording.") {
                                TypefluxSettingsRow("Language") {
                                    TypefluxPopup("Recognition language", selection: $selection, borderless: true) {
                                        choices
                                    }
                                }
                                TypefluxSettingsRow("Learn words", description: "Learn from transcriptions.") {
                                    TypefluxSwitch("Learn words", isOn: $enabled, labelsHidden: true)
                                }
                                TypefluxNavigationRow("Shortcuts", systemImage: "keyboard", color: .teal,
                                                      detail: "6") {}
                            }
                        }.frame(height: 240)
                    }
                    panel("Empty state") {
                        TypefluxEmptyState("No results", systemImage: "magnifyingglass",
                                           description: "Check spelling or add an item.") {
                            TypefluxButton("Add item", kind: .primary) {}
                        }.frame(height: 260)
                    }
                }
            }
        }.padding(24).background(TypefluxColor.contentBackground.color)
    }

    private var choices: some View { Group { Text("Automatic").tag(0); Text("Manual").tag(1) } }

    private func panel(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(TypefluxColor.windowBackground.color, in: RoundedRectangle(cornerRadius: 8))
    }
}
