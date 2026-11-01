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
            }
            Section("Connections") {
                NavigationLink {
                    UsenetSettingsView()
                } label: {
                    Label("Usenet", systemImage: "network")
                }
                NavigationLink {
                    AddonsView()
                } label: {
                    Label("Add-ons", systemImage: "puzzlepiece.extension")
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
                    TraktSettingsView()
                } label: {
                    SettingsConnectionLabel(
                        title: "Trakt", systemImage: "checkmark.circle",
                        status: store.trakt.needsReconnect
                            ? "Reconnect required"
                            : (store.trakt.isConnected ? "Connected" : "Not connected"))
                }
            }
            Section {
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
