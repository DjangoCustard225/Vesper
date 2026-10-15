import SwiftUI
import VesperCore

struct PosterTitle: View {
    let name: String
    let logoURL: String?
    var preparedImage: Image? = nil
    var isLoading = false
    var compact = false
    var alignment: Alignment = .center

    var body: some View {
        Group {
            if let preparedImage {
                titleImage(preparedImage)
            } else if isLoading {
                Color.clear.frame(height: compact ? 90 : 125)
            } else {
                CachedArtworkImage(url: logoURL.flatMap { try? AddonURL.http($0) }) { phase in
                    if let image = phase.image { titleImage(image) } else { fallbackTitle }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityAddTraits(.isHeader)
    }

    private func titleImage(_ image: Image) -> some View {
        image.resizable().scaledToFit().frame(
            maxWidth: compact ? 300 : 340, maxHeight: compact ? 90 : 125, alignment: alignment
        )
        .shadow(color: .black.opacity(0.65), radius: 12, y: 4)
    }

    private var fallbackTitle: some View {
        Text(name)
            .font(.system(compact ? .title : .largeTitle, design: .default, weight: .heavy))
            .tracking(-0.8).multilineTextAlignment(compact ? .leading : .center).lineLimit(compact ? 2 : 3)
            .minimumScaleFactor(0.7)
            .foregroundStyle(.white).shadow(color: .black.opacity(0.65), radius: 12, y: 4)
            .frame(maxWidth: 480)
    }
}
