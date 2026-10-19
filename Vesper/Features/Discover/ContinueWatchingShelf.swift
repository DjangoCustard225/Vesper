import SwiftUI
import VesperCore

struct ContinueWatchingShelf: View {
    let records: [WatchRecord]
    @State private var prefetch = PosterPrefetchState()
    @State private var visible = false

    private var artworkItems: [MediaItem] {
        records.map { record in
            var item = record.media
            item.poster = item.background ?? item.poster
            return item
        }
    }

    private var urls: [URL] { visible ? prefetch.urls(artworkItems) : [] }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 14) {
                ForEach(records, id: \.media.key) { record in
                    ContinueWatchingCard(record: record)
                        .containerRelativeFrame(.horizontal) { width, _ in
                            min(360, max(220, width * 0.615))
                        }
                        .onScrollVisibilityChange(threshold: 0.01) { active in
                            prefetch.visibility(active, key: record.media.key, items: artworkItems)
                        }
                }
            }.padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden).appScrollEdges()
        .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
        .prefetchArtwork(urls)
        .onDisappear {
            visible = false
            prefetch.reset()
        }
    }
}

private struct ContinueWatchingCard: View {
    @Environment(AppStore.self) private var store
    let record: WatchRecord
    @State private var presentation: HeroPresentation?

    private var media: MediaItem { presentation?.media ?? record.media }

    private var progress: Double { min(1, max(0, record.elapsed / record.duration)) }

    private var playbackLabel: String {
        let minutes = Int(min(99_999, ceil(max(0, record.duration - record.elapsed) / 60)))
        let remaining = "\(minutes)m"
        guard let episode = record.episodeKey?.split(separator: ":"), episode.count == 2 else {
            return remaining
        }
        return "S\(episode[0]), E\(episode[1]) · " + remaining
    }

    private var revision: String {
        record.media.key + store.metadataConfigurationRevision
            + store.metadataRevision(for: [store.detailsCacheID(record.media)])
    }

    var body: some View {
        NavigationLink {
            DetailView(item: media, startPlayback: true, resumeRecord: record)
        } label: {
            Color.clear.aspectRatio(1.42, contentMode: .fit)
                .overlay {
                    GeometryReader { geometry in
                        Artwork(url: media.background ?? media.poster)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .overlay(alignment: .leading) {
                                if let presentation {
                                    artworkTitle(presentation)
                                        .frame(
                                            width: geometry.size.width * 0.62,
                                            height: geometry.size.height * 0.4,
                                            alignment: .leading
                                        )
                                        .padding(.leading, 18).padding(.bottom, 20)
                                }
                            }
                    }
                }
                .overlay(alignment: .bottom) {
                    Rectangle().fill(.ultraThinMaterial)
                        .frame(height: 64)
                        .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 7) {
                        Image(systemName: "play.fill").font(.system(size: 13, weight: .semibold))
                        Capsule().fill(.white.opacity(0.3)).frame(width: 34, height: 5)
                            .overlay(alignment: .leading) {
                                Capsule().fill(.white).frame(width: 34 * progress, height: 5)
                            }
                        Text(playbackLabel).font(.subheadline.weight(.medium))
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 32)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 14).padding(.bottom, 14)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(
                        .white.opacity(0.16), lineWidth: 0.5)
                }
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resume \(media.name)")
        .accessibilityValue(playbackLabel + " remaining")
        .contextMenu {
            MediaMenuActions(item: media)
            removeFromContinueWatching
        }
        .overlay(alignment: .bottomTrailing) {
            Menu {
                NavigationLink {
                    DetailView(item: media)
                } label: {
                    Label("View Details", systemImage: "info.circle")
                }
                MediaMenuActions(item: media)
                removeFromContinueWatching
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8)).frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.trailing, 6).padding(.bottom, 1)
                .accessibilityLabel("Options for \(media.name)")
        }
        .task(id: revision) {
            let credentialRevision = store.metadataConfigurationRevision
            let prepared = await HeroPresentation.prepare(record.media, store: store)
            guard !Task.isCancelled, credentialRevision == store.metadataConfigurationRevision else { return }
            presentation = prepared
        }
    }

    private var removeFromContinueWatching: some View {
        Button("Remove from Continue Watching", systemImage: "minus.circle") {
            store.removeFromContinueWatching(media)
        }
    }

    @ViewBuilder private func artworkTitle(_ presentation: HeroPresentation) -> some View {
        if let image = presentation.titleImage {
            image.resizable().scaledToFit().shadow(color: .black.opacity(0.4), radius: 4, y: 2)
        } else {
            Text(media.name).font(.title2.weight(.heavy)).lineLimit(3).minimumScaleFactor(0.7)
                .multilineTextAlignment(.leading).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.65), radius: 6, y: 2)
        }
    }
}
