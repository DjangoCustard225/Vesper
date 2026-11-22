import SwiftUI
import UniformTypeIdentifiers
import VesperCore

struct SyncSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var choosingFolder = false
    @State private var confirmingStop = false

    private var sync: FolderSync { store.folderSync }

    var body: some View {
        @Bindable var sync = store.folderSync
        Form {
            if let folder = sync.folderName {
                Section {
                    LabeledContent("Folder", value: folder)
                    LabeledContent("Last synced") {
                        if sync.isSyncing {
                            ProgressView()
                        } else if let date = sync.lastSync {
                            Text(date, format: .relative(presentation: .named))
                        } else {
                            Text("Never")
                        }
                    }
                    LabeledContent("Other devices", value: devicesSummary)
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                        sync.syncNow(store: store)
                    }.disabled(sync.isSyncing)
                } footer: {
                    if let error = sync.error {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text("Syncs when Vesper opens or closes and shortly after you change your library.")
                    }
                }
                Section {
                    Toggle("Include Add-ons", isOn: $sync.includesAddons)
                } footer: {
                    Text(
                        "Add-on links can contain account tokens. When on, they’re stored in the sync folder."
                    )
                }
                Section {
                    Button("Choose Another Folder") { choosingFolder = true }
                    Button("Stop Syncing", role: .destructive) { confirmingStop = true }
                }
            } else {
                Section {
                    Button("Choose Folder", systemImage: "folder.badge.plus") { choosingFolder = true }
                } footer: {
                    Text(
                        "Pick the same iCloud Drive folder on each device. Vesper syncs your library, watch progress, Home layout and player settings through it. API keys and accounts stay on this device."
                    )
                }
            }
        }
        .appScrollEdges().navigationTitle("Sync")
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { sync.chooseFolder(url, store: store) }
        }
        .confirmationDialog(
            "Stop syncing on this device?", isPresented: $confirmingStop, titleVisibility: .visible
        ) {
            Button("Stop Syncing", role: .destructive) { sync.stopSyncing() }
        } message: {
            Text("Your library and settings stay on this device. Files in the folder aren’t deleted.")
        }
    }

    private var devicesSummary: String {
        switch sync.otherDevices.count {
        case 0: "None yet"
        case 1: sync.otherDevices[0]
        default: "\(sync.otherDevices.count) devices"
        }
    }
}
