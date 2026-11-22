import Foundation

// The widget extension can't import the app, so this file is compiled into both. The two copies,
// Vesper/Features/Widgets/WidgetShelf.swift and VesperWidgets/WidgetShelf.swift, must stay identical;
// GenerateXcodeProject.swift checks this.

/// What the Home Screen widgets show, written by the app into the shared App Group container.
struct WidgetShelf: Codable, Equatable {
    struct Item: Codable, Equatable {
        var id: String
        var type: String
        var title: String
        /// Episode label and title, or time left for a movie.
        var subtitle: String?
        /// Short episode label, such as "S1 · E2".
        var episodeLabel: String?
        var season: Int?
        var episode: Int?
        /// Watched fraction, 0...1, for Continue Watching.
        var progress: Double?
        /// Artwork file names inside the shelf directory.
        var backdropImage: String?
        var posterImage: String?
        /// Remote poster, passed back to the app so the title page has artwork while it loads.
        var posterURL: String?
        /// The title's media key, used to resume it.
        var key: String
        /// When the title was last played or marked.
        var updatedAt: Date?
        /// Air date of an Up Next episode.
        var released: Date?
    }

    struct Catalog: Codable, Equatable {
        var id: String
        var title: String
        var items: [Item]
    }

    var continueWatching: [Item] = []
    var upNext: [Item] = []
    var library: [Item] = []
    /// The first Home catalogs, for the configurable shelf widget.
    var catalogs: [Catalog] = []

    static let fileName = "widget-shelf.json"

    static func load() -> WidgetShelf {
        guard let directory = SharedContainer.shelfDirectory,
            let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
            let shelf = try? JSONDecoder().decode(WidgetShelf.self, from: data)
        else { return WidgetShelf() }
        return shelf
    }

    func save() throws {
        guard let directory = SharedContainer.shelfDirectory else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(
            to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

extension WidgetShelf {
    // Missing lists decode as empty so a file from another version still loads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        continueWatching = try container.decodeIfPresent([Item].self, forKey: .continueWatching) ?? []
        upNext = try container.decodeIfPresent([Item].self, forKey: .upNext) ?? []
        library = try container.decodeIfPresent([Item].self, forKey: .library) ?? []
        catalogs = try container.decodeIfPresent([Catalog].self, forKey: .catalogs) ?? []
    }
}

/// Links from the widgets into the app.
enum WidgetLink {
    static let scheme = "vesper"

    enum Action: String {
        /// Opens the title page.
        case title
        /// Resumes a Continue Watching title, or the latest one when no title is given.
        case resume
        /// Plays the next episode of a show.
        case play
    }

    static let resumeLatest = URL(string: "vesper://resume")!

    static func url(_ action: Action, for item: WidgetShelf.Item) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = action.rawValue
        components.queryItems =
            [
                URLQueryItem(name: "type", value: item.type), URLQueryItem(name: "id", value: item.id),
                URLQueryItem(name: "name", value: item.title), URLQueryItem(name: "key", value: item.key),
            ] + (item.posterURL.map { [URLQueryItem(name: "poster", value: $0)] } ?? [])
        return components.url!
    }
}

/// Locates the App Group shared with the widget extension.
///
/// Sideloading tools rename App Groups to fit the signing account (AltStore and SideStore list the
/// new names under `ALTAppGroups` in the app's Info.plist), so those names are tried before the
/// original. Without a usable group, as in LiveContainer, there is no container and widgets stay empty.
enum SharedContainer {
    static let defaultGroup = "group.app.vesper"

    static var shelfDirectory: URL? {
        guard let container = url else { return nil }
        return container.appendingPathComponent("Widgets", isDirectory: true)
    }

    static var url: URL? {
        for group in groups {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
                return url
            }
        }
        return nil
    }

    private static var groups: [String] {
        var bundles = [Bundle.main]
        // An extension lives at Vesper.app/PlugIns/Name.appex; the app's Info.plist lists renamed groups.
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        if app.pathExtension == "app", let bundle = Bundle(url: app) { bundles.append(bundle) }
        let renamed = bundles.flatMap { ($0.object(forInfoDictionaryKey: "ALTAppGroups") as? [String]) ?? [] }
        return renamed + [defaultGroup]
    }
}
