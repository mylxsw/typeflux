import AppKit
import SwiftUI

struct SemanticIndexDiagnosticsView: View {
    let diagnostics: SemanticIndexDiagnostics
    let pasteboard: NSPasteboard
    @State private var expanded: Bool

    init(diagnostics: SemanticIndexDiagnostics, expanded: Bool = false, pasteboard: NSPasteboard = .general) {
        self.diagnostics = diagnostics; self.pasteboard = pasteboard
        self._expanded = State(initialValue: expanded)
    }

    var body: some View {
        DisclosureGroup(L("semantic.diagnostics"), isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("semantic.reason." + diagnostics.reason.rawValue) + " · " +
                    L("semantic.stage." + diagnostics.stage.rawValue))
                Text(L("semantic.generation", String(diagnostics.id.prefix(8))))
                ForEach(SemanticIndexDiagnostics.Counter.allCases, id: \.rawValue) { counter in
                    HStack {
                        Text(L("semantic.counter." + counter.rawValue))
                        Spacer()
                        Text((diagnostics.counters[counter.rawValue] ?? 0).formatted()).monospacedDigit()
                    }
                }
                Button(L("semantic.diagnostics.copy")) {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.dateEncodingStrategy = .iso8601
                    guard let data = try? encoder.encode(diagnostics),
                          let value = String(data: data, encoding: .utf8) else { return }
                    pasteboard.clearContents(); pasteboard.setString(value, forType: .string)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(TFColors.textSecondary)
            .padding(.top, 6)
        }
        .accessibilityIdentifier("semantic.diagnostics")
    }
}
