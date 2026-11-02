import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UsenetEngine

struct UsenetSettingsView: View {
    @State private var importing = false
    @State private var configuringProvider = false
    @State private var configuringIndexer = false
    @State private var playback = UsenetPlaybackCoordinator()
    private var provider: UsenetService { .shared }
    private var indexer: NZBFinderService { .shared }

    private var indexerStatus: String {
        guard indexer.apiKey != nil else { return "Not configured" }
        return indexer.enabled ? "NZBFinder · Enabled" : "NZBFinder · Disabled"
    }

    var body: some View {
        Form {
            Section {
                Button {
                    configuringProvider = true
                } label: {
                    configurationRow(
                        "Configure Provider", icon: "network",
                        status: provider.provider?.host ?? "Not configured")
                }
                NavigationLink {
                    UsenetBackupProvidersView()
                } label: {
                    configurationRow(
                        "Fallback Providers", icon: "server.rack",
                        status: String(provider.backupProviders.count) + " configured")
                }
                Button {
                    configuringIndexer = true
                } label: {
                    configurationRow("Configure Indexer", icon: "magnifyingglass", status: indexerStatus)
                }
            }
            Section("NZB File") {
                Button("Open NZB File", systemImage: "doc.badge.plus") { importing = true }
                    .disabled(playback.preparing)
                if let name = playback.importedName {
                    Text(name).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                if playback.preparing {
                    HStack {
                        ProgressView(playback.readingFile ? "Reading NZB…" : "Preparing video…")
                        Spacer()
                        Button("Cancel") { playback.cancel() }
                    }
                }
                if let error = playback.error {
                    Text(error).foregroundStyle(.red).accessibilityLabel("Import failed. " + error)
                }
            }
        }
        .navigationTitle("Usenet").navigationBarTitleDisplayMode(.inline).appScrollEdges()
        .navigationDestination(isPresented: $configuringProvider) {
            UsenetProviderSettingsView { configuringProvider = false }
        }
        .navigationDestination(isPresented: $configuringIndexer) {
            NZBFinderSettingsView { configuringIndexer = false }
        }
        .sheet(isPresented: $importing) {
            NZBImportPicker { url in
                importing = false
                if let url {
                    playback.importFile(url) { url, video in
                        PlaybackRequest(
                            url: url, title: video.name, subtitle: nil,
                            introSkippingEnabled: { false })
                    }
                }
            }
        }
        .usenetPlayback(playback, showsErrorAlert: false)
    }

    private func configurationRow(_ title: String, icon: String, status: String) -> some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } icon: {
                Image(systemName: icon)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }.foregroundStyle(.primary)
    }
}

@MainActor @Observable
private final class UsenetProviderDraft {
    var host: String
    var port: String
    var username: String
    var password: String
    var connections: Int
    var testing = false
    var message: String?
    var error: String?
    private var operation = UUID()
    private var task: Task<Void, Never>?

    init() {
        let saved = UsenetService.shared.provider
        host = saved?.host ?? ""; port = String(saved?.port ?? 563)
        username = saved?.username ?? ""; password = saved?.password ?? ""
        connections = saved?.connections ?? 8
        error = UsenetService.shared.storageError
    }

    var provider: UsenetProvider {
        UsenetProvider(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: Int(port) ?? 0, username: username, password: password,
            connections: connections)
    }
    var valid: Bool { (try? provider.validated()) != nil }
    var inputs: [String] { [host, port, username, password, String(connections)] }

    func cancel() {
        task?.cancel(); operation = UUID(); testing = false; message = nil; error = nil
    }

    func save(finish: () -> Void) {
        cancel()
        do { try UsenetService.shared.save(provider); finish() } catch {
            self.error = error.localizedDescription
        }
    }

    func test() {
        cancel()
        let token = operation, value = provider
        testing = true
        task = Task {
            defer { if operation == token { testing = false } }
            do {
                try await UsenetService.shared.test(value)
                try Task.checkCancellation()
                guard operation == token else { return }
                message = "Connection successful."
            } catch is CancellationError {
            } catch {
                guard operation == token, !Task.isCancelled else { return }
                self.error =
                    (error as? UsenetError)?.localizedDescription ?? "The provider connection failed."
            }
        }
    }
}

private struct UsenetProviderSettingsView: View {
    @State private var draft = UsenetProviderDraft()
    let finish: () -> Void

    var body: some View {
        Form {
            Section("Server") {
                field(.host, value: draft.host.isEmpty ? "Not configured" : draft.host)
                field(.port, value: draft.port)
            }
            Section("Credentials") {
                field(.username, value: draft.username.isEmpty ? "Optional" : draft.username)
                field(.password, value: draft.password.isEmpty ? "Optional" : "••••••••")
            }
            Section {
                field(.connections, value: String(draft.connections))
            }
            Section {
                Button(action: draft.test) {
                    HStack {
                        Text("Test Connection")
                        Spacer()
                        if draft.testing { ProgressView().controlSize(.small) }
                    }
                }.disabled(draft.testing || !draft.valid)
            }
            if let message = draft.message {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            if let error = draft.error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Configure Provider").navigationBarTitleDisplayMode(.inline).appScrollEdges()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { draft.save(finish: finish) }
                    .disabled(draft.testing || !draft.valid)
            }
        }
        .onChange(of: draft.inputs) { _, _ in draft.cancel() }
        .onDisappear { draft.cancel() }
    }

    private func field(_ field: UsenetProviderField, value: String) -> some View {
        NavigationLink {
            UsenetProviderFieldView(draft: draft, field: field)
        } label: {
            LabeledContent(field.title) {
                Text(value).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private enum UsenetProviderField {
    case host, port, username, password, connections
    var title: String {
        switch self {
        case .host: "Host"
        case .port: "Port"
        case .username: "Username"
        case .password: "Password"
        case .connections: "Connections"
        }
    }
}

private struct UsenetProviderFieldView: View {
    @FocusState private var isInputFocused: Bool
    @Bindable var draft: UsenetProviderDraft
    let field: UsenetProviderField

    var body: some View {
        Form {
            Section {
                switch field {
                case .host:
                    TextField("news.example.com", text: $draft.host).keyboardType(.URL).focused(
                        $isInputFocused
                    )
                    .accessibilityLabel("Host")
                case .port:
                    TextField("563", text: $draft.port).keyboardType(.numberPad).focused($isInputFocused)
                        .accessibilityLabel("Port")
                case .username:
                    TextField("Optional", text: $draft.username).focused($isInputFocused).accessibilityLabel(
                        "Username")
                case .password:
                    SecureField("Optional", text: $draft.password).focused($isInputFocused)
                        .accessibilityLabel("Password")
                case .connections:
                    LabeledContent("Connections", value: String(draft.connections)).monospacedDigit()
                    Slider(
                        value: Binding(
                            get: { Double(draft.connections) },
                            set: { draft.connections = Int($0.rounded()) }),
                        in: Double(
                            UsenetProvider.connectionRange.lowerBound)...Double(
                                UsenetProvider.connectionRange.upperBound), step: 1
                    )
                    .accessibilityLabel("Connections").accessibilityValue(String(draft.connections))
                }
            } footer: {
                if field == .connections { Text("Use your provider’s connection limit.") }
            }
        }
        .navigationTitle(field.title).navigationBarTitleDisplayMode(.inline).appScrollEdges()
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .scrollDismissesKeyboard(.interactively)
        .task {
            guard field != .connections else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            isInputFocused = true
        }
        .onChange(of: draft.inputs) { _, _ in draft.cancel() }
    }
}

/// Import a sandbox copy so file-provider access is not needed during playback preparation.
private struct NZBImportPicker: UIViewControllerRepresentable {
    let completion: (URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [UTType(importedAs: "app.vesper.nzb", conformingTo: .xml), .xml],
            asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}
    @MainActor final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let completion: (URL?) -> Void
        init(completion: @escaping (URL?) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            completion(urls.first)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(nil) }
    }
}
