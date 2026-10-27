import SwiftUI
import VesperCore

/// Shared artwork and geometry keep Home's playback rows visually consistent.
struct HomePlaybackCard: View {
    @Environment(AppStore.self) private var store
    let item: MediaItem
    let subtitle: String
    var progress: Double? = nil
    @State private var presentation: HeroPresentation?

    private var media: MediaItem { presentation?.media ?? item }

    private var revision: String {
        item.key + store.metadataConfigurationRevision
            + store.metadataRevision(for: [store.detailsCacheID(item)])
    }

    var body: some View {
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
                    if let progress {
                        Capsule().fill(.white.opacity(0.3)).frame(width: 34, height: 5)
                            .overlay(alignment: .leading) {
                                Capsule().fill(.white).frame(width: 34 * min(1, max(0, progress)), height: 5)
                            }
                    }
                    Text(subtitle).font(.subheadline.weight(.medium))
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
            .containerRelativeFrame(.horizontal) { width, _ in
                min(360, max(220, width * 0.615))
            }
            .task(id: revision) {
                let credentialRevision = store.metadataConfigurationRevision
                let prepared = await HeroPresentation.prepare(item, store: store)
                guard !Task.isCancelled, credentialRevision == store.metadataConfigurationRevision else {
                    return
                }
                presentation = prepared
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
