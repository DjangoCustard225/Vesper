import UIKit
import Vision
import VesperCore

/// Provider language tags alone cannot establish whether artwork contains a title.
actor DetailPosterValidator {
    private let cache: ResponseCache
    private var memory: [String: Bool] = [:]
    private let requests = SharedRequestPool<Bool>()
    private var generation = UUID()

    init(cache: ResponseCache) { self.cache = cache }

    func isTextless(_ raw: String) async throws -> Bool {
        let key = "textless-v1:" + raw
        if let result = memory[key] { return result }
        let generation = generation, cache = cache
        let result = try await requests.value(for: key) { [self] in
            if let saved = await cache.value(Bool.self, key: key, ttl: 7 * 24 * 3600), saved.isFresh {
                return saved.value
            }
            let token = await cache.token()
            let url = try AddonURL.http(raw)
            let image = try await ArtworkPipeline.shared.image(for: url)
            try Task.checkCancellation()
            let result = try await inspect(image)
            try Task.checkCancellation()
            await cache.save(result, key: key, token: token)
            return result
        }
        try Task.checkCancellation()
        guard generation == self.generation else { throw CancellationError() }
        if memory.count >= 200 { memory.removeAll() }
        memory[key] = result
        return result
    }

    private func inspect(_ image: UIImage) throws -> Bool {
        guard let image = image.cgImage else { return false }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = 0.012
        try VNImageRequestHandler(cgImage: image).perform([request])
        return !(request.results ?? []).contains { observation in
            guard let text = observation.topCandidates(1).first, text.confidence >= 0.3 else { return false }
            return text.string.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count >= 2
        }
    }

    func clearCache() async throws {
        generation = UUID()
        memory.removeAll()
        await requests.cancelAll()
        try await cache.removeAll()
    }
}
