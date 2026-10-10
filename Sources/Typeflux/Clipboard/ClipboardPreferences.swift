import Foundation

/// How long unpinned clipboard items are kept. Separate from the voice history's retention.
enum ClipboardRetention: Int, CaseIterable, Identifiable {
    case oneDay = 1
    case oneWeek = 7
    case oneMonth = 30
    case threeMonths = 90
    case oneYear = 365
    case forever = 0

    var id: Int { rawValue }

    /// `nil` keeps items until the item limit removes them.
    var days: Int? {
        self == .forever ? nil : rawValue
    }

    var title: String {
        switch self {
        case .oneDay: L("clipboard.settings.retention.oneDay")
        case .oneWeek: L("clipboard.settings.retention.oneWeek")
        case .oneMonth: L("clipboard.settings.retention.oneMonth")
        case .threeMonths: L("clipboard.settings.retention.threeMonths")
        case .oneYear: L("clipboard.settings.retention.oneYear")
        case .forever: L("clipboard.settings.retention.forever")
        }
    }

    /// The clipboard used to follow the voice history's retention; keep that choice for users
    /// who never picked a clipboard-specific one. "Don't keep history" kept one day of clipboard.
    static func migrated(from policy: HistoryRetentionPolicy) -> ClipboardRetention {
        switch policy {
        case .never, .oneDay: .oneDay
        case .oneWeek: .oneWeek
        case .oneMonth: .oneMonth
        case .forever: .forever
        }
    }
}

/// Upper bound for the disk space copied images take, oldest removed first.
enum ClipboardStorageLimit: Int, CaseIterable, Identifiable {
    case megabytes500 = 500
    case gigabyte1 = 1024
    case gigabytes2 = 2048
    case unlimited = 0

    var id: Int { rawValue }

    var bytes: Int64? {
        self == .unlimited ? nil : Int64(rawValue) * 1024 * 1024
    }

    var title: String {
        switch self {
        case .unlimited: L("clipboard.settings.storage.unlimited")
        default: ByteCountFormatter.string(fromByteCount: bytes ?? 0, countStyle: .memory)
        }
    }
}

/// Where the clipboard panel opens.
enum ClipboardPanelPosition: String, CaseIterable, Identifiable {
    /// Under the launcher's top edge, on the screen with the mouse.
    case launcher
    case screenCenter
    /// Centered on the mouse pointer.
    case mouse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .launcher: L("clipboard.settings.position.launcher")
        case .screenCenter: L("clipboard.settings.position.center")
        case .mouse: L("clipboard.settings.position.mouse")
        }
    }
}

/// How long "Pause recording" lasts.
enum ClipboardPauseDuration: CaseIterable, Identifiable {
    case fifteenMinutes
    case oneHour
    case untilResumed

    var id: Self { self }

    var interval: TimeInterval? {
        switch self {
        case .fifteenMinutes: 15 * 60
        case .oneHour: 60 * 60
        case .untilResumed: nil
        }
    }

    var title: String {
        switch self {
        case .fifteenMinutes: L("clipboard.settings.pause.fifteenMinutes")
        case .oneHour: L("clipboard.settings.pause.oneHour")
        case .untilResumed: L("clipboard.settings.pause.untilResumed")
        }
    }
}

/// What the clipboard monitor records, read on every capture so settings apply at once.
struct ClipboardCapturePolicy: Equatable {
    var isRecording = true
    var plainTextOnly = false
    var maxItemCount = ClipboardMonitor.maximumItemCount
    var maxImageBytes: Int64?
    /// Copies made while one of these apps is frontmost are not recorded.
    var ignoredBundleIDs: Set<String> = []

    static let `default` = ClipboardCapturePolicy()
}

enum ClipboardItemLimit {
    static let options = [200, 500, 1000, 2000, 5000]
}
