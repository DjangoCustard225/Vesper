import SwiftUI
import VesperCore

struct SettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Form {
            Section("Preferences") {
                NavigationLink {
                    HomeSettingsView()
                } label: {
                    Label("Home", systemImage: "house")
                }
                NavigationLink {
                    VideoPlayerSettingsView()
                } label: {
                    Label("Video Player", systemImage: "play.rectangle")
                }
                NavigationLink {
                    DownloadsSettingsView()
                } label: {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
                NavigationLink {
                    TrackingSettingsView()
                } label: {
                    SettingsConnectionLabel(
                        title: "Tracking", systemImage: "checkmark.circle",
                        status: store.activeTrackingService.title)
                }
            }
            Section("Connections") {
                NavigationLink {
                    SubDLSettingsView()
                } label: {
                    SettingsConnectionLabel(
                        title: "SubDL", systemImage: "captions.bubble",
                        status: store.subdlConfigured ? "Connected" : "Not connected")
                }
                NavigationLink {
                    UsenetSettingsView()
                } label: {
                    SettingsConnectionLabel(
                        title: "Usenet", systemImage: "network",
                        status: UsenetService.shared.provider == nil ? "Not connected" : "Connected")
                }
                NavigationLink {
                    AddonsView()
                } label: {
                    SettingsConnectionLabel(
                        title: "Add-ons", systemImage: "puzzlepiece.extension",
                        status: "\(store.addons.filter(\.isEnabled).count) enabled")
                }
                NavigationLink {
                    TMDBSettingsView()
                } label: {
                    SettingsConnectionLabel(
                        title: "TMDB", systemImage: "film",
                        status: store.tmdbCredential == nil ? "Not connected" : "Connected")
                }
                NavigationLink {
                    TVDBSettingsView()
                } label: {
                    SettingsConnectionLabel(
                        title: "TVDB", systemImage: "tv",
                        status: store.tvdbCredentials == nil ? "Not connected" : "Connected")
                }
                NavigationLink {
                    MDBListSettingsView()
                } label: {
                    SettingsConnectionLabel(
                        title: "MDBList", systemImage: "star.leadinghalf.filled",
                        status: store.mdblistKey == nil ? "Not connected" : "Connected")
                }

            }
            Section {
                NavigationLink {
                    SyncSettingsView()
                } label: {
                    SettingsConnectionLabel(
                        title: "Sync", systemImage: "arrow.triangle.2.circlepath.icloud",
                        status: store.folderSync.isEnabled ? "On" : "Off")
                }
                NavigationLink {
                    DataSettingsView()
                } label: {
                    Label("Data", systemImage: "externaldrive")
                }
                NavigationLink {
                    AppAboutView()
                } label: {
                    Label("About", systemImage: "info.circle")
                }
            }
        }.appScrollEdges().navigationTitle("Settings").toolbar(.visible, for: .navigationBar)
        // The SubDL key lives only in the keychain; re-read it whenever Settings returns.
    }

}

private struct SettingsConnectionLabel: View {
    let title: String
    let systemImage: String
    let status: String

    var body: some View {
        LabeledContent {
            Text(status).foregroundStyle(.secondary)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

private struct TrackingSettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Form {
            Section {
                Picker(
                    "Active service",
                    selection: Binding(
                        get: { store.activeTrackingService },
                        set: { store.activeTrackingService = $0 }
                    )
                ) {
                    ForEach(TrackingService.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Accounts") {
                NavigationLink {
                    TraktSettingsView()
                } label: {
                    SettingsConnectionLabel(
                        title: "Trakt", systemImage: "checkmark.circle",
                        status: traktStatus)
                }
                NavigationLink {
                    SimklSettingsView()
                } label: {
                    SettingsConnectionLabel(
                        title: "SIMKL", systemImage: "checkmark.circle",
                        status: simklStatus)
                }
            }
        }
        .appScrollEdges()
        .navigationTitle("Tracking").navigationBarTitleDisplayMode(.inline)
    }

    private var traktStatus: String {
        if store.trakt.isAuthorizing { return "Connecting…" }
        if store.trakt.needsReconnect { return "Reconnect required" }
        guard store.trakt.isConnected else { return "Not connected" }
        if store.trakt.isSyncing { return "Syncing…" }
        return store.activeTrackingService == .trakt ? "Active" : "Connected"
    }

    private var simklStatus: String {
        if store.simkl.isAuthorizing { return "Connecting…" }
        guard store.simkl.isConnected else { return "Not connected" }
        if store.simkl.isSyncing { return "Syncing…" }
        if store.simkl.error != nil { return "Needs attention" }
        return store.activeTrackingService == .simkl ? "Active" : "Connected"
    }
}
