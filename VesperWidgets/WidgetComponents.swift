import SwiftUI
import WidgetKit

/// Artwork from the shared container, or a titled tile when it hasn't downloaded.
struct Artwork: View {
    let image: UIImage?
    var fallback: String? = nil

    var body: some View {
        picture.contentShape(Rectangle())
    }

    @ViewBuilder private var picture: some View {
        if let image {
            // An opaque base under the picture. Over a clear base, taps on the picture missed the
            // enclosing Link and only launched Vesper; the solid fallback tile never had that problem.
            Color(white: 0.16).overlay {
                // Keeps the real picture when the Home Screen uses tinted or clear icons. The accented
                // modes redraw it in the accent colour, which turns posters white in clear mode.
                Image(uiImage: image).resizable().widgetAccentedRenderingMode(.fullColor)
                    .scaledToFill()
            }
            // Links ignore taps on a bare image, so a near-invisible solid layer makes it tappable. It
            // is only here: over text, Clear mode drew it as a lighter band behind each entry.
            .overlay { Rectangle().fill(Color.black.opacity(0.01)) }
            .clipped()
        } else {
            ZStack {
                Color(white: 0.16)
                if let fallback {
                    Text(fallback).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center).lineLimit(3).padding(6)
                }
            }
        }
    }
}

/// Opens Vesper at `url` when its content is tapped. A `Button(intent: OpenURLIntent)` did nothing at
/// all on device, so this is a `Link`; `Artwork` makes posters tappable.
struct OpenButton<Label: View>: View {
    let url: URL
    @ViewBuilder let label: Label

    var body: some View {
        Link(destination: url) {
            label
        }
    }
}

struct ProgressLine: View {
    let value: Double?

    var body: some View {
        if let value {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3))
                    Capsule().fill(.white).frame(width: geometry.size.width * max(0.04, min(1, value)))
                        .widgetAccentable()
                }
            }.frame(height: 3)
        }
    }
}

/// A small capsule such as "New · Today".
struct Badge: View {
    let text: String

    var body: some View {
        Text(text).font(.caption2.weight(.bold)).foregroundStyle(.black)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.white, in: Capsule())
            .widgetAccentable()
    }
}

struct EmptyShelf: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.white.opacity(0.6))
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            Text(message).font(.caption).foregroundStyle(.white.opacity(0.6))
        }
        .multilineTextAlignment(.center).padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ShelfHeader: View {
    let title: String

    var body: some View {
        Text(title).font(.headline).foregroundStyle(.white).lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// Redacts sample content so it reads as loading rather than real titles.
    func placeholder(_ isPlaceholder: Bool) -> some View {
        redacted(reason: isPlaceholder ? .placeholder : [])
    }
}
