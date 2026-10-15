import Foundation
import Observation

public struct TMDBGenre: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let name: String
}

public struct PersonCredit: Codable, Hashable, Identifiable, Sendable {
    public let media: MediaItem
    public let genreIDs: [Int]
    public let popularity: Double
    public let releaseDate: String?
    public let voteCount: Int

    public var id: String { media.key }

    public var year: Int? { releaseDate.flatMap { Int($0.prefix(4)) } }
}

public enum FilmographySort: String, CaseIterable, Identifiable, Sendable {
    case popularity, rating, newest, oldest, title

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .popularity: "Popularity"
        case .rating: "Rating"
        case .newest: "Newest first"
        case .oldest: "Oldest first"
        case .title: "Title A–Z"
        }
    }
}

public struct PersonFilmography: Codable, Sendable {
    public let credits: [PersonCredit]
    public let genres: [TMDBGenre]

    private func matching(_ type: String) -> [PersonCredit] {
        credits.filter { type == "all" || $0.media.type == type }
    }

    public func genres(type: String) -> [TMDBGenre] {
        let ids = Set(matching(type).flatMap(\.genreIDs))
        return genres.filter { ids.contains($0.id) }
    }

    public func years(type: String) -> [Int] {
        Array(Set(matching(type).compactMap(\.year))).sorted(by: >)
    }

    public func items(
        type: String = "all", genreID: Int? = nil, year: Int? = nil,
        sort: FilmographySort = .popularity
    ) -> [MediaItem] {
        matching(type).filter { credit in
            (genreID.map { credit.genreIDs.contains($0) } ?? true) && (year == nil || credit.year == year)
        }.sorted { lhs, rhs in
            switch sort {
            case .popularity:
                if lhs.popularity != rhs.popularity { return lhs.popularity > rhs.popularity }
            case .rating:
                let left = lhs.media.tmdbRating ?? -1, right = rhs.media.tmdbRating ?? -1
                if left != right { return left > right }
                if lhs.voteCount != rhs.voteCount { return lhs.voteCount > rhs.voteCount }
            case .newest, .oldest:
                if lhs.releaseDate != rhs.releaseDate {
                    guard let left = lhs.releaseDate else { return false }
                    guard let right = rhs.releaseDate else { return true }
                    return sort == .newest ? left > right : left < right
                }
            case .title:
                let order = lhs.media.name.localizedStandardCompare(rhs.media.name)
                if order != .orderedSame { return order == .orderedAscending }
            }
            if lhs.popularity != rhs.popularity { return lhs.popularity > rhs.popularity }
            let order = lhs.media.name.localizedStandardCompare(rhs.media.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }.map(\.media)
    }
}

@MainActor @Observable
public final class PersonFilmographyController {
    public private(set) var value: PersonFilmography?
    public private(set) var loading = false
    public private(set) var error: String?
    @ObservationIgnored private var generation = UUID()

    public init() {}

    public func clear() {
        generation = UUID()
        value = nil
        loading = false
        error = nil
    }

    public func load(using fetch: @MainActor () async throws -> PersonFilmography) async {
        let current = UUID()
        generation = current
        loading = true
        error = nil
        defer { if generation == current { loading = false } }
        do {
            let result = try await fetch()
            guard !Task.isCancelled, generation == current else { return }
            value = result
        } catch is CancellationError {} catch {
            if !Task.isCancelled, generation == current { self.error = error.localizedDescription }
        }
    }
}
