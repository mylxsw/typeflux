import SwiftUI

/// The disabled-by-default entry in the existing launcher settings card.
struct SemanticFileSearchSettingsView: View {
    @ObservedObject var service: SemanticFileSearchService
    var filesEnabled: Bool
    let pickFolders: () -> [String]?
    @State private var presentation: Presentation?
    enum Presentation: String, Identifiable {
        case setup, manage
        var id: String { rawValue }
    }

    init(service: SemanticFileSearchService, filesEnabled: Bool,
         pickFolders: @escaping () -> [String]? = { LauncherSearchSettingsView.pickFolders(allowApps: false) }) {
        self.service = service; self.filesEnabled = filesEnabled; self.pickFolders = pickFolders
    }

    var body: some View {
        ModelSurface {
            VStack(spacing: 0) {
                AgentSettingsRow(icon: "sparkle.magnifyingglass", title: L("semantic.title"),
                                 subtitle: L(self.service.supported ? "semantic.subtitle" : "semantic.unsupported"),
                                 badge: L("semantic.experimental"), subtitleLineLimit: nil) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { self.service.supported && self.service.preferences.enabled },
                            set: { enabled in
                                if enabled { self.presentation = .setup } else { self.service.setEnabled(false) }
                            }
                        )
                    )
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(!self.service.supported || !self.filesEnabled)
                    .accessibilityLabel(L("semantic.title")).accessibilityIdentifier("semantic.enabled")
                }
                if self.service.preferences.enabled, self.service.supported {
                    ModelRowDivider(leading: 66)
                    HStack(spacing: 10) {
                        Circle().fill(self.service.phase == .failed ? Color.orange : StudioTheme.success).frame(
                            width: 6,
                            height: 6
                        )
                        Text(Self.phaseText(self.service)).font(.system(size: 12))
                            .foregroundStyle(StudioTheme.textSecondary)
                        Spacer()
                        Button(L("semantic.manage")) { self.presentation = .manage }.controlSize(.small)
                    }.padding(.horizontal, 18).padding(.vertical, 12)
                }
            }
        }
        .sheet(item: self.$presentation) { mode in
            SemanticFileSearchSheet(service: self.service, setup: mode == .setup, pickFolders: self.pickFolders) {
                self.presentation = nil
            }
        }
    }

    static func phaseText(_ service: SemanticFileSearchService) -> String {
        switch service.phase {
        case .off: L("semantic.off")
        case .preparing: L("semantic.preparing")
        case .modelRequired: L("semantic.modelRequired")
        case let .downloading(progress): L("semantic.downloading", Int(progress * 100))
        case .indexing: L("semantic.indexing", service.files)
        case .ready: L("semantic.ready", service.files)
        case .paused: L("semantic.paused")
        case .failed: L("semantic.failed")
        }
    }

}
