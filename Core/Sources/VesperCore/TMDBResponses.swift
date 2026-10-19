import Foundation

enum TMDBAuthentication: Equatable {
    case apiKey(String), bearer(String)

    init(_ input: String) throws {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("bearer ") {
            value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard (20...4096).contains(value.count),
            value.unicodeScalars.allSatisfy({
                CharacterSet(
                    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._"
                ).contains($0)
            })
        else { throw TMDBError.invalidCredential }
        if value.count == 32 && value.allSatisfy(\.isHexDigit) {
            self = .apiKey(value)
        } else {
            self = .bearer(value)
        }
    }

    var value: String {
        switch self {
        case .apiKey(let value), .bearer(let value): value
        }
    }
}

struct TMDBConfiguration: Codable, Sendable {
    struct Images: Codable, Sendable {
        let secureBaseUrl: String
        let profileSizes: [String]
        let posterSizes: [String]
        let backdropSizes: [String]
        let stillSizes: [String]?
        let logoSizes: [String]?
    }
    let images: Images

    func episodeImage(_ path: String?) -> String? {
        let sizes = images.stillSizes ?? images.backdropSizes
        let largest = sizes.compactMap { size -> (name: String, width: Int)? in
            guard size.hasPrefix("w"), let width = Int(size.dropFirst()), width > 0 else { return nil }
            return (size, width)
        }.max { $0.width < $1.width }
        guard let preferred = sizes.contains("original") ? "original" : largest?.name else { return nil }
        return image(path, sizes: sizes, preferred: preferred)
    }

    func image(_ path: String?, sizes: [String], preferred: String) -> String? {
        guard let path, path.hasPrefix("/"), !path.contains(".."), !path.contains("?"), !path.contains("#"),
            let base = URL(string: images.secureBaseUrl), base.scheme == "https",
            base.host == "image.tmdb.org",
            let size = sizes.contains(preferred) ? preferred : sizes.first,
            size.allSatisfy({ $0.isLetter || $0.isNumber })
        else { return nil }
        return base.appendingPathComponent(size).appendingPathComponent(String(path.dropFirst()))
            .absoluteString
    }
}

struct TMDBFindResponse: Decodable {
    struct Match: Decodable { let id: Int }
    let movieResults: [Match]?
    let tvResults: [Match]?
}

struct TMDBDetails: Decodable {
    struct Images: Decodable {
        struct Logo: Decodable {
            let filePath: String?
            let iso6391: String?
            let width: Int?
            let voteAverage: Double?
        }
        let logos: [Logo]?
    }
    struct ExternalIDs: Decodable { let imdbId: String? }
    struct Season: Decodable {
        let seasonNumber: Int
        let episodeCount: Int?
    }
    struct Genre: Decodable { let name: String }
    struct Person: Decodable {
        struct Role: Decodable { let character: String? }
        struct Job: Decodable { let job: String? }
        let id: Int
        let name: String
        let character: String?
        let roles: [Role]?
        let profilePath: String?
        let job: String?
        let jobs: [Job]?

        var isDirector: Bool { job == "Director" || jobs?.contains(where: { $0.job == "Director" }) == true }
    }
    struct Credits: Decodable {
        let cast: [Person]?
        let crew: [Person]?
    }
    let id: Int
    let overview: String?
    let tagline: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let runtime: Int?
    let episodeRunTime: [Int]?
    let genres: [Genre]?
    let credits: Credits?
    let aggregateCredits: Credits?
    let createdBy: [Person]?
    let voteAverage: Double?
    let voteCount: Int?
    let externalIds: ExternalIDs?
    let seasons: [Season]?
    let images: Images?

    func enrichment(type: String, configuration: TMDBConfiguration) -> MetadataEnrichment {
        let credits = type == "tv" ? aggregateCredits : credits
        var seen = Set<Int>()
        let cast = (credits?.cast ?? []).filter { !$0.name.isEmpty && seen.insert($0.id).inserted }.prefix(40)
            .map { person in
                var rolesSeen = Set<String>()
                let roles = (person.roles ?? []).compactMap(\.character).filter {
                    !$0.isEmpty && rolesSeen.insert($0).inserted
                }
                let character =
                    person.character?.isEmpty == false
                    ? person.character : roles.isEmpty ? nil : roles.joined(separator: ", ")
                return CastMember(
                    id: person.id, name: person.name, character: character,
                    portraitURL: configuration.image(
                        person.profilePath, sizes: configuration.images.profileSizes, preferred: "w185"))
            }
        var directorIDs = Set<Int>()
        let directorPeople = (credits?.crew ?? []).filter {
            $0.isDirector && $0.id > 0 && !$0.name.isEmpty && directorIDs.insert($0.id).inserted
        }.map { person in
            CastMember(
                id: person.id, name: person.name, character: nil,
                portraitURL: configuration.image(
                    person.profilePath, sizes: configuration.images.profileSizes, preferred: "w185"))
        }
        // Merge repeated movie credits and aggregate TV jobs into one portrait per person.
        var crewOrder: [Int] = []
        var crewByID: [Int: CrewMember] = [:]
        func addCrew(_ person: Person, jobs: [String]) {
            let name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard person.id > 0, !name.isEmpty else { return }
            let previous = crewByID[person.id]
            var seenJobs = Set<String>()
            let roles = ((previous?.jobs ?? []) + jobs).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty && seenJobs.insert($0).inserted }
            if previous == nil { crewOrder.append(person.id) }
            crewByID[person.id] = CrewMember(
                id: person.id, name: previous?.name ?? name, jobs: roles,
                portraitURL: previous?.portraitURL
                    ?? configuration.image(
                        person.profilePath, sizes: configuration.images.profileSizes, preferred: "w185"))
        }
        for person in credits?.crew ?? [] {
            addCrew(person, jobs: [person.job].compactMap { $0 } + (person.jobs ?? []).compactMap(\.job))
        }
        for person in createdBy ?? [] { addCrew(person, jobs: ["Creator"]) }
        let crew = crewOrder.compactMap { crewByID[$0] }.enumerated().sorted {
            let first = $0.element.jobs.contains("Director"), second = $1.element.jobs.contains("Director")
            return first != second ? first : $0.offset < $1.offset
        }.prefix(60).map(\.element)
        let logos = (images?.logos ?? []).filter {
            ($0.iso6391 == "en" || $0.iso6391 == nil)
                && ($0.filePath?.lowercased().hasSuffix(".png") == true
                    || $0.filePath?.lowercased().hasSuffix(".webp") == true)
        }.sorted {
            if ($0.iso6391 == "en") != ($1.iso6391 == "en") { return $0.iso6391 == "en" }
            if ($0.voteAverage ?? 0) != ($1.voteAverage ?? 0) {
                return ($0.voteAverage ?? 0) > ($1.voteAverage ?? 0)
            }
            return ($0.width ?? 0) > ($1.width ?? 0)
        }
        let titleLogoURL = logos.lazy.compactMap {
            configuration.image(
                $0.filePath, sizes: configuration.images.logoSizes ?? configuration.images.posterSizes,
                preferred: "w500")
        }.first
        let date = type == "tv" ? firstAirDate : releaseDate
        let year = date.flatMap { value -> String? in
            let prefix = String(value.prefix(4))

            return prefix.count == 4 && Int(prefix) != nil ? prefix : nil
        }
        return MetadataEnrichment(
            id: id, mediaType: type, overview: overview, tagline: tagline,
            posterURL: configuration.image(
                posterPath, sizes: configuration.images.posterSizes, preferred: "w500"),
            backdropURL: configuration.image(
                backdropPath, sizes: configuration.images.backdropSizes, preferred: "w1280"),
            titleLogoURL: titleLogoURL,
            releaseYear: year, runtimeMinutes: runtime ?? episodeRunTime?.first(where: { $0 > 0 }),
            genres: genres?.map(\.name) ?? [], cast: cast,
            directors: Array(Set(directorPeople.map(\.name))).sorted(), directorPeople: directorPeople,
            crew: crew,
            creators: createdBy?.map(\.name) ?? [], rating: (voteCount ?? 0) > 0 ? voteAverage : nil,
            voteCount: voteCount,
            imdbID: externalIds?.imdbId.flatMap {
                $0.range(of: "^tt[0-9]+$", options: .regularExpression) != nil ? $0 : nil
            },
            seasons: Array(
                Set(
                    (seasons ?? []).filter { $0.seasonNumber >= 0 && ($0.episodeCount ?? 1) > 0 }.map(
                        \.seasonNumber))
            ).sorted())
    }
}

struct TMDBListing: Decodable {
    struct Entry: Decodable {
        let id: Int
        let mediaType: String?
        let title: String?
        let name: String?
        let overview: String?
        let posterPath: String?
        let backdropPath: String?
        let releaseDate: String?
        let firstAirDate: String?
        let voteAverage: Double?
        let voteCount: Int?
        let adult: Bool?
        let popularity: Double?
        let genreIds: [Int]?

        func item(type: String, configuration: TMDBConfiguration) -> MediaItem? {
            guard id > 0, adult != true, type == "movie" || type == "tv",
                let name = type == "movie" ? title : name, !name.isEmpty
            else { return nil }
            return MediaItem(
                id: "tmdb:\(type):\(id)", type: type == "tv" ? "series" : "movie", name: name,
                poster: configuration.image(
                    posterPath, sizes: configuration.images.posterSizes, preferred: "w500"),
                background: configuration.image(
                    backdropPath, sizes: configuration.images.backdropSizes, preferred: "w1280"),
                description: overview,
                releaseInfo: (type == "tv" ? firstAirDate : releaseDate).flatMap {
                    $0.isEmpty ? nil : String($0.prefix(4))
                },
                tmdbRating: (voteCount ?? 0) > 0 ? voteAverage : nil)
        }
    }
    let page: Int
    let totalPages: Int
    let results: [Entry]
}

struct TMDBPersonCredits: Decodable {
    let id: Int
    let cast: [TMDBListing.Entry]
}

struct TMDBGenreList: Decodable {
    let genres: [TMDBGenre]
}

struct TMDBSeasonResponse: Decodable, Sendable {
    struct Video: Decodable, Sendable {
        let name: String?
        let seasonNumber: Int
        let episodeNumber: Int
        let overview: String?
        let stillPath: String?
        let airDate: String?
        let runtime: Int?
    }
    let seasonNumber: Int
    let episodes: [Video]
}
