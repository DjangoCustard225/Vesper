import SwiftUI
import VesperCore
import UserNotifications

struct DownloadsSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var deleting = false
    var body: some View {
        @Bindable var httpOptions = HTTPDownloadOptions.shared
        @Bindable var options = UsenetDownloadOptions.shared
        Form {
            Section {
                NavigationLink("Transfer Queue") { DownloadQueueView() }
            }
            Section {
                Toggle("Parallel Downloads", isOn: $httpOptions.parallel)
            } header: {
                Text("HTTP")
            } footer: {
                Text(
                    "Applies to new downloads. Uses up to four connections for supported files. Background processing continues when allowed by iOS."
                )
            }
            Section("Usenet") {
                LabeledContent("Bandwidth Limit (KB/s)") {
                    TextField("Unlimited", value: $options.bandwidthKBps, format: .number).keyboardType(
                        .numberPad
                    ).multilineTextAlignment(.trailing)
                }
                Toggle("Repair Damaged Files", isOn: $options.repair)
                Toggle("Keep Screen Awake", isOn: $options.keepAwake)
                    .onChange(of: options.keepAwake) { _, _ in store.downloads.updateUsenetIdleTimer() }
                Toggle("Completion Notifications", isOn: $options.notifications)
                    .onChange(of: options.notifications) { _, enabled in
                        if enabled {
                            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                            { granted, _ in
                                if !granted {
                                    Task { @MainActor in UsenetDownloadOptions.shared.notifications = false }
                                }
                            }
                        }
                    }
            }

            Section {
                Toggle(
                    "Allow Cellular Downloads",
                    isOn: Binding(
                        get: { store.downloads.allowsCellular }, set: { store.downloads.setCellular($0) }))
            }
            Section {
                LabeledContent(
                    "Storage Used",
                    value: ByteCountFormatter.string(
                        fromByteCount: store.downloads.usedBytes, countStyle: .file))
                LabeledContent(
                    "Partial Transfers (estimated)",
                    value: ByteCountFormatter.string(
                        fromByteCount: store.downloads.partialBytes, countStyle: .file))
                Button("Delete All Downloads", role: .destructive) { deleting = true }.disabled(
                    store.downloads.records.isEmpty)
            }
        }.appScrollEdges().navigationTitle("Downloads").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                "Delete all downloaded files and cancel transfers?", isPresented: $deleting,
                titleVisibility: .visible
            ) {
                Button("Delete All Downloads", role: .destructive) {
                    store.downloads.requestRemove(Set(store.downloads.records.map(\.id)))
                }
            }
    }
}
