import Foundation

/// Worksheet values only. Formulas and relationships are data, never code or network requests.
enum SemanticSpreadsheetText {
    static let recipe = "xlsx-body-zip32-cached-values-v1"
    static let namespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

    static func matches(_ uri: String?) -> Bool { SemanticPresentationText.matches(uri, namespace) }

    // swiftlint:disable:next cyclomatic_complexity
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
        guard cursor.page >= 0, cursor.page <= sheets.count, cursor.offset >= 0 else {
            throw SemanticDocumentError(EINVAL)
        }
        if cursor.page == sheets.count {
            guard cursor.offset == 0 else { throw SemanticDocumentError(EINVAL) }
            return .init(pages: [])
        }
        let shared = try relations.targets[":sharedStrings"].map(memberPath)
        let body = SemanticSpreadsheetBody(offset: cursor.offset, label: "\(cursor.page + 1):\(sheets[cursor.page].1)")
        // Foundation XMLParser is not reentrant. Suspend at a reference, parse it after the
        // worksheet parser returns, then replay the worksheet past already consumed cells.
        while true {
            try parse(descriptor, size, sheets[cursor.page].0, body)
            guard let index = body.pendingString else { break }
            guard let shared else { throw SemanticDocumentError() }
            body.stopped = false
            let strings = SemanticSpreadsheetStrings(index: index) { text in
                body.appendValue(text, nil)
                return !body.stopped && body.failure == nil
            }
            try parse(descriptor, size, shared, strings)
            if let error = body.failure { throw error }
            guard strings.found else { throw SemanticDocumentError() }
            if body.stopped { break }
            body.finishReference()
            if body.stopped { break }
        }
        if let error = body.failure { throw error }
        guard body.hasData else { throw SemanticDocumentError() }
        guard body.bytesSeen >= cursor.offset,
              let part = AskFileWorkerCommand.contentSlice(body.bytes, offset: 0)
        else { throw SemanticDocumentError(EINVAL) }
        let next: SemanticContentCursor? = body.stopped || part.consumed < body.bytes.count
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
        if let error = (delegate as? SemanticSpreadsheetBody)?.failure { throw error }
        guard delegate.hasRoot, parsed || delegate.stopped else { throw SemanticDocumentError() }
    }
}

private class SemanticSpreadsheetXML: NSObject, XMLParserDelegate {
    var path: [String] = []
    var hasRoot = false
    var stopped = false
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

/// Resolve a single reference without retaining a workbook-sized shared-string table.
private final class SemanticSpreadsheetStrings: SemanticSpreadsheetXML {
    private let index: Int
    private let output: (String) -> Bool
    private var current = -1
    var found = false
    init(index: Int, output: @escaping (String) -> Bool) { self.index = index; self.output = output }
    override func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI uri: String?,
                         qualifiedName qualified: String?, attributes: [String: String]) {
        super.parser(parser, didStartElement: name, namespaceURI: uri, qualifiedName: qualified, attributes: attributes)
        if path == ["sst"] { hasRoot = true }
        if path == ["sst", "si"] { current += 1; if current == index { found = true } }
    }
    override func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI uri: String?,
                         qualifiedName qualified: String?) {
        let done = found && path == ["sst", "si"]
        super.parser(parser, didEndElement: name, namespaceURI: uri, qualifiedName: qualified)
        if done { stopped = true; parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, foundCharacters text: String) {
        guard current == index, path == ["sst", "si", "t"] || path == ["sst", "si", "r", "t"] else { return }
        if !output(text) { stopped = true; parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if let text = String(data: data, encoding: .utf8) { self.parser(parser, foundCharacters: text) }
    }
}

private final class SemanticSpreadsheetBody: SemanticSpreadsheetXML {
    private let offset: Int64
    private let label: String
    private var cellType = ""
    private var reference = ""
    private var skipCells = 0
    private var seenCells = 0
    private var cellLabel = ""
    private var cellStarted = false
    var pendingString: Int?
    var failure: Error?
    var hasData = false
    var bytesSeen: Int64 = 0
    var bytes = Data()
    init(offset: Int64, label: String) { self.offset = offset; self.label = label }

    override func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI uri: String?,
                         qualifiedName qualified: String?, attributes: [String: String]) {
        super.parser(parser, didStartElement: name, namespaceURI: uri, qualifiedName: qualified, attributes: attributes)
        if path == ["worksheet"] { hasRoot = true }
        if path == ["worksheet", "sheetData"] { hasData = true }
        if path == ["worksheet", "sheetData", "row", "c"] {
            seenCells += 1
            cellType = attributes["t"] ?? "n"; reference = ""; cellStarted = false
            cellLabel = "[\(label)!\(attributes["r"] ?? "?")]\t"
        }
    }
    override func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI uri: String?,
                         qualifiedName qualified: String?) {
        if seenCells > skipCells {
            if path == ["worksheet", "sheetData", "row", "c", "v"], cellType == "s" {
                if let index = Int(reference.trimmingCharacters(in: .whitespacesAndNewlines)), index >= 0 {
                    pendingString = index; stopped = true; parser.abortParsing()
                } else { failure = SemanticDocumentError(); parser.abortParsing() }
            }
            if path == ["worksheet", "sheetData", "row", "c"], cellStarted { append("\n", parser) }
        }
        super.parser(parser, didEndElement: name, namespaceURI: uri, qualifiedName: qualified)
    }
    func parser(_ parser: XMLParser, foundCharacters text: String) {
        guard seenCells > skipCells else { return }
        let cell = ["worksheet", "sheetData", "row", "c"]
        if path == cell + ["v"], cellType != "inlineStr" {
            if cellType == "s" {
                // A shared-string reference is an integer, never searchable cell content.
                if reference.utf8.count + text.utf8.count > 32 {
                    failure = SemanticDocumentError(); parser.abortParsing()
                } else { reference += text }
            } else { appendValue(text, parser) }
        } else if cellType == "inlineStr", path == cell + ["is", "t"] || path == cell + ["is", "r", "t"] {
            appendValue(text, parser)
        }
    }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if let text = String(data: data, encoding: .utf8) { self.parser(parser, foundCharacters: text) }
    }
    func appendValue(_ text: String, _ parser: XMLParser?) {
        guard !text.isEmpty else { return }
        if !cellStarted { cellStarted = true; append(cellLabel, parser) }
        append(text, parser)
    }
    func finishReference() {
        if cellStarted { append("\n", nil) }
        skipCells = seenCells; seenCells = 0; pendingString = nil
        path = []; hasRoot = false
    }
    private func append(_ text: String, _ parser: XMLParser?) {
        guard !stopped, failure == nil else { return }
        for scalar in text.unicodeScalars {
            let count = Int64(scalar.utf8.count)
            if bytesSeen >= offset { bytes.append(contentsOf: scalar.utf8) } else if bytesSeen + count > offset {
                failure = SemanticDocumentError(EINVAL); parser?.abortParsing(); return
            }
            bytesSeen += count
            if bytes.count >= SemanticFilePolicy.contentBatchBytes + 4 {
                stopped = true; parser?.abortParsing(); return
            }
        }
    }
}
