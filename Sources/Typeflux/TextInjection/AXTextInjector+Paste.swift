import AppKit
import ApplicationServices
import Foundation

// swiftlint:disable closure_parameter_position file_length function_body_length
// swiftlint:disable identifier_name line_length
extension AXTextInjector {
    func readSelectedTextViaCopy(processID: pid_t?, milliseconds: Int) -> String? {
        let processScopedResult = readSelectedTextViaCopy(
            milliseconds: milliseconds,
            pasteboard: .general,
            sendCopy: { sendCopyShortcut(to: processID) }
        )
        if let processScopedResult {
            return processScopedResult
        }

        guard let processID, frontmostProcessID() == processID else { return nil }
        NetworkDebugLogger.logMessage(
            "[Text Selection] process-scoped copy did not respond; retrying through HID event tap"
        )
        return readSelectedTextViaCopy(
            milliseconds: milliseconds,
            pasteboard: .general,
            sendCopy: { sendCopyShortcutViaHID() }
        )
    }

    func readSelectedTextViaCopy(
        milliseconds: Int,
        pasteboard: NSPasteboard,
        sendCopy: () -> Void
    ) -> String? {
        guard let previousSnapshot = capturePasteboardSnapshotWithTimeout(from: pasteboard) else {
            NetworkDebugLogger.logMessage(
                "[Text Selection] clipboard-copy skipped because the clipboard could not be preserved"
            )
            return nil
        }
        guard pasteboard.changeCount == previousSnapshot.changeCount else {
            NetworkDebugLogger.logMessage(
                "[Text Selection] clipboard-copy skipped because the clipboard changed before probing"
            )
            return nil
        }

        let probeType = NSPasteboard.PasteboardType("ai.gulu.app.typeflux.selection-probe")
        pasteboard.clearContents()
        guard pasteboard.setData(Data(UUID().uuidString.utf8), forType: probeType) else {
            restorePasteboardIfUnchanged(
                previousSnapshot,
                to: pasteboard,
                expectedChangeCount: pasteboard.changeCount
            )
            return nil
        }

        var transactionChangeCount = pasteboard.changeCount
        defer {
            restorePasteboardIfUnchanged(
                previousSnapshot,
                to: pasteboard,
                expectedChangeCount: transactionChangeCount
            )
        }

        sendCopy()

        let timeout = Date().addingTimeInterval(Double(milliseconds) / 1000.0)
        while Date() < timeout {
            if pasteboard.changeCount != transactionChangeCount {
                transactionChangeCount = pasteboard.changeCount
                let copiedText = readPasteboardStringWithTimeout(from: pasteboard)
                let trimmed = copiedText?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? copiedText : nil
            }
            usleep(10000)
        }

        return nil
    }

    func restorePasteboardIfUnchanged(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: NSPasteboard,
        expectedChangeCount: Int
    ) {
        guard pasteboard.changeCount == expectedChangeCount else {
            NetworkDebugLogger.logMessage(
                "[Text Selection] clipboard restore skipped because it changed after probing"
            )
            return
        }
        restorePasteboard(snapshot, to: pasteboard)
    }

    /// Pasteboard owners can provide data lazily and may block indefinitely. Read on a
    /// dedicated serial queue so a broken provider cannot freeze Typeflux's main thread.
    /// Once that queue is wedged, later reads still time out without creating more workers.
    func readPasteboardStringWithTimeout(from pasteboard: NSPasteboard) -> String? {
        let result = LockedPasteboardStringResult()
        let completed = DispatchSemaphore(value: 0)
        let pasteboardReference = UncheckedSendableReference(pasteboard)
        pasteboardReadQueue.async {
            result.store(pasteboardReference.value.string(forType: .string))
            completed.signal()
        }
        guard completed.wait(
            timeout: .now() + .milliseconds(Self.pasteboardReadTimeoutMilliseconds)
        ) == .success else {
            NetworkDebugLogger.logMessage("[Text Injection] pasteboard string read timed out")
            return nil
        }
        return result.load()
    }

    func sendCopyShortcut(to processID: pid_t?) {
        postCopyShortcut { event in
            if let processID {
                event.postToPid(processID)
            } else {
                event.post(tap: .cghidEventTap)
            }
        }
    }

    func sendCopyShortcutViaHID() {
        postCopyShortcut { $0.post(tap: .cghidEventTap) }
    }

    private func postCopyShortcut(post: (CGEvent) -> Void) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(
            keyboardEventSource: source,
            virtualKey: Self.copyShortcutKeyCode,
            keyDown: true
        )
        down?.flags = .maskCommand
        let up = CGEvent(
            keyboardEventSource: source,
            virtualKey: Self.copyShortcutKeyCode,
            keyDown: false
        )
        up?.flags = .maskCommand

        if let down { post(down) }
        if let up { post(up) }
    }

    func capturePasteboardSnapshotWithTimeout(from pasteboard: NSPasteboard) -> PasteboardSnapshot? {
        let result = LockedPasteboardSnapshotResult()
        let completed = DispatchSemaphore(value: 0)
        let pasteboardReference = UncheckedSendableReference(pasteboard)
        pasteboardSnapshotQueue.async {
            result.store(Self.capturePasteboardSnapshot(
                from: pasteboardReference.value,
                maximumBytes: Self.maximumPasteboardSnapshotBytes
            ))
            completed.signal()
        }
        guard completed.wait(
            timeout: .now() + .milliseconds(Self.pasteboardSnapshotTimeoutMilliseconds)
        ) == .success else {
            NetworkDebugLogger.logMessage("[Text Injection] pasteboard snapshot timed out")
            return nil
        }
        guard let snapshot = result.load() else {
            NetworkDebugLogger.logMessage("[Text Injection] pasteboard snapshot exceeded size limit")
            return nil
        }
        return snapshot
    }

    static func capturePasteboardSnapshot(
        from pasteboard: NSPasteboard,
        maximumBytes: Int
    ) -> PasteboardSnapshot? {
        guard maximumBytes >= 0 else { return nil }
        let initialChangeCount = pasteboard.changeCount
        var totalBytes = 0
        var capturedItems: [PasteboardItemSnapshot] = []

        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [(type: NSPasteboard.PasteboardType, data: Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                guard data.count <= maximumBytes - totalBytes else { return nil }
                totalBytes += data.count
                representations.append((type: type, data: data))
            }
            capturedItems.append(PasteboardItemSnapshot(representations: representations))
        }

        guard pasteboard.changeCount == initialChangeCount else { return nil }
        return PasteboardSnapshot(changeCount: initialChangeCount, items: capturedItems)
    }

    func writeTransientPasteboardString(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string),
              item.setData(Data(), forType: Self.transientPasteboardType)
        else { return false }

        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    func restorePasteboard(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()

        guard !snapshot.items.isEmpty else { return }

        let restoredItems = snapshot.items.map { snapshotItem in
            let item = NSPasteboardItem()
            for representation in snapshotItem.representations {
                item.setData(representation.data, forType: representation.type)
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }

}
