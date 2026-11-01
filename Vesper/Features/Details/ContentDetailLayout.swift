import SwiftUI
import VesperCore

/// The same detail composition for online metadata and saved offline snapshots.
struct ContentDetailLayout<Actions: View, Content: View>: View {
    @Environment(AppStore.self) private var store
    let media: MediaItem
    let logoURL: String?
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content
    @State private var summaryHeight: CGFloat = 140
    @State private var showingAbout = false
    @State private var resolvedArtwork = DetailArtwork()
    @State private var resolvedContext: String?
    private var artworkContext: String {
        MediaIdentity.aliases(media).sorted().joined(separator: "|")
            + store.metadataConfigurationRevision
            + store.metadataRevision(for: [store.detailsCacheID(media)])
            + String(store.downloads.networkAvailable)
    }

    var body: some View {
        GeometryReader { viewport in
            let landscape = viewport.size.width > viewport.size.height
            let artwork =
                store.downloads.networkAvailable
                ? (resolvedContext == artworkContext ? resolvedArtwork : DetailArtwork())
                : store.downloads.offlineDetailArtwork(for: media)
            let pending =
                resolvedContext != artworkContext && store.hasMetadata(for: media)
                && store.downloads.networkAvailable
            let tall = artwork.textlessPosterURL != nil || artwork.backdropURL != nil || pending
            let height =
                landscape
                ? Design.landscapeDetailHeight(for: viewport.size.height)
                : (tall
                    ? min(620, max(400, viewport.size.width * 1.25))
                    : min(420, max(280, viewport.size.width * 0.72)))
            ImmersiveScrollView(
                artwork: ImmersiveArtworkSource(
                    backdrop: artwork.backdropURL, poster: artwork.textlessPosterURL),
                headerHeight: (artwork.textlessPosterURL == nil && artwork.backdropURL == nil)
                    ? 0 : (landscape ? height : height + 16 + summaryHeight + 48),
                isLandscape: landscape, usesPortraitPoster: !landscape
            ) {
                VStack(alignment: .leading, spacing: landscape ? 24 : 16) {
                    ZStack(alignment: landscape ? .bottomLeading : .bottom) {
                        Color.clear
                        VStack(alignment: landscape ? .leading : .center, spacing: landscape ? 8 : 16) {
                            PosterTitle(
                                name: media.name, logoURL: logoURL, compact: landscape,
                                alignment: landscape ? .leading : .center)
                            if landscape { actions }
                        }
                        .frame(
                            maxWidth: landscape ? 380 : .infinity, alignment: landscape ? .leading : .center
                        )
                        .padding(.horizontal, landscape ? 40 : 24).padding(.bottom, 20)
                    }.frame(height: height)
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: landscape ? 24 : 16) {
                            if !landscape { actions }
                            if let description = media.description, !description.isEmpty {
                                Button {
                                    showingAbout = true
                                } label: {
                                    Text(description).font(.body).foregroundStyle(.secondary).lineSpacing(4)
                                        .lineLimit(2).truncationMode(.tail).multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(
                                            Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel("About. \(description)")
                                    .accessibilityHint("Opens the full description")
                                    .frame(maxWidth: 650, alignment: .leading)
                            }
                        }.onGeometryChange(for: CGFloat.self) {
                            $0.size.height
                        } action: {
                            summaryHeight = $0
                        }
                        content
                    }.padding(.horizontal, 24).padding(.bottom, 32).frame(maxWidth: 1000)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity)
            }
        }.ignoresSafeArea(.container, edges: .top).appBackground().navigationBarTitleDisplayMode(.inline)
            .fontDesign(.default).toolbar(.visible, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .task(id: artworkContext) {
                let request = artworkContext
                let artwork = (try? await store.detailArtwork(for: media)) ?? DetailArtwork()
                guard !Task.isCancelled, request == artworkContext else { return }
                resolvedArtwork = artwork; resolvedContext = request
            }
            .sheet(isPresented: $showingAbout) {
                AboutDescriptionView(title: media.name, description: media.description ?? "")
                    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
    }
}

struct EpisodeSeasonPicker: View {
    let seasons: [Int]
    @Binding var season: Int?
    var body: some View {
        Menu {
            Picker("Season", selection: $season) {
                ForEach(seasons, id: \.self) { Text($0 == 0 ? "Specials" : "Season \($0)").tag(Optional($0)) }
            }
        } label: {
            HStack(spacing: 7) {
                Text(season.map { $0 == 0 ? "Specials" : "Season \($0)" } ?? "Season")
                    .font(.title2.bold()).foregroundStyle(.primary)
                Image(systemName: "chevron.up.chevron.down").font(.title3.weight(.bold)).foregroundStyle(
                    .gray)
            }.padding(.vertical, 3).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityHint("Choose a season")
    }
}
