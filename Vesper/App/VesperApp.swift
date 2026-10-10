import SwiftUI
import VesperCore

@main
struct VesperApp: App {
    @State private var store = AppStore()
    var body: some Scene {
        WindowGroup {
            RootView().environment(store).tint(.white).preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    private enum AppTab: Hashable { case discover, library, settings, search }
    @Environment(AppStore.self) private var store
    @State private var selectedTab = AppTab.discover
    @State private var showingSearch = false
    @State private var pendingSearchResult: MediaItem?
    @State private var searchResult: MediaItem?
    var body: some View {
        @Bindable var store = store
        TabView(selection: Binding(get: { selectedTab }, set: { tab in
            if tab == .search { showingSearch = true }
            else { selectedTab = tab }
        })) {
            Tab("Discover", systemImage: "sparkles.tv", value: AppTab.discover) { NavigationStack { DiscoverView() } }
            Tab("Library", systemImage: "rectangle.stack", value: AppTab.library) { NavigationStack { LibraryView() } }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) { NavigationStack { SettingsView() } }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) { Color.clear }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .scrollEdgeEffectHidden(true, for: .vertical)
        .task(id: store.addonSignature + store.tmdbRevision.uuidString) { await store.refresh() }
        .onOpenURL { url in
            if url.scheme == "stremio" { store.incomingAddon = url.absoluteString; store.showInstall = true }
            else if ["vesper", "swiftstream"].contains(url.scheme ?? ""),
                    let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value {
                store.incomingAddon = value; store.showInstall = true
            }
        }
        .sheet(isPresented: $store.showInstall) {
            InstallAddonView(initialURL: store.incomingAddon ?? "")
        }
        .sheet(isPresented: $showingSearch, onDismiss: openSearchResult) {
            NavigationStack {
                SearchView { item in
                    guard showingSearch else { return }
                    pendingSearchResult = item
                    showingSearch = false
                }
            }
                .presentationDetents([.large]).presentationDragIndicator(.hidden)
        }
        .fullScreenCover(item: $searchResult) { item in
            NavigationStack {
                DetailView(item: item)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { searchResult = nil } label: {
                                Label("Back", systemImage: "chevron.left")
                            }.labelStyle(.iconOnly).accessibilityLabel("Back to previous tab")
                        }
                    }
            }
        }
        .alert("Couldn’t save", isPresented: Binding(get: { store.storageError != nil }, set: { if !$0 { store.storageError = nil } })) {
            Button("OK") { store.storageError = nil }
        } message: { Text(store.storageError ?? "") }
    }

    private func openSearchResult() {
        guard let item = pendingSearchResult else { return }
        pendingSearchResult = nil
        searchResult = item
    }
}
