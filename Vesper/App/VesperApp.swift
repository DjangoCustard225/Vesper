import SwiftUI
import VesperCore

@main
struct VesperApp: App {
    @State private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView().environment(store).tint(.white).preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { store.refreshPlayers() }
                    if phase == .background {
                        Task {
                            await store.flushWatchProgress()
                            await DiagnosticRecorder.shared.flush()
                        }
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didReceiveMemoryWarningNotification)
                ) { _ in
                    Task { await ArtworkPipeline.shared.clearMemory() }
                }
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
        TabView(
            selection: Binding(
                get: { selectedTab },
                set: { tab in
                    if tab == .search { showingSearch = true } else { selectedTab = tab }
                })
        ) {
            Tab("Discover", systemImage: "sparkles.tv", value: AppTab.discover) {
                NavigationStack { DiscoverView() }
            }
            Tab("Library", systemImage: "rectangle.stack", value: AppTab.library) {
                NavigationStack { LibraryView() }
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) { settingsNavigation }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) { Color.clear }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .task(id: store.contentContext) { await store.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .vesperMetadataUpdated)) { notification in
            if let update = notification.object as? MetadataUpdate { store.metadataDidRefresh(update) }
        }
        .onOpenURL { url in
            // Ignore callbacks from player links created by older app versions.
            if AppIdentity.urlSchemes.contains(url.scheme ?? ""), url.host == "player-return" { return }
            if url.scheme == "stremio" {
                store.incomingAddon = url.absoluteString
                store.showInstall = true
            } else if AppIdentity.urlSchemes.contains(url.scheme ?? ""),
                let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(
                    where: { $0.name == "url" })?.value
            {
                store.incomingAddon = value
                store.showInstall = true
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
                            Button {
                                searchResult = nil
                            } label: {
                                Label("Back", systemImage: "chevron.left")
                            }.labelStyle(.iconOnly).accessibilityLabel("Back to previous tab")
                        }
                    }
            }
        }
        .alert(
            "Storage",
            isPresented: Binding(
                get: { store.storageError != nil }, set: { if !$0 { store.storageError = nil } })
        ) {
            Button("OK") { store.storageError = nil }
        } message: {
            Text(store.storageError ?? "")
        }
    }

    private var settingsNavigation: some View {
        NavigationStack { SettingsView() }
            .toggleStyle(SwitchToggleStyle(tint: Color(white: 0.42)))
    }

    private func openSearchResult() {
        guard let item = pendingSearchResult else { return }
        pendingSearchResult = nil
        searchResult = item
    }
}
