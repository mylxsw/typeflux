import Foundation
import SwiftUI

/// Keep the trace about what happened, not a repeated result code or duplicate path.
enum AskActivityRowPresentation {
    static func command(_ call: AskToolCall) -> String? {
        guard ["run_command", "command_job"].contains(call.function.name),
              let args = try? AskLocalTools.jsonArguments(call.function.arguments),
              let command = args["command"] as? String, !command.isEmpty else { return nil }
        return command
    }

    static func title(_ call: AskToolCall) -> String {
        if let command = command(call) {
            return L("ask.tool.run_command") + " " + String(command.prefix(300)).replacingOccurrences(of: "\n", with: " ")
        }
        if call.function.name == "files", let args = try? AskLocalTools.jsonArguments(call.function.arguments),
           let action = args["action"] as? String, ["list", "read", "search", "write", "edit"].contains(action) {
            let path = (args["path"] as? String).map { String($0.prefix(240)) } ?? ""
            let query = action == "search" ? (args["query"] as? String).map { String($0.prefix(120)) } : nil
            return [L("ask.files.action." + action), query, path.isEmpty ? nil : path]
                .compactMap { $0 }.joined(separator: " ")
        }
        return AskTheme.toolTitle(call)
    }

    static func groupTitle(_ group: AskActivityGroup) -> String {
        var seen = Set<String>()
        let titles = group.steps.compactMap { call -> String? in
            let category = AskActivity.Category.of(call.function.name)
            let key = category == .other ? call.function.name : category.rawValue
            guard seen.insert(key).inserted else { return nil }
            return category == .other ? AskActivity.toolName(call) : category.title
        }
        return titles.isEmpty ? L("ask.tool.update_plan") : titles.joined(separator: " · ")
    }
}

/// Legacy/direct block callers still get readable narration without an extra labelled row.
struct AskActivityNarration: View {
    let text: String
    @State private var expanded = false
    @State private var hovering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(alignment: .top) {
                    Text(String(text.prefix(600))).lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                        .opacity(hovering ? 1 : 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .font(.system(size: 13.5))
            .foregroundStyle(StudioTheme.textPrimary)
            if expanded { AskReasoningText(text: text) }
        }
        .padding(.vertical, 6)
    }
}
