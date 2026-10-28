import AppKit

/// Gives bounded module retirement a foreground lifetime during ordinary quit.
/// applicationWillTerminate alone is too late to persist a clean stop reliably.
@MainActor
final class AppTerminationBarrier {
    private var task: Task<Void, Never>?

    nonisolated init() {}

    func beginChecked(cleanup: @escaping @MainActor () async -> Bool,
                      reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        if task == nil {
            task = Task {
                let confirmed = await cleanup()
                reply(confirmed)
                if !confirmed { task = nil }
            }
        }
        return .terminateLater
    }

    func begin(cleanup: @escaping @MainActor () async -> Void,
               reply: @escaping @MainActor () -> Void) -> NSApplication.TerminateReply {
        if task == nil {
            task = Task {
                await cleanup()
                reply()
            }
        }
        return .terminateLater
    }
}
