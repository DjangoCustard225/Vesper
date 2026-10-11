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
    func prefetch(_ urls: [URL]) async {
        var seen = Set<URL>()
        let unique = urls.filter { seen.insert($0).inserted }
        await ConcurrentWork.run(unique, limit: 2, operation: { url in
            _ = try? await self.image(for: url, priority: .prefetch)
        }, onResult: { _, _ in })
    }
}

struct CachedArtworkImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (AsyncImagePhase) -> Content
    @State private var phase = AsyncImagePhase.empty
    @State private var loadedURL: URL?
    private var displayedPhase: AsyncImagePhase {
        if let url, let image = ArtworkPipeline.shared.cachedImage(for: url) { return .success(Image(uiImage: image)) }
        return loadedURL == url ? phase : .empty
    }
    var body: some View {
        content(displayedPhase).task(id: url) {
            loadedURL = url
            guard let url else { phase = .empty; return }
            if let image = ArtworkPipeline.shared.cachedImage(for: url) {
                phase = .success(Image(uiImage: image)); return
            }
            phase = .empty
            do {
                let image = try await ArtworkPipeline.shared.image(for: url)
                guard !Task.isCancelled else { return }
                phase = .success(Image(uiImage: image))
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failure(error)
            }
        }
    }
}
