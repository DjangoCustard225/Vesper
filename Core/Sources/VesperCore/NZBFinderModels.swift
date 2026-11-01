import Foundation

public enum NZBFinderError: Error, LocalizedError, Equatable, Sendable {
    case missingKey, unauthorized, privileges, rateLimited, unavailable, invalidResponse, missingEpisode,
        unsupported, missingRelease
    public var errorDescription: String? {
        switch self {
        case .missingKey: "Add your NZBFinder API key in Settings → Usenet → NZBFinder."
        case .unauthorized: "NZBFinder rejected the API key. Check your account and key."
        case .privileges: "Your NZBFinder account does not allow this API operation."
        case .rateLimited: "Your NZBFinder request or NZB limit has been reached. Try again later."
        case .unavailable: "NZBFinder is unavailable or blocked the request. Try again later."
        case .invalidResponse: "NZBFinder returned an invalid or incomplete response."
        case .missingEpisode: "Episode season and number are needed to search NZBFinder."
        case .unsupported: "NZBFinder does not support this search."
        case .missingRelease: "This NZBFinder release is no longer available. Choose another source."
        }
    }
}

public struct NZBSearchContext: Hashable, Sendable {
    public let title: String
    public let year: String?
    public let imdbID: String?
    public let tmdbID: Int?
    public let tvdbID: Int?
    public let season: Int?
    public let episode: Int?
    public let airDate: String?
    public var isEpisode: Bool { season != nil }
    public let seasonPack: Bool
    public init(
        media: MediaItem, episode: Episode? = nil, details: MetadataEnrichment? = nil,
        seasonPack: Bool = false
    ) throws {
        self.seasonPack = seasonPack && media.type == "series"
        let item = details?.applying(to: media) ?? media
        guard media.type == "movie" || media.type == "series" else { throw NZBFinderError.unsupported }
        if media.type == "series" {
            guard let s = episode?.season, let e = episode?.episode, s >= 0, e > 0 else {
                throw NZBFinderError.missingEpisode
            }
            season = s; self.episode = e
        } else {
            season = nil; self.episode = nil
        }
        guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.name.utf8.count <= 2048
        else { throw NZBFinderError.unsupported }
        title = item.name
        let value = String((item.releaseInfo ?? "").prefix(4))
        year = Int(value).map { (1800...2200).contains($0) } == true ? value : nil
        imdbID = MediaIdentity.validIMDb(item.imdbID) ?? MediaIdentity.validIMDb(item.id)
        tmdbID = item.tmdbID.flatMap { $0 > 0 ? $0 : nil }
        tvdbID = item.tvdbID.flatMap { $0 > 0 ? $0 : nil }
        airDate = episode?.released.map { String($0.prefix(10)) }
    }
    var key: String {
        [
            title, year ?? "", imdbID ?? "", String(tmdbID ?? 0), String(tvdbID ?? 0), String(season ?? -1),
            String(episode ?? -1), airDate ?? "", seasonPack ? "pack" : "episode",
        ].joined(separator: "|")
    }
    var seasonToken: String { String(format: "S%02d", season ?? 0) }
    var episodeToken: String { String(format: "S%02dE%02d", season ?? 0, episode ?? 0) }
}

public struct NZBRelease: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let size: Int64?
    public let posted: Date?
    public let isSeasonPack: Bool
    public let requiresPassword: Bool
    public init(
        id: String, title: String, size: Int64? = nil, posted: Date? = nil, isSeasonPack: Bool = false,
        requiresPassword: Bool = false
    ) {
        self.id = id; self.title = title; self.size = size; self.posted = posted
        self.isSeasonPack = isSeasonPack; self.requiresPassword = requiresPassword
    }
    public var streamOption: StreamOption {
        // This reference deliberately contains no API key. Only the indexer client authenticates retrieval.
        var url = URLComponents(string: "https://nzbfinder.ws/api")!
        url.queryItems = [URLQueryItem(name: "t", value: "get"), URLQueryItem(name: "id", value: id)]
        let source = StreamSource(
            name: "NZBFinder", title: title,
            description: [isSeasonPack ? "Season pack" : nil, requiresPassword ? "Encrypted" : nil].compactMap
            { $0 }.joined(separator: " · "), url: nil, externalUrl: nil, ytId: nil,
            infoHash: nil, fileIdx: nil, sources: nil, behaviorHints: nil, nzbUrl: url.url!.absoluteString,
            servers: nil, fileMustInclude: nil)
        return StreamOption(addonName: "NZBFinder", source: source, nzbRelease: self)
    }
}
public struct NZBSearchCursor: Hashable, Sendable {
    public let offset: Int
    public let titleSearch: Bool
    public init(offset: Int, titleSearch: Bool) { self.offset = offset; self.titleSearch = titleSearch }
}
public struct NZBSearchPage: Sendable {
    public let releases: [NZBRelease]
    public let next: NZBSearchCursor?
    public init(releases: [NZBRelease], next: NZBSearchCursor? = nil) {
        self.releases = releases; self.next = next
    }
}

struct NewznabCapabilities: Sendable {
    var maximum = 50
    var search: Set<String> = []
    var movie: Set<String> = []
    var tv: Set<String> = []
    func query(_ context: NZBSearchContext, titleOnly: Bool) throws -> [URLQueryItem] {
        let specific = context.isEpisode ? tv : movie
        var function = context.isEpisode ? "tvsearch" : "movie", values: [(String, String)] = []
        let ids: [(String, String?)] =
            context.isEpisode
            ? [
                ("tvdbid", context.tvdbID.map(String.init)),
                ("imdbid", context.imdbID.flatMap(NewznabIdentity.imdb)),
                ("tmdbid", context.tmdbID.map(String.init)),
            ]
            : [
                ("imdbid", context.imdbID.flatMap(NewznabIdentity.imdb)),
                ("tmdbid", context.tmdbID.map(String.init)),
            ]
        let supportsEpisode =
            !context.isEpisode
            || (specific.contains("season") && (context.seasonPack || specific.contains("ep")))
        if !titleOnly, supportsEpisode, let id = ids.first(where: { $0.1 != nil && specific.contains($0.0) })
        {
            values.append((id.0, id.1!))
        } else {
            if search.contains("q") {
                function = "search"
                values.append(
                    (
                        "q",
                        context.title
                            + (context.isEpisode
                                ? " " + (context.seasonPack ? context.seasonToken : context.episodeToken)
                                : context.year.map { " " + $0 } ?? "")
                    ))
            } else if specific.contains("q"), supportsEpisode {
                values.append(
                    ("q", context.title + (!context.isEpisode ? context.year.map { " " + $0 } ?? "" : "")))
            } else {
                throw NZBFinderError.unsupported
            }
        }
        if context.isEpisode, function == "tvsearch" {
            values.append(("season", String(context.season!)))
            if !context.seasonPack { values.append(("ep", String(context.episode!))) }
        }
        values += [("t", function), ("cat", context.isEpisode ? "5000" : "2000")]
        return values.map { URLQueryItem(name: $0.0, value: $0.1) }
    }
}

struct NewznabItem {
    var title = "", guid = "", enclosure = "", date = "", link = ""
    var length: Int64?
    var attributes: [String: String] = [:]
    func release(context: NZBSearchContext?, titleSearch: Bool) -> NZBRelease? {
        let password = (attributes["password"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !title.isEmpty, title.utf8.count <= 4096 else { return nil }
        let protected = ["true", "yes"].contains(password) || (Int(password) ?? 0) > 0
        if let context {
            // Numeric Newznab IDs omit IMDb's padding. Zero means unknown, not a conflicting title.
            // A constrained title fallback intentionally tolerates incorrect indexer ID metadata.
            if !titleSearch {
                if let actual = NewznabIdentity.imdb(attributes["imdb"] ?? attributes["imdbid"]),
                    let expected = NewznabIdentity.imdb(context.imdbID), actual != expected
                {
                    return nil
                }
                if let value = Int(attributes["tvdbid"] ?? ""), value > 0,
                    let expected = context.tvdbID, value != expected
                {
                    return nil
                }
                if let value = Int(attributes["tmdbid"] ?? ""), value > 0,
                    let expected = context.tmdbID, value != expected
                {
                    return nil
                }
            }
            if context.isEpisode {
                let season = Int(attributes["season"] ?? ""), ep = Int(attributes["episode"] ?? "")
                if let season, season != context.season { return nil }
                if context.seasonPack {
                    // A season search also returns individual episodes on many Newznab indexers.
                    // Require a season marker and reject single-episode releases even when ep=0.
                    let single =
                        title.range(
                            of: #"(?i)(?<![a-z0-9])(?:s[0-9]+[ ._-]*e[0-9]+|[0-9]+x[0-9]+)(?![0-9])"#,
                            options: .regularExpression) != nil
                    let token =
                        "(?i)(?<![a-z0-9])(?:s0*\(context.season!)|season[ ._-]*0*\(context.season!))(?![a-z0-9])"
                    guard !single, ep == nil || ep == 0,
                        season == context.season || title.range(of: token, options: .regularExpression) != nil
                    else { return nil }
                } else {
                    if attributes["episode"] != nil, ep != context.episode { return nil }
                    if season == nil || ep == nil {
                        let s = context.season!, e = context.episode!
                        let pattern = "(?i)(?<![a-z0-9])(?:s0*\(s)[ ._-]*e0*\(e)|0*\(s)x0*\(e))(?![0-9])"
                        let episodeMatch = title.range(of: pattern, options: .regularExpression) != nil
                        let dateMatch =
                            context.airDate.map { date in
                                date.count == 10
                                    && title.replacingOccurrences(of: ".", with: "-").replacingOccurrences(
                                        of: "_", with: "-"
                                    ).contains(date)
                            } ?? false
                        guard episodeMatch || dateMatch else { return nil }
                    }
                }
            }
            let matchingID =
                (NewznabIdentity.imdb(attributes["imdb"] ?? attributes["imdbid"]) != nil
                    && NewznabIdentity.imdb(attributes["imdb"] ?? attributes["imdbid"])
                        == NewznabIdentity.imdb(context.imdbID))
                || (Int(attributes["tmdbid"] ?? "").flatMap { $0 > 0 ? $0 : nil } != nil
                    && Int(attributes["tmdbid"] ?? "") == context.tmdbID)
                || (Int(attributes["tvdbid"] ?? "").flatMap { $0 > 0 ? $0 : nil } != nil
                    && Int(attributes["tvdbid"] ?? "") == context.tvdbID)
            if context.isEpisode && !titleSearch && !matchingID {
                // TV searches can return every show with the requested SxxExx. Require the
                // normalized release title to begin with this show's title before accepting it.
                let expected = NewznabTitle.tokens(context.title)
                let actual = NewznabTitle.tokens(title)
                let ignored: Set<String> = ["the", "a", "an", "of", "and"]
                let required = expected.filter { !ignored.contains($0) }
                let releasePrefix = actual.filter { !ignored.contains($0) }.prefix(required.count)
                guard !required.isEmpty, Array(releasePrefix).elementsEqual(required) else { return nil }
            }
            if titleSearch || (!context.isEpisode && !matchingID) {
                let tokens = NewznabTitle.tokens
                let words = Set(tokens(title)),
                    expected = tokens(context.title).filter { !["the", "a", "an", "of", "and"].contains($0) }
                let required = expected.isEmpty ? tokens(context.title) : expected
                guard required.allSatisfy(words.contains) else { return nil }
                if !context.isEpisode {
                    let actual = tokens(title).filter { !["the", "a", "an", "of", "and"].contains($0) }
                    guard actual.count >= required.count,
                        actual.starts(with: required)
                    else { return nil }
                }
                if !context.isEpisode, let year = context.year, !words.contains(year),
                    attributes["year"] != year
                {
                    return nil
                }
            }
            if context.isEpisode, let year = context.year,
                let releaseYear = NewznabTitle.yearImmediatelyAfterTitle(title, title: context.title),
                releaseYear != year
            {
                // The original and 2024 Avatar series share a name. A release year directly
                // after the series title identifies the version; untagged releases remain usable.
                return nil
            }
        }
        guard
            let id = [enclosure, guid, link, attributes["guid"] ?? ""].compactMap(NewznabIdentity.releaseID)
                .first
        else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX");
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return NZBRelease(
            id: id, title: title,
            size: (Int64(attributes["size"] ?? "") ?? length).flatMap { $0 > 0 ? $0 : nil },
            posted: formatter.date(from: date), isSeasonPack: context?.seasonPack == true,
            requiresPassword: protected)
    }
}

private enum NewznabTitle {
    static func tokens(_ value: String) -> [String] {
        value.folding(
            options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")
        )
        .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    static func yearImmediatelyAfterTitle(_ release: String, title: String) -> String? {
        let ignored: Set<String> = ["the", "a", "an", "of", "and"]
        let expected = tokens(title).filter { !ignored.contains($0) }
        let actual = tokens(release).filter { !ignored.contains($0) }
        guard !expected.isEmpty, actual.count > expected.count,
            Array(actual.prefix(expected.count)).elementsEqual(expected)
        else { return nil }
        let candidate = actual[expected.count]
        guard let year = Int(candidate), (1800...2099).contains(year), year != 1080, year != 2160 else {
            return nil
        }
        return candidate
    }
}

/// Normalize identifiers only. Feed links are never followed or retained as authenticated URLs.
enum NewznabIdentity {
    static func imdb(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        if value.hasPrefix("tt") { value.removeFirst(2) }
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let number = String(value.drop(while: { $0 == "0" }))
        return number.isEmpty ? nil : number
    }
    static func releaseID(_ value: String) -> String? {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parts = URLComponents(string: value),
            parts.scheme != nil || parts.host != nil || value.hasPrefix("/")
        {
            if parts.scheme != nil || parts.host != nil {
                guard ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
                    ["nzbfinder.ws", "www.nzbfinder.ws"].contains(parts.host?.lowercased() ?? "")
                else { return nil }
            }
            if let id = parts.queryItems?.first(where: { ["id", "guid"].contains($0.name.lowercased()) })?
                .value
            {
                value = id
            } else if parts.path.contains("/details/") || parts.path.lowercased().hasSuffix(".nzb") {
                value = (parts.path as NSString).lastPathComponent
            } else {
                return nil
            }
        }
        if value.lowercased().hasSuffix(".nzb") { value.removeLast(4) }
        guard !value.isEmpty, value.utf8.count <= 256,
            value.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0)
            })
        else { return nil }
        return value
    }
}

/// Retrieval-only information. Archive keys are never attached to source URLs or saved search results.
public struct NZBDownload: Sendable {
    public let data: Data
    public let password: String?
    public init(data: Data, password: String? = nil) { self.data = data; self.password = password }
}
