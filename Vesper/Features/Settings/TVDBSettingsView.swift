import SwiftUI
import VesperCore

struct TVDBSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var apiKey = ""
    @State private var pin = ""
    @State private var message: String?
    @State private var error: String?
    @State private var verifying = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                SecureField("API key", text: $apiKey)
                SecureField("Subscriber PIN (optional)", text: $pin)
                Button {
                    saveTask?.cancel()
                    saveTask = Task { await save() }
                } label: {
                    HStack {
                        Text("Save & verify")
                        Spacer()
                        if verifying { ProgressView() }
                    }
                }.disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || verifying)
                if store.tvdbCredentials != nil {
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.tint)
                    Button("Remove credentials", role: .destructive) {
                        reset()
                        do {
                            try store.removeTVDBCredentials()
                            apiKey = ""
                            pin = ""
                            message = "TVDB disconnected."
                        } catch { self.error = error.localizedDescription }
                    }
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.tint) }
                if let error { ErrorNotice(message: error) }
            } footer: {
                Text("When connected, TVDB is preferred for shows. Some API keys require a subscriber PIN.")
            }
            Section {
                Link(
                    "Get an API key",
                    destination: URL(string: "https://thetvdb.com/dashboard/account/apikeys")!)
                Link("TVDB subscriptions", destination: URL(string: "https://thetvdb.com/subscribe")!)
            }
        }.textInputAutocapitalization(.never).autocorrectionDisabled()
            .appScrollEdges().navigationTitle("TVDB").navigationBarTitleDisplayMode(.inline)
            .onChange(of: apiKey) { _, _ in reset() }
            .onChange(of: pin) { _, _ in reset() }
            .onAppear {
                apiKey = store.tvdbCredentials?.apiKey ?? ""
                pin = store.tvdbCredentials?.pin ?? ""
            }
            .onDisappear { saveTask?.cancel() }
    }

    private func reset() {
        saveTask?.cancel()
        verifying = false
        message = nil
        error = nil
    }

    private func save() async {
        let key = apiKey, subscriber = pin
        verifying = true
        message = nil
        error = nil
        defer { if key == apiKey && subscriber == pin { verifying = false } }
        do {
            try await store.saveTVDBCredentials(apiKey: key, pin: subscriber)
            try Task.checkCancellation()
            guard key == apiKey, subscriber == pin else { return }
            message = "Connected. TVDB is preferred for shows."
        } catch is CancellationError {} catch {
            if key == apiKey && subscriber == pin { self.error = error.localizedDescription }
        }
    }
}
