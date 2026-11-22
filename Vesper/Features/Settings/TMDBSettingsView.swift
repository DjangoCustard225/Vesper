import SwiftUI
import VesperCore

struct TMDBSettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var error: String?
    @State private var verifying = false
    @State private var saveTask: Task<Void, Never>?
    @State private var verificationID = UUID()
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                CredentialRow(
                    title: "API Key", text: $key, prompt: "API key or read access token", commit: commit)
                Link("TMDB Account", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
            } header: {
                Text("Metadata")
            } footer: {
                Text("TMDB supplies artwork, descriptions, cast, related titles and Discover catalogs.")
            }
            .disabled(verifying)
            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            if store.tmdbCredential != nil {
                Section {
                    Button("Remove API Key", role: .destructive) {
                        cancelVerification()
                        do {
                            try store.removeTMDBCredential()
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(verifying)
                }
            }
        }
        .appScrollEdges().navigationTitle("TMDB").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SaveVerifyButton(busy: verifying, disabled: !canSave, action: commit)
            }
        }
        .onAppear {
            // Load once; returning from the key page must not undo an edit.
            guard !loaded else { return }
            loaded = true
            key = store.tmdbCredential ?? ""
        }
        .onChange(of: key) { _, _ in
            cancelVerification()
            error = nil
        }
        .onDisappear { cancelVerification() }
    }

    private var canSave: Bool { !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Saves and verifies; run by the checkmark here and in the key sheet.
    private func commit() {
        guard canSave, !verifying else { return }
        saveTask?.cancel()
        saveTask = Task { await save() }
    }

    private func cancelVerification() {
        verificationID = UUID()
        saveTask?.cancel(); saveTask = nil
        verifying = false
    }

    private func save() async {
        let input = key, id = UUID()
        verificationID = id
        verifying = true
        defer {
            if verificationID == id { verifying = false; saveTask = nil }
        }
        error = nil
        do {
            try await store.saveTMDBCredential(input)
            guard !Task.isCancelled, verificationID == id, input == key else { return }
            dismiss()
        } catch is CancellationError { return } catch {
            if !Task.isCancelled, verificationID == id, input == key {
                self.error = error.localizedDescription
            }
        }
    }
}
