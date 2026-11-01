import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Bounded Newznab XML parsing. Authenticated enclosure URLs never leave this decoder.
final class NewznabDocument: NSObject, XMLParserDelegate {
    private(set) var root = ""
    private(set) var capabilities = NewznabCapabilities()
    private(set) var items: [NewznabItem] = []
    private(set) var offset: Int?
    private(set) var total: Int?
    private var code: Int?
    private var item: NewznabItem?
    private var text = ""
    private var stack: [String] = []
    private var invalid = false
    private var nzbProbe = false
    static func parse(_ data: Data, probeNZB: Bool = false) throws -> NewznabDocument {
        guard !data.isEmpty, let xml = String(data: data, encoding: .utf8), !xml.contains("\0"),
            !xml.contains("<!ENTITY")
        else { throw NZBFinderError.invalidResponse }
        let document = NewznabDocument(); document.nzbProbe = probeNZB
        let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false;
        parser.delegate = document
        let complete = parser.parse()
        if probeNZB, document.root == "nzb", !document.invalid { return document }
        guard complete, !document.invalid, document.stack.isEmpty else {
            throw NZBFinderError.invalidResponse
        }
        if let code = document.code {
            switch code {
            case 100, 106: throw NZBFinderError.unauthorized
            case 101, 102: throw NZBFinderError.privileges
            case 500, 501: throw NZBFinderError.rateLimited
            case 300: throw NZBFinderError.missingRelease
            default: throw NZBFinderError.invalidResponse
            }
        }
        guard document.root == "caps" || document.root == "rss" else { throw NZBFinderError.invalidResponse }
        return document
    }
    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String]
    ) {
        let name = name.components(separatedBy: ":").last!.lowercased()
        guard stack.count < 32 else { fail(parser); return }
        if stack.isEmpty {
            guard root.isEmpty, ["caps", "rss", "error", "nzb"].contains(name) else { fail(parser); return }
            root = name
            if name == "nzb" { if nzbProbe { parser.abortParsing() } else { fail(parser) }; return }
        }
        stack.append(name); text = ""
        if name == "error" { code = Int(attributes["code"] ?? "") ?? -1 }
        if root == "caps" {
            if name == "limits", let maximum = Int(attributes["max"] ?? ""), maximum > 0 {
                capabilities.maximum = min(500, maximum)
            }
            if attributes["available"] == "yes" {
                let params = Set(
                    (attributes["supportedParams"] ?? attributes["supportedparams"] ?? "").lowercased().split(
                        separator: ","
                    ).map { $0.trimmingCharacters(in: .whitespaces) })
                switch name {
                case "search": capabilities.search = params;
                case "movie-search": capabilities.movie = params;
                case "tv-search": capabilities.tv = params;
                default: break
                }
            }
        }
        if root == "rss" {
            if name == "response" {
                if let value = attributes["offset"] {
                    guard let number = Int(value), number >= 0 else { fail(parser); return }; offset = number
                }
                if let value = attributes["total"] {
                    guard let number = Int(value), number >= 0 else { fail(parser); return }; total = number
                }
            }
            if name == "item" {
                guard item == nil, items.count < 500 else { fail(parser); return }; item = NewznabItem()
            }
            if name == "enclosure", item != nil {
                item?.enclosure = attributes["url"] ?? ""; item?.length = Int64(attributes["length"] ?? "")
            }
            if name == "attr", item != nil, let key = attributes["name"], let value = attributes["value"] {
                item?.attributes[key.lowercased()] = value
            }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard item != nil, ["title", "guid", "pubdate", "link"].contains(stack.last ?? "") else { return }
        guard text.utf8.count + string.utf8.count <= 8192 else { fail(parser); return }; text += string
    }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        guard let value = String(data: data, encoding: .utf8) else { fail(parser); return }
        self.parser(parser, foundCharacters: value)
    }
    func parser(
        _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?
    ) {
        let name = name.components(separatedBy: ":").last!.lowercased()
        guard stack.last == name else { fail(parser); return }; stack.removeLast()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "title": item?.title = value;
        case "guid": item?.guid = value;
        case "link": item?.link = value;
        case "pubdate": item?.date = value;
        case "item": if let item { items.append(item) }; item = nil;
        default: break
        }
        text = ""
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName: String, value: String?) {
        fail(parser)
    }
    func parser(
        _ parser: XMLParser, foundExternalEntityDeclarationWithName: String, publicID: String?,
        systemID: String?
    ) { fail(parser) }
    private func fail(_ parser: XMLParser) { invalid = true; parser.abortParsing() }
}
