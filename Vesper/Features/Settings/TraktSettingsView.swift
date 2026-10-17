import SafariServices
import SwiftUI
import VesperCore

struct TraktSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var signingIn = false
    @State private var accountAction: AccountAction?
    @State private var changingAccount = false

    private enum AccountAction {
        case switchAccount, disconnect

        var title: String { self == .switchAccount ? "Switch Trakt account?" : "Disconnect Trakt?" }
        var buttonTitle: String { self == .switchAccount ? "Switch account" : "Disconnect" }
    }

    private var connectionIssue: Bool {
        !store.trakt.isConnected || store.trakt.needsReconnect || store.trakt.state.account == nil
    }

    private var connectionStatus: String {
        if store.trakt.isAuthorizing { return "Connecting…" }
        if store.trakt.needsReconnect { return "Reconnect required" }
        if !store.trakt.isConnected { return "Not connected" }
        if store.trakt.state.account == nil, store.trakt.error != nil { return "Needs attention" }
        return "Connected"
    }

    var body: some View {
        @Bindable var trakt = store.trakt
        Form {
            Section("Account") {
                if let account = trakt.state.account, trakt.isConnected {
                    LabeledContent("Account", value: account.displayName)
                }
                LabeledContent("Status", value: connectionStatus)
                if !trakt.isConnected || trakt.needsReconnect {
                    Button(trakt.needsReconnect ? "Reconnect Trakt" : "Connect Trakt") { signingIn = true }
                        .disabled(trakt.isAuthorizing || changingAccount)
                }
                if connectionIssue, let error = trakt.error {
                    TraktIssueNotice(title: "Connection needs attention", message: error)
                }
            }
            if trakt.isConnected {
                Section("Sync") {
                    Button {
                        Task { await store.syncTrakt(force: true) }
                    } label: {
                        HStack {
                            Text(trakt.isSyncing ? "Syncing…" : "Sync now")
                            Spacer()
                            if trakt.isSyncing { ProgressView().accessibilityHidden(true) }
                        }
                    }.disabled(
                        trakt.isSyncing || trakt.needsReconnect || trakt.isAuthorizing || changingAccount)
                    LabeledContent("Last synced") {
                        if let date = trakt.state.lastSyncedAt {
                            Text(date, style: .relative).foregroundStyle(.secondary)
                        } else {
                            Text("Never").foregroundStyle(.secondary)
                        }
                    }
                    if !trakt.state.pending.isEmpty {
                        NavigationLink {
                            TraktPendingChangesView()
                        } label: {
                            LabeledContent("Unsent changes", value: String(trakt.state.pending.count))
                        }
                    }
                    if !connectionIssue, let error = trakt.error {
                        TraktIssueNotice(title: "Sync needs attention", message: error)
                    }
                }
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
                    if let error = trakt.scrobbleError {
                        TraktIssueNotice(title: "Scrobbling needs attention", message: error)
                    }
                    #endif
                } header: {
                    Text("Preferences")
                } footer: {
                    #if !VESPER_GO
                    Text("Scrobbling tracks playback in Vesper’s built-in players.")
                    #endif
                }
            }
            Section("Account management") {
                if trakt.isConnected {
                    Button("Switch account") { accountAction = .switchAccount }
                        .disabled(trakt.isAuthorizing || changingAccount)
                }
                Link("Manage connected apps", destination: URL(string: "https://app.trakt.tv/settings/apps")!)
                if trakt.isConnected {
                    Button("Disconnect Trakt", role: .destructive) { accountAction = .disconnect }
                        .disabled(trakt.isAuthorizing || changingAccount)
                }
            }
        }
        .appScrollEdges().navigationTitle("Trakt").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $signingIn) { TraktSignInSheet() }
        .confirmationDialog(
            accountAction?.title ?? "Trakt account",
            isPresented: Binding(get: { accountAction != nil }, set: { if !$0 { accountAction = nil } }),
            titleVisibility: .visible
        ) {
            if let action = accountAction {
                Button(action.buttonTitle, role: action == .disconnect ? .destructive : nil) {
                    changingAccount = true
                    Task {
                        await store.disconnectTrakt()
                        changingAccount = false
                        if action == .switchAccount, !store.trakt.isConnected { signingIn = true }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your local watch history will be kept. Unsent Trakt changes will be discarded.")
        }
    }
}

private struct TraktIssueNotice: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "exclamationmark.circle").font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
            Text(message).font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
}

private struct TraktSignInSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var browserURL: URL?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            GeometryReader { viewport in
                ScrollView {
                    VStack(spacing: 24) {
                        if let code = store.trakt.deviceCode {
                            authorization(code)
                        } else if store.trakt.isAuthorizing {
                            ProgressView("Connecting to Trakt…")
                        } else if let error = store.trakt.error {
                            TraktIssueNotice(title: "Couldn’t connect", message: error)
                            Button("Try again") { store.connectTrakt() }.buttonStyle(.glass)
                        }
                    }
                    .frame(maxWidth: 420)
                    .frame(maxWidth: .infinity, minHeight: max(0, viewport.size.height - 48))
                    .padding(24)
                }.appScrollEdges()
            }
            .navigationTitle("Connect Trakt").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .onAppear { store.connectTrakt() }
        .onDisappear { store.trakt.cancelSignIn() }
        .onChange(of: store.trakt.deviceCode?.userCode) { _, _ in copied = false }
        .onChange(of: store.trakt.isAuthorizing) { _, authorizing in
            if !authorizing, store.trakt.isConnected, store.trakt.state.account != nil,
                !store.trakt.needsReconnect
            {
                browserURL = nil
                dismiss()
            }
        }
        .sheet(
            isPresented: Binding(
                get: { browserURL != nil },
                set: { if !$0 { browserURL = nil } }
            )
        ) {
            if let browserURL {
                TraktBrowser(url: browserURL).ignoresSafeArea()
            }
        }
    }

    private func authorization(_ code: TraktDeviceCode) -> some View {
        Group {
            Text("Copy the code, open Trakt, and approve Vesper.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button {
                copy(code)
            } label: {
                VStack(spacing: 10) {
                    Text(code.userCode).font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(copied ? "Copied" : "Tap to copy").font(.footnote).foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: .infinity)
            }.buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 24))
                .accessibilityLabel("Copy Trakt code").accessibilityValue(code.userCode)
            Button {
                copy(code)
                browserURL = code.verificationURL
            } label: {
                Text("Open Trakt").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                    .accentButtonForeground()
            }.buttonStyle(.glassProminent).buttonBorderShape(.capsule)
            ProgressView(store.trakt.isConnected ? "Finishing connection…" : "Waiting for approval…")
                .font(.footnote).foregroundStyle(.secondary)
            DisclosureGroup("Use another account") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sign out of Trakt in the browser, then return here and open Trakt again.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Sign out in browser") {
                        browserURL = URL(string: "https://trakt.tv/signout")
                    }.frame(minHeight: 44)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }.font(.subheadline)
            #if VESPER_GO
            Text("Connecting shares watch history with Trakt.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            #else
            Text("Connecting shares watch history and enabled playback activity with Trakt.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            #endif
        }
    }

    private func copy(_ code: TraktDeviceCode) {
        UIPasteboard.general.string = code.userCode
        copied = true
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
            VStack(alignment: .leading, spacing: 5) {
                Text(change.media.name).font(.headline)
                Text(actionLabel(change)).font(.subheadline).foregroundStyle(.secondary)
                if let episode = episodeLabel(change) {
                    Text(episode)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(change.date, style: .relative).font(.caption).foregroundStyle(.secondary)
            }.accessibilityElement(children: .combine)
                .swipeActions { Button("Discard", role: .destructive) { discarding = change } }
        }
        .overlay {
            if store.trakt.state.pending.isEmpty {
                ContentUnavailableView("No unsent changes", systemImage: "checkmark.circle")
            }
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
        } message: {
            Text("This change will no longer be sent to Trakt. Your local watch history will be kept.")
        }
    }

    private func actionLabel(_ change: TraktHistoryChange) -> String {
        switch change.action {
        case .watched: "Mark as watched"
        case .unwatched: "Mark as unwatched"
        #if !VESPER_GO
        case .stopped: "Playback completion"
        #endif
        }
    }

    private func episodeLabel(_ change: TraktHistoryChange) -> String? {
        guard change.media.type == "series", let parts = change.videoID?.split(separator: ":"),
            parts.count >= 3, let season = Int(parts[parts.count - 2]), season >= 0,
            let episode = Int(parts[parts.count - 1]), episode > 0
        else { return nil }
        return "Season \(season), Episode \(episode)"
    }
}
