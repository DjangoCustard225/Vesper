import Foundation

public enum AddonError: LocalizedError, Equatable {
    case invalidURL, invalidManifest, configurationRequired, http(Int), invalidResponse, network,
        unsupportedStream

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid HTTP or HTTPS URL."
        case .invalidManifest: "This endpoint did not return a valid add-on manifest."
        case .configurationRequired:
            "Configure this add-on on its website, then paste the generated manifest URL."
        case .http(let status): "The add-on returned HTTP \(status). Try again or check its configuration."
        case .invalidResponse: "The add-on returned an unreadable response."
        case .network: "Couldn’t connect. Check your connection and the add-on address."
        case .unsupportedStream:
            "This source can’t be opened in an external player. Choose an HTTP video source or an external link."
        }
    }
}

public enum AddonURL {
    // Escape a single path value, including /, ?, &, =, + and Unicode.
    public static func encode(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? ""
    }

    public static func http(_ input: String) throws -> URL {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: input), ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
            c.host?.isEmpty == false, c.user == nil, c.password == nil, let url = c.url
        else { throw AddonError.invalidURL }
        return url
    }

    public static func manifest(_ input: String) throws -> URL {
        var input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.lowercased().hasPrefix("stremio://") { input = "https://" + input.dropFirst(10) }
        let url = try http(input)
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AddonError.invalidURL
        }
        c.fragment = nil
        if !c.path.hasSuffix("/manifest.json") {
            c.percentEncodedPath =
                c.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    .isEmpty ? "/manifest.json" : c.percentEncodedPath.trimmingSuffix("/") + "/manifest.json"
        }
        guard let result = c.url else { throw AddonError.invalidURL }
        return result
    }

    public static func resource(
        manifest: URL, resource: String, type: String, id: String, extras: [String: String] = [:]
    ) throws -> URL {
        guard var c = URLComponents(url: manifest, resolvingAgainstBaseURL: false),
            c.path.hasSuffix("/manifest.json")
        else { throw AddonError.invalidURL }
        c.fragment = nil
        let base = String(c.percentEncodedPath.dropLast("/manifest.json".count))
        let extra = extras.sorted { $0.key < $1.key }.map { encode($0.key) + "=" + encode($0.value) }.joined(
            separator: "&")
        c.percentEncodedPath =
            base + "/" + [resource, type, id].map(encode).joined(separator: "/")
            + (extra.isEmpty ? "" : "/" + extra) + ".json"
        guard let url = c.url else { throw AddonError.invalidURL }
        return url
    }

    public static func configure(_ manifest: URL) -> URL? {
        guard var c = URLComponents(url: manifest, resolvingAgainstBaseURL: false),
            c.path.hasSuffix("/manifest.json")
        else { return nil }
        c.percentEncodedPath = String(c.percentEncodedPath.dropLast("manifest.json".count)) + "configure"
        return c.url
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
