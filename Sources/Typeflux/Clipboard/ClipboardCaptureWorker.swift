import AppKit
import Darwin

protocol ClipboardCaptureWorking: AnyObject {
    func capture(changeCount: Int, plainTextOnly: Bool,
                 cancelled: @escaping @Sendable () -> Bool) throws -> ClipboardCapture?
}

struct ClipboardWorkerResponse: Codable {
    var version = 1
    var changeCount: Int
    var capture: ClipboardCapture?

    var isValid: Bool {
        guard version == 1 else { return false }
        switch capture {
        case nil: return true
        case let .text(text): return ClipboardCaptureRules.isWithinBudget(.init(string: text))
        case let .files(urls):
            return urls.allSatisfy(\.isFileURL) && ClipboardCaptureRules.isWithinBudget(.init(fileURLs: urls))
        case let .image(data, width, height):
            return data.count <= ClipboardCaptureRules.maximumImageBytes
                && ClipboardCaptureRules.acceptsDimensions(width: Int64(width), height: Int64(height))
        }
    }
}

/// One disposable child per new clipboard change. A failed input is never replayed;
/// the next eligible change gets a fresh process, subject to the recovery budget.
/// Used exclusively by ClipboardMonitor's serial work queue.
final class ClipboardCaptureWorker: ClipboardCaptureWorking {
    private let executable: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    private let uptime: () -> TimeInterval
    private var recovery = ModuleRecoveryBudget()

    init(executable: URL = AskFileReader.executableURL,
         arguments: [String] = ["clipboard-capture-worker", NSPasteboard.Name.general.rawValue],
         timeout: TimeInterval = 5,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        self.uptime = uptime
    }

    func capture(changeCount: Int, plainTextOnly: Bool,
                 cancelled: @escaping @Sendable () -> Bool) throws -> ClipboardCapture? {
        guard recovery.permitsAttempt(at: uptime()) else { throw CocoaError(.featureUnsupported) }
        let directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(directory) }
        do {
            let result = try ManagedProcess().runBlocking(.init(
                executable: executable.path,
                arguments: arguments + [String(changeCount), plainTextOnly ? "plain" : "all"],
                environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"],
                directoryDescriptor: directory, timeout: timeout,
                outputLimit: 16 * 1024 * 1024, stopOnOutputLimit: true, preserveWhitespace: true,
                stderrLimit: 4096, immediateCleanupOnExit: true
            ), isCancelled: cancelled)
            if result.termination == .cancelled || cancelled() {
                throw CancellationError()
            }
            guard result.exitCode == 0, result.termination == .exited(0), !result.outputTruncated else {
                throw CocoaError(.coderReadCorrupt)
            }
            let response = try JSONDecoder().decode(ClipboardWorkerResponse.self, from: Data(result.stdout.utf8))
            guard response.changeCount == changeCount, response.isValid else { throw CocoaError(.coderReadCorrupt) }
            recovery.succeeded(at: uptime())
            return response.capture
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            recovery.failed(at: uptime())
            // Content and subprocess output can be private; never include them.
            ErrorLogStore.shared.log("Clipboard capture worker unavailable; skipped this clipboard change.")
            throw error
        }
    }
}

/// Runs before the app coordinator starts, so decoding faults stay in this child.
public enum ClipboardCaptureWorkerCommand {
    public static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 3, let changeCount = Int(arguments[1]),
              ["plain", "all"].contains(arguments[2]) else { return 2 }
        let board = NSPasteboard(name: NSPasteboard.Name(arguments[0]))
        let response = capture(pasteboard: SystemPasteboardReader(pasteboard: board),
                               changeCount: changeCount, plainTextOnly: arguments[2] == "plain")
        do {
            try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(response))
            return 0
        } catch { return 1 }
    }

    static func capture(pasteboard: any PasteboardReading, changeCount: Int,
                        plainTextOnly: Bool) -> ClipboardWorkerResponse {
        guard pasteboard.changeCount == changeCount else { return .init(changeCount: changeCount) }
        let contents = pasteboard.readContents()
        guard pasteboard.changeCount == changeCount else { return .init(changeCount: changeCount) }
        let capture = ClipboardCaptureRules.capture(from: contents, plainTextOnly: plainTextOnly)
        // Do not publish a slow read/decoder result after the clipboard changed.
        return .init(changeCount: changeCount, capture: pasteboard.changeCount == changeCount ? capture : nil)
    }
}
