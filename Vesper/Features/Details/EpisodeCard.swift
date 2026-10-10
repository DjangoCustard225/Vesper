import SwiftUI
import VesperCore

struct EpisodeCard: View {
    @Environment(AppStore.self) private var store
    let media: MediaItem
    let episode: Episode
    let play: () -> Void
    let showDescription: () -> Void
    @ScaledMetric(relativeTo: .body) private var cardWidth = 240.0
    @ScaledMetric(relativeTo: .body) private var cardHeight = 248.0
    private var progress: WatchProgress? { store.progress(for: media, videoID: episode.id) }
    private var playbackLabel: String {
        if let progress, progress.isFinished { return "Watched" }
        if let progress, progress.duration > 0 {
            return "\(max(1, Int(ceil((progress.duration - progress.position) / 60))))m"
        }
        if let runtime = episode.runtimeMinutes { return "\(runtime)m" }
        return "Play"
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Button(action: play) {
                ZStack(alignment: .bottomLeading) {
                    Artwork(url: episode.thumbnail ?? media.background ?? media.poster)
                        .frame(width: cardWidth, height: cardHeight)
                    LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(episode.episode.map { "EPISODE \($0)" } ?? "EPISODE")
                            .font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.7))
                        Text(episode.displayTitle).font(.headline).foregroundStyle(.white).lineLimit(1)
                        Text(episode.overview ?? "")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineSpacing(2)
                            .lineLimit(3, reservesSpace: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 40)
                    .background {
                        Rectangle().fill(.ultraThinMaterial)
                            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.25)], startPoint: .top, endPoint: .bottom))
                            .padding(.top, -24)
                    }
                }.frame(width: cardWidth, height: cardHeight).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("\(episode.label), \(episode.displayTitle)")
                .accessibilityHint("Choose a stream for this episode")
            HStack(spacing: 8) {
                Button(action: play) {
                    HStack(spacing: 5) {
                        Image(systemName: progress?.isFinished == true ? "checkmark" : "play.fill").font(.caption)
                        if let progress, !progress.isFinished, progress.position > 0 {
                            GeometryReader { proxy in
                                Capsule().fill(.white.opacity(0.2))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(.white).frame(width: proxy.size.width * progress.fraction)
                                    }
                            }.frame(width: 30, height: 5).accessibilityHidden(true)
                        }
                        Text(playbackLabel).font(.subheadline.weight(.medium))
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Play \(episode.displayTitle), \(playbackLabel)")
                Spacer(minLength: 4)
                Menu {
                    Button("Play episode", systemImage: "play", action: play)
                    if let overview = episode.overview, !overview.isEmpty {
                        Button("Episode description", systemImage: "text.alignleft", action: showDescription)
                    }
                    if let progress {
                        Button("Remove watch progress", systemImage: "clock.badge.xmark", role: .destructive) { store.removeProgress(progress) }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.body.weight(.bold))
                        .frame(width: 30, height: 26).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Options for \(episode.displayTitle)")
            }.foregroundStyle(.white.opacity(0.7)).padding(.horizontal, 12).padding(.bottom, 8)
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 0.5) }
    }
}
