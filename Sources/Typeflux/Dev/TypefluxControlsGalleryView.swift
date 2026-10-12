import SwiftUI

/// Synthetic developer examples. All production labels are supplied by callers to the library.
struct TypefluxControlsGalleryView: View {
    @State private var toggle = true
    @State private var selection = 0
    @State private var slider = 0.7
    @State private var text = "https://example.com/v1"
    @State private var tokenPresent = true
    @State private var actionCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Content controls").font(.title2)
            Text("Native shapes follow macOS. Hover and hold a control, or use Tab / Space / Return. "
                 + "Read-only status, tags, key hints and progress have no press or focus state.")
                .font(.body).foregroundStyle(TypefluxColor.secondaryLabel.color)
            TypefluxControlGallerySection("Buttons") { buttons }
            TypefluxControlGallerySection("Pop-up button") { popups }
            TypefluxControlGallerySection("Pull-down menu") {
                HStack {
                    TypefluxMenu { menuActions } label: { Text("Import") }
                    TypefluxMenu(borderless: true) { menuActions } label: { Label("More", systemImage: "ellipsis") }
                }
            }
            TypefluxControlGallerySection("Segmented control") { segments }
            TypefluxControlGallerySection("Switch") {
                HStack {
                    TypefluxSwitch("Automatic learning", isOn: $toggle)
                    TypefluxSwitch("Off", isOn: .constant(false))
                    TypefluxSwitch("Hidden label", isOn: $toggle, labelsHidden: true)
                }
            }
            TypefluxControlGallerySection("Checkbox") {
                HStack {
                    TypefluxCheckbox("Restore clipboard", isOn: $toggle)
                    TypefluxCheckbox("Unchecked", isOn: .constant(false))
                }
            }
            TypefluxControlGallerySection("Radio group") {
                TypefluxRadioGroup("Placement", selection: $selection) { options }
            }
            TypefluxControlGallerySection("Slider") {
                HStack {
                    TypefluxSlider("Continuous", value: $slider)
                    TypefluxSlider("Stepped", value: $slider, step: 0.1)
                }
            }
            TypefluxControlGallerySection("Text field / form row") {
                VStack {
                    TypefluxSettingsRow("Base URL") { TypefluxTextField("Base URL", text: $text) }
                    TypefluxSettingsRow("Invalid URL") {
                        TypefluxTextField("Invalid URL", text: .constant(""), prompt: "https://example.com",
                                          error: "Enter a valid URL.")
                    }
                }
            }
            TypefluxControlGallerySection("Progress", interactive: false) {
                HStack {
                    TypefluxProgress("Downloading", value: slider).frame(width: 180)
                    TypefluxProgress("Waiting")
                    TypefluxProgress("Complete", value: 1).frame(width: 180)
                }
            }
            TypefluxControlGallerySection("Grouped form / settings row / navigation row") { form }
            TypefluxControlGallerySection("Table") { TypefluxGalleryTable().frame(height: 180) }
            TypefluxControlGallerySection("Status", interactive: false) {
                HStack { ForEach(TypefluxTone.allCases, id: \.self) { TypefluxStatus($0.rawValue, tone: $0) } }
            }
            TypefluxControlGallerySection("Tag (read-only)", interactive: false) {
                HStack { ForEach(TypefluxTone.allCases, id: \.self) { TypefluxTag($0.rawValue, tone: $0) } }
            }
            TypefluxControlGallerySection("Token (attachment / context)") {
                HStack {
                    if tokenPresent {
                        TypefluxToken("Report.pdf", removeLabel: "Remove Report.pdf") { tokenPresent = false }
                    }
                    TypefluxToken("Read-only context", removeLabel: "")
                    TypefluxButton("Restore token") { tokenPresent = true }
                }
            }
            TypefluxControlGallerySection("Key hint", interactive: false) {
                HStack {
                    TypefluxKeyHint("⌘K", accessibilityLabel: "Command K")
                    TypefluxKeyHint("fn", accessibilityLabel: "Function")
                    TypefluxKeyHint("↵", accessibilityLabel: "Return")
                }
            }
            TypefluxControlGallerySection("Empty state") {
                TypefluxEmptyState("No results", systemImage: "magnifyingglass",
                                   description: "Check spelling or add a new item.") {
                    TypefluxButton("Add item", kind: .primary) { actionCount += 1 }
                }.frame(height: 260)
            }
            TypefluxControlGallerySection("Help tooltip") {
                TypefluxIconButton("Help", systemImage: "questionmark.circle") { actionCount += 1 }
                    .typefluxHelp("Native help appears after the system hover delay.")
            }
            Text("Actions: \(actionCount)").font(.callout).monospacedDigit()
        }
    }

    private var buttons: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ForEach(TypefluxButtonKind.allCases, id: \.self) { kind in
                    TypefluxButton(kind.rawValue, kind: kind) { actionCount += 1 }
                }
            }
            HStack {
                TypefluxButton("Default", kind: .primary, defaultAction: true) { actionCount += 1 }
                TypefluxButton("Large", kind: .primary, size: .large) { actionCount += 1 }
                TypefluxButton("Large regular", size: .large) { actionCount += 1 }
                TypefluxIconButton("Copy", systemImage: "doc.on.doc", kind: .regular) { actionCount += 1 }
            }
        }
    }

    private var popups: some View {
        HStack {
            TypefluxPopup("Language", selection: $selection) { options }
            TypefluxPopup("Language (borderless)", selection: $selection, borderless: true) { options }
        }
    }

    private var segments: some View {
        HStack {
            TypefluxSegmentedControl("Source", selection: $selection) { options }
            TypefluxSegmentedControl("View", selection: $selection, iconsOnly: true) {
                Label("List", systemImage: "list.bullet").tag(0)
                Label("Grid", systemImage: "square.grid.2x2").tag(1)
            }.frame(width: 120)
        }
    }

    private var options: some View {
        Group { Text("Automatic").tag(0); Text("Manual").tag(1); Text("Other").tag(2) }
    }

    private var menuActions: some View {
        Group {
            TypefluxButton("From file…") { actionCount += 1 }
            TypefluxButton("Scan directory…") { actionCount += 1 }
        }
    }

    private var form: some View {
        TypefluxForm {
            TypefluxFormSection("Voice input", footer: "Changes take effect on the next recording.") {
                TypefluxSettingsRow("Shortcut") { TypefluxKeyHint("fn", accessibilityLabel: "Function") }
                TypefluxSettingsRow("Language") {
                    TypefluxPopup("Recognition language", selection: $selection, borderless: true) { options }
                }
                TypefluxSettingsRow("Learn new words", description: "You can remove learned words at any time.") {
                    TypefluxSwitch("Learn new words", isOn: $toggle, labelsHidden: true)
                }
            }
            TypefluxFormSection("Advanced") {
                TypefluxNavigationRow("Shortcuts", systemImage: "keyboard", color: .teal, detail: "6") {
                    actionCount += 1
                }
                TypefluxNavigationRow("Personas", systemImage: "sparkles", color: .purple) { actionCount += 1 }
            }
        }.frame(height: 420)
    }
}
