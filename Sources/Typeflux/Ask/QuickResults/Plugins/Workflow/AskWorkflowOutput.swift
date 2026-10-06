import Foundation

extension AskWorkflowManifest {
    /// What the launcher does with a run: how it shows what the script printed, and
    /// what it does after a run succeeds or fails. See
    /// `docs/design/workflow-gallery-output-actions.md` §3.1.
    ///
    /// `"output": "text"` (the first format) still reads, as a display with no
    /// actions, and is written back that way while it has nothing else to say.
    struct Output: Codable, Equatable, Sendable {
        // swiftlint:disable:next nesting
        enum Display: String, Codable, CaseIterable, Sendable {
            /// Printed text, shown as it arrives.
            case text
            /// Nothing to show: the script does something and the launcher closes.
            case none
            /// `{"items": [...]}` lists as a list, anything else as text.
            case auto
            /// `{"items": [...]}` lists; they come with O3.
            case items
            /// A Markdown card (O3).
            case markdown
            /// An image path or data URL (O4).
            case image

            /// Shown by this version of the launcher.
            var isSupported: Bool {
                self == .text || self == .none || self == .auto
            }
        }

        /// The most actions one list may have.
        static let maximumActions = 8

        var display: Display = .auto
        var onSuccess: [AskWorkflowAction] = []
        var onFailure: [AskWorkflowAction] = []
        /// Close the launcher once the actions ran. A workflow that shows nothing always closes.
        var close = false
        /// Let the script add actions at run time (O4); kept, not yet used.
        var scriptActions = false

        init(display: Display = .auto, onSuccess: [AskWorkflowAction] = [], onFailure: [AskWorkflowAction] = [],
             close: Bool = false, scriptActions: Bool = false) {
            self.display = display
            self.onSuccess = onSuccess
            self.onFailure = onFailure
            self.close = close
            self.scriptActions = scriptActions
        }

        /// Whether the launcher closes after a successful run.
        var closes: Bool {
            display == .none || close
        }

        /// Nothing besides the display: the short string form says it all.
        var isPlain: Bool {
            onSuccess.isEmpty && onFailure.isEmpty && !close && !scriptActions
        }

        // swiftlint:disable:next nesting
        private enum CodingKeys: String, CodingKey {
            case display, onSuccess, onFailure, close, scriptActions
        }

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(), let raw = try? single.decode(String.self) {
                guard let display = Display(rawValue: raw) else {
                    throw DecodingError.dataCorruptedError(in: single, debugDescription: "Unknown output \"\(raw)\".")
                }
                self.init(display: display)
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                display: container.decodeIfPresent(Display.self, forKey: .display) ?? .auto,
                onSuccess: container.decodeIfPresent([AskWorkflowAction].self, forKey: .onSuccess) ?? [],
                onFailure: container.decodeIfPresent([AskWorkflowAction].self, forKey: .onFailure) ?? [],
                close: container.decodeIfPresent(Bool.self, forKey: .close) ?? false,
                scriptActions: container.decodeIfPresent(Bool.self, forKey: .scriptActions) ?? false
            )
        }

        func encode(to encoder: Encoder) throws {
            if isPlain {
                var single = encoder.singleValueContainer()
                try single.encode(display.rawValue)
                return
            }
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(display, forKey: .display)
            if !onSuccess.isEmpty {
                try container.encode(onSuccess, forKey: .onSuccess)
            }
            if !onFailure.isEmpty {
                try container.encode(onFailure, forKey: .onFailure)
            }
            if close {
                try container.encode(close, forKey: .close)
            }
            if scriptActions {
                try container.encode(scriptActions, forKey: .scriptActions)
            }
        }

        // MARK: - Validation

        /// What is wrong with the display and the two action lists. Fields name the
        /// row: `output.onSuccess[1]`.
        func problems(folder: URL) -> [Problem] {
            var problems: [Problem] = []
            switch display {
            case .items: problems.append(Problem(field: "output", message: L("ask.workflow.problem.items")))
            case .markdown, .image:
                problems.append(Problem(field: "output", message: L("ask.workflow.problem.display", display.rawValue)))
            case .text, .none, .auto: break
            }
            for (list, actions) in [("onSuccess", onSuccess), ("onFailure", onFailure)] {
                if actions.count > Self.maximumActions {
                    problems.append(Problem(field: "output." + list,
                                            message: L("ask.workflow.problem.tooManyActions", Self.maximumActions)))
                }
                for (index, action) in actions.enumerated() {
                    if let message = action.problem(folder: folder, failure: list == "onFailure") {
                        problems.append(Problem(field: "output.\(list)[\(index)]", message: message))
                    }
                }
            }
            return problems
        }
    }
}
