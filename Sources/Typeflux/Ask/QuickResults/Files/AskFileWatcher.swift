import CoreServices
import Foundation

/// A change the file system reported under a watched folder.
struct AskFileChange: Equatable, Sendable {
    var path: String
    /// Events were dropped or merged: everything below `path` must be read again.
    var rescan: Bool
    /// FSEvents reports the entry kind even when the entry has already been removed.
    var isDirectory: Bool?
    /// A directory was created, removed, or renamed, so its children may have changed.
    var structureChanged = false
}

/// Watches folders for changes. The real one is FSEvents; tests drive the index directly.
protocol AskFileWatching: AnyObject {
    /// Starts reporting changes after `since` (an FSEvents event id, or nil for from now on).
    func start(paths: [String], since: UInt64?, onChange: @escaping ([AskFileChange], UInt64) -> Void)
    func stop()
}

/// FSEvents with per-file events, delivered in batches about half a second apart.
/// Starting from the last event id seen means changes made while Typeflux was not
/// running arrive at launch, so the index never needs a full rescan.
final class AskFSEventsWatcher: AskFileWatching {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "typeflux.ask.files.events", qos: .utility)
    private var onChange: (([AskFileChange], UInt64) -> Void)?
    var latency: CFTimeInterval = 0.5
    private let maximumBatchSize: Int?

    init(maximumBatchSize: Int? = nil) {
        self.maximumBatchSize = maximumBatchSize.map { max(1, $0) }
    }

    deinit { stop() }

    func start(paths: [String], since: UInt64?, onChange: @escaping ([AskFileChange], UInt64) -> Void) {
        stop()
        guard !paths.isEmpty else { return }
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let watcher = Unmanaged<AskFSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var changes: [AskFileChange] = []
            var last: UInt64 = 0
            for index in 0 ..< min(count, list.count) {
                let flag = Int(flags[index])
                let rescan = flag & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged) != 0
                if flag & kFSEventStreamEventFlagHistoryDone == 0 {
                    let directory: Bool? = if flag & kFSEventStreamEventFlagItemIsDir != 0 {
                        true
                    } else if flag & kFSEventStreamEventFlagItemIsFile != 0 {
                        false
                    } else {
                        nil
                    }
                    let structureChanged = flag & (kFSEventStreamEventFlagItemCreated
                        | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) != 0
                    changes.append(AskFileChange(path: list[index], rescan: rescan,
                                                 isDirectory: directory, structureChanged: structureChanged))
                }
                last = max(last, ids[index])
                if let size = watcher.maximumBatchSize, changes.count >= size {
                    watcher.onChange?(changes, last)
                    changes.removeAll(keepingCapacity: true)
                }
            }
            if !changes.isEmpty || watcher.maximumBatchSize == nil {
                watcher.onChange?(changes, last)
            }
        }
        let since = since.map { FSEventStreamEventId($0) } ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray, since, latency,
                                               FSEventStreamCreateFlags(flags)) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        onChange = nil
    }

    /// The newest event id on this Mac, to save with an index built from scratch.
    static var currentEventID: UInt64 {
        UInt64(FSEventsGetCurrentEventId())
    }
}
