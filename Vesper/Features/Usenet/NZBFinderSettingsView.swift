import SwiftUI
import VesperCore

struct NZBFinderSettingsView: View {
    @State private var draft = NZBFinderDraft()
    let finish: () -> Void

    var body: some View {
        Form {
            Section("Indexer") {
                CredentialRow(title: "API Key", text: $draft.apiKey, commit: commit)
                enabledRow()
                Toggle("Include Season Packs", isOn: $draft.seasonPacks)
                Link("NZBFinder Account", destination: URL(string: "https://nzbfinder.ws")!)
            }
            .disabled(draft.busy)
            if let error = draft.error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            if draft.configured {
                Section {
                    Button("Remove API Key", role: .destructive) { draft.remove(finish: finish) }
                        .disabled(draft.busy)
                }
            }
        }
        .navigationTitle("Configure Indexer").navigationBarTitleDisplayMode(.inline).appScrollEdges()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SaveVerifyButton(busy: draft.busy, disabled: !draft.valid, action: commit)
            }
        }
        .onChange(of: draft.inputs) { _, _ in draft.cancel() }
        .onDisappear { draft.cancel() }
    }

    /// Saves and verifies; run by the checkmark here and in the key sheet.
    private func commit() {
        guard draft.valid, !draft.busy else { return }
        draft.save(finish: finish)
    }

    private func enabledRow() -> some View {
        NavigationLink {
            NZBFinderEnabledView(draft: draft)
        } label: {
            LabeledContent("Enabled") {
                Text(draft.enabled ? "On" : "Off").foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private struct NZBFinderEnabledView: View {
    @Bindable var draft: NZBFinderDraft

    var body: some View {
        Form {
            Section { Toggle("Enabled", isOn: $draft.enabled) }
        }
        .navigationTitle("Enabled").navigationBarTitleDisplayMode(.inline).appScrollEdges()
        .onChange(of: draft.inputs) { _, _ in draft.cancel() }
    }
}

@MainActor @Observable
private final class NZBFinderDraft {
    var apiKey: String
    var enabled: Bool
    var seasonPacks: Bool
    var busy = false
    var error: String?
    private var operation = UUID()
    private var task: Task<Void, Never>?
    private var service: NZBFinderService { .shared }

    init() {
        let service = NZBFinderService.shared
        apiKey = service.apiKey ?? ""
        enabled = service.apiKey == nil ? true : service.enabled
        seasonPacks = service.apiKey == nil ? true : service.includeSeasonPacks
        error = service.storageError
    }

    var valid: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var inputs: [String] { [apiKey, String(enabled), String(seasonPacks)] }
    var configured: Bool { service.apiKey != nil }

    func cancel() {
        task?.cancel(); operation = UUID(); busy = false; error = nil
    }

    func save(finish: @escaping () -> Void) {
        cancel()
        let token = operation, key = apiKey, enableSearch = enabled, packs = seasonPacks
        busy = true
        task = Task {
            defer { if operation == token { busy = false } }
            do {
                try await service.save(key)
                try Task.checkCancellation()
                guard operation == token else { return }
                service.setEnabled(enableSearch)
                service.setIncludeSeasonPacks(packs)
                finish()
            } catch is CancellationError {
            } catch {
                guard operation == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func remove(finish: @escaping () -> Void) {
        cancel()
        let token = operation
        busy = true
        task = Task {
            defer { if operation == token { busy = false } }
            do {
                try await service.remove()
                guard operation == token, !Task.isCancelled else { return }
                finish()
            } catch {
                guard operation == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
