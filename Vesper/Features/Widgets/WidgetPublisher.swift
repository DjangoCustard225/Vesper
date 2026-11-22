import CryptoKit
import Foundation
import UIKit
import VesperCore
import WidgetKit

/// Writes Continue Watching, Up Next, Library and the first Home catalogs to the shared container and
/// reloads the widgets. Artwork is saved as small JPEGs because widgets can't load images from the network.
@MainActor
final class WidgetPublisher {
    static let shared = WidgetPublisher()

    static let continueWatchingLimit = 6
    static let upNextLimit = 6
    static let shelfLimit = 12
    static let catalogLimit = 4
    /// Backdrops are only drawn for the first items of a poster shelf.
    static let shelfBackdropLimit = 6

    private var scheduled: Task<Void, Never>?
    private var published: WidgetShelf?
    private let upNextFeed = UpNextFeedController()
    private var upNextRequest: UpNextRequest?

    private struct UpNextRequest {
        let seeds: [UpNext.Seed]
        let context: String
        let loaded: Date

        func matches(_ other: UpNextRequest) -> Bool {
            // New episodes air without any local change, so the feed is refreshed every few hours.
            seeds == other.seeds && context == other.context
                && other.loaded.timeIntervalSince(loaded) < 6 * 3600
        }
    }

    private struct ArtworkJob: Sendable {
        let file: String
        let url: URL
        let size: ArtworkDecodeSize?
    }

    private init() {}

    func schedule(store: AppStore, delay: Duration = .seconds(2)) {
        scheduled?.cancel()
        scheduled = Task { [weak store] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let store else { return }
            await self.publish(store: store, refreshUpNext: false)
        }
    }

    /// Publishes now. A background refresh passes `refreshUpNext` to look for newly aired episodes.
    func publish(store: AppStore, refreshUpNext: Bool) async {
        guard let directory = SharedContainer.shelfDirectory else { return }
        // Publishing before saved data is read would empty the widgets.
        await store.waitUntilLoaded()
        guard !Task.isCancelled else { return }
        let previous = published ?? WidgetShelf.load()
        let upNext = await upNextItems(store: store, force: refreshUpNext)
        guard !Task.isCancelled else { return }

        var jobs: [String: ArtworkJob] = [:]
        func artwork(_ source: String?, wide: Bool) -> String? {
            guard let source, let url = URL(string: source) else { return nil }
            let digest = SHA256.hash(data: Data((source + (wide ? "|wide" : "|poster")).utf8))
            let file = digest.prefix(12).map { String(format: "%02x", $0) }.joined() + ".jpg"
            jobs[file] = ArtworkJob(
                file: file, url: url,
                size: wide
                    ? ArtworkDecodeSize(width: 360, height: 203, scale: 2)
                    : ArtworkDecodeSize(width: 120, height: 180, scale: 2))
            return file
        }
        func item(_ media: MediaItem, backdrop: Bool, poster: Bool) -> WidgetShelf.Item {
            WidgetShelf.Item(
                id: media.id, type: media.type, title: media.name,
                backdropImage: backdrop ? artwork(media.background ?? media.poster, wide: true) : nil,
                posterImage: poster ? artwork(media.poster, wide: false) : nil,
                posterURL: media.poster, key: media.key)
        }
        func shelf(_ items: [MediaItem]) -> [WidgetShelf.Item] {
            items.prefix(Self.shelfLimit).enumerated().map { index, media in
                item(media, backdrop: index < Self.shelfBackdropLimit, poster: true)
            }
        }

        let continuing =
            store.showContinueWatching
            ? Array(store.watchProgress.continueWatching.prefix(Self.continueWatchingLimit)) : []
        let presentation = store.catalogPresentation
        let rows = presentation.rows.filter { !$0.items.isEmpty }.prefix(Self.catalogLimit)
        // Home catalogs only load in the foreground, so until they do the last ones are kept,
        // unless no catalogs are enabled at all.
        let keepCatalogs = rows.isEmpty && !presentation.availableCatalogs.isEmpty
        let shelf = WidgetShelf(
            continueWatching: continuing.map { record in
                var value = item(record.media, backdrop: true, poster: true)
                let episode = record.episodeKey?.split(separator: ":").compactMap { Int($0) }
                if let episode, episode.count == 2 {
                    value.season = episode[0]
                    value.episode = episode[1]
                    value.episodeLabel = "S\(episode[0]) · E\(episode[1])"
                }
                value.subtitle = Self.subtitle(record, label: value.episodeLabel)
                value.progress = record.duration > 0 ? min(1, record.elapsed / record.duration) : nil
                value.updatedAt = record.updatedAt
                return value
            },
            upNext: upNext.map { next in
                var value = item(next.media, backdrop: true, poster: true)
                value.season = next.episode.season
                value.episode = next.episode.episode
                value.episodeLabel = next.episode.season == nil ? nil : next.episode.label
                value.subtitle = [value.episodeLabel, next.episode.title ?? next.episode.name]
                    .compactMap { $0 }.joined(separator: " · ")
                value.released = UpNext.releaseDate(of: next.episode)
                value.updatedAt =
                    store.watchProgress.records.filter { $0.media.isSameTitle(as: next.media) }
                    .map(\.updatedAt).max()
                return value
            },
            library: shelf(store.library.items),
            catalogs: keepCatalogs
                ? previous.catalogs
                : rows.map { WidgetShelf.Catalog(id: $0.id, title: $0.title, items: shelf($0.items)) })
        guard shelf != published else { return }

        // File work runs off the main actor.
        let candidates = Array(jobs.values)
        let missing = await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return candidates.filter {
                !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.file).path)
            }
        }.value
        let complete = await Self.download(missing, into: directory)
        guard !Task.isCancelled else { return }
        let keep = Set(jobs.keys).union([WidgetShelf.fileName])
        let saved = await Task.detached(priority: .utility) { () -> Bool in
            do { try shelf.save() } catch { return false }
            // Remove artwork no longer shown, and files from older versions.
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            where !keep.contains(name) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
            return true
        }.value
        guard saved, !Task.isCancelled else { return }
        // Artwork that failed to load is retried on the next publish.
        published = complete ? shelf : nil
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }

    private func upNextItems(store: AppStore, force: Bool) async -> [UpNextFeedController.Item] {
        let request = UpNextRequest(
            seeds: UpNext.homeSeeds(in: store.watchProgress, limit: Self.upNextLimit),
            context: store.metadataConfigurationRevision + store.addonRevision.uuidString, loaded: .now)
        if !force, let upNextRequest, upNextRequest.matches(request) { return upNextFeed.items }
        await upNextFeed.load(request.seeds, context: request.context) { seed in
            try await store.upNextItem(for: seed)
        }
        if !Task.isCancelled { upNextRequest = request }
        return upNextFeed.items
    }

    private nonisolated static func download(_ jobs: [ArtworkJob], into directory: URL) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            var next = 0
            var complete = true
            // A few at a time, so a large first publish doesn't crowd out the app's own artwork.
            while next < min(4, jobs.count) {
                let job = jobs[next]
                group.addTask { await fetch(job, into: directory) }
                next += 1
            }
            for await succeeded in group {
                complete = complete && succeeded
                if next < jobs.count {
                    let job = jobs[next]
                    group.addTask { await fetch(job, into: directory) }
                    next += 1
                }
            }
            return complete
        }
    }

    private nonisolated static func fetch(_ job: ArtworkJob, into directory: URL) async -> Bool {
        guard
            let image = try? await ArtworkPipeline.shared.image(
                for: job.url, size: job.size, priority: .prefetch),
            let data = image.jpegData(compressionQuality: 0.8)
        else { return false }
        return (try? data.write(to: directory.appendingPathComponent(job.file), options: .atomic)) != nil
    }

    /// Episode title for shows, time left for movies.
    private static func subtitle(_ record: WatchRecord, label: String?) -> String? {
        guard let label else { return record.media.type == "movie" ? remaining(record) : record.subtitle }
        // Older records store the label in front of the episode title.
        var title = record.subtitle ?? ""
        if title.hasPrefix(label) { title = String(title.dropFirst(label.count)) }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " ·"))
        return title.isEmpty ? label : label + " · " + title
    }

    private static func remaining(_ record: WatchRecord) -> String? {
        let seconds = record.duration - record.elapsed
        guard record.duration > 0, seconds >= 60 else { return nil }
        let minutes = Int(seconds / 60)
        return (minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m") + " left"
    }
}
