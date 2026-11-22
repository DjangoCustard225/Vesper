import SwiftUI
import UIKit
import ImageIO
import CoreImage
import VesperCore

/// NSCache supports concurrent lookup; rendering never waits on the pipeline actor.
private final class PreparedArtworkCache: @unchecked Sendable {
    private let images = NSCache<NSString, UIImage>()

    init() {
        images.totalCostLimit = 96 * 1024 * 1024
        images.countLimit = 120
    }

    func image(for key: String) -> UIImage? { images.object(forKey: key as NSString) }

    func insert(_ image: UIImage, for key: String) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        images.setObject(image, forKey: key as NSString, cost: cost)
    }

    func clear() { images.removeAllObjects() }
}

actor ArtworkPipeline {
    static let shared = ArtworkPipeline()
    private nonisolated let client = ArtworkDataClient.shared
    private nonisolated let memory = PreparedArtworkCache()
    private var requests = SharedRequestPool<UIImage>()
    private var generation = UUID()
    private var clearingTask: Task<Void, Never>?
    private let preparation = PriorityRequestLimiter(limit: 2, prefetchLimit: 1)

    private init() {}

    nonisolated private func key(for url: URL, size: ArtworkDecodeSize?) -> String {
        (size?.cacheIdentifier ?? "original") + "|" + url.absoluteString
    }

    nonisolated func cachedImage(for url: URL, size: ArtworkDecodeSize? = nil) -> UIImage? {
        memory.image(for: key(for: url, size: size))
    }

    func clearMemory() async {
        memory.clear()
        await client.clearMemory()
    }

    func clearCache() async {
        if let clearingTask {
            await clearingTask.value
            return
        }
        generation = UUID()
        let previous = requests
        requests = SharedRequestPool()
        memory.clear()
        let task = Task {
            await previous.cancelAll()
            await client.clearCache()
        }
        clearingTask = task
        await task.value
        clearingTask = nil
    }

    func image(
        for url: URL, size: ArtworkDecodeSize? = nil, priority: ArtworkPriority = .visible
    ) async throws -> UIImage {
        await clearingTask?.value
        try Task.checkCancellation()
        let key = key(for: url, size: size)
        if let image = memory.image(for: key) { return image }
        let client = client, preparation = preparation, token = generation
        do {
            return try await requests.value(
                for: key, priority: priority,
                onPromotion: {
                    await client.promote(url)
                    await preparation.promote(key)
                }
            ) { demand in
                let data: Data
                if DownloadFiles.isArtwork(url) {
                    data = try await Task.detached {
                        guard DownloadFiles.size(url) <= 12 * 1024 * 1024 else {
                            throw URLError(.cannotDecodeContentData)
                        }
                        return try Data(contentsOf: url, options: .mappedIfSafe)
                    }.value
                } else {
                    data = try await client.data(for: url, priority: demand.priority)
                }
                try Task.checkCancellation()
                let queued = ArtworkTimer()
                let (image, queueTime, decodeTime) = try await preparation.run(key: key, demand: demand) {
                    let queueTime = queued.milliseconds
                    let decoding = ArtworkTimer()
                    let image: UIImage
                    if let size, let thumbnail = Self.thumbnail(data, size: size) {
                        image = thumbnail
                    } else {
                        guard let original = UIImage(data: data) else {
                            throw URLError(.cannotDecodeContentData)
                        }
                        image = await original.byPreparingForDisplay() ?? original
                    }
                    return (image, queueTime, decoding.milliseconds)
                }
                try Task.checkCancellation()
                try await self.store(image, for: key, token: token)
                await DiagnosticRecorder.shared.recordArtwork(
                    .preparationQueue, milliseconds: queueTime, priority: demand.priority)
                await DiagnosticRecorder.shared.recordArtwork(
                    .preparation, milliseconds: decodeTime, priority: demand.priority)
                return image
            }
        } catch is CancellationError {
            try Task.checkCancellation()
            guard token != generation else { throw CancellationError() }
            return try await image(for: url, size: size, priority: priority)
        }
    }

    private func store(_ image: UIImage, for key: String, token: UUID) throws {
        guard token == generation else { throw CancellationError() }
        memory.insert(image, for: key)
    }

    nonisolated private static func thumbnail(_ data: Data, size: ArtworkDecodeSize) -> UIImage? {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) == 1,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let rotated = (5...8).contains(orientation)
        guard
            let maximum = size.maximumPixelSize(
                sourceWidth: rotated ? height : width, sourceHeight: rotated ? width : height)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map {
            UIImage(cgImage: $0)
        }
    }
}

private struct ArtworkPrefetchModifier: ViewModifier {
    let urls: [URL]
    let size: ArtworkDecodeSize?
    @State private var active = false
    @State private var controller: ArtworkPrefetchController

    init(urls: [URL], size: ArtworkDecodeSize?) {
        self.urls = urls
        self.size = size
        _controller = State(initialValue: Self.makeController(size: size))
    }

    private static func makeController(size: ArtworkDecodeSize?) -> ArtworkPrefetchController {
        ArtworkPrefetchController { url in
            _ = try? await ArtworkPipeline.shared.image(for: url, size: size, priority: .prefetch)
        }
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                active = true
                controller.update(urls)
            }
            .onChange(of: urls) { _, urls in if active { controller.update(urls) } }
            .onChange(of: size) { _, size in
                controller.cancel()
                controller = Self.makeController(size: size)
                if active { controller.update(urls) }
            }
            .onDisappear {
                active = false
                controller.cancel()
            }
    }
}

extension View {
    func prefetchArtwork(_ urls: [URL], size: ArtworkDecodeSize? = nil) -> some View {
        modifier(ArtworkPrefetchModifier(urls: urls, size: size))
    }
}

struct CachedArtworkImage<Content: View>: View {
    let url: URL?
    var decodeSize: ArtworkDecodeSize? = nil
    var fadesIn = false
    var retainsPreviousImage = false
    @ViewBuilder let content: (AsyncImagePhase) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = AsyncImagePhase.empty
    private struct Request: Hashable {
        let url: URL?
        let size: ArtworkDecodeSize?
    }
    private var request: Request { Request(url: url, size: decodeSize) }
    @State private var loadedRequest: Request?

    private var displayedPhase: AsyncImagePhase {
        // Once loading starts, phase owns presentation so a cache insertion cannot skip the fade.
        if loadedRequest == request { return phase }
        if let url, let image = ArtworkPipeline.shared.cachedImage(for: url, size: decodeSize) {
            return .success(Image(uiImage: image))
        }
        if retainsPreviousImage, phase.image != nil { return phase }
        return .empty
    }

    var body: some View {
        ZStack {
            content(displayedPhase)
                .id(displayedPhase.image != nil)
                .transition(fadesIn ? .opacity : .identity)
        }.task(id: request) {
            guard let url else {
                withTransaction(Transaction(animation: nil)) {
                    loadedRequest = nil
                    phase = .empty
                }
                return
            }
            if let image = ArtworkPipeline.shared.cachedImage(for: url, size: decodeSize) {
                withTransaction(Transaction(animation: nil)) {
                    loadedRequest = request
                    phase = .success(Image(uiImage: image))
                }
                return
            }
            withTransaction(Transaction(animation: nil)) {
                loadedRequest = request
                if !retainsPreviousImage || phase.image == nil { phase = .empty }
            }
            do {
                let image = try await ArtworkPipeline.shared.image(for: url, size: decodeSize)
                guard !Task.isCancelled else { return }
                withAnimation(fadesIn && !reduceMotion ? .easeOut(duration: 0.22) : nil) {
                    phase = .success(Image(uiImage: image))
                }
            } catch {
                guard !Task.isCancelled else { return }
                if !retainsPreviousImage || phase.image == nil { phase = .failure(error) }
            }
        }
    }
}

/// A heavily blurred copy of an artwork, rendered once from a tiny thumbnail and cached.
/// A live `.blur` on a full-screen image is re-rendered by the GPU on every scroll frame;
/// this is a plain bitmap, so it moves for free.
struct BlurredArtwork: View {
    let url: URL?
    /// Blur radius as a fraction of the image's width.
    var amount: CGFloat = 0.1
    @State private var image: UIImage?
    @State private var loadedURL: URL?

    var body: some View {
        ZStack {
            if let image, loadedURL == url {
                Image(uiImage: image).resizable().interpolation(.medium).scaledToFill()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            guard let url else { image = nil; loadedURL = nil; return }
            let key = "\(amount)|\(url.absoluteString)" as NSString
            if let cached = BlurredArtworkCache.images.object(forKey: key) {
                image = cached; loadedURL = url
                return
            }
            // The blur starts from a 64-pixel-wide thumbnail, so decoding the full image is wasted work.
            guard
                let source = try? await ArtworkPipeline.shared.image(
                    for: url, size: ArtworkDecodeSize(width: 128, height: 128, scale: 1)),
                !Task.isCancelled
            else {
                return
            }
            let amount = amount
            let blurred = await Task.detached(priority: .userInitiated) {
                BlurredArtworkCache.render(source, amount: amount)
            }.value
            guard !Task.isCancelled, let blurred else { return }
            BlurredArtworkCache.images.setObject(blurred, forKey: key)
            withAnimation(.easeOut(duration: 0.2)) {
                image = blurred; loadedURL = url
            }
        }
    }
}

enum BlurredArtworkCache {
    nonisolated(unsafe) static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 24
        return cache
    }()
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Shrinks to a thumbnail, then blurs it; detail lost by shrinking is invisible under the blur.
    nonisolated static func render(_ source: UIImage, amount: CGFloat) -> UIImage? {
        let width: CGFloat = 64
        guard source.size.width > 0, source.size.height > 0 else { return nil }
        let size = CGSize(width: width, height: (width * source.size.height / source.size.width).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let thumbnail = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let input = thumbnail.cgImage.map(CIImage.init(cgImage:)),
            let filter = CIFilter(name: "CIGaussianBlur")
        else { return nil }
        // Clamp first so the edges stay opaque instead of fading to transparent.
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(width * amount, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent),
            let rendered = context.createCGImage(output, from: input.extent)
        else { return nil }
        return UIImage(cgImage: rendered)
    }
}
