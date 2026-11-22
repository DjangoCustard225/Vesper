import SwiftUI
import VesperCore

@main
struct VesperApp: App {
    @UIApplicationDelegateAdaptor(DownloadAppDelegate.self) private var downloadDelegate
    @State private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = AppStore()
        _store = State(initialValue: store)
        // Background tasks must be registered before launch finishes.
        WidgetRefresh.register(store: store)
        // Vesper shows no scroll bars. SwiftUI scroll views follow `.scrollIndicators(.hidden)` below;
        // this covers scroll views UIKit creates on its own.
        UIScrollView.appearance().showsVerticalScrollIndicator = false
        UIScrollView.appearance().showsHorizontalScrollIndicator = false
    }

    var body: some Scene {
        WindowGroup {
            RootView().environment(store).tint(.white).preferredColorScheme(.dark).scrollIndicators(.hidden)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        store.refreshPlayers()
                        store.downloads.enterForeground()
                        store.downloads.start()
                        Task { await store.resumeTrakt() }
                        store.folderSync.syncNow(store: store)
                        WidgetPublisher.shared.schedule(store: store, delay: .seconds(1))
                    }
                    if phase == .background {
                        store.trakt.suspend()
                        store.simkl.suspendSync()
                        store.downloads.enterBackground()
                        store.folderSync.syncNow(store: store)
                        WidgetPublisher.shared.schedule(store: store, delay: .zero)
                        WidgetRefresh.schedule()
                        Task {
                            await store.flushWatchProgress()
                            await store.flushLibrary()
                            await DiagnosticRecorder.shared.flush()
                        }
                    }
                }
                .task { await store.resumeTrakt() }
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
    @State private var presented: PresentedTitle?
    @State private var launch = OfflineLaunch()

    var body: some View {
        Group {
            switch launch.mode {
            case .waiting:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).appBackground()
            case .offline:
                NavigationStack {
                    LibraryView(
                        offlineOnly: true,
                        goOnline: { launch.goOnline(available: store.downloads.networkAvailable) })
                }
            case .online:
                tabs
            }
        }
        .onAppear { checkInitialNetwork() }
        .onChange(of: store.downloads.networkStatusKnown) { _, _ in checkInitialNetwork() }
        .alert(
            "Downloads",
            isPresented: Binding(
                get: { store.downloads.error != nil }, set: { if !$0 { store.downloads.error = nil } })
        ) {
            Button("OK") { store.downloads.error = nil }
        } message: {
            Text(store.downloads.error ?? "")
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

    private func checkInitialNetwork() {
        guard store.downloads.networkStatusKnown else { return }
        launch.observe(available: store.downloads.networkAvailable)
    }

    private var tabs: some View {
        @Bindable var store = store
        return TabView(
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
        .task(id: ContentRequestID(input: store.homeCatalogRevision, context: store.contentContext)) {
            await store.refresh(preservingUnchanged: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .vesperMetadataUpdated)) { notification in
            if let update = notification.object as? MetadataUpdate { store.metadataDidRefresh(update) }
        }
        .onOpenURL { url in
            // Ignore callbacks from player links created by older app versions.
            if AppIdentity.urlSchemes.contains(url.scheme ?? ""), url.host == "player-return" { return }
            if url.scheme == WidgetLink.scheme, url.host.flatMap(WidgetLink.Action.init(rawValue:)) != nil {
                // Opened from a widget or control. At launch, wait until saved progress is read so the
                // link finds the title it names.
                Task {
                    await store.waitUntilLoaded()
                    guard let title = PresentedTitle(widgetURL: url, store: store) else { return }
                    showingSearch = false
                    presented = title
                }
                return
            }
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
        .alert(
            "Add-ons from Another Device",
            isPresented: Binding(get: { store.pendingSyncedAddons != nil }, set: { _ in })
        ) {
            Button("Add") { store.acceptSyncedAddons() }
            Button("Stop Syncing Add-ons", role: .cancel) { store.declineSyncedAddons() }
        } message: {
            let names = store.newSyncedAddons(in: store.pendingSyncedAddons ?? []).map(\.manifest.name)
            Text(
                "Your sync folder has add-ons that aren’t installed here: \(names.joined(separator: ", ")). Add them only if you installed them on your other device."
            )
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
        .fullScreenCover(item: $presented) { title in
            NavigationStack {
                DetailView(
                    item: title.item, startPlayback: title.startPlayback, resumeRecord: title.resumeRecord
                )
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            presented = nil
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }.labelStyle(.iconOnly).accessibilityLabel("Back to previous tab")
                    }
                }
            }
        }

    }

    private var settingsNavigation: some View {
        NavigationStack { SettingsView() }
            .toggleStyle(SwitchToggleStyle(tint: Color(white: 0.42)))
    }

    private func openSearchResult() {
        guard let item = pendingSearchResult else { return }
        pendingSearchResult = nil
        presented = PresentedTitle(item: item)
    }
}
