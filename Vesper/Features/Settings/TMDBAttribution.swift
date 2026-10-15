import SwiftUI

struct TMDBAttribution: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Link(destination: URL(string: "https://www.themoviedb.org")!) {
                HStack(spacing: 10) {
                    // Unmodified approved TMDB logo, raster preview of the original vector.
                    CachedArtworkImage(
                        url: URL(
                            string:
                                "https://thumb.wikimedia.org/wikipedia/commons/thumb/8/89/Tmdb.new.logo.svg/330px-Tmdb.new.logo.svg.png"
                        )
                    ) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit()
                        } else {
                            Text("TMDB").font(.caption.bold())
                        }
                    }.frame(width: 56, height: 41).accessibilityHidden(true)
                    Text("The Movie Database (TMDB)").font(.caption.weight(.semibold))
                }
            }
            Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                .font(.caption2).foregroundStyle(.secondary)
            Link(
                "Logo: Travis Bell · CC BY-SA 4.0",
                destination: URL(string: "https://commons.wikimedia.org/wiki/File:Tmdb.new.logo.svg")!
            )
            .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
