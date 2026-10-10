import SwiftUI
import UIKit
import VesperCore

actor ArtworkPipeline {
    static let shared = ArtworkPipeline()
    private let client = ArtworkDataClient()
    private let memory = NSCache<NSURL, UIImage>()
    private var requests: [URL: Task<UIImage, Error>] = [:]
    private init() {
        memory.totalCostLimit = 96 * 1024 * 1024
        memory.countLimit = 120
    }
    func image(for url: URL) async throws -> UIImage {
        if let image = memory.object(forKey: url as NSURL) { return image }
        if let request = requests[url] { return try await request.value }
        let client = client
        let task = Task<UIImage, Error> {
            let data = try await client.data(for: url)
            guard let original = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
            return await original.byPreparingForDisplay() ?? original
        }
        requests[url] = task
        do {
            let image = try await task.value
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            memory.setObject(image, forKey: url as NSURL, cost: cost)
            requests[url] = nil
            return image
        } catch { requests[url] = nil; throw error }
    }
}

struct CachedArtworkImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (AsyncImagePhase) -> Content
    @State private var phase = AsyncImagePhase.empty
    var body: some View {
        content(phase).task(id: url) {
            phase = .empty
            guard let url else { return }
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
