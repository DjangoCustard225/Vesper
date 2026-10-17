import SafariServices
import SwiftUI
import VesperCore

struct TraktSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var signingIn = false
    @State private var confirmingDisconnect = false

    var body: some View {
        @Bindable var trakt = store.trakt
        Form {
            Section {
                if let account = trakt.state.account, trakt.isConnected {
                    LabeledContent("Account", value: account.displayName)
                }
                if !trakt.isConnected || trakt.needsReconnect {
                    Button(trakt.needsReconnect ? "Reconnect Trakt" : "Connect Trakt") { signingIn = true }
                }
                if trakt.isConnected {
                    Button {
                        Task { await store.syncTrakt(force: true) }
                    } label: {
                        HStack {
                            Text("Sync now")
                            Spacer()
                            if trakt.isSyncing { ProgressView() }
                        }
                    }.disabled(trakt.isSyncing || trakt.needsReconnect)
                    if let date = trakt.state.lastSyncedAt {
                        LabeledContent("Last synced") {
                            Text(date, style: .relative).foregroundStyle(.secondary)
                        }
                    }
                    if !trakt.state.pending.isEmpty {
                        NavigationLink("Unsent changes (\(trakt.state.pending.count))") {
                            TraktPendingChangesView()
                        }
                    }
                }
                if let error = trakt.error { ErrorNotice(message: error) }
            }
            if trakt.isConnected {
                Section {
                    Toggle("Sync watch history", isOn: $trakt.syncHistory)
                        .onChange(of: trakt.syncHistory) { _, enabled in
                            if enabled { Task { await store.syncTrakt(force: true) } }
                        }
                    #if !VESPER_GO
                    Toggle("Scrobble playback", isOn: $trakt.scrobbling)
                        .onChange(of: trakt.scrobbling) { _, enabled in
                            if enabled { Task { await store.syncTrakt(force: true) } }
                        }
                    #endif
                } footer: {
                    #if !VESPER_GO
                    Text("Scrobbling tracks playback in Vesper’s built-in players.")
                    #endif
                }
                Section {
                    Button("Disconnect Trakt", role: .destructive) { confirmingDisconnect = true }
                }
            }
            Section {
                Link("Manage connected apps", destination: URL(string: "https://app.trakt.tv/settings/apps")!)
            }
        }
        .appScrollEdges().navigationTitle("Trakt").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $signingIn) { TraktSignInSheet() }
        .confirmationDialog(
            "Disconnect Trakt?", isPresented: $confirmingDisconnect, titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) { Task { await store.disconnectTrakt() } }
        } message: {
            Text("Your local watch history will be kept. Unsent Trakt changes will be discarded.")
        }
    }
}

private struct TraktSignInSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var browser = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                if let code = store.trakt.deviceCode {
                    Text("Connect to Trakt").font(.title2.bold())
                    Text("Enter this code on Trakt, then approve Vesper.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text("Connecting shares watched history and enabled playback activity with Trakt.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button {
                        UIPasteboard.general.string = code.userCode
                        copied = true
                    } label: {
                        VStack(spacing: 10) {
                            Text(code.userCode).font(
                                .system(size: 34, weight: .semibold, design: .monospaced))
                            Text(copied ? "Copied" : "Tap to copy").font(.footnote).foregroundStyle(
                                .secondary)
                        }.padding(24)
                    }.buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 24))
                        .accessibilityLabel("Copy Trakt code \(code.userCode)")
                    Button("Open Trakt") {
                        UIPasteboard.general.string = code.userCode
                        copied = true
                        browser = true
                    }.buttonStyle(.glassProminent).foregroundStyle(.black)
                } else if store.trakt.isAuthorizing {
                    ProgressView("Connecting to Trakt…")
                } else if let error = store.trakt.error {
                    ErrorNotice(message: error)
                    Button("Try again") { store.connectTrakt() }.buttonStyle(.glass)
                }
                Spacer()
            }.padding(28).frame(maxWidth: .infinity)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
        }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .onAppear { store.connectTrakt() }
        .onDisappear { store.trakt.cancelSignIn() }
        .onChange(of: store.trakt.isAuthorizing) { _, authorizing in
            if !authorizing, store.trakt.isConnected, !store.trakt.needsReconnect {
                browser = false
                dismiss()
            }
        }
        .sheet(isPresented: $browser) {
            if let code = store.trakt.deviceCode { TraktBrowser(url: code.verificationURL).ignoresSafeArea() }
        }
    }
}

private struct TraktBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

private struct TraktPendingChangesView: View {
    @Environment(AppStore.self) private var store
    @State private var discarding: TraktHistoryChange?

    var body: some View {
        List(store.trakt.state.pending) { change in
            VStack(alignment: .leading, spacing: 4) {
                Text(change.media.name).lineLimit(1)
                Text(change.action == .unwatched ? "Mark as unwatched" : "Mark as watched")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .swipeActions { Button("Discard", role: .destructive) { discarding = change } }
        }
        .appScrollEdges().navigationTitle("Unsent changes").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Discard this unsent change?",
            isPresented: Binding(
                get: { discarding != nil }, set: { if !$0 { discarding = nil } }
            ), titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                if let discarding { store.trakt.discard(discarding.id) }
                discarding = nil
            }
        }
    }
}
