import SwiftUI
import WidgetKit

struct ContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "continue-watching", provider: ShelfProvider(section: .continueWatching)) {
            PlaybackShelfView(entry: $0, style: .continueWatching).containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Continue Watching")
        .description("Resume where you left off.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryCircular,
            .accessoryRectangular, .accessoryInline,
        ])
        .contentMarginsDisabled()
    }
}

struct UpNextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "up-next", provider: ShelfProvider(section: .upNext)) {
            PlaybackShelfView(entry: $0, style: .upNext).containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Up Next")
        .description("The next episode of the shows you’re watching.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryRectangular,
            .accessoryInline,
        ])
        .contentMarginsDisabled()
    }
}

/// What differs between Continue Watching and Up Next.
struct PlaybackStyle {
    let section: ShelfSection
    let title: String
    let link: WidgetLink.Action
    let symbol: String
    let emptyTitle: String
    let emptyMessage: String

    static let continueWatching = PlaybackStyle(
        section: .continueWatching, title: "Continue Watching", link: .resume, symbol: "play.rectangle",
        emptyTitle: "Nothing in progress", emptyMessage: "Start watching in Vesper.")
    static let upNext = PlaybackStyle(
        section: .upNext, title: "Up Next", link: .play, symbol: "forward.end",
        emptyTitle: "You’re all caught up", emptyMessage: "New episodes of your shows appear here.")
}

struct PlaybackShelfView: View {
    let entry: ShelfEntry
    let style: PlaybackStyle
    @Environment(\.widgetFamily) private var family

    private var items: [WidgetShelf.Item] { style.section.items(in: entry.shelf) }

    var body: some View {
        content.placeholder(entry.isPlaceholder)
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        default:
            if items.isEmpty {
                EmptyShelf(symbol: style.symbol, title: style.emptyTitle, message: style.emptyMessage)
            } else {
                system
            }
        }
    }

    @ViewBuilder private var system: some View {
        switch family {
        case .systemSmall:
            FeaturedCard(entry: entry, item: items[0], style: style)
                .widgetURL(WidgetLink.url(style.link, for: items[0]))
        case .systemMedium:
            HStack(alignment: .top, spacing: 12) {
                ForEach(0..<2, id: \.self) { index in
                    if index < items.count {
                        card(items[index])
                    } else {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }.padding(14)
        case .systemExtraLarge:
            VStack(alignment: .leading, spacing: 12) {
                ShelfHeader(title: style.title)
                Grid(horizontalSpacing: 14, verticalSpacing: 12) {
                    ForEach(0..<2, id: \.self) { row in
                        GridRow(alignment: .top) {
                            ForEach(0..<3, id: \.self) { column in
                                let index = row * 3 + column
                                if index < items.count { card(items[index]) } else { Color.clear }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }.padding(18)
        default:
            VStack(alignment: .leading, spacing: 10) {
                ShelfHeader(title: style.title)
                ForEach(Array(items.prefix(4).enumerated()), id: \.offset) { _, item in
                    PlaybackRow(entry: entry, item: item, style: style)
                }
                Spacer(minLength: 0)
            }.padding(16)
        }
    }

    private func card(_ item: WidgetShelf.Item) -> some View {
        OpenButton(url: WidgetLink.url(style.link, for: item)) {
            PlaybackCard(entry: entry, item: item)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Lock Screen

    @ViewBuilder private var circular: some View {
        if let item = items.first {
            Gauge(value: item.progress ?? 0) {
                Image(systemName: "play.fill")
            } currentValueLabel: {
                Image(systemName: "play.fill")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetURL(WidgetLink.url(style.link, for: item))
            .accessibilityLabel(WidgetFormat.accessibilityLabel(item, now: entry.date))
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: style.symbol).font(.title3)
            }.accessibilityLabel(style.emptyTitle)
        }
    }

    @ViewBuilder private var rectangular: some View {
        if let item = items.first {
            VStack(alignment: .leading, spacing: 1) {
                Text(WidgetFormat.newLabel(item.released, now: entry.date) ?? style.title)
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(item.title).font(.headline).lineLimit(1).widgetAccentable()
                if let label = item.episodeLabel ?? item.subtitle {
                    Text(label).font(.caption).lineLimit(1)
                }
                if let progress = item.progress {
                    ProgressView(value: progress).tint(.primary).padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(WidgetLink.url(style.link, for: item))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(style.title + ", " + WidgetFormat.accessibilityLabel(item, now: entry.date))
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(style.title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(style.emptyTitle).font(.headline).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var inline: some View {
        if let item = items.first {
            Label(
                [item.title, item.episodeLabel].compactMap { $0 }.joined(separator: " · "),
                systemImage: style.link == .resume ? "play.fill" : "forward.end.fill"
            )
            .widgetURL(WidgetLink.url(style.link, for: item))
        } else {
            Label(style.emptyTitle, systemImage: style.symbol)
        }
    }
}

/// Small widget: artwork fills the widget, title over a gradient.
private struct FeaturedCard: View {
    let entry: ShelfEntry
    let item: WidgetShelf.Item
    let style: PlaybackStyle

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Artwork(image: entry.image(item.backdropImage), fallback: nil)
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 3) {
                if let new = WidgetFormat.newLabel(item.released, now: entry.date) { Badge(text: new) }
                Spacer(minLength: 0)
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(item.subtitle ?? " ").font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                ProgressLine(value: item.progress).padding(.top, 4)
            }
            .foregroundStyle(.white).padding(12)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WidgetFormat.accessibilityLabel(item, now: entry.date))
        .accessibilityHint(style.link == .resume ? "Resumes playback" : "Plays the episode")
    }
}

/// Medium and extra large widgets: artwork with progress, then two lines of text.
private struct PlaybackCard: View {
    let entry: ShelfEntry
    let item: WidgetShelf.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Artwork(image: entry.image(item.backdropImage), fallback: item.title)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .bottom) { ProgressLine(value: item.progress).padding(6) }
                .overlay(alignment: .topLeading) {
                    if let new = WidgetFormat.newLabel(item.released, now: entry.date) {
                        Badge(text: new).padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(item.title).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                .padding(.top, 7)
            // Always reserve the second line so neighbouring cards line up.
            Text(item.subtitle ?? " ").font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                .padding(.top, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WidgetFormat.accessibilityLabel(item, now: entry.date))
    }
}

/// Large widget: one row per title.
private struct PlaybackRow: View {
    let entry: ShelfEntry
    let item: WidgetShelf.Item
    let style: PlaybackStyle

    var body: some View {
        OpenButton(url: WidgetLink.url(style.link, for: item)) {
            HStack(spacing: 12) {
                Artwork(image: entry.image(item.backdropImage), fallback: item.title)
                    .frame(width: 96, height: 54)
                    .overlay(alignment: .bottom) { ProgressLine(value: item.progress).padding(5) }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if WidgetFormat.newLabel(item.released, now: entry.date) != nil {
                            Badge(text: "New")
                        }
                        if let subtitle = item.subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(WidgetFormat.accessibilityLabel(item, now: entry.date))
        }
    }
}
