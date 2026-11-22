import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Configuration

/// What the shelf widget shows: Library, Continue Watching, Up Next or one of the first Home catalogs.
struct ShelfSource: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Shelf"
    static let defaultQuery = ShelfSourceQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }

    static let library = ShelfSource(id: "library", title: "Library")
    static let continueWatching = ShelfSource(id: "continue-watching", title: "Continue Watching")
    static let upNext = ShelfSource(id: "up-next", title: "Up Next")

    /// The fixed shelves, then the catalogs Vesper last published.
    static func all(in shelf: WidgetShelf = .load()) -> [ShelfSource] {
        [.library, .continueWatching, .upNext]
            + shelf.catalogs.map { ShelfSource(id: "catalog:" + $0.id, title: $0.title) }
    }
}

struct ShelfSourceQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ShelfSource] {
        let all = ShelfSource.all()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [ShelfSource] { ShelfSource.all() }

    func defaultResult() async -> ShelfSource? { .library }
}

enum ShelfArtwork: String, AppEnum {
    case posters
    case backdrops

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Artwork"
    static let caseDisplayRepresentations: [ShelfArtwork: DisplayRepresentation] = [
        .posters: "Posters", .backdrops: "Backdrops",
    ]
}

struct ShelfConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Shelf"
    static let description = IntentDescription("Choose what the widget shows and how.")

    @Parameter(title: "Show") var source: ShelfSource?
    @Parameter(title: "Artwork", default: .posters) var artwork: ShelfArtwork

    init() {}
}

struct ConfiguredShelfProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ShelfEntry { .placeholder }

    func snapshot(for configuration: ShelfConfiguration, in context: Context) async -> ShelfEntry {
        let entry = entry(for: configuration)
        return context.isPreview && ShelfContent(entry: entry).items.isEmpty
            ? configured(.placeholder, configuration) : entry
    }

    func timeline(for configuration: ShelfConfiguration, in context: Context) async -> Timeline<ShelfEntry> {
        // Vesper reloads the widget whenever the shelf changes.
        Timeline(entries: [entry(for: configuration)], policy: .never)
    }

    private func entry(for configuration: ShelfConfiguration) -> ShelfEntry {
        configured(.load(), configuration)
    }

    private func configured(_ entry: ShelfEntry, _ configuration: ShelfConfiguration) -> ShelfEntry {
        var entry = entry
        entry.sourceID = configuration.source?.id ?? ShelfSource.library.id
        entry.artwork = configuration.artwork
        return entry
    }
}

// MARK: - Widget

struct LibraryWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "library", intent: ShelfConfiguration.self, provider: ConfiguredShelfProvider()
        ) {
            ShelfView(entry: $0).containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Shelf")
        .description("Your library, a Home catalog, or what you’re watching. Edit the widget to choose.")
        .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
    }
}

/// The items and links for the configured source.
struct ShelfContent {
    let title: String
    let items: [WidgetShelf.Item]
    let link: WidgetLink.Action
    /// Set when the chosen catalog is no longer on Vesper's Home screen.
    let missing: Bool

    init(entry: ShelfEntry) {
        let shelf = entry.shelf
        switch entry.sourceID {
        case ShelfSource.continueWatching.id:
            (title, items, link, missing) = ("Continue Watching", shelf.continueWatching, .resume, false)
        case ShelfSource.upNext.id:
            (title, items, link, missing) = ("Up Next", shelf.upNext, .play, false)
        case let id where id.hasPrefix("catalog:"):
            let catalog = shelf.catalogs.first { "catalog:" + $0.id == id }
            (title, items, link, missing) = (
                catalog?.title ?? "Catalog", catalog?.items ?? [], .title, catalog == nil
            )
        default:
            (title, items, link, missing) = ("Library", shelf.library, .title, false)
        }
    }
}

private struct ShelfView: View {
    let entry: ShelfEntry
    @Environment(\.widgetFamily) private var family

    private var content: ShelfContent { ShelfContent(entry: entry) }

    var body: some View {
        Group {
            if content.items.isEmpty {
                empty
            } else if entry.artwork == .backdrops {
                grid(rows: family == .systemMedium ? 1 : 2, columns: family == .systemExtraLarge ? 3 : 2) {
                    BackdropCard(entry: entry, item: $0)
                }
            } else {
                grid(rows: family == .systemMedium ? 1 : 2, columns: family == .systemExtraLarge ? 6 : 4) {
                    PosterCard(entry: entry, item: $0)
                }
            }
        }
        .placeholder(entry.isPlaceholder)
    }

    @ViewBuilder private var empty: some View {
        if content.missing {
            EmptyShelf(
                symbol: "square.stack.3d.up.slash", title: "Catalog unavailable",
                message: "It’s no longer on Vesper’s Home screen. Edit the widget to choose another.")
        } else {
            switch content.link {
            case .resume:
                EmptyShelf(
                    symbol: "play.rectangle", title: "Nothing in progress",
                    message: "Start watching in Vesper.")
            case .play:
                EmptyShelf(
                    symbol: "forward.end", title: "You’re all caught up", message: "New episodes appear here."
                )
            case .title:
                EmptyShelf(
                    symbol: "rectangle.stack",
                    title: entry.sourceID == ShelfSource.library.id
                        ? "Your library is empty" : "Nothing here yet",
                    message: entry.sourceID == ShelfSource.library.id
                        ? "Save titles in Vesper." : "Open Vesper to load this catalog.")
            }
        }
    }

    private func grid<Card: View>(
        rows: Int, columns: Int, @ViewBuilder card: @escaping (WidgetShelf.Item) -> Card
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // The medium widget is too short for a header.
            if family != .systemMedium { ShelfHeader(title: content.title) }
            Grid(horizontalSpacing: 8, verticalSpacing: 10) {
                ForEach(0..<rows, id: \.self) { row in
                    GridRow(alignment: .top) {
                        ForEach(0..<columns, id: \.self) { column in
                            let index = row * columns + column
                            if index < content.items.count {
                                OpenButton(url: WidgetLink.url(content.link, for: content.items[index])) {
                                    card(content.items[index])
                                }
                            } else {
                                Color.clear
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct PosterCard: View {
    let entry: ShelfEntry
    let item: WidgetShelf.Item

    var body: some View {
        Artwork(image: entry.image(item.posterImage ?? item.backdropImage), fallback: item.title)
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay(alignment: .bottom) { ProgressLine(value: item.progress).padding(5) }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(WidgetFormat.accessibilityLabel(item, now: entry.date))
    }
}

private struct BackdropCard: View {
    let entry: ShelfEntry
    let item: WidgetShelf.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Artwork(image: entry.image(item.backdropImage ?? item.posterImage), fallback: item.title)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .bottom) { ProgressLine(value: item.progress).padding(5) }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(item.title).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WidgetFormat.accessibilityLabel(item, now: entry.date))
    }
}
