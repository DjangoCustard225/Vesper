import Foundation
import Observation

@MainActor @Observable
public final class UpNextFeedController {
    private enum Resolution: Sendable { case resolved(Item?), failed }
    public struct Item: Identifiable, Sendable {
        public let media: MediaItem
        public let episode: Episode
        public var id: String { media.key }

        public init(media: MediaItem, episode: Episode) {
            self.media = media
            self.episode = episode
        }
    }

    public private(set) var items: [Item] = []
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var retained: [UpNext.Seed: Item] = [:]
    @ObservationIgnored private var context: String?

    public init() {}

    public func load(
        _ seeds: [UpNext.Seed], context: String = "",
        resolve: @escaping @MainActor @Sendable (UpNext.Seed) async throws -> Item?
    ) async {
        let token = UUID()
        generation = token
        if self.context != context { retained = [:] }
        self.context = context
        let activeSeeds = Set(seeds)
        retained = retained.filter { activeSeeds.contains($0.key) }
        items = seeds.compactMap { retained[$0] }
        var results: [Int: Item] = [:]
        await ConcurrentWork.run(
            seeds, limit: 3,
            operation: { seed in
                do { return Resolution.resolved(try await resolve(seed)) } catch { return .failed }
            }
        ) { index, resolution in
            guard self.generation == token, !Task.isCancelled else { return }
            let item: Item?
            switch resolution {
            case .resolved(let value): item = value
            case .failed: item = self.retained[seeds[index]]
            }
            if let item { results[index] = item }
        }
        guard generation == token, !Task.isCancelled else { return }
        // Publish once so an offscreen refresh cannot repeatedly change the section's height.
        retained = Dictionary(
            uniqueKeysWithValues: seeds.enumerated().compactMap { index, seed in
                results[index].map { (seed, $0) }
            })
        items = seeds.compactMap { retained[$0] }
    }

    public func cancel() { generation = UUID() }
}
