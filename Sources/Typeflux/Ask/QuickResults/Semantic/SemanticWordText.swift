import Foundation

/// Main-body DOCX text only. ZIP entries, external links, images and embedded objects are never opened.
enum SemanticWordText {
    static let recipe = "docx-body-zip32-utf8-no-dtd-v1"

    static func read(descriptor: Int32, size: Int64, cursor: SemanticContentCursor) throws -> AskFileReadResponse {
        guard cursor.page == 0 else { throw SemanticDocumentError(EINVAL) }
        let member = try SemanticDocumentZIP.body(descriptor, size: size)
        let stream = try SemanticDocumentStream(descriptor: descriptor, member: member)
        let parser = XMLParser(stream: stream)
        let body = SemanticWordBody(offset: cursor.offset)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = body
        let parsed = parser.parse()
        if let error = stream.streamError { throw error }
        if body.invalid { throw SemanticDocumentError(body.invalidCode) }
        guard body.hasBody, parsed || body.stopped else { throw SemanticDocumentError() }
        guard body.bytesSeen >= cursor.offset else { throw SemanticDocumentError(EINVAL) }
        guard let part = AskFileWorkerCommand.contentSlice(body.bytes, offset: 0)
        else { throw SemanticDocumentError(EINVAL) }
        let next = body.stopped ? SemanticContentCursor(offset: cursor.offset + Int64(part.consumed)) : nil
        return .init(pages: [.init(text: part.text, offset: cursor.offset, segmentKind: "docx-body")], nextCursor: next)
    }
}

private final class SemanticWordBody: NSObject, XMLParserDelegate {
    private let offset: Int64
    private var bodyDepth = 0
    private var textDepth = 0
    private var depth = 0
    var hasBody = false
    var invalid = false
    var invalidCode: Int32 = EILSEQ
    var stopped = false
    private var hasDocument = false
    var bytesSeen: Int64 = 0
    var bytes = Data()
    private let namespaces: Set<String> = [
        "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
        "http://purl.oclc.org/ooxml/wordprocessingml/main"
    ]

    init(offset: Int64) { self.offset = offset }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName _: String?, attributes _: [String: String]) {
        depth += 1
        guard namespaces.contains(namespaceURI ?? "") else { return }
        if depth == 1, elementName == "document" { hasDocument = true }
        if elementName == "body" {
            guard depth == 2, hasDocument, !hasBody else { invalid = true; parser.abortParsing(); return }
            hasBody = true; bodyDepth = depth
        }
        guard bodyDepth > 0 else { return }
        if elementName == "t" { textDepth = depth }
        if ["tab", "br", "cr"].contains(elementName) { append(elementName == "tab" ? "\t" : "\n", parser) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName _: String?) {
        if namespaces.contains(namespaceURI ?? ""), bodyDepth > 0 {
            if ["p", "tc"].contains(elementName) { append("\n", parser) }
            if textDepth == depth { textDepth = 0 }
            if bodyDepth == depth { bodyDepth = 0 }
        }
        depth -= 1
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if textDepth > 0 { append(string, parser) }
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        if textDepth > 0, let text = String(data: block, encoding: .utf8) { append(text, parser) }
    }

    private func append(_ text: String, _ parser: XMLParser) {
        guard !stopped, !invalid else { return }
        for scalar in text.unicodeScalars {
            let count = Int64(scalar.utf8.count)
            if bytesSeen >= offset { bytes.append(contentsOf: scalar.utf8) } else if bytesSeen + count > offset {
                invalid = true; invalidCode = EINVAL; parser.abortParsing(); return
            }
            bytesSeen += count
            if bytes.count >= SemanticFilePolicy.contentBatchBytes + 4 {
                stopped = true; parser.abortParsing(); return
            }
        }
    }
}
