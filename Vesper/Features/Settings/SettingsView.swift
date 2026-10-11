import SwiftUI
import VesperCore

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                NavigationLink { AddonsView() } label: { Label("Add-ons", systemImage: "puzzlepiece.extension") }
                NavigationLink { TMDBSettingsView() } label: {
                    HStack {
                        Label("TMDB", systemImage: "film")
                        Spacer()
                        Text(store.tmdbCredential == nil ? "Not connected" : "Connected").foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                NavigationLink { HeroSettingsView() } label: { Label("Home hero", systemImage: "rectangle.on.rectangle") }
                Picker("Player", selection: $store.preferredPlayer) {
                    ForEach(VideoPlayer.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                NavigationLink { DataSettingsView() } label: { Label("Data", systemImage: "externaldrive") }
                NavigationLink { AppAboutView() } label: { Label("About", systemImage: "info.circle") }
            }
        }.appScrollEdges().navigationTitle("Settings").toolbar(.visible, for: .navigationBar)
    }
}

struct HeroSettingsView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        Form {
            Picker("Catalog", selection: Binding(get: { store.heroCatalogID }, set: { store.setHeroCatalog($0) })) {
                Text("Automatic").tag(HeroCatalogSelection.automaticID)
                ForEach(store.heroCatalogs) { catalog in Text(catalog.title).tag(catalog.id) }
                if store.heroCatalogID != HeroCatalogSelection.automaticID && !store.heroCatalogs.contains(where: { $0.id == store.heroCatalogID }) {
                    Text("Unavailable catalog").tag(store.heroCatalogID)
                }
            }.pickerStyle(.inline)
        }.appScrollEdges().navigationTitle("Home hero").navigationBarTitleDisplayMode(.inline)
    }
}

struct TMDBSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var key = ""
    @State private var message: String?
    @State private var error: String?
    @State private var verifying = false
    @State private var saveTask: Task<Void, Never>?
    var body: some View {
        Form {
            Section {
                SecureField("API key or read access token", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    .onChange(of: key) { _, _ in
                        saveTask?.cancel(); verifying = false; message = nil; error = nil
                    }
                Button {
                    saveTask?.cancel()
                    saveTask = Task { await save() }
                } label: {
                    HStack { Text("Save & verify"); Spacer(); if verifying { ProgressView() } }
                }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || verifying)
                if store.tmdbCredential != nil {
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.tint)
                    Button("Remove API key", role: .destructive) {
                        saveTask?.cancel(); verifying = false
                        do {
                            try store.removeTMDBCredential(); key = ""
                            error = nil; message = "API key removed."
                        } catch { self.error = error.localizedDescription }
                    }
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.tint) }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            Section {
                Link("Get an API key", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
            }
        }.appScrollEdges().navigationTitle("TMDB").navigationBarTitleDisplayMode(.inline)
            .onAppear { key = store.tmdbCredential ?? "" }
            .onDisappear { saveTask?.cancel() }
    }
    private func save() async {
        let input = key
        verifying = true; message = nil; error = nil
        do {
            try await store.saveTMDBCredential(input)
            guard !Task.isCancelled, input == key else { return }
            message = "Verified and saved."
        } catch is CancellationError { return }
        catch { if input == key { self.error = error.localizedDescription } }
        if input == key { verifying = false }
    }
}

struct AppAboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let release = info["CFBundleShortVersionString"] as? String ?? ""
        guard let build = info["CFBundleVersion"] as? String else { return release }
        return "\(release) (\(build))"
    }
    var body: some View {
        Form {
            Section {
                LabeledContent("Vesper", value: version)
                LabeledContent("Designed for", value: "iOS 27")
            }
            Section {
                NavigationLink("Credits") { CreditsView() }
                Link("Stremio add-on protocol", destination: URL(string: "https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/protocol.md")!)
            }
        }.appScrollEdges().navigationTitle("About").navigationBarTitleDisplayMode(.inline)
    }
}

struct CreditsView: View {
    var body: some View {
        ScrollView {
            TMDBAttribution().frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }.appBackground().navigationTitle("Credits")
    }
}
