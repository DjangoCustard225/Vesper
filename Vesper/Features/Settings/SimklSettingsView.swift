import SafariServices
import SwiftUI

struct SimklSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var signingIn = false
    @State private var disconnecting = false

    var body: some View {
        @Bindable var simkl = store.simkl
        Form {
            Section("Account") {
                LabeledContent("Status", value: simkl.isConnected ? "Connected" : "Not connected")
                if !simkl.isConnected {
                    Button("Connect SIMKL") { signingIn = true }
                }
                if let error = simkl.error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            if simkl.isConnected {
                Section {
                    LabeledContent(
                        "Tracking", value: store.activeTrackingService == .simkl ? "Active" : "Paused")
                    if store.activeTrackingService != .simkl {
                        Button("Use SIMKL") { store.activeTrackingService = .simkl }
                    }
                }
                Section("Sync") {
                    Button {
                        Task { await store.syncSimkl() }
                    } label: {
                        HStack {
                            Text(simkl.isSyncing ? "Syncing…" : "Sync now")
                            Spacer()
                            if simkl.isSyncing { ProgressView().accessibilityHidden(true) }
                        }
                    }.disabled(simkl.isSyncing || !simkl.enabled || !simkl.syncWatched)
                    LabeledContent("Last synced") {
                        if let date = simkl.state.lastSyncedAt {
                            Text(date, style: .relative).foregroundStyle(.secondary)
                        } else {
                            Text("Never").foregroundStyle(.secondary)
                        }
                    }
                    if !simkl.state.pending.isEmpty {
                        LabeledContent("Unsent changes", value: String(simkl.state.pending.count))
                    }
                }
                Section {
                    Toggle("Sync watch history", isOn: $simkl.syncWatched).onChange(of: simkl.syncWatched) {
                        _, enabled in if enabled { Task { await store.syncSimkl() } }
                    }
                    Toggle("Scrobble playback", isOn: $simkl.scrobbling)
                } header: {
                    Text("Preferences")
                } footer: {
                    Text("Scrobbling tracks playback in Vesper’s built-in player.")
                }
                Section {
                    Button("Switch account") {
                        Task {
                            await simkl.disconnect()
                            if !simkl.isConnected { signingIn = true }
                        }
                    }
                    Button("Disconnect SIMKL", role: .destructive) { disconnecting = true }
                }
            }
        }
        .appScrollEdges()
        .navigationTitle("SIMKL").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $signingIn) { SimklSignInSheet() }
        .confirmationDialog("Disconnect SIMKL?", isPresented: $disconnecting, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { Task { await simkl.disconnect() } }
        } message: {
            Text("Your local watch history will be kept.")
        }
    }
}

private struct SimklSignInSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var browserURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                if let code = store.simkl.deviceCode {
                    Section {
                        Text(code.userCode).font(.largeTitle.monospaced().weight(.semibold))
                            .textSelection(.enabled).frame(maxWidth: .infinity)
                        Button("Open SIMKL") {
                            var components = URLComponents(
                                url: code.verificationURI, resolvingAgainstBaseURL: false)
                            components?.queryItems = [URLQueryItem(name: "user_code", value: code.userCode)]
                            browserURL = components?.url
                        }
                        ProgressView("Waiting for approval…")
                    } footer: {
                        Text("Sign in and approve Vesper on SIMKL. The code is filled in for you.")
                    }
                } else if store.simkl.isAuthorizing {
                    ProgressView("Connecting…")
                }
                if let error = store.simkl.error {
                    Text(error).foregroundStyle(.red)
                    Button("Try again") { store.simkl.startAuthorization() }
                }
            }
            .navigationTitle("Connect SIMKL").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium])
        .onAppear { store.simkl.startAuthorization() }
        .onDisappear { store.simkl.cancelAuthorization() }
        .sheet(isPresented: Binding(get: { browserURL != nil }, set: { if !$0 { browserURL = nil } })) {
            if let browserURL { SimklBrowser(url: browserURL).ignoresSafeArea() }
        }
        .onChange(of: store.simkl.isConnected) { _, connected in
            if connected {
                browserURL = nil
                if !store.trakt.isConnected { store.activeTrackingService = .simkl };
                Task { await store.resumeTrakt() }; dismiss()
            }
        }
    }
}

private struct SimklBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
