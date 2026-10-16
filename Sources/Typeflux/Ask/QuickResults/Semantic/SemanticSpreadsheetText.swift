import Foundation

/// Worksheet values only. Formulas and relationships are data, never code or network requests.
enum SemanticSpreadsheetText {
    static let recipe = "xlsx-body-zip32-cached-values-v1"
    static let namespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

    static func matches(_ uri: String?) -> Bool { SemanticPresentationText.matches(uri, namespace) }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func read(descriptor: Int32, size: Int64, cursor: SemanticContentCursor) throws -> AskFileReadResponse {
        let order = SemanticSpreadsheetMetadata(relationships: false)
        try parse(descriptor, size, "xl/workbook.xml", order)
        let relations = SemanticSpreadsheetMetadata(relationships: true)
        try parse(descriptor, size, "xl/_rels/workbook.xml.rels", relations)
        guard !order.invalid, !relations.invalid else { throw SemanticDocumentError() }
        let sheets = try order.sheets.map { sheet -> (String, String) in
            guard let target = relations.targets[sheet.0 + ":worksheet"] else { throw SemanticDocumentError() }
            return (try memberPath(target), sheet.1)
        }
        guard cursor.page >= 0, cursor.page <= sheets.count, cursor.offset >= 0,
              cursor.offset <= Int64.max - Int64(SemanticFilePolicy.contentBatchBytes + 4) else {
            throw SemanticDocumentError(EINVAL)
        }
        if cursor.page == sheets.count {
            guard cursor.offset == 0 else { throw SemanticDocumentError(EINVAL) }
            return .init(pages: [])
        }
        let shared = try relations.targets[":sharedStrings"].map(memberPath)
        let sheet = sheets[cursor.page]
        let output = SemanticSpreadsheetWindow(lower: cursor.offset,
            upper: cursor.offset + Int64(SemanticFilePolicy.contentBatchBytes + 4))
        var position: Int64 = 0, firstCell = 0, more = false
        // Resolve a bounded group together. No parser is entered from another parser's callback.
        repeat {
            let body = SemanticSpreadsheetBody(firstCell: firstCell, label: "\(cursor.page + 1):\(sheet.1)")
            try parse(descriptor, size, sheet.0, body)
            guard body.hasData else { throw SemanticDocumentError() }
            let indices = Set(body.cells.compactMap(\.index))
            var lengths: [Int: Int64] = [:]
            if !indices.isEmpty {
                guard let shared else { throw SemanticDocumentError() }
                let strings = SemanticSpreadsheetStrings(indices: indices)
                try parse(descriptor, size, shared, strings)
                guard strings.lengths.count == indices.count else { throw SemanticDocumentError() }
                lengths = strings.lengths
            }
            let groupStart = position
            var values: [Int: [SemanticSpreadsheetWindow]] = [:]
            for cell in body.cells {
                let length = cell.index.flatMap { lengths[$0] } ?? cell.length
                guard length > 0 else { continue }
                position += Int64(cell.label.utf8.count)
                if position < output.upper, position + length > output.lower {
                    cell.window = SemanticSpreadsheetWindow(lower: max(0, output.lower - position),
                        upper: min(length, output.upper - position))
                    if let index = cell.index, let window = cell.window {
                        values[index, default: []].append(window)
                    }
                }
                position += length
                position += 1
            }
            if !values.isEmpty, let shared {
                let strings = SemanticSpreadsheetStrings(indices: Set(values.keys), windows: values)
                try parse(descriptor, size, shared, strings)
            }
            if body.cells.contains(where: { $0.index == nil && $0.window != nil }) {
                let text = SemanticSpreadsheetBody(firstCell: firstCell, label: "", replay: body.cells)
                try parse(descriptor, size, sheet.0, text)
            }
            var groupPosition = groupStart
            for cell in body.cells {
                let length = cell.index.flatMap { lengths[$0] } ?? cell.length
                guard length > 0 else { continue }
                try output.append(cell.label, at: groupPosition)
                groupPosition += Int64(cell.label.utf8.count)
                output.bytes.append(cell.window?.bytes ?? Data())
                groupPosition += length
                try output.append("\n", at: groupPosition)
                groupPosition += 1
            }
            firstCell += body.cells.count
            more = body.stopped
            if position >= output.upper || !more { break }
        } while true
        guard position >= cursor.offset,
              let part = AskFileWorkerCommand.contentSlice(output.bytes, offset: 0)
        else { throw SemanticDocumentError(EINVAL) }
        let next: SemanticContentCursor? = more || part.consumed < output.bytes.count
            ? .init(page: cursor.page, offset: cursor.offset + Int64(part.consumed))
            : cursor.page + 1 < sheets.count ? .init(page: cursor.page + 1) : nil
        // The ordinal is a worksheet position, distinguished from a PDF page by segmentKind.
        return .init(pages: [.init(text: part.text, page: cursor.page + 1, offset: cursor.offset,
                                  segmentKind: "xlsx-sheet")], nextCursor: next)
    }

    private static func memberPath(_ target: String) throws -> String {
        guard let decoded = target.removingPercentEncoding, !decoded.isEmpty,
              !decoded.contains(where: { ":\\?#\0".contains($0) }) else { throw SemanticDocumentError(ENOTSUP) }
        var parts = decoded.hasPrefix("/") ? [] : ["xl"]
        for part in decoded.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                guard !parts.isEmpty else { throw SemanticDocumentError(ENOTSUP) }
                parts.removeLast()
            } else { parts.append(String(part)) }
        }
        guard !parts.isEmpty else { throw SemanticDocumentError(ENOTSUP) }
        return parts.joined(separator: "/")
    }

    fileprivate static func parse(_ descriptor: Int32, _ size: Int64, _ path: String,
                                  _ delegate: SemanticSpreadsheetXML) throws {
        let stream = try SemanticDocumentStream(descriptor: descriptor,
            member: SemanticDocumentZIP.body(descriptor, size: size, path: path))
        let parser = XMLParser(stream: stream)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let parsed = parser.parse()
        if let error = stream.streamError { throw error }
        if let error = delegate.failure { throw error }
        guard delegate.hasRoot, parsed || delegate.stopped else { throw SemanticDocumentError() }
    }
}

private class SemanticSpreadsheetXML: NSObject, XMLParserDelegate {
    var path: [String] = []
    var hasRoot = false
    var stopped = false
    var failure: Error?
    func parser(_: XMLParser, didStartElement name: String, namespaceURI uri: String?,
                qualifiedName _: String?, attributes _: [String: String]) {
        path.append(SemanticSpreadsheetText.matches(uri) ? name : "?")
    }
    func parser(_: XMLParser, didEndElement _: String, namespaceURI _: String?, qualifiedName _: String?) {
        path.removeLast()
    }
}

private final class SemanticSpreadsheetMetadata: SemanticSpreadsheetXML {
    private let relationships: Bool
    private var prefixes: [String: [String]] = [:]
    private var ids: Set<String> = []
    var invalid = false
    var sheets: [(String, String)] = []
    var targets: [String: String] = [:]
    init(relationships: Bool) { self.relationships = relationships }
    func parser(_: XMLParser, didStartMappingPrefix prefix: String, toURI uri: String) {
        prefixes[prefix, default: []].append(uri)
    }
    func parser(_: XMLParser, didEndMappingPrefix prefix: String) { _ = prefixes[prefix]?.popLast() }

    // swiftlint:disable:next cyclomatic_complexity
    override func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI uri: String?,
                         qualifiedName qualified: String?, attributes: [String: String]) {
        super.parser(parser, didStartElement: name, namespaceURI: uri, qualifiedName: qualified, attributes: attributes)
        if relationships {
            guard uri == SemanticPresentationText.package else { return }
            if path.count == 1, name == "Relationships" { hasRoot = true }
            guard hasRoot, path.count == 2, name == "Relationship" else { return }
            guard let id = attributes["Id"], ids.insert(id).inserted else { invalid = true; return }
            guard attributes["TargetMode"] == nil || attributes["TargetMode"] == "Internal",
                  let target = attributes["Target"] else { return }
            for kind in ["worksheet", "sharedStrings"] where SemanticPresentationText.matches(
                attributes["Type"], SemanticPresentationText.relationship + "/" + kind) {
                let key = kind == "worksheet" ? id + ":worksheet" : ":sharedStrings"
                if targets.updateValue(target, forKey: key) != nil { invalid = true }
            }
        } else {
            if path == ["workbook"] { hasRoot = true }
            guard hasRoot, path == ["workbook", "sheets", "sheet"] else { return }
            let id = attributes.first { key, _ in
                let parts = key.split(separator: ":")
                return parts.count == 2 && parts[1] == "id" && SemanticPresentationText.matches(
                    prefixes[String(parts[0])]?.last, SemanticPresentationText.relationship)
            }?.value
            guard let id, !id.isEmpty, let name = attributes["name"], !name.isEmpty else {
                invalid = true; return
            }
            sheets.append((id, name))
        }
    }
}

/// A byte window into one streamed value. Memory depends on the response, not the value length.
private final class SemanticSpreadsheetWindow {
    let lower: Int64
    let upper: Int64
    var bytes = Data()
    init(lower: Int64, upper: Int64) { self.lower = lower; self.upper = upper }
    func append(_ text: String, at start: Int64) throws {
        var position = start
        if position + Int64(text.utf8.count) <= lower || position >= upper { return }
        for scalar in text.unicodeScalars {
            let end = position + Int64(scalar.utf8.count)
            if position < lower, end > lower { throw SemanticDocumentError(EINVAL) }
            if position >= lower, position < upper { bytes.append(contentsOf: scalar.utf8) }
            position = end
            if position >= upper { break }
        }
    }
}

/// One sequential string-table pass measures or captures all references in the current group.
private final class SemanticSpreadsheetStrings: SemanticSpreadsheetXML {
    private var remaining: Set<Int>
    private let windows: [Int: [SemanticSpreadsheetWindow]]
    private var current = -1
    private var length: Int64 = 0
    var lengths: [Int: Int64] = [:]
    init(indices: Set<Int>, windows: [Int: [SemanticSpreadsheetWindow]] = [:]) {
        remaining = indices; self.windows = windows
    }
    override func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI uri: String?,
                         qualifiedName qualified: String?, attributes: [String: String]) {
        super.parser(parser, didStartElement: name, namespaceURI: uri, qualifiedName: qualified, attributes: attributes)
        if path == ["sst"] { hasRoot = true }
        if path == ["sst", "si"] { current += 1; length = 0 }
    }
    override func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI uri: String?,
                         qualifiedName qualified: String?) {
        if path == ["sst", "si"], remaining.remove(current) != nil {
            lengths[current] = length
            if remaining.isEmpty { stopped = true; parser.abortParsing() }
        }
        super.parser(parser, didEndElement: name, namespaceURI: uri, qualifiedName: qualified)
    }
    func parser(_ parser: XMLParser, foundCharacters text: String) {
        guard remaining.contains(current), path == ["sst", "si", "t"] || path == ["sst", "si", "r", "t"] else { return }
        do {
            for window in windows[current] ?? [] { try window.append(text, at: length) }
            length += Int64(text.utf8.count)
        } catch { failure = error; parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if let text = String(data: data, encoding: .utf8) { self.parser(parser, foundCharacters: text) }
    }
}

private final class SemanticSpreadsheetCell {
    let label: String
    var index: Int?
    var length: Int64 = 0
    var window: SemanticSpreadsheetWindow?
    init(label: String) { self.label = label }
}

/// Keep at most 128 cell descriptors, then replay only to capture selected inline/cache windows.
private final class SemanticSpreadsheetBody: SemanticSpreadsheetXML {
    private let firstCell: Int
    private let label: String
    private let replay: [SemanticSpreadsheetCell]?
    private var seenCells = 0
    private var cellType = ""
    private var reference = ""
    private var cell: SemanticSpreadsheetCell?
    private var length: Int64 = 0
    var cells: [SemanticSpreadsheetCell] = []
    var hasData = false
    init(firstCell: Int, label: String, replay: [SemanticSpreadsheetCell]? = nil) {
        self.firstCell = firstCell; self.label = label; self.replay = replay
    }
    override func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI uri: String?,
                         qualifiedName qualified: String?, attributes: [String: String]) {
        super.parser(parser, didStartElement: name, namespaceURI: uri, qualifiedName: qualified, attributes: attributes)
        if path == ["worksheet"] { hasRoot = true }
        if path == ["worksheet", "sheetData"] { hasData = true }
        if path == ["worksheet", "sheetData", "row", "c"] {
            seenCells += 1
            guard seenCells > firstCell else { return }
            cellType = attributes["t"] ?? "n"; reference = ""; length = 0
            let index = seenCells - firstCell - 1
            cell = replay?[index] ?? SemanticSpreadsheetCell(label: "[\(label)!\(attributes["r"] ?? "?")]\t")
            if let cell { cells.append(cell) }
        }
    }
    override func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI uri: String?,
                         qualifiedName qualified: String?) {
        if cell != nil {
            if path == ["worksheet", "sheetData", "row", "c", "v"], cellType == "s" {
                if let index = Int(reference.trimmingCharacters(in: .whitespacesAndNewlines)), index >= 0 {
                    cell?.index = index
                } else { failure = SemanticDocumentError(); parser.abortParsing() }
            }
            if path == ["worksheet", "sheetData", "row", "c"] {
                cell = nil
                if cells.count == (replay?.count ?? 128) { stopped = true; parser.abortParsing() }
            }
        }
        super.parser(parser, didEndElement: name, namespaceURI: uri, qualifiedName: qualified)
    }
    func parser(_ parser: XMLParser, foundCharacters text: String) {
        guard let cell else { return }
        let pathToCell = ["worksheet", "sheetData", "row", "c"]
        if path == pathToCell + ["v"], cellType == "s" {
            if reference.utf8.count + text.utf8.count > 32 {
                failure = SemanticDocumentError(); parser.abortParsing()
            } else { reference += text }
        } else if (path == pathToCell + ["v"] && cellType != "inlineStr") ||
            (cellType == "inlineStr" && (path == pathToCell + ["is", "t"] || path == pathToCell + ["is", "r", "t"])) {
            do {
                if replay != nil {
                    try cell.window?.append(text, at: length)
                } else { cell.length += Int64(text.utf8.count) }
                length += Int64(text.utf8.count)
            } catch { failure = error; parser.abortParsing() }
        }
    }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if let text = String(data: data, encoding: .utf8) { self.parser(parser, foundCharacters: text) }
    }
}
