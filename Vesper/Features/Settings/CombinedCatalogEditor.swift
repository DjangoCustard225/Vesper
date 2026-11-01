import SwiftUI
import VesperCore

struct CombinedCatalogEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CombinedCatalog
    @State private var deleting = false
    private let isNew: Bool

    init(group: CombinedCatalog? = nil) {
        isNew = group == nil
        _draft = State(initialValue: group ?? CombinedCatalog(name: "", members: []))
    }

    private var sources: [HomeCatalog] {
        store.catalogs.filter { if case .combined = $0 { false } else { true } }
    }

    private var valid: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && Set(draft.members).count >= 2
    }

    var body: some View {
        List {
            Section("Name") { TextField("Combined catalog name", text: $draft.name) }
            Section {
                ForEach(draft.members, id: \.self) { id in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(
                                sources.first { $0.id == id }.map(store.catalogTitle) ?? "Unavailable catalog"
                            )
                            if let source = sources.first(where: { $0.id == id }) {
                                Text(source.providerName).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            draft.members.removeAll { $0 == id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }.buttonStyle(.borderless).accessibilityLabel("Remove catalog")
                    }
                }
                .onMove { offsets, destination in
                    draft.members.move(fromOffsets: offsets, toOffset: destination)
                }
            } header: {
                Text("Selected Catalogs")
            } footer: {
                Text("Choose at least two. Results alternate in this order.")
            }
            Section("Add Catalogs") {
                ForEach(sources.filter { !draft.members.contains($0.id) }) { catalog in
                    Button {
                        draft.members.append(catalog.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(store.catalogTitle(catalog)).foregroundStyle(.primary)
                                Text(catalog.providerName).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "plus.circle")
                        }
                    }
                }
            }
            if !isNew {
                Section { Button("Delete Combined Catalog", role: .destructive) { deleting = true } }
            }
        }
        .appScrollEdges().navigationTitle(isNew ? "Combine Catalogs" : "Edit Combined Catalog")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!valid) }
        }
        .confirmationDialog(
            "Delete this combined catalog?", isPresented: $deleting, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                var proposed = store.catalogPreferences
                proposed.groups.removeAll { $0.id == draft.id }
                proposed.customizations[draft.id] = nil
                proposed.order.removeAll { $0 == draft.id }
                if store.saveCatalogPreferences(proposed) { dismiss() }
            }
        } message: {
            Text("Its source catalogs will return to their previous Home visibility.")
        }
    }

    private func save() {
        guard valid else { return }
        var proposed = store.catalogPreferences
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = proposed.groups.firstIndex(where: { $0.id == draft.id }) {
            proposed.groups[index] = draft
        } else {
            proposed.groups.append(draft)
        }
        if store.saveCatalogPreferences(proposed) { dismiss() }
    }
}
