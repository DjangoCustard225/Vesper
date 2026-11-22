import SwiftUI
import WidgetKit

struct ShelfEntry: TimelineEntry {
    let date: Date
    let shelf: WidgetShelf
    let directory: URL?
    /// Sample content, drawn redacted while the widget loads or in the gallery before Vesper has data.
    var isPlaceholder = false
    var relevance: TimelineEntryRelevance?
    /// The configurable shelf's choices.
    var sourceID = ShelfSource.library.id
    var artwork = ShelfArtwork.posters

    func image(_ name: String?) -> UIImage? {
        guard let directory, let name else { return nil }
        return UIImage(contentsOfFile: directory.appendingPathComponent(name).path)
    }

    static func load(at date: Date = .now) -> ShelfEntry {
        ShelfEntry(date: date, shelf: .load(), directory: SharedContainer.shelfDirectory)
    }

    static var placeholder: ShelfEntry {
        ShelfEntry(date: .now, shelf: .sample, directory: nil, isPlaceholder: true)
    }
}

enum ShelfSection {
    case continueWatching
    case upNext

    func items(in shelf: WidgetShelf) -> [WidgetShelf.Item] {
        switch self {
        case .continueWatching: shelf.continueWatching
        case .upNext: shelf.upNext
        }
    }
}

/// Continue Watching and Up Next. Vesper rewrites the shelf and reloads widgets when it changes; the
/// timeline adds entries where labels such as "New · Today" or Smart Stack relevance change.
struct ShelfProvider: TimelineProvider {
    let section: ShelfSection

    func placeholder(in context: Context) -> ShelfEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (ShelfEntry) -> Void) {
        let entry = ShelfEntry.load()
        completion(context.isPreview && section.items(in: entry.shelf).isEmpty ? .placeholder : entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ShelfEntry>) -> Void) {
        let shelf = WidgetShelf.load()
        let directory = SharedContainer.shelfDirectory
        let dates = ShelfRelevance.dates(from: .now)
        let entries = dates.enumerated().map { index, date in
            ShelfEntry(
                date: date, shelf: shelf, directory: directory,
                relevance: ShelfRelevance.relevance(
                    section.items(in: shelf), at: date,
                    until: index + 1 < dates.count ? dates[index + 1] : nil))
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

/// How much the widget matters right now, for Smart Stack rotation.
enum ShelfRelevance {
    /// Now, then each midnight (day labels change), evening start and late night for two days.
    static func dates(from now: Date, calendar: Calendar = .current) -> [Date] {
        let start = calendar.startOfDay(for: now)
        let boundaries = (0...2).flatMap { day -> [Date] in
            guard let base = calendar.date(byAdding: .day, value: day, to: start) else { return [] }
            return [0, 18, 23].compactMap { calendar.date(bySettingHour: $0, minute: 0, second: 0, of: base) }
        }
        return [now] + boundaries.filter { $0 > now }.sorted()
    }

    static func relevance(
        _ items: [WidgetShelf.Item], at date: Date, until end: Date?, calendar: Calendar = .current
    ) -> TimelineEntryRelevance? {
        guard !items.isEmpty else { return TimelineEntryRelevance(score: 0) }
        var score: Float = 0.1
        // Evenings are when people usually watch.
        if (18..<23).contains(calendar.component(.hour, from: date)) { score += 0.4 }
        // Something played in the last two days is likely to be continued.
        if let latest = items.compactMap(\.updatedAt).max(), date.timeIntervalSince(latest) < 2 * 86400 {
            score += 0.3
        }
        if items.contains(where: { WidgetFormat.newLabel($0.released, now: date) != nil }) { score += 0.2 }
        return TimelineEntryRelevance(
            score: min(1, score), duration: end.map { $0.timeIntervalSince(date) } ?? 0)
    }
}

enum WidgetFormat {
    /// "New · Today", "New · Yesterday" or "New · Tue" for an episode that aired in the last week.
    static func newLabel(_ released: Date?, now: Date, calendar: Calendar = .current) -> String? {
        guard let released, released <= now, now.timeIntervalSince(released) < 7 * 86400 else { return nil }
        if calendar.isDate(released, inSameDayAs: now) { return "New · Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(released, inSameDayAs: yesterday)
        {
            return "New · Yesterday"
        }
        return "New · " + released.formatted(.dateTime.weekday(.abbreviated))
    }

    /// What VoiceOver reads for a title.
    static func accessibilityLabel(_ item: WidgetShelf.Item, now: Date) -> String {
        var parts = [item.title]
        if let season = item.season, let episode = item.episode {
            parts.append("Season \(season), Episode \(episode)")
            if let title = item.subtitle?.components(separatedBy: " · ").dropFirst(2).joined(
                separator: " · "),
                !title.isEmpty
            {
                parts.append(title)
            }
        } else if let subtitle = item.subtitle {
            parts.append(subtitle)
        }
        if let progress = item.progress { parts.append("\(Int((progress * 100).rounded())) percent watched") }
        if newLabel(item.released, now: now) != nil { parts.append("New episode") }
        return parts.joined(separator: ", ")
    }
}

extension WidgetShelf {
    /// Gallery and loading content, drawn redacted.
    static let sample: WidgetShelf = {
        func item(_ index: Int) -> Item {
            Item(
                id: "sample-\(index)", type: "series", title: "Title of the Show",
                subtitle: "S1 · E\(index) · Episode", episodeLabel: "S1 · E\(index)", season: 1,
                episode: index,
                progress: 0.35, key: "series:sample-\(index)")
        }
        let items = (1...12).map(item)
        return WidgetShelf(
            continueWatching: Array(items.prefix(6)), upNext: Array(items.prefix(6)), library: items,
            catalogs: [])
    }()
}
