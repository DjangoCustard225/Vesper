import SwiftUI
import VesperCore

struct PosterCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.displayScale) private var displayScale
    let item: MediaItem
    var width: CGFloat? = nil
    var showsDownloadProgress = false

    private var watched: Bool { WatchProgress.supports(item) && store.isWatched(item) }
    private var downloaded: Bool { store.downloads.completed.contains { $0.media.isSameTitle(as: item) } }

    var body: some View {
        Color.clear.aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    Artwork(
                        url: item.poster,
                        decodeSize: ArtworkDecodeSize(
                            width: geometry.size.width, height: geometry.size.height, scale: displayScale))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Design.posterCornerRadius, style: .continuous))
            .overlay {
                if showsDownloadProgress { LibraryDownloadOverlay(item: item).allowsHitTesting(false) }
            }
            .overlay {
                RoundedRectangle(cornerRadius: Design.posterCornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
            .overlay(alignment: .topTrailing) {
                if watched { WatchedBadge().padding(8) }
            }
            .overlay(alignment: .topLeading) {
                if downloaded
                    && (!showsDownloadProgress
                        || libraryDownload(for: item, records: store.downloads.records) == nil)
                {
                    DownloadedBadge().padding(8)
                }
            }
            .frame(width: width, alignment: .topLeading)
            .contentShape(Rectangle())
            .accessibilityRepresentation {
                LibraryPosterAccessibility(
                    item: item, watched: watched, downloaded: downloaded,
                    showsDownloadProgress: showsDownloadProgress)
            }
    }
}

struct WatchedBadge: View {
    var body: some View { MediaStatusBadge(systemImage: "checkmark") }
}

struct DownloadedBadge: View {
    var body: some View { MediaStatusBadge(systemImage: "arrow.down") }
}

private struct MediaStatusBadge: View {
    let systemImage: String
    var body: some View {
        Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white).frame(width: 28, height: 28)
            .background(.ultraThinMaterial, in: Circle())
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct MediaGrid: View {
    let items: [MediaItem]
    var onNearEnd: (() -> Void)? = nil
    var onSelect: ((MediaItem) -> Void)? = nil
    var onViewDetails: ((MediaItem) -> Void)? = nil
    var showsDownloadProgress = false
    @State private var prefetch = ArtworkPrefetchState()
    @Environment(\.displayScale) private var displayScale
    @State private var availableWidth: CGFloat = 0

    private var decodeSize: ArtworkDecodeSize? {
        guard availableWidth > 0 else { return nil }
        let count = max(
            1, floor((availableWidth + Design.posterSpacing) / (Design.posterWidth + Design.posterSpacing)))
        let width = min(140, (availableWidth - Design.posterSpacing * (count - 1)) / count)
        return ArtworkDecodeSize(width: width, height: width * 1.5, scale: displayScale)
    }

    private var prefetchURLs: [URL] { prefetch.urls(items) }

    var body: some View {
        LazyVGrid(columns: Design.columns, alignment: .leading, spacing: 16) {
            ForEach(Array(items.enumerated()), id: \.element.key) { index, item in
                Group {
                    if let onSelect {
                        Button {
                            onSelect(item)
                        } label: {
                            PosterCard(item: item, showsDownloadProgress: showsDownloadProgress)
                        }
                    } else {
                        NavigationLink {
                            DetailView(item: item)
                        } label: {
                            PosterCard(item: item, showsDownloadProgress: showsDownloadProgress)
                        }
                    }
                }.buttonStyle(.plain)
                    .modifier(MediaContextMenu(item: item, onViewDetails: onViewDetails))
                    .onScrollVisibilityChange(threshold: 0.01) { visible in
                        prefetch.visibility(visible, key: item.key, items: items)
                    }
                    .onAppear { if index >= items.count - 6 { onNearEnd?() } }
            }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            availableWidth = $0
        }
        .prefetchArtwork(decodeSize == nil ? [] : prefetchURLs, size: decodeSize)
        .onDisappear { prefetch.reset() }
    }
}

struct CatalogHeading: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.title2.bold()).foregroundStyle(.primary)
            Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.gray)
                .accessibilityHidden(true)
        }.padding(.vertical, 2).contentShape(Rectangle())
    }
}

private func libraryDownload(for item: MediaItem, records: [DownloadRecord]) -> DownloadRecord? {
    let candidates = records.filter { $0.phase != .completed && $0.media.isSameTitle(as: item) }
    let selected = DownloadTransferPresentation.preferredID(in: candidates, keeping: nil)
    return candidates.first { $0.id == selected }
}

private struct LibraryDownloadOverlay: View {
    @Environment(AppStore.self) private var store
    let item: MediaItem

    var body: some View {
        if let record = libraryDownload(for: item, records: store.downloads.records) {
            LibraryDownloadIndicator(record: record)
        }
    }
}

private struct LibraryDownloadIndicator: View {
    @Environment(AppStore.self) private var store
    let record: DownloadRecord
    private var progress: DownloadProgress { store.downloads.progress(for: record) }
    private var fraction: Double? {
        DownloadTransferPresentation(record: record).fraction(
            bytes: progress.bytes, total: progress.total, work: progress.work)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
            VStack(spacing: 6) {
                ZStack {
                    Circle().stroke(.white.opacity(0.28), lineWidth: 3)
                    if let fraction {
                        Circle().trim(from: 0, to: fraction)
                            .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(Int((fraction * 100).rounded(.down)))%")
                            .font(.system(size: 14, weight: .semibold)).monospacedDigit().minimumScaleFactor(
                                0.7)
                    } else if record.phase == .paused || record.phase == .pausing {
                        Image(systemName: "pause.fill")
                    } else if record.phase == .failed {
                        Image(systemName: "exclamationmark.circle.fill")
                    } else {
                        ProgressView().tint(.white)
                    }
                }.frame(width: 58, height: 58)
                if fraction != nil && (record.phase == .paused || record.phase == .pausing) {
                    Image(systemName: "pause.fill").font(.caption.weight(.semibold))
                } else if fraction != nil && record.phase == .failed {
                    Image(systemName: "exclamationmark.circle.fill").font(.caption.weight(.semibold))
                }
            }.foregroundStyle(.white)
        }
        .clipShape(RoundedRectangle(cornerRadius: Design.posterCornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

private struct LibraryPosterAccessibility: View {
    @Environment(AppStore.self) private var store
    let item: MediaItem
    let watched: Bool
    let downloaded: Bool
    let showsDownloadProgress: Bool

    private var status: String? {
        guard showsDownloadProgress, let record = libraryDownload(for: item, records: store.downloads.records)
        else {
            return downloaded ? "Downloaded" : nil
        }
        let progress = store.downloads.progress(for: record)
        let presentation = DownloadTransferPresentation(record: record)
        let state = presentation.status(
            networkAvailable: store.downloads.networkAvailable, canTransfer: store.downloads.canTransfer,
            work: progress.work)
        guard
            let fraction = presentation.fraction(
                bytes: progress.bytes, total: progress.total, work: progress.work)
        else { return state }
        return "\(state), \(Int((fraction * 100).rounded(.down))) percent"
    }
    var body: some View {
        Text(item.name).accessibilityLabel(item.name)
            .accessibilityValue(
                [item.releaseInfo ?? item.typeLabel, watched ? "Watched" : nil, status].compactMap { $0 }
                    .joined(separator: ", "))
    }
}
