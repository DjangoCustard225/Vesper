import SwiftUI
import UIKit
import VesperCore

/// A centered row of logos under the description linking to the title on IMDb, Letterboxd and
/// Rotten Tomatoes, each with its score when known. A link appears only when it can point at this title.
struct TitleLinksSection: View {
    let media: MediaItem
    let details: MetadataEnrichment?
    /// Scores from MDBList, when an API key is set.
    var ratings: TitleRatings? = nil

    var body: some View {
        let links = self.links
        if !links.isEmpty {
            HStack(spacing: 24) {
                ForEach(links) { link in
                    Button {
                        openPreferringApp(link.url)
                    } label: {
                        LinkMark(link: link)
                    }.buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var links: [TitleLink] {
        guard media.type == "movie" || media.type == "series" else { return [] }
        let imdb =
            MediaIdentity.validIMDb(media.imdbID) ?? MediaIdentity.validIMDb(details?.imdbID)
            ?? MediaIdentity.validIMDb(media.id)
        // Prefer MDBList's scores; without them, IMDb's can still come from the add-on's metadata.
        let imdbScore =
            ratings?.imdb
            ?? media.imdbRating.flatMap { Double($0) }.flatMap { (0.1...10).contains($0) ? $0 : nil }
        let imdbRating = imdbScore.map { String(format: "%.1f", $0) }
        let tmdb = details?.tmdbID ?? media.tmdbID
        var links: [TitleLink] = []
        if let imdb, let url = URL(string: "https://www.imdb.com/title/\(imdb)/") {
            links.append(TitleLink(site: .imdb, url: url, rating: imdbRating))
        }
        // Letterboxd lists films only, and resolves TMDB and IMDb IDs to the film's page.
        if media.type == "movie" {
            let path = tmdb.map { "tmdb/\($0)" } ?? imdb.map { "imdb/\($0)" }
            if let path, let url = URL(string: "https://letterboxd.com/\(path)/") {
                links.append(
                    TitleLink(
                        site: .letterboxd, url: url,
                        rating: ratings?.letterboxd.map { String(format: "%.1f", $0) }))
            }
        }
        // Rotten Tomatoes has no ID lookup, so search for the title instead.
        var search = URLComponents(string: "https://www.rottentomatoes.com/search")
        search?.queryItems = [URLQueryItem(name: "search", value: media.name)]
        if !media.name.isEmpty, let url = search?.url {
            links.append(
                TitleLink(site: .rottenTomatoes, url: url, rating: ratings?.rottenTomatoes.map { "\($0)%" }))
        }
        return links
    }
}

/// Opens the site's app when it is installed and claims the link, otherwise the website.
@MainActor func openPreferringApp(_ url: URL) {
    UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { opened in
        if !opened { UIApplication.shared.open(url) }
    }
}

private struct TitleLink: Identifiable {
    enum Site: String {
        case imdb = "IMDb"
        case letterboxd = "Letterboxd"
        case rottenTomatoes = "Rotten Tomatoes"
    }
    let site: Site
    let url: URL
    var rating: String? = nil
    var id: String { site.rawValue }
}

private struct LinkMark: View {
    let link: TitleLink

    var body: some View {
        HStack(spacing: 8) {
            mark
            if let rating = link.rating {
                Text(rating).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            }
        }
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(link.rating.map { "\(link.site.rawValue), rated \($0)" } ?? link.site.rawValue)
        .accessibilityHint(
            link.site == .rottenTomatoes
                ? "Searches Rotten Tomatoes for this title" : "Opens this title on \(link.site.rawValue)"
        )
        .accessibilityAddTraits(.isLink)
    }

    @ViewBuilder private var mark: some View {
        switch link.site {
        case .imdb:
            // A wide rectangle, as in IMDb's own badge, so the letters always sit on one line.
            Text("IMDb").font(.system(size: 12, weight: .black)).foregroundStyle(.black)
                .lineLimit(1).fixedSize()
                .frame(width: 44, height: 22)
                .background(Color(red: 0.96, green: 0.77, blue: 0.09), in: RoundedRectangle(cornerRadius: 4))
        case .letterboxd:
            HStack(spacing: -3) {
                Circle().fill(Color(red: 1, green: 0.5, blue: 0))
                Circle().fill(Color(red: 0, green: 0.88, blue: 0.33))
                Circle().fill(Color(red: 0.25, green: 0.74, blue: 0.96))
            }
            .frame(width: 36, height: 14)
        case .rottenTomatoes:
            Text("🍅").font(.system(size: 24))
        }
    }
}
