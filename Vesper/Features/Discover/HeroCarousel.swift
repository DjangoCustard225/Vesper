import SwiftUI
import VesperCore

struct HeroPresentation {
    let media: MediaItem
    let titleImage: Image?
    let metadataRevision: String
}

struct HeroCarousel: View {
    @Environment(AppStore.self) private var store
    let items: [MediaItem]
    @Binding var horizontalOffset: CGFloat
    @State private var selectedID: String?
    @State private var presentations: [String: HeroPresentation] = [:]
    @State private var presentationRevision: UUID?
    private var nearbyArtwork: [URL] {
        guard !items.isEmpty else { return [] }
        let index = items.firstIndex { $0.key == selectedID } ?? 0
        return items[max(0, index - 1)...min(items.count - 1, index + 1)].compactMap {
            ($0.background ?? $0.poster).flatMap { try? AddonURL.http($0) }
        }
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(items, id: \.key) { item in
                    FeaturedCard(item: item, presentation: presentationRevision == store.tmdbRevision ? presentations[item.key] : nil)
                        .containerRelativeFrame(.horizontal).id(item.key)
                }
            }.scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging).scrollPosition(id: $selectedID)
        .scrollIndicators(.hidden).appScrollEdges().frame(height: Design.heroHeight)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.x + geometry.contentInsets.leading
        } action: { _, offset in horizontalOffset = offset }
        .onChange(of: items.map(\.key), initial: true) { _, keys in
            if !keys.contains(selectedID ?? "") { selectedID = keys.first; horizontalOffset = 0 }
        }
        .task(id: items.map(\.key).joined(separator: "|") + store.tmdbRevision.uuidString + store.metadataRevision(for: items.map { store.detailsCacheID($0) })) { await prepareTitles() }
        .task(id: nearbyArtwork) { await ArtworkPipeline.shared.prefetch(nearbyArtwork) }
        .overlay(alignment: .bottom) {
            if items.count > 1 {
                HStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.key) { index, item in
                        Button {
                            withAnimation(.snappy) { selectedID = item.key }
                        } label: {
                            Circle().fill(.white.opacity((selectedID ?? items.first?.key) == item.key ? 1 : 0.35))
                                .frame(width: 5, height: 5).padding(.horizontal, 3).padding(.vertical, 5)
                        }.buttonStyle(.plain)
                            .accessibilityLabel("Page \(index + 1) of \(items.count), \(item.name)")
                            .accessibilityAddTraits((selectedID ?? items.first?.key) == item.key ? .isSelected : [])
                    }
                }.padding(.bottom, 4)
            }
        }
    }

    private func prepareTitles() async {
        let revision = store.tmdbRevision
        if presentationRevision != revision { presentations = [:]; presentationRevision = revision }
        let keys = Set(items.map(\.key))
        presentations = presentations.filter { keys.contains($0.key) }
        let current = items.firstIndex { $0.key == selectedID } ?? 0
        let pending = (Array(items.dropFirst(current)) + Array(items.prefix(current)))
            .filter { presentations[$0.key] == nil || presentations[$0.key]?.metadataRevision != store.metadataRevision(for: [store.detailsCacheID($0)]) }
        // Prepare nearby titles first, with at most three metadata/logo loads at once.
        await withTaskGroup(of: (String, HeroPresentation).self) { group in
            var remaining = pending.makeIterator()
            for _ in 0..<3 {
                if let item = remaining.next() { group.addTask { await prepare(item) } }
            }
            while let (key, presentation) = await group.next() {
                guard !Task.isCancelled, store.tmdbRevision == revision else { group.cancelAll(); return }
                presentations[key] = presentation
                if let item = remaining.next() { group.addTask { await prepare(item) } }
            }
        }
    }

    private func prepare(_ item: MediaItem) async -> (String, HeroPresentation) {
        var media = item
        var image: Image?
        if let details = try? await store.enrichedMetadata(for: item), !Task.isCancelled {
            media = details.applying(to: item)
            if let value = details.titleLogoURL, let url = try? AddonURL.http(value),
               let prepared = try? await ArtworkPipeline.shared.image(for: url), !Task.isCancelled {
                image = Image(uiImage: prepared)
            }
        }
        return (item.key, HeroPresentation(media: media, titleImage: image,
            metadataRevision: store.metadataRevision(for: [store.detailsCacheID(item)])))
    }
}
