import SwiftUI
import UIKit
import VesperCore

struct HeroPresentation {
    let media: MediaItem
    let titleImage: Image?
    let metadataRevision: String

    @MainActor static func prepare(
        _ item: MediaItem, store: AppStore, priority: ArtworkPriority = .visible
    ) async -> HeroPresentation {
        var media = item
        var image: Image?
        if let details = try? await store.enrichedMetadata(for: item), !Task.isCancelled {
            media = details.applying(to: item)
            media.poster = item.poster
            media.background = item.background
            if let value = details.titleLogoURL, let url = try? AddonURL.http(value),
                let prepared = try? await ArtworkPipeline.shared.image(for: url, priority: priority),
                !Task.isCancelled
            {
                image = Image(uiImage: prepared)
            }
        }
        return HeroPresentation(
            media: media, titleImage: image,
            metadataRevision: store.metadataRevision(for: [store.detailsCacheID(item)]))
    }
}

struct HeroCarousel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let items: [MediaItem]
    let height: CGFloat
    let isLandscape: Bool
    @Binding var horizontalPage: CGFloat
    @State private var selectedID: String?
    @State private var presentations: [String: HeroPresentation] = [:]
    @State private var presentationRevision: String?

    private var nearbyArtwork: [URL] {
        guard !items.isEmpty else { return [] }
        let index = items.firstIndex { $0.key == selectedID } ?? 0
        return items[max(0, index - 1)...min(items.count - 1, index + 1)].compactMap {
            ($0.type == "series" ? ($0.poster ?? $0.background) : ($0.background ?? $0.poster)).flatMap {
                try? AddonURL.http($0)
            }
        }
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(items, id: \.key) { item in
                    FeaturedCard(
                        item: item,
                        presentation: presentationRevision == store.metadataConfigurationRevision
                            ? presentations[item.key] : nil,
                        height: height, isLandscape: isLandscape, showsPageControl: items.count > 1
                    )
                    .containerRelativeFrame(.horizontal).id(item.key)
                }
            }.scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging).scrollPosition(id: $selectedID)
        .scrollIndicators(.hidden).appScrollEdges().frame(height: height)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            (geometry.contentOffset.x + geometry.contentInsets.leading) / max(geometry.containerSize.width, 1)
        } action: { _, page in
            horizontalPage = page
        }
        .onChange(of: items.map(\.key), initial: true) { _, keys in
            if !keys.contains(selectedID ?? "") {
                selectedID = keys.first
                horizontalPage = 0
            }
        }
        .task(
            id: (selectedID ?? "") + "|" + items.map(\.key).joined(separator: "|")
                + store.metadataConfigurationRevision
                + store.metadataRevision(for: items.map { store.detailsCacheID($0) })
        ) { await prepareTitles() }
        .prefetchArtwork(nearbyArtwork)
        .overlay(alignment: .bottom) {
            if items.count > 1 {
                HStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.key) { index, item in
                        Button {
                            withAnimation(reduceMotion ? nil : .snappy) { selectedID = item.key }
                        } label: {
                            Circle()
                                .fill(.white.opacity((selectedID ?? items.first?.key) == item.key ? 1 : 0.35))
                                .frame(width: 5, height: 5).padding(.horizontal, 3).padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Page \(index + 1) of \(items.count), \(item.name)")
                        .accessibilityAddTraits(
                            (selectedID ?? items.first?.key) == item.key ? .isSelected : [])
                    }
                }.padding(.bottom, 4)
            }
        }
    }

    private func prepareTitles() async {
        let revision = store.metadataConfigurationRevision
        if presentationRevision != revision {
            presentations = [:]
            presentationRevision = revision
        }
        let keys = Set(items.map(\.key))
        presentations = presentations.filter { keys.contains($0.key) }
        let current = items.firstIndex { $0.key == selectedID } ?? 0
        let pending = (Array(items.dropFirst(current)) + Array(items.prefix(current)))
            .filter {
                presentations[$0.key] == nil
                    || presentations[$0.key]?.metadataRevision
                        != store.metadataRevision(for: [store.detailsCacheID($0)])
            }
        // Prepare nearby titles first, with at most three metadata/logo loads at once.
        await withTaskGroup(of: (String, HeroPresentation).self) { group in
            var remaining = pending.makeIterator()
            for _ in 0..<3 {
                if let item = remaining.next() { group.addTask { await prepare(item) } }
            }
            while let (key, presentation) = await group.next() {
                guard !Task.isCancelled, store.metadataConfigurationRevision == revision else {
                    group.cancelAll()
                    return
                }
                presentations[key] = presentation
                if let item = remaining.next() { group.addTask { await prepare(item) } }
            }
        }
    }

    private func prepare(_ item: MediaItem) async -> (String, HeroPresentation) {
        let priority: ArtworkPriority = item.key == (selectedID ?? items.first?.key) ? .visible : .prefetch
        return (item.key, await HeroPresentation.prepare(item, store: store, priority: priority))
    }
}
