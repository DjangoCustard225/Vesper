import SwiftUI
import VesperCore

struct SubDLSettingsView: View {
    @AppStorage("subdlLanguage") private var language =
        Locale.current.language.languageCode?.identifier ?? "en"
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @State private var key = ""
    @State private var saved = false
    @State private var error: String?
    @State private var verifying = false
    @State private var saveTask: Task<Void, Never>?
    @State private var verificationID = UUID()
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                CredentialRow(title: "API Key", text: $key, commit: commit).disabled(!loaded)
                Link("SubDL Account", destination: URL(string: "https://subdl.com/panel/api")!)
            } header: {
                Text("Subtitles")
            } footer: {
                Text("SubDL supplies subtitles you can search for from the player.")
            }
            .disabled(verifying)
            Section {
                SubDLLanguagePicker("Subtitle language", selection: $language)
            }
            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            if saved {
                Section {
                    Button("Remove API Key", role: .destructive) {
                        cancelVerification()
                        do {
                            try SecureStorage.delete(.subdlAPIKey)
                            store.subdlConfigured = false
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(verifying)
                }
            }
        }
        .appScrollEdges().navigationTitle("SubDL").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SaveVerifyButton(busy: verifying, disabled: !canSave, action: commit)
            }
        }
        .task {
            // Load once; returning from the key sheet must not undo an edit.
            guard !loaded else { return }
            do {
                key = try SecureStorage.load(.subdlAPIKey) ?? ""
                saved = !key.isEmpty
                loaded = true
            } catch {
                self.error = error.localizedDescription
            }
        }
        .onChange(of: key) { _, _ in
            cancelVerification()
            error = nil
        }
        .onDisappear { cancelVerification() }
    }

    private var canSave: Bool { loaded && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

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
        let input = key.trimmingCharacters(in: .whitespacesAndNewlines), id = UUID()
        verificationID = id
        verifying = true
        defer {
            if verificationID == id { verifying = false; saveTask = nil }
        }
        error = nil
        do {
            try await SubDLClient(key: input).validate()
            guard !Task.isCancelled, verificationID == id else { return }
            try SecureStorage.save(input, for: .subdlAPIKey)
            store.subdlConfigured = true
            dismiss()
        } catch is CancellationError { return } catch {
            if !Task.isCancelled, verificationID == id {
                self.error = error.localizedDescription
            }
        }
    }
}
