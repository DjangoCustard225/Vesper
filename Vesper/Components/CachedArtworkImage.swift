import SwiftUI
import UIKit
import VesperCore

/// NSCache supports concurrent lookup; rendering never waits on the pipeline actor.
private final class PreparedArtworkCache: @unchecked Sendable {
    private let images = NSCache<NSURL, UIImage>()
    init() { images.totalCostLimit = 96 * 1024 * 1024; images.countLimit = 120 }
    func image(for url: URL) -> UIImage? { images.object(forKey: url as NSURL) }
    func insert(_ image: UIImage, for url: URL) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        images.setObject(image, forKey: url as NSURL, cost: cost)
    }
    func clear() { images.removeAllObjects() }
}

actor ArtworkPipeline {
    static let shared = ArtworkPipeline()
    private nonisolated let client = ArtworkDataClient()
    private nonisolated let memory = PreparedArtworkCache()
    private let requests = SharedRequestPool<UIImage>()
    private let preparation = PriorityRequestLimiter(limit: 2, prefetchLimit: 1)
    private init() {}
    nonisolated func cachedImage(for url: URL) -> UIImage? { memory.image(for: url) }
    func clearMemory() async { memory.clear(); await client.clearMemory() }

    func image(for url: URL, priority: ArtworkPriority = .visible) async throws -> UIImage {
        try Task.checkCancellation()
        if let image = memory.image(for: url) { return image }
        let client = client, memory = memory, preparation = preparation
        return try await requests.value(for: url.absoluteString, priority: priority, onPromotion: {
            await client.promote(url)
            await preparation.promote(url.absoluteString)
        }) { demand in
            let data = try await client.data(for: url, priority: demand.priority)
            try Task.checkCancellation()
            let image = try await preparation.run(key: url.absoluteString, demand: demand) {
                guard let original = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
                return await original.byPreparingForDisplay() ?? original
            }
            try Task.checkCancellation()
            memory.insert(image, for: url)
            return image
        }
    }
}

private struct ArtworkPrefetchModifier: ViewModifier {
    let urls: [URL]
    @State private var active = false
    @State private var controller = ArtworkPrefetchController { url in
        _ = try? await ArtworkPipeline.shared.image(for: url, priority: .prefetch)
    }
    func body(content: Content) -> some View {
        content
            .onAppear { active = true; controller.update(urls) }
            .onChange(of: urls) { _, urls in if active { controller.update(urls) } }
            .onDisappear { active = false; controller.cancel() }
    }
}

extension View {
    func prefetchArtwork(_ urls: [URL]) -> some View { modifier(ArtworkPrefetchModifier(urls: urls)) }
}

struct CachedArtworkImage<Content: View>: View {
    let url: URL?
    var fadesIn = false
    @ViewBuilder let content: (AsyncImagePhase) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = AsyncImagePhase.empty
    @State private var loadedURL: URL?
    private var displayedPhase: AsyncImagePhase {
        // Once loading starts, phase owns presentation so a cache insertion cannot skip the fade.
        if loadedURL == url { return phase }
        if let url, let image = ArtworkPipeline.shared.cachedImage(for: url) { return .success(Image(uiImage: image)) }
        return .empty
    }
    var body: some View {
        ZStack {
            content(displayedPhase)
                .id(displayedPhase.image != nil)
                .transition(fadesIn ? .opacity : .identity)
        }.task(id: url) {
            guard let url else {
                withTransaction(Transaction(animation: nil)) { loadedURL = nil; phase = .empty }
                return
            }
            if let image = ArtworkPipeline.shared.cachedImage(for: url) {
                withTransaction(Transaction(animation: nil)) {
                    loadedURL = url; phase = .success(Image(uiImage: image))
                }
                return
            }
            withTransaction(Transaction(animation: nil)) {
                loadedURL = url; phase = .empty
            }
            do {
                let image = try await ArtworkPipeline.shared.image(for: url)
                guard !Task.isCancelled else { return }
                withAnimation(fadesIn && !reduceMotion ? .easeOut(duration: 0.22) : nil) {
                    phase = .success(Image(uiImage: image))
                }
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failure(error)
            }
        }
    }
}
