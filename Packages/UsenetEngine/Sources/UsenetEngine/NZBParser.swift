import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

extension NZBManifest {
    public static func parse(_ data: Data, name: String? = nil, passwords: [String] = []) throws
        -> NZBManifest
    {
        guard !data.isEmpty, data.count <= 16 * 1024 * 1024,
            let xml = String(data: data, encoding: .utf8), !xml.contains("\0"), !xml.contains("<!ENTITY")
        else { throw UsenetError.invalidNZB }
        let delegate = ManifestParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid, delegate.sawRoot, !delegate.files.isEmpty else {
            throw UsenetError.invalidNZB
        }
        return NZBManifest(
            title: delegate.title, files: delegate.files,
            passwords: ArchivePasswords.candidates(
                explicit: delegate.passwords + passwords, names: [delegate.title, name].compactMap { $0 }))
    }
}
private final class ManifestParser: NSObject, XMLParserDelegate {
    var files: [NZBFile] = []
    var title: String?
    var passwords: [String] = []
    var invalid = false
    var sawRoot = false
    private var subject = ""
    private var segments: [NZBSegment] = []
    private var segmentNumber = 0
    private var segmentBytes = 0
    private var totalSegments = 0
    private var text = ""
    private var meta: String?
    private var inFile = false
    private var stack: [String] = []
    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String]
    ) {
        let parent = stack.last
        guard stack.count < 16, parent != nil || elementName == "nzb",
            !["segment", "meta"].contains(parent ?? "")
        else { fail(parser); return }
        if elementName == "file", parent != "nzb" { fail(parser); return }
        if elementName == "segment", parent != "segments" || !inFile { fail(parser); return }
        if elementName == "segments", parent != "file" { fail(parser); return }
        stack.append(elementName)
        text = ""
        if elementName == "nzb" { if sawRoot || parent != nil { fail(parser); return }; sawRoot = true }
        if elementName == "file" {
            if inFile || files.count >= 20_000 { fail(parser); return }
            inFile = true; subject = attributes["subject"] ?? ""; segments = []
            if subject.utf8.count > 4096 { fail(parser) }
        }
        if elementName == "segment" {
            guard inFile, let number = Int(attributes["number"] ?? ""), number > 0,
                let bytes = Int(attributes["bytes"] ?? ""), bytes > 0, bytes <= 8 * 1024 * 1024,
                totalSegments < 250_000
            else { fail(parser); return }
            segmentNumber = number; segmentBytes = bytes; totalSegments += 1
        }
        if elementName == "meta" { meta = attributes["type"] }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard stack.last == "segment" || stack.last == "meta" else { return }
        guard text.utf8.count + string.utf8.count <= 8192 else { fail(parser); return }; text += string
    }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        guard let value = String(data: data, encoding: .utf8) else { fail(parser); return }
        self.parser(parser, foundCharacters: value)
    }
    func parser(
        _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?
    ) {
        guard stack.last == name else { fail(parser); return }
        defer { stack.removeLast() }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "segment" {
            var id = value
            if id.hasPrefix("<"), id.hasSuffix(">") { id = String(id.dropFirst().dropLast()) }
            guard !id.isEmpty, id.utf8.count <= 1000,
                id.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e && $0 != 0x3c && $0 != 0x3e })
            else { fail(parser); return }
            segments.append(NZBSegment(number: segmentNumber, messageID: id, encodedBytes: segmentBytes))
        }
        if name == "meta" {
            if meta == "title" { title = value }
            if meta == "password", !value.isEmpty, passwords.count < 8 { passwords.append(value) }
            meta = nil
        }
        if name == "file" {
            let ordered = segments.sorted { $0.number < $1.number }
            guard !ordered.isEmpty, ordered.enumerated().allSatisfy({ $0.element.number == $0.offset + 1 }),
                Set(ordered.map(\.messageID)).count == ordered.count
            else { fail(parser); return }
            var filename = subject
            if let start = subject.firstIndex(of: "\""),
                let end = subject[subject.index(after: start)...].firstIndex(of: "\"")
            {
                filename = String(subject[subject.index(after: start)..<end])
            } else if let range = filename.range(of: #"\s*\(\d+/\d+\)\s*$"#, options: .regularExpression) {
                filename.removeSubrange(range)
            }
            filename = (filename as NSString).lastPathComponent.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !filename.isEmpty, filename != ".", filename != "..", filename.utf8.count <= 2048 else {
                fail(parser); return
            }
            files.append(NZBFile(id: files.count, name: filename, segments: ordered)); inFile = false
        }
        text = ""
    }
    func parser(_ parser: XMLParser, parseErrorOccurred: Error) { invalid = true }
    func parser(
        _ parser: XMLParser, foundExternalEntityDeclarationWithName: String, publicID: String?,
        systemID: String?
    ) { fail(parser) }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName: String, value: String?) {
        fail(parser)
    }
    private func fail(_ parser: XMLParser) { invalid = true; parser.abortParsing() }
}
