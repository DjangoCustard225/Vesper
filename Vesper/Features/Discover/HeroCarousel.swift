import SwiftUI
import UIKit
import VesperCore

struct HeroPresentation {
    let media: MediaItem
    let titleImage: Image?
    let metadataRevision: String

    @MainActor static func prepare(_ item: MediaItem, store: AppStore) async -> HeroPresentation {
        var media = item
        var image: Image?
        if let details = try? await store.enrichedMetadata(for: item), !Task.isCancelled {
            media = details.applying(to: item)
            if let value = details.titleLogoURL, let url = try? AddonURL.http(value),
                let prepared = try? await ArtworkPipeline.shared.image(for: url), !Task.isCancelled
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
    @Binding var artworkSources: [String: ImmersiveArtworkSource]
    @State private var selectedID: String?
    @State private var presentations: [String: HeroPresentation] = [:]
    @State private var presentationRevision: String?

    private var nearbyArtwork: [URL] {
        guard !items.isEmpty else { return [] }
        let index = items.firstIndex { $0.key == selectedID } ?? 0
        return items[max(0, index - 1)...min(items.count - 1, index + 1)].compactMap {
            (artworkSources[$0.key]?.preferred ?? $0.background ?? $0.poster).flatMap {
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
            id: items.map(\.key).joined(separator: "|") + store.metadataConfigurationRevision
                + store.metadataRevision(for: items.map { store.detailsCacheID($0) })
        ) { await prepareTitles() }
        .prefetchArtwork(nearbyArtwork)
        .overlay(alignment: .bottom) {
            if items.count > 1 {
                HeroPageControl(
                    titles: items.map(\.name),
                    selection: Binding(
                        get: { items.firstIndex { $0.key == selectedID } ?? 0 },
                        set: { index in
                            guard items.indices.contains(index) else { return }
                            withAnimation(reduceMotion ? nil : .snappy) { selectedID = items[index].key }
                        })
                )
                .frame(height: Design.minimumHitTarget).padding(.horizontal, 20).padding(.bottom, 4)
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
                artworkSources[key] = ImmersiveArtworkSource(
                    backdrop: presentation.media.background,
                    poster: presentation.media.poster)
                if let item = remaining.next() { group.addTask { await prepare(item) } }
            }
        }
    }

    private func prepare(_ item: MediaItem) async -> (String, HeroPresentation) {
        (item.key, await HeroPresentation.prepare(item, store: store))
    }
}

/// A single native adjustable control keeps dense dots usable without overlapping hit areas.
private struct HeroPageControl: UIViewRepresentable {
    let titles: [String]
    @Binding var selection: Int

    func makeUIView(context: Context) -> UIPageControl {
        let control = UIPageControl()
        control.pageIndicatorTintColor = .white.withAlphaComponent(0.35)
        control.currentPageIndicatorTintColor = .white
        control.backgroundStyle = .minimal
        control.allowsContinuousInteraction = true
        control.hidesForSinglePage = true
        control.accessibilityLabel = "Featured titles"
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UIPageControl, context: Context) {
        context.coordinator.selection = $selection
        if control.numberOfPages != titles.count { control.numberOfPages = titles.count }
        let page = min(max(0, selection), max(0, titles.count - 1))
        if control.currentPage != page { control.currentPage = page }
        control.isEnabled = context.environment.isEnabled && titles.count > 1
        let title = titles.indices.contains(control.currentPage) ? titles[control.currentPage] : ""
        control.accessibilityValue = "Page \(control.currentPage + 1) of \(titles.count), \(title)"
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIPageControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: Design.minimumHitTarget)
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    @MainActor final class Coordinator: NSObject {
        var selection: Binding<Int>

        init(selection: Binding<Int>) { self.selection = selection }

        @objc func changed(_ control: UIPageControl) { selection.wrappedValue = control.currentPage }
    }
}
