import SwiftUI
import UsenetEngine

struct UsenetBackupProvidersView: View {
    private var service: UsenetService { .shared }
    @State private var selection: Selection?
    @State private var error: String?
    private struct Selection: Identifiable { let id = UUID(); let index: Int? }
    var body: some View {
        List {
            Section {
                ForEach(Array(service.backupProviders.enumerated()), id: \.offset) { index, provider in
                    Button {
                        selection = Selection(index: index)
                    } label: {
                        LabeledContent(provider.host, value: String(provider.connections) + " connections")
                    }
                }
                .onDelete { indices in
                    var values = service.backupProviders
                    values.remove(atOffsets: indices)
                    do { try service.saveBackupProviders(values) } catch {
                        self.error = error.localizedDescription
                    }
                }
                .onMove { indices, offset in
                    var values = service.backupProviders
                    values.move(fromOffsets: indices, toOffset: offset)
                    do { try service.saveBackupProviders(values) } catch {
                        self.error = error.localizedDescription
                    }
                }
                Button("Add Provider", systemImage: "plus") { selection = Selection(index: nil) }
            } footer: {
                Text(
                    "Downloads try these providers in order when an article is missing from the primary provider."
                )
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Fallback Providers")
        .toolbar { EditButton() }
        .sheet(item: $selection) { selection in
            NavigationStack {
                UsenetBackupProviderEditor(index: selection.index)
            }.presentationDetents([.large])
        }
    }
}

private struct UsenetBackupProviderEditor: View {
    @Environment(\.dismiss) private var dismiss
    let index: Int?
    @State private var host = ""
    @State private var port = "563"
    @State private var username = ""
    @State private var password = ""
    @State private var connections = 8.0
    @State private var error: String?
    var body: some View {
        Form {
            Section("Provider") {
                TextField("Host", text: $host).keyboardType(.URL)
                TextField("Port", text: $port).keyboardType(.numberPad)
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
            }
            Section {
                LabeledContent("Connections", value: String(Int(connections)))
                Slider(value: $connections, in: 1...100, step: 1)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .navigationTitle("Provider").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    do {
                        let provider = try UsenetProvider(
                            host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: Int(port) ?? 0,
                            username: username, password: password, connections: Int(connections)
                        ).validated()
                        var providers = UsenetService.shared.backupProviders
                        if let index, providers.indices.contains(index) {
                            providers[index] = provider
                        } else {
                            providers.append(provider)
                        }
                        try UsenetService.shared.saveBackupProviders(providers)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
        .onAppear {
            if let index, UsenetService.shared.backupProviders.indices.contains(index) {
                let provider = UsenetService.shared.backupProviders[index]
                host = provider.host; port = String(provider.port); username = provider.username
                password = provider.password; connections = Double(provider.connections)
            }
        }
    }
}
