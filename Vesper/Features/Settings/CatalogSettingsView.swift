import SwiftUI
import VesperCore

struct CatalogSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var resetting = false

    var body: some View {
        List {
            Section {
                NavigationLink("Create Combined Catalog") { CombinedCatalogEditor() }
            }
            Section {
                ForEach(store.catalogs) { catalog in
                    HStack(spacing: 12) {
                        Toggle("Show \(store.catalogTitle(catalog))", isOn: visibility(catalog))
                            .labelsHidden().disabled(store.catalogPreferences.isGrouped(catalog.id))
                        NavigationLink {
                            if case .combined(let group) = catalog {
                                CombinedCatalogEditor(group: group)
                            } else {
                                CatalogCustomizationView(
                                    catalog: catalog,
                                    customization: store.catalogPreferences.customization(for: catalog.id))
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(store.catalogTitle(catalog))
                                Text(
                                    store.catalogPreferences.isGrouped(catalog.id)
                                        ? "Included in a combined catalog" : catalog.providerName
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onMove { indices, destination in
                    var order = store.catalogs.map(\.id)
                    order.move(fromOffsets: indices, toOffset: destination)
                    var proposed = store.catalogPreferences
                    // Keep unavailable entries so disabling an add-on does not erase its placement.
                    proposed.order = order + proposed.order.filter { !order.contains($0) }
                    store.saveCatalogPreferences(proposed)
                }
            }
            Section {
                Button("Reset All", role: .destructive) { resetting = true }
            }
        }
        .toolbar { EditButton() }
        .appScrollEdges().navigationTitle("Catalogs").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Reset all catalog customizations?", isPresented: $resetting, titleVisibility: .visible
        ) {
            Button("Reset All", role: .destructive) { store.saveCatalogPreferences(CatalogPreferences()) }
        }
    }

    private func visibility(_ catalog: HomeCatalog) -> Binding<Bool> {
        Binding(
            get: { store.catalogPreferences.isVisible(catalog) },
            set: { visible in
                var proposed = store.catalogPreferences
                var customization = proposed.customization(for: catalog.id)
                customization.isHidden = !visible
                proposed.customizations[catalog.id] = customization
                store.saveCatalogPreferences(proposed)
            })
    }
}

private struct CatalogCustomizationView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let catalog: HomeCatalog
    @State private var draft: CatalogCustomization
    @State private var resetting = false

    init(catalog: HomeCatalog, customization: CatalogCustomization) {
        self.catalog = catalog
        _draft = State(initialValue: customization)
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField(catalog.title, text: Binding(get: { draft.name ?? "" }, set: { draft.name = $0 }))
            }
            if case .addon(let feed) = catalog, !feed.catalog.filters.isEmpty {
                Section("Default Filters") {
                    CatalogFilterPickers(catalog: feed.catalog, selections: $draft.filters)
                }
            }
            Section {
                Button("Reset Catalog", role: .destructive) { resetting = true }
            }
        }
        .appScrollEdges().navigationTitle(catalog.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { if save(draft) { dismiss() } }
            }
        }
        .confirmationDialog("Reset this catalog?", isPresented: $resetting, titleVisibility: .visible) {
            Button("Reset Catalog", role: .destructive) {
                if save(CatalogCustomization()) { draft = CatalogCustomization() }
            }
        }
    }

    private func save(_ customization: CatalogCustomization) -> Bool {
        var proposed = store.catalogPreferences
        proposed.customizations[catalog.id] = customization
        return store.saveCatalogPreferences(proposed)
    }
}

struct CatalogFilterPickers: View {
    let catalog: AddonCatalog
    @Binding var selections: [String: String]

    var body: some View {
        ForEach(catalog.filters) { filter in
            Picker(filter.title, selection: selection(filter)) {
                if !filter.isRequired { Text("Default").tag("") }
                ForEach(filter.options, id: \.self) { Text($0).tag($0) }
            }
        }
    }

    private func selection(_ filter: CatalogFilter) -> Binding<String> {
        Binding(
            get: {
                if let value = selections[filter.id], filter.options.contains(value) { return value }
                return filter.isRequired ? filter.options.first ?? "" : ""
            },
            set: { selections[filter.id] = $0 })
    }
}
