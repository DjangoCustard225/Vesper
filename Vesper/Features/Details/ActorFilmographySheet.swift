import SwiftUI
import VesperCore

struct ActorFilmographySheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let personID: Int
    let name: String
    let portraitURL: URL
    let onSelect: (MediaItem) -> Void
    @State private var model = PersonFilmographyController()
    @State private var credentialRevision: UUID?
    @State private var retryID = UUID()
    @State private var type = "all"
    @State private var sort = FilmographySort.popularity
    @State private var genreID: Int?
    @State private var year: Int?

    private var genres: [TMDBGenre] { model.value?.genres(type: type) ?? [] }

    private var years: [Int] { model.value?.years(type: type) ?? [] }

    private var filtersActive: Bool { type != "all" || genreID != nil || year != nil }

    private var requestKey: String {
        "\(personID):\(store.tmdbRevision):\(retryID):"
            + store.metadataRevision(for: [store.filmographyCacheID(personID)])
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    portrait
                    MediaTypePicker(selection: $type).disabled(model.value == nil)
                    titles
                    if let error = model.error { ErrorNotice(message: error) { retryID = UUID() } }
                }.padding(20).frame(maxWidth: 1100).frame(maxWidth: .infinity)
            }.appBackground().navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        sortMenu
                        filtersMenu
                        Button("Done") { dismiss() }
                    }
                }
                .task(id: requestKey) { await load() }
                .onChange(of: type) { _, _ in normalizeFilters() }
        }
    }

    private var portrait: some View {
        VStack(spacing: 10) {
            CachedArtworkImage(url: portraitURL, fadesIn: true) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Circle().fill(Design.surface)
                }
            }.frame(width: 120, height: 120).clipShape(Circle()).accessibilityHidden(true)
            Text(name).font(.title2.bold()).multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder private var titles: some View {
        if let filmography = model.value {
            let items = filmography.items(type: type, genreID: genreID, year: year, sort: sort)
            if items.isEmpty {
                ContentUnavailableView(
                    filtersActive ? "No matching titles" : "No titles available", systemImage: "film")
                if filtersActive { Button("Reset filters", action: resetFilters).buttonStyle(.glass) }
            } else {
                MediaGrid(items: items, onSelect: onSelect)
            }
        } else if model.error == nil {
            ProgressView("Loading titles…").frame(maxWidth: .infinity).padding(.vertical, 36)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(FilmographySort.allCases) { Text($0.title).tag($0) }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }.labelStyle(.iconOnly).accessibilityValue(sort.title).disabled(model.value == nil)
    }

    private var filtersMenu: some View {
        Menu {
            Picker("Genre", selection: $genreID) {
                Text("All genres").tag(nil as Int?)
                ForEach(genres) { Text($0.name).tag(Optional($0.id)) }
            }.disabled(genres.isEmpty)
            Picker("Year", selection: $year) {
                Text("All years").tag(nil as Int?)
                ForEach(years, id: \.self) { Text(String($0)).tag(Optional($0)) }
            }.disabled(years.isEmpty)
            if filtersActive {
                Button("Reset filters", systemImage: "arrow.counterclockwise", action: resetFilters)
            }
        } label: {
            Label(
                "Filter",
                systemImage: filtersActive
                    ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }.labelStyle(.iconOnly).accessibilityValue(filtersActive ? "Filters active" : "All titles")
            .disabled(model.value == nil)
    }

    private func load() async {
        if credentialRevision != store.tmdbRevision {
            model.clear()
            resetFilters()
            credentialRevision = store.tmdbRevision
        }
        await model.load { try await store.filmography(personID: personID) }
        if !Task.isCancelled { normalizeFilters() }
    }

    private func normalizeFilters() {
        if let genreID, !genres.contains(where: { $0.id == genreID }) { self.genreID = nil }
        if let year, !years.contains(year) { self.year = nil }
    }

    private func resetFilters() {
        type = "all"
        genreID = nil
        year = nil
    }
}
