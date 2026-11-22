import Foundation

/// Biographical details for a cast or crew member, from TMDB with gaps filled from TheTVDB.
public struct PersonProfile: Codable, Hashable, Sendable {
    public var name: String
    public var biography: String?
    /// `yyyy-MM-dd`, as both providers publish it.
    public var birthday: String?
    public var deathday: String?
    public var placeOfBirth: String?
    public var knownFor: String?
    public var aliases: [String]
    public var imdbID: String?
    public var instagram: String?
    public var twitter: String?
    public var tiktok: String?
    public var youtube: String?
    public var homepage: URL?
    public var tmdbID: Int
    public var tvdbID: Int?

    public init(
        name: String, biography: String? = nil, birthday: String? = nil, deathday: String? = nil,
        placeOfBirth: String? = nil, knownFor: String? = nil, aliases: [String] = [], imdbID: String? = nil,
        instagram: String? = nil, twitter: String? = nil, tiktok: String? = nil, youtube: String? = nil,
        homepage: URL? = nil, tmdbID: Int, tvdbID: Int? = nil
    ) {
        self.name = name
        self.biography = biography
        self.birthday = birthday
        self.deathday = deathday
        self.placeOfBirth = placeOfBirth
        self.knownFor = knownFor
        self.aliases = aliases
        self.imdbID = imdbID
        self.instagram = instagram
        self.twitter = twitter
        self.tiktok = tiktok
        self.youtube = youtube
        self.homepage = homepage
        self.tmdbID = tmdbID
        self.tvdbID = tvdbID
    }

    private static let day = Date.ISO8601FormatStyle().year().month().day()

    public var birthDate: Date? { birthday.flatMap(Self.date) }
    public var deathDate: Date? { deathday.flatMap(Self.date) }

    static func date(_ value: String) -> Date? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 10 else { return nil }
        return try? day.parse(String(value.prefix(10)))
    }

    /// Whole years lived, to today or to the date of death.
    public func age(now: Date = Date()) -> Int? {
        guard let birth = birthDate else { return nil }
        let end = deathDate ?? now
        guard end >= birth else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.dateComponents([.year], from: birth, to: end).year
    }

    /// Profile links, in display order. Handles are reduced to safe path components.
    public var links: [PersonLink] {
        var links: [PersonLink] = []
        if let imdbID, imdbID.range(of: #"^nm\d{3,10}$"#, options: .regularExpression) != nil {
            links.append(PersonLink(site: .imdb, url: URL(string: "https://www.imdb.com/name/\(imdbID)/")!))
        }
        func handle(_ value: String?, _ site: PersonLink.Site, _ base: String) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty, value.count <= 100,
                value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }),
                let url = URL(string: base + AddonURL.encode(value))
            else { return }
            links.append(PersonLink(site: site, url: url))
        }
        handle(instagram, .instagram, "https://www.instagram.com/")
        handle(twitter, .x, "https://x.com/")
        handle(tiktok, .tiktok, "https://www.tiktok.com/@")
        handle(youtube, .youtube, "https://www.youtube.com/@")
        if let homepage, ["http", "https"].contains(homepage.scheme?.lowercased() ?? ""), homepage.host != nil
        {
            links.append(PersonLink(site: .website, url: homepage))
        }
        return links
    }

    /// Fills what TMDB left empty with TheTVDB's details, never replacing TMDB's own.
    public func filling(from tvdb: TVDBPersonDetails) -> PersonProfile {
        var result = self
        if result.biography == nil { result.biography = tvdb.biography }
        if result.birthday == nil { result.birthday = tvdb.birthday }
        if result.deathday == nil { result.deathday = tvdb.deathday }
        if result.placeOfBirth == nil { result.placeOfBirth = tvdb.placeOfBirth }
        let known = Set(([result.name] + result.aliases).map { $0.lowercased() })
        result.aliases += tvdb.aliases.filter { !known.contains($0.lowercased()) }
        return result
    }

    /// TMDB appends a Wikipedia attribution line to many biographies; it is not part of the text.
    static func cleanBiography(_ value: String?) -> String? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if let range = text.range(
            of: #"\s*Description above from the Wikipedia article[^\n]*$"#, options: .regularExpression)
        {
            text.removeSubrange(range)
        }
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct PersonLink: Hashable, Identifiable, Sendable {
    public enum Site: String, Sendable {
        case imdb = "IMDb"
        case instagram = "Instagram"
        case x = "X"
        case tiktok = "TikTok"
        case youtube = "YouTube"
        case website = "Website"
    }
    public let site: Site
    public let url: URL
    public var id: String { site.rawValue }
}

/// The parts of a TheTVDB person record used to complete a TMDB profile.
public struct TVDBPersonDetails: Hashable, Sendable {
    public var biography: String?
    public var birthday: String?
    public var deathday: String?
    public var placeOfBirth: String?
    public var aliases: [String]

    public init(
        biography: String? = nil, birthday: String? = nil, deathday: String? = nil,
        placeOfBirth: String? = nil, aliases: [String] = []
    ) {
        self.biography = biography
        self.birthday = birthday
        self.deathday = deathday
        self.placeOfBirth = placeOfBirth
        self.aliases = aliases
    }
}

struct TMDBPersonResponse: Decodable {
    struct ExternalIDs: Decodable {
        let imdbId: String?
        let tvdbId: Int?
        let instagramId: String?
        let twitterId: String?
        let tiktokId: String?
        let youtubeId: String?
    }
    let id: Int
    let name: String?
    let biography: String?
    let birthday: String?
    let deathday: String?
    let placeOfBirth: String?
    let knownForDepartment: String?
    let alsoKnownAs: [String]?
    let homepage: String?
    let externalIds: ExternalIDs?

    var profile: PersonProfile {
        func clean(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return nil
            }
            return value
        }
        let name = clean(name) ?? ""
        var seen = Set([name.lowercased()])
        let aliases = (alsoKnownAs ?? []).compactMap(clean).filter { seen.insert($0.lowercased()).inserted }
        return PersonProfile(
            name: name, biography: PersonProfile.cleanBiography(biography),
            birthday: clean(birthday).flatMap { PersonProfile.date($0) == nil ? nil : $0 },
            deathday: clean(deathday).flatMap { PersonProfile.date($0) == nil ? nil : $0 },
            placeOfBirth: clean(placeOfBirth), knownFor: clean(knownForDepartment), aliases: aliases,
            imdbID: clean(externalIds?.imdbId), instagram: clean(externalIds?.instagramId),
            twitter: clean(externalIds?.twitterId), tiktok: clean(externalIds?.tiktokId),
            youtube: clean(externalIds?.youtubeId), homepage: clean(homepage).flatMap(URL.init(string:)),
            tmdbID: id, tvdbID: externalIds?.tvdbId.flatMap { $0 > 0 ? $0 : nil })
    }
}
