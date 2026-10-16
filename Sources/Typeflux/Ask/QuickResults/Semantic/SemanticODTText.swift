import Foundation

/// ODT main text only; all package members remain data on the held descriptor.
enum SemanticODTText {
    static let recipe = "odt-body-zip32-utf8-no-dtd-v1"
    static let office = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    static let text = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
    static let table = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"

    static func read(descriptor: Int32, size: Int64, cursor: SemanticContentCursor) throws -> AskFileReadResponse {
        guard cursor.page == 0 else { throw SemanticDocumentError(EINVAL) }
        let manifest = SemanticODTManifest()
        let metadata = try stream(descriptor, size, "META-INF/manifest.xml")
        let checked = parse(metadata, delegate: manifest)
        if let error = metadata.streamError { throw error }
        if manifest.encrypted { throw SemanticDocumentError(EAUTH) }
        guard checked, manifest.hasRoot else { throw SemanticDocumentError() }
        let source = try stream(descriptor, size, "content.xml")
        let body = SemanticODTBody(offset: cursor.offset)
        let parsed = parse(source, delegate: body)
        if let error = source.streamError { throw error }
        if body.invalid { throw SemanticDocumentError(EINVAL) }
        guard body.hasText, parsed || body.stopped else { throw SemanticDocumentError() }
        guard body.bytesSeen >= cursor.offset,
              let part = AskFileWorkerCommand.contentSlice(body.bytes, offset: 0)
        else { throw SemanticDocumentError(EINVAL) }
        let next = body.stopped ? SemanticContentCursor(offset: cursor.offset + Int64(part.consumed)) : nil
        return .init(pages: [.init(text: part.text, offset: cursor.offset, segmentKind: "odt-body")], nextCursor: next)
    }

    private static func stream(_ descriptor: Int32, _ size: Int64, _ path: String) throws -> SemanticDocumentStream {
        try SemanticDocumentStream(descriptor: descriptor,
            member: SemanticDocumentZIP.body(descriptor, size: size, path: path))
    }

    private static func parse(_ stream: InputStream, delegate: XMLParserDelegate) -> Bool {
        let parser = XMLParser(stream: stream)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        return parser.parse()
    }
}

private final class SemanticODTManifest: NSObject, XMLParserDelegate {
    private var depth = 0
    var hasRoot = false
    var encrypted = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName _: String?, attributes _: [String: String]) {
        depth += 1
        guard namespaceURI == "urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" else { return }
        if depth == 1, name == "manifest" { hasRoot = true }
        // Reject packages with any encrypted member, without reading or decrypting its payload.
        if name == "encryption-data" { encrypted = true; parser.abortParsing() }
    }

    func parser(_: XMLParser, didEndElement _: String, namespaceURI _: String?, qualifiedName _: String?) {
        depth -= 1
    }
}

private final class SemanticODTBody: NSObject, XMLParserDelegate {
    private let offset: Int64
    private var depth = 0
    private var document = false
    private var bodyDepth = 0
    private var textDepth = 0
    private var paragraphDepth = 0
    private var ignoredDepth = 0
    var hasText = false
    var invalid = false
    var stopped = false
    var bytesSeen: Int64 = 0
    var bytes = Data()

    init(offset: Int64) { self.offset = offset }

    // swiftlint:disable:next cyclomatic_complexity
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI namespace: String?,
                qualifiedName _: String?, attributes: [String: String]) {
        depth += 1
        if depth == 1, namespace == SemanticODTText.office, name == "document-content" { document = true }
        if document, depth == 2, namespace == SemanticODTText.office, name == "body" { bodyDepth = depth }
        if bodyDepth > 0, depth == bodyDepth + 1, namespace == SemanticODTText.office, name == "text", !hasText {
            hasText = true; textDepth = depth
        }
        guard textDepth > 0, ignoredDepth == 0 else { return }
        if namespace == SemanticODTText.office || namespace == "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
            || (namespace == SemanticODTText.text && ["tracked-changes", "note", "ruby-text"].contains(name)) {
            if depth != textDepth { ignoredDepth = depth }
            return
        }
        guard namespace == SemanticODTText.text else { return }
        if ["p", "h"].contains(name) { paragraphDepth = depth }
        guard paragraphDepth > 0 else { return }
        if name == "tab" { append("\t", parser) }
        if name == "line-break" { append("\n", parser) }
        if name == "s" {
            // XMLParser keeps attribute prefixes. The namespace of the containing element is checked above.
            let value = attributes.first { $0.key == "c" || $0.key.hasSuffix(":c") }?.value ?? "1"
            guard let count = Int64(value), count > 0 else { invalid = true; parser.abortParsing(); return }
            let skip = min(count, max(0, offset - bytesSeen))
            bytesSeen += skip
            var remaining = count - skip
            while remaining > 0, !stopped { append(" ", parser); remaining -= 1 }
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI namespace: String?,
                qualifiedName _: String?) {
        if ignoredDepth == 0, textDepth > 0 {
            if paragraphDepth == depth { append("\n", parser); paragraphDepth = 0 }
            if namespace == SemanticODTText.table, name == "table-cell" { append("\t", parser) }
            if namespace == SemanticODTText.table, name == "table-row" { append("\n", parser) }
        }
        if ignoredDepth == depth { ignoredDepth = 0 }
        if textDepth == depth { textDepth = 0 }
        if bodyDepth == depth { bodyDepth = 0 }
        depth -= 1
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if paragraphDepth > 0, ignoredDepth == 0 { append(string, parser) }
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        if let text = String(data: block, encoding: .utf8) { self.parser(parser, foundCharacters: text) }
    }

    private func append(_ text: String, _ parser: XMLParser) {
        guard !stopped, !invalid else { return }
        for scalar in text.unicodeScalars {
            let count = Int64(scalar.utf8.count)
            if bytesSeen >= offset { bytes.append(contentsOf: scalar.utf8) } else if bytesSeen + count > offset {
                invalid = true; parser.abortParsing(); return
            }
            bytesSeen += count
            if bytes.count >= SemanticFilePolicy.contentBatchBytes + 4 {
                stopped = true; parser.abortParsing(); return
            }
        }
    }
}
