import SwiftUI
import VesperCore

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
                        saveTask?.cancel()
                        verifying = false
                        message = nil
                        error = nil
                    }
                Button {
                    saveTask?.cancel()
                    saveTask = Task { await save() }
                } label: {
                    HStack {
                        Text("Save & verify")
                        Spacer()
                        if verifying { ProgressView() }
                    }
                }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || verifying)
                if store.tmdbCredential != nil {
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.tint)
                    Button("Remove API key", role: .destructive) {
                        saveTask?.cancel()
                        verifying = false
                        do {
                            try store.removeTMDBCredential()
                            key = ""
                            error = nil
                            message = "API key removed."
                        } catch { self.error = error.localizedDescription }
                    }
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.tint) }
                if let error { ErrorNotice(message: error) }
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
        verifying = true
        message = nil
        error = nil
        do {
            try await store.saveTMDBCredential(input)
            guard !Task.isCancelled, input == key else { return }
            message = "Verified and saved."
        } catch is CancellationError { return } catch {
            if input == key { self.error = error.localizedDescription }
        }
        if input == key { verifying = false }
    }
}
