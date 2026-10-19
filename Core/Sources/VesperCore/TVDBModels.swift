import Foundation

public struct TVDBCredentials: Codable, Equatable, Sendable {
    public let apiKey: String
    public let pin: String?

    public init(apiKey: String, pin: String? = nil) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = pin?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 1024,
            !key.contains(where: { $0.isWhitespace || $0.isNewline }),
            (value?.count ?? 0) <= 256
        else { throw TVDBError.invalidCredential }
        self.apiKey = key
        self.pin = value?.isEmpty == false ? value : nil
    }

    var fingerprint: String { ResponseCache.fingerprint(apiKey + ":" + (pin ?? "")) }
}

public enum TVDBError: LocalizedError, Equatable {
    case invalidCredential, unauthorized, rateLimited, unavailable, invalidResponse, missingPlaybackIdentity

    public var errorDescription: String? {
        switch self {
        case .invalidCredential: "Enter your TVDB API key and subscriber PIN if required."
        case .unauthorized: "TVDB rejected these credentials. Check your API key, PIN and subscription."
        case .rateLimited: "TVDB is temporarily limiting requests. Try again shortly."
        case .unavailable: "TVDB couldn’t be reached. Try again shortly."
        case .invalidResponse: "TVDB returned an unreadable response. Try again shortly."
        case .missingPlaybackIdentity: "This show has no known playback ID. Try another metadata provider."
        }
    }
}

struct TVDBResponse<Value: Codable & Sendable>: Codable, Sendable {
    let status: String?
    let data: Value?
    let links: TVDBLinks?
}
struct TVDBLinks: Codable, Sendable { let next: String? }
struct TVDBLogin: Codable, Sendable { let token: String }
struct TVDBRemoteMatch: Codable, Sendable { let series: TVDBRecord? }
struct TVDBRecord: Codable, Sendable { let id: Int }
struct TVDBRemoteID: Codable, Sendable {
    let id: String
    let sourceName: String?
    var tmdbID: Int? {
        let source = (sourceName ?? "").lowercased().filter { $0.isLetter || $0.isNumber }
        guard source.hasPrefix("themoviedb") || source.hasPrefix("themoviedatabase"),
            let number = Int(id), number > 0
        else { return nil }
        return number
    }
}
struct TVDBNamedRecord: Codable, Sendable {
    let id: Int?
    let name: String?
    let slug: String?
    let recordType: String?
    let type: String?
}
struct TVDBSeason: Codable, Sendable {
    let number: Int?
    let type: TVDBNamedRecord?
}
struct TVDBTranslation: Codable, Sendable {
    let language: String?
    let overview: String?
}
struct TVDBTranslations: Codable, Sendable { let overviewTranslations: [TVDBTranslation]? }
struct TVDBArtwork: Codable, Sendable {
    let image: String?
    let type: Int?
    let language: String?
    let score: Double?
    let width: Int?
}
struct TVDBCharacter: Codable, Sendable {
    let peopleId: Int?
    let personName: String?
    let name: String?
    let personImgURL: String?
    let peopleType: String?
    let sort: Int?
}
struct TVDBSeries: Codable, Sendable {
    let id: Int
    let overview: String?
    let image: String?
    let firstAired: String?
    let averageRuntime: Int?
    let genres: [TVDBNamedRecord]?
    let characters: [TVDBCharacter]?
    let artworks: [TVDBArtwork]?
    let remoteIds: [TVDBRemoteID]?
    let seasons: [TVDBSeason]?
    let translations: TVDBTranslations?

    func enrichment(artworkTypes: [TVDBNamedRecord]) -> MetadataEnrichment {
        func artwork(_ kind: String) -> String? {
            let types = Set(
                artworkTypes.filter {
                    $0.recordType?.lowercased() == "series" && $0.name?.lowercased().contains(kind) == true
                }.compactMap(\.id))
            let images = (artworks ?? []).filter { types.contains($0.type ?? -1) }
            let sorted = images.sorted {
                let a = $0.language == "eng" ? 2 : ($0.language == nil || $0.language == "" ? 1 : 0)
                let b = $1.language == "eng" ? 2 : ($1.language == nil || $1.language == "" ? 1 : 0)
                if a != b { return a > b }
                if $0.score != $1.score { return ($0.score ?? 0) > ($1.score ?? 0) }
                return ($0.width ?? 0) > ($1.width ?? 0)
            }
            return sorted.compactMap { TVDBImage.url($0.image) }.first
        }
        var cast: [CastMember] = [], crew: [CrewMember] = []
        let people = (characters ?? []).sorted { ($0.sort ?? Int.max) < ($1.sort ?? Int.max) }
        for person in people {
            guard let id = person.peopleId, id > 0, let name = person.personName?.nonempty,
                let portrait = TVDBImage.url(person.personImgURL)
            else { continue }
            let role = person.peopleType?.nonempty ?? "Actor"
            if role.lowercased() == "actor" || role.lowercased() == "guest star" {
                if !cast.contains(where: { $0.id == id }) {
                    cast.append(
                        CastMember(
                            id: id, name: name, character: person.name?.nonempty,
                            portraitURL: portrait, provider: .tvdb))
                }
            } else if let index = crew.firstIndex(where: { $0.id == id }) {
                let old = crew[index]
                if !old.jobs.contains(role) {
                    crew[index] = CrewMember(
                        id: id, name: name, jobs: old.jobs + [role],
                        portraitURL: portrait, provider: .tvdb)
                }
            } else {
                crew.append(
                    CrewMember(id: id, name: name, jobs: [role], portraitURL: portrait, provider: .tvdb))
            }
        }
        let imdb = remoteIds?.first { $0.sourceName?.lowercased() == "imdb" }.flatMap {
            MediaIdentity.validIMDb($0.id)
        }
        let tmdb = remoteIds?.compactMap(\.tmdbID).first
        let overview =
            translations?.overviewTranslations?.first { $0.language == "eng" }?.overview?.nonempty
            ?? self.overview?.nonempty
        let seasons = Array(
            Set(
                (seasons ?? []).filter {
                    $0.type?.typeIsOfficial == true
                }.compactMap(\.number).filter { $0 >= 0 })
        ).sorted()
        return MetadataEnrichment(
            id: id, mediaType: "tv", overview: overview, tagline: nil,
            posterURL: artwork("poster") ?? TVDBImage.url(image), backdropURL: artwork("background"),
            titleLogoURL: artwork("clearlogo"),
            releaseYear: firstAired?.nonempty.map { String($0.prefix(4)) },
            runtimeMinutes: averageRuntime.flatMap { $0 > 0 ? $0 : nil },
            genres: (genres ?? []).compactMap(\.name),
            cast: Array(cast.prefix(40)), directors: crew.filter { $0.jobs.contains("Director") }.map(\.name),
            directorPeople: [], crew: Array(crew.prefix(40)), creators: [], rating: nil, voteCount: nil,
            imdbID: imdb, seasons: seasons, provider: .tvdb, linkedTMDBID: tmdb)
    }
}
extension TVDBNamedRecord {
    var typeIsOfficial: Bool {
        type?.lowercased() == "official" || slug?.lowercased() == "official"
            || name?.lowercased() == "aired order"
            || name?.lowercased() == "official order"
    }
}
struct TVDBEpisodes: Codable, Sendable {
    let series: TVDBRecord?
    let episodes: [TVDBEpisode]?
}
struct TVDBEpisode: Codable, Sendable {
    let id: Int
    let seriesId: Int?
    let seasonNumber: Int?
    let number: Int?
    let name: String?
    let overview: String?
    let image: String?
    let aired: String?
    let runtime: Int?
}
struct TVDBPerson: Codable, Sendable { let id: Int; let remoteIds: [TVDBRemoteID]? }

enum TVDBImage {
    static func url(_ value: String?) -> String? {
        guard let value = value?.nonempty else { return nil }
        let text =
            value.hasPrefix("/")
            ? "https://artworks.thetvdb.com" + value
            : (value.contains("://")
                ? value
                : "https://artworks.thetvdb.com/"
                    + (value.hasPrefix("banners/") ? value : "banners/" + value))
        guard let url = try? AddonURL.http(text), url.scheme == "https",
            let host = url.host?.lowercased(), host == "thetvdb.com" || host.hasSuffix(".thetvdb.com"),
            !["svg", "pdf"].contains(url.pathExtension.lowercased())
        else { return nil }
        return url.absoluteString
    }
}
extension String {
    var nonempty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
