import os

/// Signposts around the clipboard panel's hot paths, visible in Instruments under
/// "ai.gulu.app.typeflux / Clipboard".
enum ClipboardPerformance {
    private static let signposter = OSSignposter(subsystem: "ai.gulu.app.typeflux", category: "Clipboard")

    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}
