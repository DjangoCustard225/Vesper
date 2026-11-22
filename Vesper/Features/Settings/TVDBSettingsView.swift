import SwiftUI
import VesperCore

struct TVDBSettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var pin = ""
    @State private var error: String?
    @State private var verifying = false
    @State private var saveTask: Task<Void, Never>?
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                CredentialRow(title: "API Key", text: $apiKey, commit: commit)
                CredentialRow(title: "Subscriber PIN", text: $pin, prompt: "Optional", commit: commit)
                Link(
                    "TVDB Account", destination: URL(string: "https://thetvdb.com/dashboard/account/apikeys")!
                )
                Link("TVDB Subscriptions", destination: URL(string: "https://thetvdb.com/subscribe")!)
            } header: {
                Text("Metadata")
            } footer: {
                Text("When connected, TVDB is preferred for shows. Some API keys require a subscriber PIN.")
            }
            .disabled(verifying)
            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            if store.tvdbCredentials != nil {
                Section {
                    Button("Remove Credentials", role: .destructive) {
                        reset()
                        do {
                            try store.removeTVDBCredentials()
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(verifying)
                }
            }
        }
        .appScrollEdges().navigationTitle("TVDB").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SaveVerifyButton(busy: verifying, disabled: !canSave, action: commit)
            }
        }
        .onChange(of: apiKey) { _, _ in reset() }
        .onChange(of: pin) { _, _ in reset() }
        .onAppear {
            // Load once; returning from a field page must not undo an edit.
            guard !loaded else { return }
            loaded = true
            apiKey = store.tvdbCredentials?.apiKey ?? ""
            pin = store.tvdbCredentials?.pin ?? ""
        }
        .onDisappear { saveTask?.cancel() }
    }

    /// The PIN is optional; the API key isn't.
    private var canSave: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Saves and verifies; run by the checkmark here and in the field sheets.
    private func commit() {
        guard canSave, !verifying else { return }
        saveTask?.cancel()
        saveTask = Task { await save() }
    }

    private func reset() {
        saveTask?.cancel()
        verifying = false
        error = nil
    }

    private func save() async {
        let key = apiKey, subscriber = pin
        verifying = true
        error = nil
        defer { if key == apiKey && subscriber == pin { verifying = false } }
        do {
            try await store.saveTVDBCredentials(apiKey: key, pin: subscriber)
            try Task.checkCancellation()
            guard key == apiKey, subscriber == pin else { return }
            dismiss()
        } catch is CancellationError {} catch {
            if key == apiKey && subscriber == pin { self.error = error.localizedDescription }
        }
    }
}
