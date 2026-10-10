import SwiftUI
import VesperCore

struct AddonsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var removing: InstalledAddon?
    var body: some View {
        @Bindable var store = store
        List {
            Section {
                Button { store.incomingAddon = nil; store.showInstall = true } label: {
                    Label("Add add-on", systemImage: "plus")
                }
            }
            Section("Installed · \(store.addons.count)") {
                ForEach(store.addons) { addon in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 14) {
                            Artwork(url: addon.manifest.logo).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(addon.manifest.name).font(.headline)
                                Text("Version \(addon.manifest.version)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Enable \(addon.manifest.name)", isOn: Binding(get: { addon.isEnabled }, set: { store.setEnabled(addon, $0) })).labelsHidden()
                        }
                        if let description = addon.manifest.description { Text(description).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
                        Text(addon.manifest.resources.map { $0.name.capitalized }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.tint)
                        HStack {
                            if addon.manifest.behaviorHints?.configurable == true, let url = AddonURL.configure(addon.manifestURL) {
                                Button("Configure", systemImage: "slider.horizontal.3") { openURL(url) }.font(.caption).buttonStyle(.bordered)
                            }
                            Spacer()
                            Button("Remove", systemImage: "trash", role: .destructive) { removing = addon }.font(.caption).buttonStyle(.borderless)
                        }
                    }.padding(.vertical, 8)
                }
                if store.addons.isEmpty { Text("No add-ons installed.").foregroundStyle(.secondary) }
            }
        }.listStyle(.insetGrouped).scrollContentBackground(.hidden).appBackground().navigationTitle("Add-ons")
            .confirmationDialog("Remove \(removing?.manifest.name ?? "add-on")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Remove add-on", role: .destructive) { if let removing { store.remove(removing) }; removing = nil }
            }
    }
}

struct InstallAddonView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let initialURL: String
    @State private var url = ""
    @State private var preview: InstalledAddon?
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var attempted = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://addon.example/manifest.json", text: $url, axis: .vertical)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                        .onChange(of: url) { _, _ in loadTask?.cancel(); loading = false; preview = nil; error = nil }
                    Button {
                        loadTask?.cancel()
                        loadTask = Task { await inspect() }
                    } label: { HStack { Text("Preview add-on"); Spacer(); if loading { ProgressView() } } }
                        .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading || saving)
                } header: { Text("Manifest URL") }
                if let error {
                    Section { Text(error).foregroundStyle(.secondary)
                        if let manifest = try? AddonURL.manifest(url), let configure = AddonURL.configure(manifest) {
                            Button("Open add-on configuration") { openURL(configure) }
                        }
                    }
                }
                if let addon = preview {
                    Section("Preview") {
                        LabeledContent("Name", value: addon.manifest.name)
                        LabeledContent("Version", value: addon.manifest.version)
                        if let description = addon.manifest.description { Text(description).font(.subheadline).foregroundStyle(.secondary) }
                        LabeledContent("Resources", value: addon.manifest.resources.map(\.name).joined(separator: ", "))
                        LabeledContent("Catalogs", value: String(addon.manifest.catalogs.count))
                        Text(addon.manifestURL.host ?? "").font(.caption).foregroundStyle(.secondary)
                        Button {
                            saving = true
                            do {
                                // Commit exactly the manifest that the user reviewed.
                                try store.installReviewed(addon)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                            saving = false
                        } label: { Label(store.addons.contains(where: { $0.id == addon.id }) ? "Update add-on" : "Install add-on", systemImage: "plus.circle.fill").font(.headline) }.disabled(saving)
                    }
                }
            }.appScrollEdges().navigationTitle("Install add-on").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { loadTask?.cancel(); dismiss() } } }
                .onAppear { url = initialURL }
                .onDisappear { loadTask?.cancel() }
                .task { if !initialURL.isEmpty { await inspect() } }
        }
    }
    private func inspect() async {
        let input = url.isEmpty ? initialURL : url
        attempted = input; loading = true; error = nil; preview = nil
        do {
            let addon = try await store.client.install(input)
            guard !Task.isCancelled, attempted == input, url == input || url.isEmpty else { return }
            preview = addon
        } catch is CancellationError { }
        catch { if attempted == input { self.error = error.localizedDescription } }
        if attempted == input { loading = false }
    }
}
