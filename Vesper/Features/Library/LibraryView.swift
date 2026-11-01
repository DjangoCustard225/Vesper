import SwiftUI
import VesperCore

struct LibraryView: View {
    @Environment(AppStore.self) private var store
    @State private var filter = "all"
    @State private var selectedDownload: MediaItem?
    @State private var selectedDetail: MediaItem?
    var offlineOnly = false
    var goOnline: (() -> Void)? = nil

    private var records: [DownloadRecord] {
        offlineOnly ? store.downloads.completed : store.downloads.records
    }
    private var allItems: [MediaItem] {
        let records = records
        return LibraryDownloadPresentation.titles(
            saved: store.library.items, downloads: records, offlineOnly: offlineOnly
        ).map { item in
            guard let record = records.first(where: { $0.media.isSameTitle(as: item) }),
                let poster = store.downloads.localArtwork(item.poster ?? record.media.poster, record: record)
            else { return item }
            var local = item; local.poster = poster.absoluteString; return local
        }
    }

    var body: some View {
        let allItems = allItems
        let items = allItems.filter { filter == "all" || $0.type == filter }
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !allItems.isEmpty { MediaTypePicker(selection: $filter) }
                if allItems.isEmpty {
                    ContentUnavailableView(
                        offlineOnly ? "No downloaded videos" : "Make it a movie night",
                        systemImage: offlineOnly ? "arrow.down.circle" : "bookmark",
                        description: Text(
                            offlineOnly
                                ? "Your completed downloads appear here."
                                : "Save a movie or series to see it here.")
                    ).padding(.top, 70)
                } else if items.isEmpty {
                    ContentUnavailableView("Nothing here yet", systemImage: "rectangle.stack")
                } else {
                    MediaGrid(
                        items: items,
                        onSelect: { item in
                            if records.contains(where: { $0.media.isSameTitle(as: item) }) {
                                selectedDownload = item
                            } else {
                                selectedDetail = item
                            }
                        })
                }
            }.padding(20).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }
        .appBackground().navigationTitle(offlineOnly ? "Downloaded" : "Library")
        .navigationDestination(item: $selectedDetail) { DetailView(item: $0) }
        .toolbar {
            if offlineOnly, store.downloads.networkAvailable, let goOnline {
                ToolbarItem(placement: .topBarTrailing) { Button("Go Online", action: goOnline) }
            }
        }
        .sheet(item: $selectedDownload) { item in
            DownloadTitleSheet(media: item, completedOnly: offlineOnly)
        }
    }
}
