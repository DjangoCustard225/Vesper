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
                    ContentUnavailableView(
                        "Make it a movie night", systemImage: "bookmark",
                        description: Text(
                            "Save a movie or series from its detail page. Your watchlist stays here on this device."
                        )
                    )
                    .padding(.top, 70)
                } else {
                    MediaTypePicker(selection: $filter)
                    if items.isEmpty {
                        ContentUnavailableView("Nothing saved here yet", systemImage: "bookmark")
                    }
                    MediaGrid(items: items)
                }
            }.padding(20).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }.appBackground().navigationTitle("Library")
    }
}
