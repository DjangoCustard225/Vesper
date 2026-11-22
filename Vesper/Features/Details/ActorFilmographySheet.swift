import SwiftUI
import VesperCore

struct ActorFilmographySheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    @State private var profile: PersonProfile?

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
                    if let profile { PersonProfileSummary(profile: profile) }
                    MediaTypePicker(selection: $type).disabled(model.value == nil)
                    titles
                    if let error = model.error { ErrorNotice(message: error) { retryID = UUID() } }
                }.padding(20).frame(maxWidth: 1100).frame(maxWidth: .infinity)
            }.appBackground().navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        sortMenu
                        filtersMenu
                        Button(role: .close) { dismiss() }
                    }
                }
                .task(id: requestKey) { await load() }
                .task(id: "\(personID):\(store.metadataConfigurationRevision)") {
                    // Details are a bonus: the filmography stays usable when they fail.
                    let found = try? await store.personProfile(personID: personID)
                    guard !Task.isCancelled else { return }
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { profile = found }
                }
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
            if let known = profile?.knownFor {
                Text(known).font(.subheadline).foregroundStyle(.secondary)
            }
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

/// Life dates, birthplace, biography and profile links under the actor's portrait.
private struct PersonProfileSummary: View {
    let profile: PersonProfile
    @State private var showingBiography = false

    private static let dateStyle = Date.FormatStyle(
        date: .long, time: .omitted, timeZone: TimeZone(secondsFromGMT: 0)!)

    private var lifeLines: [String] {
        var lines: [String] = []
        let age = profile.age()
        if let birth = profile.birthDate {
            let born = "Born " + birth.formatted(Self.dateStyle)
            lines.append(profile.deathDate == nil ? born + (age.map { " (age \($0))" } ?? "") : born)
        }
        if let death = profile.deathDate {
            lines.append("Died " + death.formatted(Self.dateStyle) + (age.map { " (aged \($0))" } ?? ""))
        }
        return lines
    }

    var body: some View {
        VStack(spacing: 14) {
            if !lifeLines.isEmpty || profile.placeOfBirth != nil {
                VStack(spacing: 4) {
                    ForEach(lifeLines, id: \.self) { Text($0) }
                    if let place = profile.placeOfBirth {
                        Label(place, systemImage: "mappin.and.ellipse").labelStyle(.titleAndIcon)
                    }
                }
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .accessibilityElement(children: .combine)
            }
            if !profile.aliases.isEmpty {
                Text("Also known as " + profile.aliases.prefix(3).joined(separator: ", "))
                    .font(.footnote).foregroundStyle(.tertiary).multilineTextAlignment(.center).lineLimit(2)
            }
            if let biography = profile.biography { biographyView(biography) }
            links
        }
        .frame(maxWidth: 700)
    }

    private func biographyView(_ text: String) -> some View {
        Button {
            showingBiography = true
        } label: {
            Text(text).font(.callout).foregroundStyle(.primary.opacity(0.85))
                .lineLimit(5).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the full biography")
        .sheet(isPresented: $showingBiography) {
            NavigationStack {
                ScrollView {
                    Text(text).font(.body).padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle(profile.name).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .close) { showingBiography = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var links: some View {
        let row = HStack(spacing: 8) {
            ForEach(profile.links) { link in
                Button {
                    openPreferringApp(link.url)
                } label: {
                    PersonLinkGlyph(site: link.site).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(link.site.rawValue)
                .accessibilityHint("Opens \(profile.name) on \(link.site.rawValue)")
                .accessibilityAddTraits(.isLink)
            }
        }
        return ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row.padding(.horizontal, 2) }
        }
    }
}

/// Brand marks from Simple Icons (CC0) on a 24-point grid, pre-converted to absolute
/// move (M), line (L), cubic curve (C) and close (Z) commands.
private enum BrandMark {
    static let imdb =
        "M 22.38 0 L 1.622 0 C 0.7411 0.0583 0.0587 0.7437 0.0018 1.595 L 0.0008 22.38 C 0.0593 23.25 0.7133 23.92 1.557 24 C 1.572 24 1.587 24 1.602 24 L 22.4 24 C 22.41 24 22.43 24 22.44 24 C 23.32 23.92 24 23.17 24 22.29 L 24 1.71 C 24 0.8184 23.3 0.0682 22.42 0.002 C 22.4 0.0006359 22.39 -3.185e-05 22.38 -5.551e-17 Z M 22.38 0.496 C 23.01 0.5428 23.5 1.073 23.5 1.71 L 23.5 22.29 C 23.5 22.93 23.02 23.45 22.4 23.5 L 1.602 23.5 C 1.005 23.45 0.5371 22.97 0.4963 22.38 L 0.4963 1.628 C 0.5371 1.018 1.018 0.5364 1.622 0.496 L 22.38 0.496 Z M 4.795 8.26 L 4.795 15.62 L 2.89 15.62 L 2.89 8.26 L 4.795 8.26 Z M 11.33 8.26 L 11.33 15.62 L 9.671 15.62 L 9.671 10.65 L 9 15.62 L 7.813 15.62 L 7.114 10.76 L 7.108 15.62 L 5.44 15.62 L 5.44 8.26 L 7.908 8.26 C 7.983 8.708 8.057 9.23 8.139 9.834 L 8.41 11.71 L 8.85 8.26 L 11.33 8.26 Z M 14.31 9.589 C 14.38 9.63 14.43 9.697 14.45 9.793 C 14.48 9.888 14.49 10.1 14.49 10.44 L 14.49 13.29 C 14.49 13.78 14.45 14.08 14.39 14.19 C 14.33 14.3 14.16 14.36 13.89 14.36 L 13.89 9.521 C 14.09 9.521 14.23 9.542 14.31 9.589 Z M 14.29 15.62 C 14.74 15.62 15.09 15.6 15.31 15.55 C 15.54 15.5 15.73 15.41 15.88 15.28 C 16.04 15.16 16.15 14.99 16.21 14.76 C 16.27 14.54 16.31 14.1 16.31 13.44 L 16.31 10.86 C 16.31 10.16 16.28 9.691 16.24 9.454 C 16.19 9.217 16.09 8.999 15.92 8.81 C 15.75 8.613 15.5 8.477 15.18 8.389 C 14.86 8.308 14.32 8.26 13.41 8.26 L 11.98 8.26 L 11.98 15.62 L 14.29 15.62 Z M 19.43 13.84 C 19.43 14.19 19.41 14.42 19.37 14.51 C 19.34 14.61 19.18 14.65 19.07 14.65 C 18.96 14.65 18.88 14.61 18.85 14.52 C 18.8 14.43 18.78 14.22 18.78 13.9 L 18.78 11.95 C 18.78 11.62 18.8 11.41 18.84 11.32 C 18.87 11.24 18.95 11.2 19.06 11.2 C 19.17 11.2 19.33 11.24 19.37 11.35 C 19.41 11.44 19.43 11.64 19.43 11.95 L 19.43 13.84 Z M 16.95 8.26 L 16.95 15.62 L 18.67 15.62 L 18.78 15.16 C 18.94 15.35 19.11 15.49 19.3 15.58 C 19.48 15.67 19.76 15.72 19.98 15.72 C 20.28 15.72 20.54 15.64 20.76 15.48 C 20.97 15.33 21.12 15.14 21.18 14.92 C 21.23 14.7 21.27 14.38 21.27 13.94 L 21.27 11.87 C 21.27 11.43 21.25 11.14 21.23 11 C 21.21 10.86 21.16 10.72 21.06 10.58 C 20.96 10.44 20.82 10.33 20.64 10.25 C 20.45 10.17 20.24 10.13 19.98 10.13 C 19.76 10.13 19.48 10.18 19.29 10.26 C 19.11 10.35 18.94 10.48 18.78 10.66 L 18.78 8.26 L 16.95 8.26 Z"
    static let instagram =
        "M 7.03 0.084 C 5.753 0.1442 4.881 0.348 4.119 0.6474 C 3.33 0.9549 2.662 1.367 1.996 2.035 C 1.331 2.703 0.9213 3.372 0.6161 4.162 C 0.3207 4.926 0.1205 5.799 0.0641 7.076 C 0.0077 8.354 -0.0048 8.764 0.0015 12.02 C 0.0077 15.28 0.0221 15.69 0.084 16.97 C 0.145 18.25 0.348 19.12 0.6475 19.88 C 0.9555 20.67 1.367 21.34 2.035 22 C 2.703 22.67 3.372 23.08 4.164 23.38 C 4.927 23.68 5.8 23.88 7.077 23.94 C 8.355 23.99 8.766 24 12.02 24 C 15.28 23.99 15.69 23.98 16.97 23.92 C 18.25 23.86 19.12 23.65 19.88 23.35 C 20.67 23.05 21.34 22.63 22 21.97 C 22.67 21.3 23.08 20.63 23.38 19.84 C 23.68 19.07 23.88 18.2 23.94 16.92 C 23.99 15.64 24 15.24 24 11.98 C 23.99 8.719 23.98 8.31 23.92 7.03 C 23.86 5.751 23.65 4.882 23.35 4.119 C 23.05 3.33 22.63 2.662 21.97 1.996 C 21.3 1.33 20.63 0.9208 19.84 0.6165 C 19.07 0.321 18.2 0.1197 16.92 0.0645 C 15.65 0.0093 15.24 -0.005 11.98 0.0014 C 8.718 0.0076 8.31 0.0215 7.03 0.0839 M 7.17 21.78 C 6 21.73 5.365 21.53 4.942 21.37 C 4.381 21.15 3.982 20.89 3.56 20.47 C 3.138 20.06 2.879 19.66 2.66 19.1 C 2.495 18.67 2.297 18.04 2.243 16.87 C 2.183 15.6 2.171 15.22 2.164 12.02 C 2.157 8.816 2.169 8.437 2.224 7.172 C 2.274 6.003 2.47 5.367 2.632 4.944 C 2.848 4.383 3.109 3.984 3.527 3.562 C 3.946 3.141 4.346 2.881 4.906 2.662 C 5.329 2.497 5.963 2.301 7.133 2.245 C 8.398 2.185 8.777 2.173 11.98 2.166 C 15.18 2.159 15.56 2.171 16.83 2.227 C 18 2.277 18.64 2.471 19.06 2.635 C 19.62 2.851 20.02 3.11 20.44 3.53 C 20.86 3.949 21.12 4.347 21.34 4.908 C 21.51 5.33 21.7 5.964 21.76 7.135 C 21.82 8.4 21.83 8.78 21.84 11.98 C 21.84 15.19 21.83 15.57 21.78 16.83 C 21.72 18 21.53 18.64 21.37 19.06 C 21.15 19.62 20.89 20.02 20.47 20.44 C 20.05 20.86 19.65 21.12 19.09 21.34 C 18.67 21.51 18.04 21.7 16.87 21.76 C 15.6 21.82 15.22 21.83 12.02 21.84 C 8.814 21.84 8.436 21.83 7.17 21.78 M 16.95 5.586 C 16.95 6.169 17.31 6.693 17.84 6.915 C 18.38 7.137 19 7.013 19.41 6.6 C 19.82 6.188 19.95 5.568 19.72 5.03 C 19.5 4.493 18.97 4.143 18.39 4.144 C 17.59 4.146 16.95 4.791 16.95 5.586 M 5.838 12.01 C 5.845 15.42 8.609 18.17 12.01 18.16 C 15.41 18.15 18.17 15.39 18.16 11.99 C 18.16 8.585 15.39 5.831 11.99 5.838 C 8.585 5.845 5.832 8.609 5.838 12.01 M 8 12.01 C 7.996 9.799 9.783 8.004 11.99 8 C 14.2 7.995 16 9.783 16 11.99 C 16 14.2 14.22 16 12.01 16 C 10.95 16 9.929 15.58 9.177 14.83 C 8.425 14.09 8.002 13.07 8 12.01"
    static let x =
        "M 18.9 1.153 L 22.58 1.153 L 14.54 10.34 L 24 22.85 L 16.59 22.85 L 10.79 15.26 L 4.156 22.85 L 0.474 22.85 L 9.074 13.02 L 0 1.154 L 7.594 1.154 L 12.84 8.086 Z M 17.61 20.64 L 19.65 20.64 L 6.486 3.24 L 4.298 3.24 Z"
    static let tiktok =
        "M 12.53 0.02 C 13.84 0 15.13 0.01 16.44 0 C 16.52 1.53 17.07 3.09 18.19 4.17 C 19.31 5.28 20.89 5.79 22.43 5.96 L 22.43 9.99 C 20.99 9.94 19.54 9.64 18.23 9.02 C 17.66 8.76 17.13 8.43 16.61 8.09 C 16.6 11.01 16.62 13.93 16.59 16.84 C 16.51 18.24 16.05 19.63 15.24 20.78 C 13.93 22.7 11.66 23.95 9.325 23.99 C 7.895 24.07 6.465 23.68 5.245 22.96 C 3.225 21.77 1.805 19.59 1.595 17.25 C 1.575 16.75 1.565 16.25 1.585 15.76 C 1.765 13.86 2.705 12.04 4.165 10.8 C 5.825 9.36 8.145 8.67 10.32 9.08 C 10.34 10.56 10.28 12.04 10.28 13.52 C 9.285 13.2 8.125 13.29 7.255 13.89 C 6.625 14.3 6.145 14.93 5.895 15.64 C 5.685 16.15 5.745 16.71 5.755 17.25 C 5.995 18.89 7.575 20.27 9.255 20.12 C 10.38 20.11 11.45 19.46 12.03 18.51 C 12.22 18.18 12.43 17.84 12.44 17.45 C 12.54 15.66 12.5 13.88 12.51 12.09 C 12.52 8.06 12.5 4.04 12.53 0.02 Z"
    static let youtube =
        "M 23.5 6.186 C 23.22 5.147 22.41 4.333 21.38 4.05 C 19.5 3.545 12 3.545 12 3.545 C 12 3.545 4.495 3.545 2.623 4.05 C 1.586 4.333 0.7779 5.147 0.502 6.186 C 0 8.07 0 12 0 12 C 0 12 0 15.93 0.502 17.81 C 0.7779 18.85 1.586 19.67 2.624 19.95 C 4.495 20.45 12 20.45 12 20.45 C 12 20.45 19.5 20.45 21.38 19.95 C 22.41 19.67 23.22 18.85 23.5 17.81 C 24 15.93 24 12 24 12 C 24 12 24 8.07 23.5 6.186 Z M 9.545 15.57 L 9.545 8.432 L 15.82 12 L 9.545 15.57 Z"
    static let tmdb =
        "M6.62 12a2.291 2.291 0 0 1 2.292-2.295h-.013A2.291 2.291 0 0 1 11.189 12a2.291 2.291 0 0 1-2.29 2.291h.013A2.291 2.291 0 0 1 6.62 12zm10.72-4.062h4.266a2.291 2.291 0 0 0 2.29-2.291 2.291 2.291 0 0 0-2.29-2.296H17.34a2.291 2.291 0 0 0-2.291 2.296 2.291 2.291 0 0 0 2.29 2.29zM2.688 20.645h8.285a2.291 2.291 0 0 0 2.291-2.292 2.291 2.291 0 0 0-2.29-2.295H2.687a2.291 2.291 0 0 0-2.291 2.295 2.291 2.291 0 0 0 2.29 2.292zm10.881-6.354h.81l1.894-4.586H15.19l-1.154 3.008h-.013l-1.135-3.008h-1.154zm4.208 0h1.011V9.705h-1.011zm2.878 0h3.235v-.93h-2.223v-.933h1.99v-.934h-1.99v-.855h2.107v-.934h-3.112zM1.31 7.941h1.01V4.247h1.31v-.895H0v.895h1.31zm3.747 0h1.011V5.959h1.958v1.984h1.011v-4.59h-1.01v1.711H6.061V3.351H5.057zm5.348 0h3.242v-.933H11.41v-.934h1.99v-.933h-1.99v-.856h2.107v-.934h-3.112zM.162 14.296h1.005v-3.52h.013l1.167 3.52h.765l1.206-3.52h.013v3.52h1.011v-4.59H3.82L2.755 12.7h-.013L1.686 9.705H.156zm14.534 6.353h1.641a3.188 3.188 0 0 0 .98-.149 2.531 2.531 0 0 0 .824-.437 2.123 2.123 0 0 0 .567-.713 2.193 2.193 0 0 0 .223-.983 2.399 2.399 0 0 0-.218-1.07 1.958 1.958 0 0 0-.586-.716 2.405 2.405 0 0 0-.873-.392 4.349 4.349 0 0 0-1.046-.13h-1.519zm1.013-3.656h.596a2.26 2.26 0 0 1 .606.08 1.514 1.514 0 0 1 .503.244 1.167 1.167 0 0 1 .34.412 1.28 1.28 0 0 1 .13.587 1.546 1.546 0 0 1-.13.658 1.127 1.127 0 0 1-.347.433 1.41 1.41 0 0 1-.518.238 2.797 2.797 0 0 1-.649.07h-.538zm4.686 3.656h1.88a2.997 2.997 0 0 0 .613-.064 1.735 1.735 0 0 0 .554-.214 1.221 1.221 0 0 0 .402-.39 1.105 1.105 0 0 0 .155-.606 1.188 1.188 0 0 0-.071-.415 1.01 1.01 0 0 0-.204-.34 1.087 1.087 0 0 0-.317-.24 1.297 1.297 0 0 0-.413-.13v-.012a1.203 1.203 0 0 0 .575-.366.962.962 0 0 0 .216-.648 1.081 1.081 0 0 0-.149-.603 1.022 1.022 0 0 0-.389-.354 1.673 1.673 0 0 0-.54-.169 4.463 4.463 0 0 0-.6-.041h-1.712zm1.011-3.734h.687a1.4 1.4 0 0 1 .24.022.748.748 0 0 1 .22.075.432.432 0 0 1 .16.147.418.418 0 0 1 .061.236.47.47 0 0 1-.055.233.433.433 0 0 1-.146.156.62.62 0 0 1-.204.084 1.058 1.058 0 0 1-.23.026h-.745zm0 1.835h.765a1.96 1.96 0 0 1 .266.02 1.015 1.015 0 0 1 .26.07.519.519 0 0 1 .204.152.406.406 0 0 1 .08.26.481.481 0 0 1-.06.253.519.519 0 0 1-.16.168.62.62 0 0 1-.217.09 1.155 1.155 0 0 1-.237.027H21.4z"
}

private struct BrandShape: Shape {
    let data: String

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        var tokens = data.split(separator: " ").makeIterator()
        func point() -> CGPoint? {
            guard let x = tokens.next().flatMap({ Double($0) }), let y = tokens.next().flatMap({ Double($0) })
            else { return nil }
            return CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        var path = Path()
        while let command = tokens.next() {
            switch command {
            case "M": if let p = point() { path.move(to: p) }
            case "L": if let p = point() { path.addLine(to: p) }
            case "C":
                if let c1 = point(), let c2 = point(), let p = point() {
                    path.addCurve(to: p, control1: c1, control2: c2)
                }
            case "Z": path.closeSubpath()
            default: return path
            }
        }
        return path
    }
}

/// The site's own logo.
private struct PersonLinkGlyph: View {
    let site: PersonLink.Site
    private let size: CGFloat = 28

    var body: some View {
        switch site {
        case .imdb:
            // Yellow badge with black lettering.
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.07, style: .continuous)
                    .fill(Color(red: 0.961, green: 0.773, blue: 0.094))
                BrandShape(data: BrandMark.imdb).fill(.black)
            }.frame(width: size, height: size)
        case .instagram:
            BrandShape(data: BrandMark.instagram)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.996, green: 0.855, blue: 0.459),
                            Color(red: 0.98, green: 0.494, blue: 0.118),
                            Color(red: 0.839, green: 0.161, blue: 0.463),
                            Color(red: 0.588, green: 0.184, blue: 0.749),
                            Color(red: 0.31, green: 0.357, blue: 0.835),
                        ], startPoint: .bottomLeading, endPoint: .topTrailing)
                )
                .frame(width: size, height: size)
        case .x:
            BrandShape(data: BrandMark.x).fill(.primary).frame(width: size * 0.85, height: size * 0.85)
        case .tiktok:
            // The note with its cyan and red offset shadows.
            ZStack {
                BrandShape(data: BrandMark.tiktok).fill(Color(red: 0.145, green: 0.957, blue: 0.933))
                    .offset(x: -1, y: -1)
                BrandShape(data: BrandMark.tiktok).fill(Color(red: 0.996, green: 0.173, blue: 0.333))
                    .offset(x: 1, y: 1)
                BrandShape(data: BrandMark.tiktok).fill(.primary)
            }.frame(width: size, height: size)
        case .youtube:
            // Red rounded rectangle; the white behind it shows through the play cut-out.
            ZStack {
                Rectangle().fill(.white).frame(width: size * 0.4, height: size * 0.35)
                BrandShape(data: BrandMark.youtube).fill(Color(red: 1, green: 0, blue: 0))
            }.frame(width: size, height: size)
        case .website:
            Image(systemName: "globe").font(.system(size: size * 0.85)).foregroundStyle(.primary)
        }
    }
}
