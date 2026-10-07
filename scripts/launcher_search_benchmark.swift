import Foundation
import Combine
import Darwin

// Standalone diagnostic: production search sources are compiled unchanged.
// Localization is irrelevant to matching; no application or user files are scanned.
func L(_ key: String) -> String { key }

struct Generator {
    var value: UInt64 = 242
    mutating func next(_ bound: Int) -> Int {
        value = value &* 6364136223846793005 &+ 1442695040888963407
        return Int((value >> 32) % UInt64(bound))
    }
}

func measure(_ label: String, runs: Int = 31, operation: () -> Int) {
    var timings: [Double] = []
    var checksum = 0
    for round in 0..<runs {
        let start = DispatchTime.now().uptimeNanoseconds
        checksum += operation()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        if round > 0 { timings.append(elapsed) }
    }
    timings.sort()
    print(String(format: "%@ p50=%.3fms p95=%.3fms max=%.3fms checksum=%d", label,
                 timings[timings.count / 2], timings[min(timings.count - 1, Int(Double(timings.count) * 0.95))],
                 timings.last!, checksum))
}

let words = ["report", "invoice", "notes", "draft", "final", "budget", "design", "meeting", "photo", "IMG",
             "Screenshot", "README", "index", "main", "test", "config", "合同", "周报", "会议纪要", "设计稿",
             "presentation", "summary", "project", "roadmap", "backup", "archive", "letter", "resume"]
let extensions = ["pdf", "docx", "md", "swift", "png", "jpg", "xlsx", "txt", "key", "json", "ts", "py"]
let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
let queries = ["r", "re", "report", "ht", "hetong", "会议", "budget final", "img .png", "summary in:project", "xyzzy"]
let applications = (0..<500).map { number in
    AskAppEntry(name: words[number % words.count] + " App \(number)",
                url: URL(fileURLWithPath: "/Applications/Synthetic\(number).app"),
                bundleID: "synthetic.\(number)", names: [])
}
for query in ["r", "report", "ht"] {
    measure("apps=500 query=\(query)") { AskAppMatcher.search(query, in: applications, limit: 12).count }
}
var largest: AskFileIndexState?
for size in [100_000, 500_000, 1_000_000] {
    var generator = Generator()
    var state = AskFileIndexState(home: "/Users/bench")
    let root = state.directory("/Users/bench")
    var folders = [root]
    let started = Date()
    for number in 0..<size {
        if number % 40 == 0 {
            let parent = folders[generator.next(folders.count)]
            let name = words[generator.next(words.count)] + "-\(number / 40)"
            let record = state.add(name: name, directory: parent, kind: .folder, modified: now)
            folders.append(state.directory(state.path(of: record), parent: parent, record: record))
        } else {
            let name = words[generator.next(words.count)] + " " + words[generator.next(words.count)]
                + "-\(number)." + extensions[generator.next(extensions.count)]
            state.add(name: name, directory: folders[generator.next(folders.count)], kind: .file,
                      modified: now.addingTimeInterval(-Double(generator.next(401)) * 86400))
        }
    }
    print(String(format: "entries=%d build=%.2fs", state.count, Date().timeIntervalSince(started)))
    let options = AskFileSearchOptions(limit: 24, now: now)
    for query in queries {
        let parsed = AskSearchQuery(query)
        measure("files=\(size) query=\(query)") { state.search(parsed, options: options).count }
    }
    measure("files=\(size) recent") { state.recent(options: options).count }
    largest = state
}


final class BenchmarkFiles: AskFileSearching, @unchecked Sendable {
    let state: AskFileIndexState
    init(_ state: AskFileIndexState) { self.state = state }
    var status: AskFileIndexStatus { .init(phase: .ready, count: state.count) }
    var usage: [String: Int] { [:] }
    func search(_ query: AskSearchQuery, options: AskFileSearchOptions) -> [AskFileHit] { state.search(query, options: options) }
    func recent(options: AskFileSearchOptions) -> [AskFileHit] { state.recent(options: options) }
    func start() {}
    func recordOpen(_ path: String) {}
    func forget(_ path: String) {}
    func rebuild() {}
    func clear() {}
}

final class BenchmarkApps: AskAppSearching, @unchecked Sendable {
    let entries: [AskAppEntry]
    init(_ entries: [AskAppEntry]) { self.entries = entries }
    func search(_ query: String, limit: Int) -> [AskAppMatch] { AskAppMatcher.search(query, in: entries, limit: limit) }
    func refreshIfStale() {}
    func recordLaunch(_ entry: AskAppEntry) {}
}

func percentile(_ values: [Double], _ fraction: Double) -> Double {
    values.sorted()[min(values.count - 1, Int(Double(values.count) * fraction))]
}

// Measures the actual production coordinator, including its 60 ms debounce.
// Publication latency is distinct from a rendered frame; UI tests cover interaction.
let pipelineState = largest!
Task { @MainActor in
    let session = AskQuickSearchSession()
    let sources = AskQuickResults.Sources(apps: BenchmarkApps(applications), files: BenchmarkFiles(pipelineState))
    var inputs: [Double] = [], apps: [Double] = [], files: [Double] = []
    for round in 0..<31 {
        let query = ["report", "re", "ht"][round % 3]
        let start = DispatchTime.now().uptimeNanoseconds
        var applicationTime: Double?, fileTime: Double?
        let subscription = session.$results.dropFirst().sink { result in
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            if result?.apps.isEmpty == false, applicationTime == nil { applicationTime = elapsed }
            if result?.files.isEmpty == false, fileTime == nil { fileTime = elapsed }
        }
        session.update(text: query, chinese: false, calculator: true, sources: sources)
        let input = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        let deadline = Date().addingTimeInterval(5)
        while session.isSearching, Date() < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        guard !session.isSearching, let applicationTime, let fileTime else {
            print("PIPELINE FAILED: missing result batch")
            exit(1)
        }
        if round > 0 { inputs.append(input); apps.append(applicationTime); files.append(fileTime) }
        subscription.cancel()
    }
    for (name, values) in [("input", inputs), ("apps", apps), ("files_with_debounce", files)] {
        print(String(format: "PIPELINE %@ p50=%.3fms p95=%.3fms max=%.3fms", name,
                     percentile(values, 0.5), percentile(values, 0.95), values.max()!))
    }
    session.cancel()
    exit(0)
}
dispatchMain()
