import Foundation

/// Starting points for a new workflow: a script that prints text in Python, Node
/// or zsh, and a zsh script that only does something.
enum AskWorkflowTemplate: String, CaseIterable, Identifiable, Sendable {
    case pythonText, nodeText, shellText, shellAction

    var id: String { rawValue }

    var title: String { L("ask.workflow.template." + rawValue) }

    var runtime: AskWorkflowRuntime {
        switch self {
        case .pythonText: .python3
        case .nodeText: .node
        case .shellText, .shellAction: .zsh
        }
    }

    var slug: String {
        switch self {
        case .pythonText: "python"
        case .nodeText: "node"
        case .shellText: "shell"
        case .shellAction: "action"
        }
    }

    var keyword: String { self == .shellAction ? "act" : "wf" }

    var fileName: String {
        switch self {
        case .pythonText: "main.py"
        case .nodeText: "main.js"
        case .shellText, .shellAction: "main.sh"
        }
    }

    func manifest(id: String, keyword: String) -> AskWorkflowManifest {
        AskWorkflowManifest(
            id: id, name: title, description: L("ask.workflow.template.description"),
            keywords: [AskWorkflowManifest.Keyword(keyword: keyword, title: nil, options: nil)],
            input: .init(argument: .optional, selection: .ifEmpty),
            run: .init(mode: .onSubmit, timeoutSeconds: 30),
            command: .init(runtime: runtime, script: fileName, inline: nil, args: ["{query}"], interpreter: nil),
            output: .init(display: self == .shellAction ? .none : .text)
        )
    }

    /// The script, commented in English like the rest of the code, showing every way in.
    var script: String {
        switch self {
        case .pythonText:
            return """
            #!/usr/bin/env python3
            # A Typeflux workflow. The typed text is the first argument; everything else
            # (selection, source app, options) arrives as one JSON line on stdin and as
            # TYPEFLUX_* environment variables. Whatever you print is shown in the launcher.
            import json
            import sys

            request = json.loads(sys.stdin.readline() or "{}")
            query = sys.argv[1] if len(sys.argv) > 1 else ""
            text = query or request.get("selection") or ""

            print(f"{len(text)} characters, {len(text.split())} words")

            """
        case .nodeText:
            return """
            #!/usr/bin/env node
            // A Typeflux workflow. The typed text is the first argument; everything else
            // (selection, source app, options) arrives as one JSON line on stdin and as
            // TYPEFLUX_* environment variables. Whatever you print is shown in the launcher.
            const query = process.argv[2] ?? "";
            let input = "";
            process.stdin.on("data", (chunk) => (input += chunk));
            process.stdin.on("end", () => {
              const request = JSON.parse(input || "{}");
              const text = query || request.selection || "";
              console.log(text.toUpperCase());
            });

            """
        case .shellText:
            return """
            #!/bin/zsh
            # A Typeflux workflow. The typed text is $1; the selection is in
            # $TYPEFLUX_SELECTION. Whatever you print is shown in the launcher.
            text="${1:-$TYPEFLUX_SELECTION}"
            print -r -- "$text" | rev

            """
        case .shellAction:
            return """
            #!/bin/zsh
            # A Typeflux workflow that only does something: it prints nothing, so the
            # launcher closes when it finishes. A non-zero exit shows the error instead.
            # This one reads the text aloud.
            say -- "${1:-$TYPEFLUX_SELECTION}"

            """
        }
    }
}
