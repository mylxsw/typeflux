import SwiftUI

struct MCPServerImportSheet: View {
    @Binding var text: String
    let existingNames: [String]
    let cancel: () -> Void
    let confirm: ([MCPServerConfig]) -> Void

    var body: some View {
        let parsed = Result(catching: { try MCPServerImport.parse(text, existingNames: existingNames) })
        let servers = (try? parsed.get())?.servers ?? []
        TypefluxSheet(title: L("agent.mcp.import.title"), cancelTitle: L("common.cancel"),
                      confirmTitle: L("agent.mcp.import.confirm"), isConfirmEnabled: !servers.isEmpty,
                      scrollsContent: true,
                      cancel: cancel, confirm: { confirm(servers) }, content: {
                          Text(L("agent.mcp.import.hint")).font(.body).foregroundStyle(.secondary)
                          TextEditor(text: $text).font(.body.monospaced()).frame(height: 180)
                              .multilineTextAlignment(.leading)
                              .accessibilityLabel(L("agent.mcp.import.title"))
                          if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                              switch parsed {
                              case let .success(result):
                                  if !result.servers.isEmpty {
                                      Text(L("agent.mcp.import.preview", result.servers.count,
                                             result.servers.map(\.name).joined(separator: L("agent.listSeparator"))))
                                          .font(.subheadline)
                                  }
                                  if !result.skipped.isEmpty {
                                      Text(L(
                                          "agent.mcp.import.skipped",
                                          result.skipped.joined(separator: L("agent.listSeparator"))
                                      ))
                                      .font(.subheadline).foregroundStyle(TypefluxColor.warning.color)
                                  }
                              case let .failure(error):
                                  Text(error.localizedDescription).font(.subheadline)
                                      .foregroundStyle(TypefluxColor.danger.color)
                              }
                          }
                      }).frame(width: 520)
    }
}
