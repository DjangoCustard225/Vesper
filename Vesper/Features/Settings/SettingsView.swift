import SwiftUI
import VesperCore

struct SettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    AddonsView()
                } label: {
                    Label("Add-ons", systemImage: "puzzlepiece.extension")
                }
                NavigationLink {
                    TMDBSettingsView()
                } label: {
                    HStack {
                        Label("TMDB", systemImage: "film")
                        Spacer()
                        Text(store.tmdbCredential == nil ? "Not connected" : "Connected").foregroundStyle(
                            .secondary)
                    }
                }
                NavigationLink {
                    TraktSettingsView()
                } label: {
                    HStack {
                        Label("Trakt", systemImage: "checkmark.circle")
                        Spacer()
                        Text(
                            store.trakt.needsReconnect
                                ? "Reconnect required"
                                : (store.trakt.isConnected ? "Connected" : "Not connected")
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
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
