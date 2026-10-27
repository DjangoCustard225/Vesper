import SwiftUI
import VesperCore

struct VideoPlayerSettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Picker("Preferred player", selection: $store.preferredPlayer) {
                    ForEach(store.availablePlayers) { Text($0.title).tag($0) }
                }
                NavigationLink("Intro Skipping") { IntroSkippingSettingsView() }
            }
            Section {
                Toggle("Show all external players", isOn: $store.showAllExternalPlayers)
            } footer: {
                Text("Enable if using Vesper in LiveContainer.")
            }
            Section("Gestures") {
                Toggle("Hold for 2×", isOn: gestureBinding(\.holdFor2x))
                Toggle("Brightness swipe (left side)", isOn: gestureBinding(\.brightnessSwipe))
                Toggle("Volume swipe (right side)", isOn: gestureBinding(\.volumeSwipe))
            }
        }.appScrollEdges().navigationTitle("Video Player").navigationBarTitleDisplayMode(.inline)
            .onAppear { store.refreshPlayers() }
    }

    private func gestureBinding(_ keyPath: WritableKeyPath<PlayerGesturePreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.playerGestures[keyPath: keyPath] },
            set: { store.playerGestures[keyPath: keyPath] = $0 })
    }
}

private struct IntroSkippingSettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Toggle("Show Skip Intro", isOn: $store.showSkipIntro)
        }.appScrollEdges().navigationTitle("Intro Skipping").navigationBarTitleDisplayMode(.inline)
    }
}
