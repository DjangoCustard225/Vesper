import SwiftUI
import VesperCore

struct DownloadQueueView: View {
    @Environment(AppStore.self) private var store
    private var records: [DownloadRecord] { store.downloads.records.filter { $0.phase != .completed } }
    var body: some View {
        List {
            if let status = store.downloads.backgroundStatus, !records.isEmpty {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(records) { record in
                DownloadTransferRow(record: record)
                    .swipeActions {
                        Button("Remove", role: .destructive) { store.downloads.requestRemove([record.id]) }
                    }
            }
            .onMove { indices, offset in
                var ids = records.map(\.id)
                ids.move(fromOffsets: indices, toOffset: offset)
                store.downloads.reorder(ids)
            }
        }
        .overlay {
            if records.isEmpty { ContentUnavailableView("No transfers", systemImage: "arrow.down.circle") }
        }
        .navigationTitle("Transfer Queue")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Pause All", systemImage: "pause") { store.downloads.pauseAll() }
                Spacer()
                Button("Resume All", systemImage: "play") { store.downloads.resumeAll() }
            }
        }
    }
}
