import SwiftUI
import VesperCore

struct HomeSettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                NavigationLink {
                    HeroSettingsView()
                } label: {
                    LabeledContent("Hero", value: heroTitle)
                }
                NavigationLink("Catalogs") { CatalogSettingsView() }
            }
            Section { Toggle("Continue Watching", isOn: $store.showContinueWatching) }
        }.appScrollEdges().navigationTitle("Home").navigationBarTitleDisplayMode(.inline)
    }

    private var heroTitle: String {
        guard store.heroCatalogID != HeroCatalogSelection.automaticID else { return "Automatic" }
        return store.heroCatalogs.first(where: { $0.id == store.heroCatalogID })?.title
            ?? "Unavailable catalog"
    }
}

private struct HeroSettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Form {
            Picker(
                "Catalog", selection: Binding(get: { store.heroCatalogID }, set: { store.setHeroCatalog($0) })
            ) {
                Text("Automatic").tag(HeroCatalogSelection.automaticID)
                ForEach(store.heroCatalogs) { catalog in Text(catalog.title).tag(catalog.id) }
                if store.heroCatalogID != HeroCatalogSelection.automaticID
                    && !store.heroCatalogs.contains(where: { $0.id == store.heroCatalogID })
                {
                    Text("Unavailable catalog").tag(store.heroCatalogID)
                }
            }.pickerStyle(.inline)
        }.appScrollEdges().navigationTitle("Hero").navigationBarTitleDisplayMode(.inline)
    }
}
