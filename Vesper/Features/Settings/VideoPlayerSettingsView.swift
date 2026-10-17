import SwiftUI
import VesperCore

struct VideoPlayerSettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                if store.availablePlayers.isEmpty {
                    Text("Install Infuse, Outplayer, or VLC to play videos.").foregroundStyle(.secondary)
                } else {
                    Picker("Preferred player", selection: $store.preferredPlayer) {
                        ForEach(store.availablePlayers) { Text($0.title).tag($0) }
                    }
                }
            }
            Section {
                Toggle("Show all external players", isOn: $store.showAllExternalPlayers)
            } footer: {
                Text("Enable if using Vesper in LiveContainer.")
            }
            #if !VESPER_GO
            Section("Gestures") {
                Toggle("Hold for 2×", isOn: gestureBinding(\.holdFor2x))
                Toggle("Brightness swipe (left side)", isOn: gestureBinding(\.brightnessSwipe))
                Toggle("Volume swipe (right side)", isOn: gestureBinding(\.volumeSwipe))
            }
            #endif
        }.appScrollEdges().navigationTitle("Video Player").navigationBarTitleDisplayMode(.inline)
            .onAppear { store.refreshPlayers() }
    }

    #if !VESPER_GO
    private func gestureBinding(_ keyPath: WritableKeyPath<PlayerGesturePreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.playerGestures[keyPath: keyPath] },
            set: { store.playerGestures[keyPath: keyPath] = $0 })
    }
    #endif
}
