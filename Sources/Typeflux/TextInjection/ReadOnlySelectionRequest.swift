import AppKit

/// Fixed before showing the launcher. Creating a request must never query an
/// external AX tree or wait for the serialized text-operation queue.
struct ReadOnlySelectionRequest {
    var id = UUID()
    var processID: pid_t?
    var processName: String?
    var bundleIdentifier: String?
    var nativeSnapshot: TextSelectionSnapshot?

    @MainActor
    static func frontmost() -> Self {
        let app = NSWorkspace.shared.frontmostApplication
        return Self(processID: app?.processIdentifier, processName: app?.localizedName,
                    bundleIdentifier: app?.bundleIdentifier)
    }

    func matches(processID current: pid_t?) -> Bool {
        guard let processID else { return false }
        return processID == current
    }

    /// Metadata only: never include selection contents, window titles or AX values.
    func log(status: String, details: [String: Any] = [:]) {
        guard let message = diagnosticMessage(status: status, details: details) else { return }
        NetworkDebugLogger.logMessage("[Ask Selection] \(message)")
    }

    func diagnosticMessage(status: String, details: [String: Any] = [:]) -> String? {
        var fields = details
        fields["captureID"] = id.uuidString
        fields["pid"] = processID
        fields["app"] = processName
        fields["bundleID"] = bundleIdentifier
        fields["status"] = status
        fields["clipboardProbe"] = "disabled"
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let message = String(data: data, encoding: .utf8) else { return nil }
        return message
    }
}

extension TextInjector {
    @MainActor
    func makeReadOnlySelectionRequest() -> ReadOnlySelectionRequest { .frontmost() }

    @MainActor
    func readOnlySelectionSnapshot(for request: ReadOnlySelectionRequest) async -> TextSelectionSnapshot {
        // An injector without pinned-source support must not fall back to reading
        // the new frontmost application after the launcher has taken focus.
        TextSelectionSnapshot(source: "pinned-source-unavailable")
    }
}
