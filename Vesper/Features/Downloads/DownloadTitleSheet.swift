import SwiftUI
import UIKit
import VesperCore

/// A title's downloads and transfers share one native sheet.
struct DownloadTitleSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let media: MediaItem
    var completedOnly = false
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var selectedID: UUID?
    @State private var detent = PresentationDetent.large
    @State private var router = DownloadPlaybackRouter()
    @State private var removalTarget: DownloadRecord?
    @State private var confirmingRemoval = false
    @State private var closingAfterRemoval = false
    @State private var export: DownloadExportItem?
    @State private var exporting: UUID?
    @State private var preparingExport = false
    @State private var exportURL: URL?
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
        let id = DownloadTransferPresentation.preferredID(in: records, keeping: selectedID)
        return records.first { $0.id == id }
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                List {
                    if let record = featured {
                        Section {
                            featuredContent(record, artworkHeight: artworkHeight(in: geometry.size))
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 12, trailing: 0))
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
                .scrollContentBackground(.hidden)
                .frame(maxWidth: 680).frame(maxWidth: .infinity)
                .overlay {
                    if records.isEmpty {
                        ContentUnavailableView("No downloads", systemImage: "arrow.down.circle")
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                        .accessibilityLabel("Close downloads")
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .onChange(of: records.map(\.id), initial: true) { _, _ in
            selectedID = DownloadTransferPresentation.preferredID(in: records, keeping: selectedID)
        }
        .downloadedPlayback(router, knownEpisodes: records.compactMap(\.episode))
        .sheet(item: $export, onDismiss: finishExport) { item in
            DownloadExportSheet(url: item.url, completion: finishExport)
        }
        .confirmationDialog(
            removalTarget?.phase == .completed ? "Remove this download?" : "Cancel this download?",
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button(
                removalTarget?.phase == .completed ? "Remove Download" : "Cancel Download", role: .destructive
            ) {
                guard let target = removalTarget else { return }
                downloads.requestRemove([target.id])
                closingAfterRemoval = target.phase != .completed
            }
        }
        .onChange(of: confirmingRemoval) { _, presented in
            if !presented { removalTarget = nil }
        }
        .task(id: removalTarget?.id) {
            guard removalTarget != nil else { return }
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            confirmingRemoval = true
        }
        .task(id: closingAfterRemoval) {
            guard closingAfterRemoval else { return }
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            dismiss()
        }
    }

    private func artworkHeight(in size: CGSize) -> CGFloat {
        if dynamicType.isAccessibilitySize { return 96 }
        return min(size.width > size.height ? 120 : 240, max(96, size.height * 0.34))
    }
    private func featuredContent(_ record: DownloadRecord, artworkHeight: CGFloat) -> some View {
        VStack(spacing: 20) {
            VStack(spacing: 16) {
                DownloadSheetArtwork(
                    url: downloads.localArtwork(record.media.poster, record: record)?.absoluteString
                        ?? record.media.poster,
                    height: artworkHeight)
                VStack(spacing: 6) {
                    Text(media.name).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                    if let subtitle = record.subtitle, subtitle != media.name {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }
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
                        Button("Share / Export", systemImage: "square.and.arrow.up") { share(record) }
                            .disabled(preparingExport || exporting != nil)
                    }
                    Button(
                        record.phase == .completed ? "Remove Download" : "Cancel Download",
                        systemImage: "trash", role: .destructive
                    ) { removalTarget = record }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 24)
                }.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
                    .frame(minWidth: Design.minimumHitTarget, minHeight: Design.minimumHitTarget)
                    .accessibilityLabel("Download options")
            }.frame(maxWidth: 320)
        }
        .padding(20)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .padding(.horizontal, 8)
    }
    private func share(_ record: DownloadRecord) {
        guard !preparingExport, exporting == nil, downloads.acquire(record.id) else { return }
        preparingExport = true
        Task {
            defer { preparingExport = false }
            do {
                let url = try await downloads.export(record)
                exporting = record.id; exportURL = url; export = DownloadExportItem(url: url)
            } catch { downloads.unprotect([record.id]); downloads.error = error.localizedDescription }
        }
    }
    private func finishExport() {
        guard let exporting else { return }
        if let url = exportURL { downloads.finishExport(url) }; exportURL = nil
        downloads.unprotect([exporting]); self.exporting = nil; export = nil
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
