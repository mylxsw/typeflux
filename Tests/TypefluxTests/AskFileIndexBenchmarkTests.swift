import Foundation
import Testing
@testable import Typeflux

/// How fast the file index answers at the size of a large home folder. Runs only
/// with `TYPEFLUX_SEARCH_BENCH=1`; prints the timings and checks the design's targets
/// (`docs/design/launcher-content-search.md` §3.7) loosely, as machines differ.
@Suite("Ask file index benchmark", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["TYPEFLUX_SEARCH_BENCH"] != nil))
struct AskFileIndexBenchmarkTests {
    static let size = 500_000

    /// Names like a real home folder's: words, numbers, extensions, some Chinese.
    static func makeState() -> AskFileIndexState {
        let words = ["report", "invoice", "notes", "draft", "final", "budget", "design", "meeting", "photo", "IMG",
                     "Screenshot", "README", "index", "main", "test", "config", "合同", "周报", "会议纪要", "设计稿",
                     "presentation", "summary", "project", "roadmap", "backup", "archive", "letter", "resume"]
        let extensions = ["pdf", "docx", "md", "swift", "png", "jpg", "xlsx", "txt", "key", "json", "ts", "py"]
        var generator = SystemRandomNumberGenerator()
        var state = AskFileIndexState(home: "/Users/bench")
        let root = state.directory("/Users/bench")
        var folders = [root]
        let now = Date()
        for number in 0 ..< size {
            if number % 40 == 0 {
                let parent = folders.randomElement(using: &generator)!
                let name = words.randomElement(using: &generator)! + "-\(number / 40)"
                let record = state.add(name: name, directory: parent, kind: .folder, modified: now)
                let path = state.path(of: record)
                folders.append(state.directory(path, parent: parent, record: record))
                continue
            }
            let name = words.randomElement(using: &generator)! + " " + words.randomElement(using: &generator)!
                + "-\(number)." + extensions.randomElement(using: &generator)!
            state.add(name: name, directory: folders.randomElement(using: &generator)!, kind: .file,
                      modified: now.addingTimeInterval(-Double(Int.random(in: 0 ... 400, using: &generator)) * 86400))
        }
        return state
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
    }

    @Test func searchingHalfAMillionNames() {
        let started = Date()
        let state = Self.makeState()
        let built = Date().timeIntervalSince(started)
        let queries = ["r", "re", "rep", "report", "inv 2026", "ht", "hetong", "zb", "readme", "img .png", "dsgn",
                       "budget final", "roadmap pdf", "会议", "tst cfg", "summary in:project", "xyzzy", "notes 12"]
        var timings: [Double] = []
        for round in 0 ..< 30 {
            for query in queries {
                let parsed = AskSearchQuery(query)
                let start = DispatchTime.now().uptimeNanoseconds
                let hits = state.search(parsed, options: AskFileSearchOptions(limit: 24))
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                if round > 0 { timings.append(elapsed) }
                _ = hits
            }
        }
        let p50 = Self.percentile(timings, 0.5), p95 = Self.percentile(timings, 0.95)
        let bytes = AskFileIndex.bytes(of: state)
        let encodeStart = Date()
        let data = AskFileSnapshot.encode(state, fingerprint: "bench", eventID: 1)
        let encode = Date().timeIntervalSince(encodeStart)
        let decodeStart = Date()
        let decoded = AskFileSnapshot.decode(data)
        let decode = Date().timeIntervalSince(decodeStart)
        print(String(format: "BENCH entries=%d build=%.2fs p50=%.2fms p95=%.2fms max=%.2fms memory=%.1fMB snapshot=%.1fMB encode=%.0fms decode=%.0fms",
                     state.count, built, p50, p95, timings.max() ?? 0, Double(bytes) / 1_048_576,
                     Double(data.count) / 1_048_576, encode * 1000, decode * 1000))
        #expect(decoded?.state.count == state.count)
        #expect(p95 < 40, "the design asks for 15 ms on an M1; this allows for slower test machines")
    }
}
