import AppKit
import AVFoundation
import SQLite3
import Testing
@testable import Typeflux

@Suite("Sustained real indexing and native desktop response", .serialized, .exclusiveUIState)
@MainActor
struct SemanticResourceBudgetTests {
    private nonisolated static func finalSnapshot(_ url: URL) throws -> [String: Int] {
        var database: OpaquePointer?
        try #require(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) ==
            SQLITE_OK)
        defer { sqlite3_close(database) }
        try #require(sqlite3_exec(database, "BEGIN", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        let queries = [
            "published_vectors": "SELECT count(*) FROM chunks WHERE length(vector)=3072",
            "pending_vectors": "SELECT count(*) FROM vector_pending",
            "saved_media_segments": "SELECT count(*) FROM media_segments",
            "queued_documents": "SELECT count(*) FROM work_queue WHERE priority=0",
            "queued_images": "SELECT count(*) FROM work_queue WHERE priority=1",
            "queued_audio": "SELECT count(*) FROM work_queue WHERE priority=2",
            "queued_video": "SELECT count(*) FROM work_queue WHERE priority=3",
            "jobs_done": "SELECT count(*) FROM jobs WHERE state='done'",
            "jobs_partial": "SELECT count(*) FROM jobs WHERE state='partial'",
            "jobs_pending": "SELECT count(*) FROM jobs WHERE state='pending'",
            "jobs_failed": "SELECT count(*) FROM jobs WHERE state='failed'",
            "subtree_requests": "SELECT count(*) FROM scan_requests"
        ]
        var result: [String: Int] = [:]
        for (key, sql) in queries {
            var row: OpaquePointer?
            try #require(sqlite3_prepare_v2(database, sql, -1, &row, nil) == SQLITE_OK)
            defer { sqlite3_finalize(row) }
            try #require(sqlite3_step(row) == SQLITE_ROW)
            result[key] = Int(sqlite3_column_int64(row, 0))
        }
        return result
    }

    private func process(_ binary: String, _ arguments: [String]) throws {
        let child = Process(); child.executableURL = URL(fileURLWithPath: binary); child.arguments = arguments
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run(); child.waitUntilExit(); try #require(child.terminationStatus == 0)
    }

    private func templates(_ folder: URL) async throws {
        let image = NSImage(size: NSSize(width: 640, height: 360))
        image.lockFocus(); NSColor.systemBlue.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 640, height: 360))
            .fill()
        ("A blue mountain lake under a clear sky. Reimbursement receipts." as NSString).draw(at: .init(x: 20, y: 160),
                                                                                             withAttributes: [
                                                                                                 .font: NSFont
                                                                                                     .systemFont(
                                                                                                         ofSize: 22
                                                                                                     ),
                                                                                                 .foregroundColor: NSColor
                                                                                                     .white
                                                                                             ])
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let representation = try #require(NSBitmapImageRep(data: tiff))
        try #require(representation.representation(using: .png, properties: [:]))
            .write(to: folder.appendingPathComponent("image.png"))
        try process(
            "/usr/bin/say",
            ["-v", "Samantha", "-o", folder.appendingPathComponent("speech.aiff").path,
             "Employees submit project expense reimbursement requests using the finance form. Attach receipts and obtain manager approval. Gardeners water tomato plants twice weekly. Engineers inspect the cooling pump every morning."]
        )
        try process("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                                           folder.appendingPathComponent("speech.aiff").path,
                                           folder.appendingPathComponent("speech.wav").path])
        let writer = try AVAssetWriter(outputURL: folder.appendingPathComponent("video.mov"), fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                           AVVideoWidthKey: 640, AVVideoHeightKey: 360])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: [
                                                               kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                                               kCVPixelBufferWidthKey as String: 640,
                                                               kCVPixelBufferHeightKey as String: 360
                                                           ])
        try #require(writer.canAdd(input)); writer.add(input); try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0 ..< 24 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            var pixel: CVPixelBuffer?
            try #require(CVPixelBufferPoolCreatePixelBuffer(nil, #require(adaptor.pixelBufferPool), &pixel) ==
                kCVReturnSuccess)
            let value = try #require(pixel); CVPixelBufferLockBaseAddress(value, [])
            let context = try #require(CGContext(data: CVPixelBufferGetBaseAddress(value), width: 640, height: 360,
                                                 bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(value),
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
            try context.draw(#require(representation.cgImage), in: CGRect(x: 0, y: 0, width: 640, height: 360))
            CVPixelBufferUnlockBaseAddress(value, [])
            try #require(adaptor.append(value, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        input.markAsFinished(); await writer.finishWriting(); try #require(writer.status == .completed)
    }

    @Test func `fifteen minute off on comparison when explicitly requested`() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let folderName = env["TYPEFLUX_RESOURCE_REPORT"], let model = env["TYPEFLUX_RESOURCE_MODEL"],
              let projector = env["TYPEFLUX_RESOURCE_PROJECTOR"],
              let helper = env["TYPEFLUX_RESOURCE_HELPER"],
              let probePath = env["TYPEFLUX_RESOURCE_PROBE"] else { return }
        let duration = Double(env["TYPEFLUX_RESOURCE_SECONDS"] ?? "900") ?? 900
        try #require(duration >= 900, "formal resource evidence requires at least fifteen minutes per condition")
        _ = NSApplication.shared
        let root = try semanticFixture(), assets = root.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await templates(assets)
        var report: [[String: Any]] = []
        for enabled in [false, true] {
            let condition = enabled ? "index-on" : "index-off"
            let corpus = root.appendingPathComponent(condition),
                state = root.appendingPathComponent(condition + "-state")
            try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            try FileManager.default.linkItem(
                at: URL(fileURLWithPath: model),
                to: state.appendingPathComponent("embeddinggemma-2-Q8_0.gguf")
            )
            try FileManager.default.linkItem(
                at: URL(fileURLWithPath: projector),
                to: state.appendingPathComponent(SemanticMediaModel.name)
            )
            let suite = "budget-reference-" + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsStore(defaults: defaults)
            var names = AskLauncherSearchSettings(); names.fileRoots = [corpus.path]; names.excludedPaths = []
            settings.askLauncherSearchSettings = names
            let service = SemanticFileSearchService(
                settings: settings,
                directory: state,
                helper: URL(fileURLWithPath: helper),
                supported: true,
                automaticStart: false,
                lowPowerMode: { false }
            )
            try FileManager.default.createDirectory(atPath: folderName, withIntermediateDirectories: true)
            let responseURL = URL(fileURLWithPath: folderName).appendingPathComponent(condition + "-response.json")
            let probe = Process(); probe.executableURL = URL(fileURLWithPath: probePath)
            probe.arguments = [responseURL.path, String(duration + 3)]
            let logURL = URL(fileURLWithPath: folderName).appendingPathComponent(condition + "-probe.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)
            defer {
                if probe.isRunning {
                    probe.terminate(); probe.waitUntilExit()
                }; try? log.close()
            }
            probe.standardOutput = log; probe.standardError = log
            try probe.run()
            let readyDeadline = ContinuousClock.now + .seconds(8)
            while !FileManager.default.fileExists(atPath: responseURL.path), probe.isRunning,
                  ContinuousClock.now < readyDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(FileManager.default.fileExists(atPath: responseURL.path) && probe.isRunning,
                         "Standalone native response probe did not become ready")
            let started = ProcessInfo.processInfo.systemUptime
            let startedWall = Date().timeIntervalSince1970
            var nextFile = started, supplied = 0
            var progress: [[String: Any]] = []
            do {
                if enabled {
                    try #require(service.setEnabled(true))
                }
                while ProcessInfo.processInfo.systemUptime - started < duration {
                    let now = ProcessInfo.processInfo.systemUptime
                    try #require(probe.isRunning, "Native response probe stopped before this condition completed")
                    if now >= nextFile {
                        let number = supplied
                        try (String(repeating: "Project \(number) travel receipts and finance approval. ", count: 500) +
                            " tail marker \(number)")
                            .write(
                                to: corpus.appendingPathComponent("document-\(number).txt"),
                                atomically: true,
                                encoding: .utf8
                            )
                        for (source, ext) in [("image.png", "png"), ("speech.wav", "wav"), ("video.mov", "mov")] {
                            try FileManager.default.copyItem(
                                at: assets.appendingPathComponent(source),
                                to: corpus.appendingPathComponent("media-\(number)." + ext)
                            )
                        }
                        supplied += 1; nextFile += 30
                        try progress.append([
                            "seconds": now - started,
                            "supplied_files": supplied * 4,
                            "published_files": service.files,
                            "published_chunks": service.chunks,
                            "thermal": ProcessInfo.processInfo.thermalState.rawValue,
                            "phase": String(describing: service.phase),
                            "diagnostics": service.diagnostics.map {
                                try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
                            } ?? NSNull()
                        ])
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                try await Task.sleep(for: .seconds(1))
                let probeDeadline = ContinuousClock.now + .seconds(10)
                while probe.isRunning,
                      ContinuousClock.now < probeDeadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                try #require(!probe.isRunning && probe.terminationStatus == 0, "Native response probe did not finish")
                let nativeReport = try #require(JSONSerialization
                    .jsonObject(with: Data(contentsOf: responseURL)) as? [String: Any])
                let storage = try SemanticFileStore(url: state.appendingPathComponent("semantic-files.sqlite"))
                let counts = try storage.counts()
                let databaseURL = storage.url
                let snapshot = try await Task.detached(priority: .utility) { try Self.finalSnapshot(databaseURL) }.value
                try report.append([
                    "condition": condition,
                    "started_unix": startedWall, "started_uptime": started,
                    "duration_seconds": ProcessInfo.processInfo.systemUptime - started,
                    "response_probe": nativeReport,
                    "inputs": nativeReport["inputs"] ?? [],
                    "progress": progress,
                    "supplied_files": supplied * 4,
                    "final_database_snapshot": snapshot,
                    "final_diagnostics": service.diagnostics.map {
                        try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
                    } ?? NSNull(),
                    "published": [
                        "documents": counts.documents,
                        "images": counts.images,
                        "audio": counts.audio,
                        "videos": counts.videos,
                        "chunks": counts.chunks
                    ],
                    "events": "Standalone native AppKit application using NSApplication.run. CGEvent.postToPid -> NSResponder -> Metal GPU completion and, when available, drawable presentedTime. A zero presentedTime stays null; GPU completion is substitute evidence, not an onscreen presentation claim. Only generated event IDs are recorded."
                ])
                await service.clear(); defaults.removePersistentDomain(forName: suite)
                try FileManager.default.createDirectory(atPath: folderName, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                    .write(
                        to: URL(fileURLWithPath: folderName).appendingPathComponent("native-resource.json"),
                        options: .atomic
                    )
            } catch {
                if probe.isRunning {
                    probe.terminate(); probe.waitUntilExit()
                }
                await service.clear(); defaults.removePersistentDomain(forName: suite)
                let partial: [String: Any] = [
                    "condition": condition,
                    "started_unix": startedWall,
                    "started_uptime": started,
                    "incomplete": true,
                    "response_probe_file": responseURL.lastPathComponent,
                    "progress": progress,
                    "elapsed_seconds": ProcessInfo.processInfo.systemUptime - started
                ]
                try? FileManager.default.createDirectory(atPath: folderName, withIntermediateDirectories: true)
                if let data = try? JSONSerialization.data(withJSONObject: partial, options: [.sortedKeys]) {
                    try? data
                        .write(to: URL(fileURLWithPath: folderName)
                            .appendingPathComponent("native-resource-incomplete.json"))
                }
                throw error
            }
        }
    }
}
