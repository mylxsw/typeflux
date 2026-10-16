import Foundation

/// Presentation-order slide text. Relationship targets select archive data, never filesystem paths or URLs.
enum SemanticPresentationText {
    static let recipe = "pptx-body-zip32-presentation-order-v1"
    static let presentation = "http://schemas.openxmlformats.org/presentationml/2006/main"
    static let drawing = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let package = "http://schemas.openxmlformats.org/package/2006/relationships"

    static func matches(_ uri: String?, _ transitional: String) -> Bool {
        uri == transitional || uri == transitional.replacingOccurrences(of: "http://schemas.openxmlformats.org/",
                                                                         with: "http://purl.oclc.org/ooxml/")
            .replacingOccurrences(of: "/2006", with: "")
    }

    static func read(descriptor: Int32, size: Int64, cursor: SemanticContentCursor) throws -> AskFileReadResponse {
        let order = SemanticPresentationMetadata(relationships: false)
        _ = try parse(descriptor, size, "ppt/presentation.xml", order)
        let relations = SemanticPresentationMetadata(relationships: true)
        _ = try parse(descriptor, size, "ppt/_rels/presentation.xml.rels", relations)
        let slides = try order.slides.map { id -> String in
            guard let target = relations.targets[id] else { throw SemanticDocumentError() }
            return try memberPath(target)
        }
        guard cursor.page >= 0, cursor.page <= slides.count, cursor.offset >= 0 else {
            throw SemanticDocumentError(EINVAL)
        }
        if cursor.page == slides.count {
            guard cursor.offset == 0 else { throw SemanticDocumentError(EINVAL) }
            return .init(pages: [])
        }
        let body = SemanticPresentationBody(offset: cursor.offset)
        let parsed = try parse(descriptor, size, slides[cursor.page], body)
        if body.invalid { throw SemanticDocumentError(EINVAL) }
        guard body.hasTree, parsed || body.stopped else { throw SemanticDocumentError() }
        guard body.bytesSeen >= cursor.offset,
              let part = AskFileWorkerCommand.contentSlice(body.bytes, offset: 0)
        else { throw SemanticDocumentError(EINVAL) }
        let next: SemanticContentCursor? = body.stopped
            ? .init(page: cursor.page, offset: cursor.offset + Int64(part.consumed))
            : cursor.page + 1 < slides.count ? .init(page: cursor.page + 1) : nil
        return .init(pages: [.init(text: part.text, page: cursor.page + 1, offset: cursor.offset,
                                  segmentKind: "pptx-slide")], nextCursor: next)
    }

    private static func memberPath(_ target: String) throws -> String {
        guard let decoded = target.removingPercentEncoding, !decoded.isEmpty,
              !decoded.contains(where: { ":\\?#\0".contains($0) }) else { throw SemanticDocumentError(ENOTSUP) }
        var components = decoded.hasPrefix("/") ? [] : ["ppt"]
        for part in decoded.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                guard !components.isEmpty else { throw SemanticDocumentError(ENOTSUP) }
                components.removeLast()
            } else { components.append(String(part)) }
        }
        guard !components.isEmpty else { throw SemanticDocumentError(ENOTSUP) }
        return components.joined(separator: "/")
    }

    private static func parse(_ descriptor: Int32, _ size: Int64, _ path: String,
                              _ delegate: XMLParserDelegate) throws -> Bool {
        let stream = try SemanticDocumentStream(descriptor: descriptor,
            member: SemanticDocumentZIP.body(descriptor, size: size, path: path))
        let parser = XMLParser(stream: stream)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let parsed = parser.parse()
        if let error = stream.streamError { throw error }
        if let metadata = delegate as? SemanticPresentationMetadata {
            guard parsed, metadata.hasRoot, !metadata.invalid else { throw SemanticDocumentError() }
        }
        return parsed
    }
}

private final class SemanticPresentationMetadata: NSObject, XMLParserDelegate {
    private let relationships: Bool
    private var depth = 0
    private var listDepth = 0
    private var prefixes: [String: [String]] = [:]
    var hasRoot = false
    var invalid = false
    var slides: [String] = []
    var targets: [String: String] = [:]
    private var relationIDs: Set<String> = []

    init(relationships: Bool) { self.relationships = relationships }

    func parser(_: XMLParser, didStartMappingPrefix prefix: String, toURI uri: String) {
        prefixes[prefix, default: []].append(uri)
    }

    func parser(_: XMLParser, didEndMappingPrefix prefix: String) { _ = prefixes[prefix]?.popLast() }

    // swiftlint:disable:next cyclomatic_complexity
    func parser(_: XMLParser, didStartElement name: String, namespaceURI uri: String?,
                qualifiedName _: String?, attributes: [String: String]) {
        depth += 1
        if relationships {
            guard uri == SemanticPresentationText.package else { return }
            if depth == 1, name == "Relationships" { hasRoot = true }
            guard hasRoot, depth == 2, name == "Relationship" else { return }
            guard let id = attributes["Id"], relationIDs.insert(id).inserted else { invalid = true; return }
            // External/non-slide relationships are never loaded. A slide referencing one fails deterministically.
            if attributes["TargetMode"] == nil || attributes["TargetMode"] == "Internal",
               SemanticPresentationText.matches(attributes["Type"], SemanticPresentationText.relationship + "/slide"),
               let target = attributes["Target"] { targets[id] = target }
        } else {
            guard SemanticPresentationText.matches(uri, SemanticPresentationText.presentation) else { return }
            if depth == 1, name == "presentation" { hasRoot = true }
            if hasRoot, depth == 2, name == "sldIdLst" { listDepth = depth }
            guard listDepth > 0, depth == listDepth + 1, name == "sldId" else { return }
            let id = attributes.first { key, _ in
                let parts = key.split(separator: ":")
                return parts.count == 2 && parts[1] == "id"
                    && SemanticPresentationText.matches(prefixes[String(parts[0])]?.last,
                                                        SemanticPresentationText.relationship)
            }?.value
            if let id, !id.isEmpty { slides.append(id) } else { invalid = true }
        }
    }

    func parser(_: XMLParser, didEndElement _: String, namespaceURI _: String?, qualifiedName _: String?) {
        if listDepth == depth { listDepth = 0 }
        depth -= 1
    }
}

private final class SemanticPresentationBody: NSObject, XMLParserDelegate {
    private let offset: Int64
    private var path: [String] = []
    private var textBodyDepth = 0
    var hasTree = false
    private var textDepth = 0
    var hasRoot = false
    var invalid = false
    var stopped = false
    var bytesSeen: Int64 = 0
    var bytes = Data()

    init(offset: Int64) { self.offset = offset }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI uri: String?,
                qualifiedName _: String?, attributes _: [String: String]) {
        let isPresentation = SemanticPresentationText.matches(uri, SemanticPresentationText.presentation)
        let isDrawing = SemanticPresentationText.matches(uri, SemanticPresentationText.drawing)
        let key = (isPresentation ? "p:" : isDrawing ? "a:" : "?:") + name
        let parent = path.last
        path.append(key)
        if path.count == 1, key == "p:sld" { hasRoot = true }
        guard hasRoot, path.prefix(3) == ["p:sld", "p:cSld", "p:spTree"] else { return }
        hasTree = true
        let shape = ["p:sp", "p:txBody"]
        let table = ["p:graphicFrame", "a:graphic", "a:graphicData", "a:tbl", "a:tr", "a:tc", "a:txBody"]
        let bodyPath = Array(path.dropFirst(3))
        let shapeBody = bodyPath.suffix(shape.count) == shape
            && bodyPath.dropLast(shape.count).allSatisfy({ $0 == "p:grpSp" })
        let tableBody = bodyPath.suffix(table.count) == table
            && bodyPath.dropLast(table.count).allSatisfy({ $0 == "p:grpSp" })
        if shapeBody || tableBody {
            textBodyDepth = path.count
        }
        guard textBodyDepth > 0 else { return }
        if key == "a:t", path.count == textBodyDepth + 3, path[textBodyDepth] == "a:p",
           parent == "a:r" || parent == "a:fld" { textDepth = path.count }
        if key == "a:br", path.count == textBodyDepth + 2, parent == "a:p" { append("\n", parser) }
    }

    func parser(_ parser: XMLParser, didEndElement _: String, namespaceURI _: String?, qualifiedName _: String?) {
        if textBodyDepth > 0, path.count == textBodyDepth + 1, path.last == "a:p" { append("\n", parser) }
        if textDepth == path.count { textDepth = 0 }
        if textBodyDepth == path.count { textBodyDepth = 0 }
        path.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if textDepth == path.count, textBodyDepth > 0 { append(string, parser) }
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
