import SwiftUI
import VesperCore

struct MDBListSettingsView: View {
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
                CredentialRow(title: "API Key", text: $key, commit: commit)
                Link("MDBList Account", destination: URL(string: "https://mdblist.com/preferences/")!)
            } header: {
                Text("Ratings")
            } footer: {
                Text(
                    "MDBList supplies the IMDb, Rotten Tomatoes and Letterboxd scores shown under a title's description."
                )
            }
            .disabled(verifying)
            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            if store.mdblistKey != nil {
                Section {
                    Button("Remove API Key", role: .destructive) {
                        cancelVerification()
                        do {
                            try store.removeMDBListKey()
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(verifying)
                }
            }
        }
        .appScrollEdges().navigationTitle("MDBList").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SaveVerifyButton(busy: verifying, disabled: !canSave, action: commit)
            }
        }
        .onAppear {
            // Load once; returning from the key page must not undo an edit.
            guard !loaded else { return }
            loaded = true
            key = store.mdblistKey ?? ""
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
            try await store.saveMDBListKey(input)
            guard !Task.isCancelled, verificationID == id, input == key else { return }
            dismiss()
        } catch is CancellationError { return } catch {
            if !Task.isCancelled, verificationID == id, input == key {
                self.error = error.localizedDescription
            }
        }
    }
}
