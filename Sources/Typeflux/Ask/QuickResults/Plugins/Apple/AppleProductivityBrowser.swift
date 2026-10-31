import Foundation

struct AppleProductivityItem: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var container: String
    var modified: Date?
    var due: Date?
    var alarm: Date?
    var completed: Bool
    var locked: Bool
    var body: String
    var truncated: Bool
    var allDay: Bool? = nil
}

struct AppleProductivityMatches: Equatable, Sendable {
    var items: [AppleProductivityItem]
    var total: Int
    var hasMore: Bool
}

protocol AppleProductivityBrowsing: Sendable {
    func search(kind: AskAppleProductivityPlugin.Kind, query: String, includeCompleted: Bool) async throws -> AppleProductivityMatches
    func read(kind: AskAppleProductivityPlugin.Kind, id: String) async throws -> AppleProductivityItem
    func open(kind: AskAppleProductivityPlugin.Kind, id: String) async throws
    func requestAccess(kind: AskAppleProductivityPlugin.Kind) async throws
}

extension AppleProductivityBrowsing {
    func requestAccess(kind _: AskAppleProductivityPlugin.Kind) async throws {}
}

/// Read access stays separate from creation. No local Notes database or AI service is involved.
actor AppleProductivityBrowser: AppleProductivityBrowsing {
    private let runner: any ProcessCommandRunning

    init(runner: any ProcessCommandRunning = ProcessCommandRunner(timeout: 45, outputLimit: 2 * 1024 * 1024)) {
        self.runner = runner
    }

    func search(kind: AskAppleProductivityPlugin.Kind, query: String, includeCompleted: Bool) async throws -> AppleProductivityMatches {
        guard kind == .notes, query.count <= 500 else { throw Failure.invalid }
        let response = try await run("search", kind: kind, value: query, includeCompleted: includeCompleted)
        guard let items = response.items, let total = response.total, let hasMore = response.hasMore,
              items.count <= 30, total >= items.count, hasMore == (total > items.count),
              Set(items.map(\.id)).count == items.count, items.allSatisfy({ !$0.id.isEmpty && $0.body.isEmpty })
        else { throw Failure.invalid }
        return .init(items: items, total: total, hasMore: hasMore)
    }

    func read(kind: AskAppleProductivityPlugin.Kind, id: String) async throws -> AppleProductivityItem {
        guard kind == .notes else { throw Failure.invalid }
        try validate(id)
        let response = try await run("read", kind: kind, value: id)
        guard let item = response.item, item.id == id, item.body.count <= 50000,
              !item.locked || item.body.isEmpty else { throw Failure.invalid }
        return item
    }

    func open(kind: AskAppleProductivityPlugin.Kind, id: String) async throws {
        guard kind == .notes else { throw Failure.invalid }
        try validate(id)
        guard try await run("open", kind: kind, value: id).opened == true else { throw Failure.invalid }
    }

    private func validate(_ id: String) throws {
        guard !id.isEmpty, id.count <= 2048 else { throw Failure.invalid }
    }

    private func run(_ operation: String, kind: AskAppleProductivityPlugin.Kind, value: String,
                     includeCompleted: Bool = false) async throws -> Response {
        try Task.checkCancellation()
        let result = try await runner.run(executablePath: "/usr/bin/osascript", arguments: [
            "-l", "JavaScript", "-e", try Self.script(), "--", operation, kind.rawValue, value,
            includeCompleted ? "true" : "false"
        ])
        guard result.exitCode == 0, let data = result.stdout.data(using: .utf8) else { throw Failure.invalid }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let response = try decoder.decode(Response.self, from: data)
        if let error = response.error {
            switch error {
            case "missing": throw Failure.missing
            case "changed": throw Failure.changed
            default: throw Failure.invalid
            }
        }
        return response
    }

    static func script() throws -> String {
        guard let url = Bundle.module.url(forResource: "AppleProductivityBrowse", withExtension: "js") else {
            throw Failure.invalid
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private struct Response: Decodable {
        var items: [AppleProductivityItem]?
        var item: AppleProductivityItem?
        var total: Int?
        var hasMore: Bool?
        var opened: Bool?
        var error: String?
    }

    enum Failure: Error { case invalid, missing, changed }
}
