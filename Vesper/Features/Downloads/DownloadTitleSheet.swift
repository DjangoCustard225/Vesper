import SwiftUI
import UIKit
import VesperCore

/// A title's downloads and transfers share one native sheet.
struct DownloadTitleSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let media: MediaItem
    var completedOnly = false
    var initialSelectedID: UUID? = nil
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var selectedID: UUID?
    @State private var detent = PresentationDetent.medium
    @State private var router = DownloadPlaybackRouter()
    @State private var removalTarget: DownloadRecord?
    @State private var confirmingRemoval = false
    @State private var closingAfterRemoval = false
    @State private var removingDownload = false
    @State private var exportSession = DownloadExportSession()
    private var downloads: DownloadManager { store.downloads }
    private var records: [DownloadRecord] {
        downloads.records.filter {
            $0.media.isSameTitle(as: media) && (!completedOnly || $0.phase == .completed)
        }
        .sorted { lhs, rhs in
            if lhs.episode?.season != rhs.episode?.season {
                return (lhs.episode?.season ?? 0) < (rhs.episode?.season ?? 0)
            }
            if lhs.episode?.episode != rhs.episode?.episode {
                return (lhs.episode?.episode ?? 0) < (rhs.episode?.episode ?? 0)
            }
            return lhs.createdAt > rhs.createdAt
        }
    }
    private var featured: DownloadRecord? {
        let id = DownloadTransferPresentation.preferredID(
            in: records, keeping: selectedID ?? initialSelectedID)
        return records.first { $0.id == id }
    }
    var body: some View {
        @Bindable var exportSession = exportSession
        NavigationStack {
            List {
                if let record = featured {
                    Section {
                        featuredContent(record)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))
                    }
                    if records.count > 1 {
                        Section("Downloads") {
                            ForEach(records) { candidate in
                                Button {
                                    selectedID = candidate.id
                                } label: {
                                    HStack(spacing: 12) {
                                        DownloadTransferSummary(
                                            record: candidate,
                                            title: candidate.subtitle ?? DownloadTransferPresentation(
                                                record: candidate
                                            ).filename ?? "Download")
                                        if candidate.id == record.id {
                                            Image(systemName: "checkmark").font(.body.weight(.semibold))
                                                .foregroundStyle(.primary).accessibilityHidden(true)
                                        }
                                    }.padding(.vertical, 4).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .accessibilityAddTraits(candidate.id == record.id ? .isSelected : [])
                            }
                        }
                    }
                    Section {
                        DisclosureGroup("Details") {
                            if let filename = DownloadTransferPresentation(record: record).filename {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Source filename").font(.caption).foregroundStyle(.secondary)
                                    Text(filename).font(.subheadline).textSelection(.enabled)
                                }.padding(.vertical, 4)
                            }
                            if downloads.progress(for: record).connections > 0 {
                                LabeledContent(
                                    "Connections",
                                    value: String(downloads.progress(for: record).connections))
                            }
                            if record.phase != .completed, let status = downloads.backgroundStatus {
                                Text(status).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped).appScrollEdges()
            .contentMargins(.top, 8, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 680).frame(maxWidth: .infinity)
            .overlay {
                if records.isEmpty {
                    ContentUnavailableView("No downloads", systemImage: "arrow.down.circle")
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .onChange(of: records.map(\.id), initial: true) { _, _ in
            selectedID = DownloadTransferPresentation.preferredID(
                in: records, keeping: selectedID ?? initialSelectedID)
        }
        .downloadedPlayback(router, knownEpisodes: records.compactMap(\.episode))
        .background { DownloadExportLifetime(session: exportSession).frame(width: 0, height: 0) }
        .sheet(item: $exportSession.item, onDismiss: exportSession.finish) { item in
            DownloadExportSheet(url: item.url, completion: exportSession.finish)
        }
        .confirmationDialog(
            removalTarget?.phase == .completed ? "Remove this download?" : "Cancel this download?",
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button(
                removalTarget?.phase == .completed ? "Remove Download" : "Cancel Download", role: .destructive
            ) {
                guard let target = removalTarget, !removingDownload else { return }
                removingDownload = true
                Task {
                    defer { removingDownload = false }
                    if await downloads.removeDownloads([target.id]) {
                        closingAfterRemoval = target.phase != .completed
                    }
                }
            }
        }
        .onChange(of: confirmingRemoval) { _, presented in
            if !presented {
                removalTarget = nil
                if closingAfterRemoval { dismiss() }
            }
        }
        .onChange(of: closingAfterRemoval) { _, closing in
            if closing, !confirmingRemoval { dismiss() }
        }
        .onChange(of: dynamicType, initial: true) { _, size in
            if size.isAccessibilitySize { detent = .large }
        }
    }

    private func featuredContent(_ record: DownloadRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if dynamicType.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    artwork(record)
                    title(record)
                }
            } else {
                HStack(spacing: 16) {
                    artwork(record)
                    title(record)
                }
            }
            DownloadTransferProgress(record: record)
            if let message = DownloadTransferPresentation(record: record).supportingMessage {
                Label(
                    message, systemImage: record.phase == .failed ? "exclamationmark.circle" : "info.circle"
                )
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                DownloadTransferAction(record: record, prominent: true) {
                    router.play(record, store: store, knownEpisodes: records.compactMap(\.episode))
                }.id(record.id)
                Menu {
                    if record.phase == .completed {
                        Button("Share / Export", systemImage: "square.and.arrow.up") {
                            exportSession.prepare(record, downloads: downloads)
                        }.disabled(exportSession.preparing || exportSession.item != nil)
                    }
                    Button(
                        record.phase == .completed ? "Remove Download" : "Cancel Download",
                        systemImage: "trash", role: .destructive
                    ) {
                        removalTarget = record; confirmingRemoval = true
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 24)
                }.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
                    .disabled(removingDownload)
                    .frame(minWidth: Design.minimumHitTarget, minHeight: Design.minimumHitTarget)
                    .accessibilityLabel("Download options")
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }

    private func artwork(_ record: DownloadRecord) -> some View {
        DownloadSheetArtwork(
            url: downloads.localArtwork(record.media.poster, record: record)?.absoluteString
                ?? record.media.poster,
            height: dynamicType.isAccessibilitySize ? 72 : 96)
    }

    private func title(_ record: DownloadRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(media.name).font(.headline).accessibilityAddTraits(.isHeader)
            if let subtitle = record.subtitle, subtitle != media.name {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

/// Holds the source lease until copying finishes and the export lease until sharing ends.
@MainActor @Observable
private final class DownloadExportSession {
    var item: DownloadExportItem?
    private(set) var preparing = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var lease: (DownloadManager, UUID)?
    @ObservationIgnored private var exportURL: URL?

    func prepare(_ record: DownloadRecord, downloads: DownloadManager) {
        guard task == nil, lease == nil, downloads.acquire(record.id) else { return }
        preparing = true
        let current = revision
        task = Task {
            var transferredLease = false
            defer {
                if !transferredLease { downloads.unprotect([record.id]) }
                if revision == current { preparing = false; task = nil }
            }
            do {
                let url = try await downloads.export(record)
                guard !Task.isCancelled, revision == current else {
                    downloads.finishExport(url)
                    return
                }
                lease = (downloads, record.id)
                transferredLease = true
                exportURL = url
                item = DownloadExportItem(url: url)
            } catch is CancellationError {} catch {
                if revision == current, !Task.isCancelled { downloads.error = error.localizedDescription }
            }
        }
    }

    func finish() {
        revision = UUID()
        task?.cancel(); task = nil
        preparing = false
        if let (downloads, id) = lease {
            if let exportURL { downloads.finishExport(exportURL) }
            downloads.unprotect([id])
        }
        lease = nil; exportURL = nil; item = nil
    }
}

/// Presenting the share sheet must retain the lease. Removing its owner must release it.
private struct DownloadExportLifetime: UIViewRepresentable {
    let session: DownloadExportSession
    func makeCoordinator() -> DownloadExportSession { session }
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) {}
    static func dismantleUIView(_ view: UIView, coordinator: DownloadExportSession) {
        coordinator.finish()
    }
}
private struct DownloadExportItem: Identifiable { let id = UUID(); let url: URL }
private struct DownloadExportSheet: UIViewControllerRepresentable {
    let url: URL
    let completion: () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in Task { @MainActor in completion() } }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view; popover.sourceRect = CGRect(x: 1, y: 1, width: 1, height: 1)
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// This sheet uses the cached title poster without cropping its artwork.
private struct DownloadSheetArtwork: View {
    let url: String?
    let height: CGFloat
    var body: some View {
        CachedArtworkImage(url: DownloadFiles.artworkURL(url), fadesIn: true) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFit()
            default:
                RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                    .overlay { Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary) }
            }
        }.frame(width: height * 2 / 3, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
    }
}
