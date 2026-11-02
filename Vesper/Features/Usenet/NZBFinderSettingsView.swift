import SwiftUI
import VesperCore

struct NZBFinderSettingsView: View {
    @State private var draft = NZBFinderDraft()
    let finish: () -> Void

    var body: some View {
        Form {
            Section("Indexer") {
                row(.apiKey, value: draft.apiKey.isEmpty ? "Not configured" : "••••••••")
                row(.enabled, value: draft.enabled ? "On" : "Off")
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
                Button {
                    draft.save(finish: finish)
                } label: {
                    HStack {
                        Text("Save & Verify")
                        if draft.busy { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(draft.busy || !draft.valid)
            }
        }
        .onChange(of: draft.inputs) { _, _ in draft.cancel() }
        .onDisappear { draft.cancel() }
    }

    private func row(_ field: NZBFinderField, value: String) -> some View {
        NavigationLink {
            NZBFinderFieldView(draft: draft, field: field)
        } label: {
            LabeledContent(field.title) { Text(value).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

private enum NZBFinderField {
    case apiKey, enabled
    var title: String {
        switch self {
        case .apiKey: "API Key"
        case .enabled: "Enabled"
        }
    }
}

private struct NZBFinderFieldView: View {
    @FocusState private var isInputFocused: Bool
    @Bindable var draft: NZBFinderDraft
    let field: NZBFinderField

    var body: some View {
        Form {
            Section {
                switch field {
                case .apiKey:
                    SecureField("Required", text: $draft.apiKey).focused($isInputFocused).accessibilityLabel(
                        "API Key")
                case .enabled:
                    Toggle("Enabled", isOn: $draft.enabled)
                }
            }
        }
        .navigationTitle(field.title).navigationBarTitleDisplayMode(.inline).appScrollEdges()
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .scrollDismissesKeyboard(.interactively)
        .task {
            guard field == .apiKey else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            isInputFocused = true
        }
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
