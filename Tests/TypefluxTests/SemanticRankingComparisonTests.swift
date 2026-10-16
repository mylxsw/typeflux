// Nested capture DTOs mirror the frozen JSON fixture schema.
import Foundation
import Testing
@testable import Typeflux

/// The same harness also compiles against the pre-change store in a detached baseline checkout.
@Suite("Baseline-compatible frozen ranking comparison", .serialized)
struct SemanticRankingComparisonTests {
    struct Capture: Decodable {
        // swiftlint:disable:next nesting
        struct Document: Decodable {
            var id: String; var kind: String; var text: String; var vector: [Float]; var duration: Double
        }

        // swiftlint:disable:next nesting
        struct Query: Decodable {
            var id: String; var group: String; var query: String; var expected: [String]; var vector: [Float]
        }

        var documents: [Document]
        var queries: [Query]
    }

    // Keep the complete baseline-compatible replay in one scenario.
    // swiftlint:disable:next function_body_length
    @Test func `compare frozen corpus when requested`() throws {
        guard ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_RANKING_COMPARISON"] == "1" else { return }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let folder = repository.appendingPathComponent("docs/validation/gul-383/optimization/ranking-scale")
        for fixture in ["final-holdout", "unseen-query"] {
            let capture = try JSONDecoder().decode(
                Capture.self,
                from: Data(contentsOf: folder.appendingPathComponent("\(fixture)-vectors.json"))
            )
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("ranking-comparison-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            var names = AskLauncherSearchSettings(); names.fileRoots = [root.path]; names.excludedPaths = []
            let scope = SemanticFilePolicy.scope(names: names, fullDiskAccess: true)
            let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
            for document in capture.documents {
                let ext = document.kind == "text" ? ".txt" : (document.kind == "audio" ? ".wav" : ".png")
                let path = root.path + "/" + document.id + ext
                if document.kind == "text" {
                    try store.replace(
                        path: path,
                        modified: Date(),
                        bytes: 1,
                        chunks: [.init(text: document.text, page: nil)],
                        vectors: [document.vector]
                    )
                } else {
                    let metadata = AskFileReadResponse(fileSize: 1, modified: Date(), version: document.id)
                    let generation = try store.beginMediaJob(path: path, metadata: metadata)
                    try store.saveMediaSegment(path: path, generation: generation, ordinal: 0,
                                               input: .init(
                                                   kind: document.kind == "audio" ? .audio : .image,
                                                   path: path,
                                                   time: 0,
                                                   endTime: document.duration
                                               ), vector: document.vector)
                    try #require(try store.commitMediaJob(
                        path: path,
                        generation: generation,
                        metadata: metadata,
                        segments: 1
                    ))
                }
            }
            var rows: [[String: Any]] = []
            let mediaIDs = Set(capture.documents.filter { $0.kind != "text" }.map(\.id))
            for query in capture.queries {
                let hits = try store.search(
                    vector: query.vector,
                    text: query.query,
                    query: .init(query.query),
                    type: .all,
                    scope: scope,
                    limit: 5,
                    cancelled: { false }
                )
                let ids = hits.map { ($0.name as NSString).deletingPathExtension }
                let index = ids.firstIndex { query.expected.contains($0) }
                rows.append(["id": query.id, "group": query.group, "expected": query.expected, "hits": ids,
                             "rank": index.map { $0 + 1 } as Any? ?? NSNull(),
                             "location_correct": index
                                 .map { !mediaIDs.contains(ids[$0]) || hits[$0].evidence?.time == 0 } ?? false])
            }
            let label = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_LABEL"] ?? "after"
            let report: [String: Any] = ["label": label, "fixture": fixture, "rows": rows,
                                         "model_sha256": SemanticModel.sha256,
                                         "projector_sha256": SemanticMediaModel.sha256,
                                         "scope": """
                                         Same fixed real captured vectors and baseline-compatible Swift harness. Store/ranking comparison only. Media fixtures each have one segment at zero; extraction, permission checks and UI are excluded.
                                         """]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("ranking-\(label)-\(fixture).json"))
        }
    }
}
