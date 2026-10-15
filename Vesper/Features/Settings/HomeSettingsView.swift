import SwiftUI
import VesperCore

struct HomeSettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Picker(
                "Hero", selection: Binding(get: { store.heroCatalogID }, set: { store.setHeroCatalog($0) })
            ) {
                Text("Automatic").tag(HeroCatalogSelection.automaticID)
                ForEach(store.heroCatalogs) { catalog in Text(catalog.title).tag(catalog.id) }
                if store.heroCatalogID != HeroCatalogSelection.automaticID
                    && !store.heroCatalogs.contains(where: { $0.id == store.heroCatalogID })
                {
                    Text("Unavailable catalog").tag(store.heroCatalogID)
                }
            }.pickerStyle(.inline)
            #if !VESPER_GO
            Section { Toggle("Continue Watching", isOn: $store.showContinueWatching) }
            #endif
        }.appScrollEdges().navigationTitle("Home").navigationBarTitleDisplayMode(.inline)
    }
}
