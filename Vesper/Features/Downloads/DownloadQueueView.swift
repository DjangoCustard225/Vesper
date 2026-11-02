import SwiftUI
import VesperCore

struct DownloadQueueView: View {
    @Environment(AppStore.self) private var store
    @State private var selected: DownloadRecord?
    @State private var cancellationTarget: DownloadRecord?
    @State private var confirmingCancellation = false
    private var records: [DownloadRecord] { store.downloads.records.filter { $0.phase != .completed } }
    private var canPause: Bool {
        records.contains { [.preparing, .downloading, .queued].contains($0.phase) }
    }
    private var canResume: Bool {
        records.contains { $0.phase == .paused && $0.usenetNeedsPassword != true && $0.usenetFiles == nil }
    }

    var body: some View {
        List {
            if !records.isEmpty {
                Section {
                    ForEach(records) { record in
                        DownloadTransferRow(record: record) { selected = record }
                            .swipeActions(allowsFullSwipe: false) {
                                Button("Cancel download", systemImage: "xmark", role: .destructive) {
                                    cancellationTarget = record
                                    confirmingCancellation = true
                                }
                            }
                    }
                    .onMove { indices, offset in
                        var ids = records.map(\.id)
                        ids.move(fromOffsets: indices, toOffset: offset)
                        store.downloads.reorder(ids)
                    }
                } footer: {
                    if let status = store.downloads.backgroundStatus {
                        Text(status)
                    }
                }
            }
        }
        .listStyle(.insetGrouped).appScrollEdges()
        .overlay {
            if records.isEmpty { ContentUnavailableView("No transfers", systemImage: "arrow.down.circle") }
        }
        .navigationTitle("Transfer Queue").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !records.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Pause All", systemImage: "pause") { store.downloads.pauseAll() }
                        .disabled(!canPause)
                    Spacer()
                    Button("Resume All", systemImage: "play") { store.downloads.resumeAll() }
                        .disabled(!canResume)
                }
            }
        }
        .sheet(item: $selected) { record in
            DownloadTitleSheet(media: record.media, initialSelectedID: record.id)
        }
        .confirmationDialog(
            "Cancel this download?", isPresented: $confirmingCancellation, titleVisibility: .visible
        ) {
            Button("Cancel Download", role: .destructive) {
                if let record = cancellationTarget { store.downloads.requestRemove([record.id]) }
            }
        }
        .onChange(of: confirmingCancellation) { _, visible in
            if !visible { cancellationTarget = nil }
        }
    }
}
