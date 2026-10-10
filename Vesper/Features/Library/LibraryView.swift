import SwiftUI
import VesperCore

struct LibraryView: View {
    @Environment(AppStore.self) private var store
    @State private var filter = "all"
    private var items: [MediaItem] { store.library.items.filter { filter == "all" || $0.type == filter } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if store.library.items.isEmpty {
                    ContentUnavailableView("Make it a movie night", systemImage: "bookmark", description: Text("Save a movie or series from its detail page. Your watchlist stays here on this device."))
                        .padding(.top, 70)
                } else {
                    Picker("Content", selection: $filter) { Text("All").tag("all"); Text("Movies").tag("movie"); Text("Series").tag("series") }.pickerStyle(.segmented)
                    if items.isEmpty { ContentUnavailableView("Nothing saved here yet", systemImage: "bookmark") }
                    LazyVGrid(columns: Design.columns, alignment: .leading, spacing: 24) {
                        ForEach(items, id: \.key) { item in
                            NavigationLink { DetailView(item: item) } label: { PosterCard(item: item) }.buttonStyle(.plain)
                                .contextMenu { Button("Remove from library", systemImage: "bookmark.slash", role: .destructive) { store.toggleLibrary(item) } }
                        }
                    }
                }
            }.padding(20).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }.appBackground().navigationTitle("Library")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink { HistoryView() } label: { Image(systemName: "clock.arrow.circlepath") }.accessibilityLabel("Watch history") } }
    }
}

struct HistoryView: View {
    @Environment(AppStore.self) private var store
    @State private var confirmClear = false
    var body: some View {
        List {
            ForEach(store.library.history) { progress in
                NavigationLink { DetailView(item: progress.media, preferredVideoID: progress.videoID) } label: {
                    HStack(spacing: 14) {
                        Artwork(url: progress.media.poster).frame(width: 50, height: 74).clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(progress.media.name).font(.headline)
                            if let title = progress.episodeTitle { Text(title).font(.subheadline).foregroundStyle(.secondary) }
                            Text(progress.isFinished ? "Watched" : "\(Int(progress.position / 60)) min watched").font(.caption).foregroundStyle(.secondary)
                            ProgressView(value: progress.fraction)
                        }
                    }.padding(.vertical, 4)
                }.swipeActions { Button("Delete", role: .destructive) { store.removeProgress(progress) } }
            }
        }.scrollContentBackground(.hidden).appBackground().navigationTitle("Watch history")
            .overlay { if store.library.history.isEmpty { ContentUnavailableView("Nothing watched yet", systemImage: "clock", description: Text("Your playback progress will appear here.")) } }
            .toolbar { if !store.library.history.isEmpty { Button("Clear", role: .destructive) { confirmClear = true } } }
            .confirmationDialog("Clear all watch history?", isPresented: $confirmClear, titleVisibility: .visible) { Button("Clear history", role: .destructive) { store.clearHistory() } }
    }
}
