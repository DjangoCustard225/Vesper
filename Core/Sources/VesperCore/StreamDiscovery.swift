import Foundation

/// Discovers independent add-on sources concurrently while retaining provider order in every update.
public struct StreamDiscovery: Sendable {
    private struct ProviderResult: Sendable {
        let options: [StreamOption]
        let failure: String?
    }

    private let client: AddonClient

    public init(client: AddonClient) { self.client = client }

    @MainActor
    public func load(
        addons: [InstalledAddon], type: String, videoID: String, embedded: [StreamSource]? = nil,
        onUpdate: (@MainActor (StreamResults) -> Void)? = nil
    ) async -> StreamResults {
        if let embedded {
            return StreamResults(
                options: embedded.map {
                    StreamOption(addonName: "Included source", source: $0)
                }
            ).playable()
        }
        let providers = addons.filter {
            $0.isEnabled && $0.manifest.supports("stream", type: type, id: videoID)
        }
        var results = [ProviderResult?](repeating: nil, count: providers.count)
        await ConcurrentWork.run(
            providers,
            operation: { [client] addon in
                do {
                    let sources = try await client.streams(addon, type: type, videoID: videoID)
                    return ProviderResult(
                        options: sources.map {
                            StreamOption(addonName: addon.manifest.name, source: $0, provider: addon)
                        }, failure: nil)
                } catch is CancellationError {
                    return ProviderResult(options: [], failure: nil)
                } catch {
                    return ProviderResult(
                        options: [], failure: addon.manifest.name + ": " + error.localizedDescription)
                }
            }
        ) { index, response in
            results[index] = response
            onUpdate?(Self.combined(results))
        }
        return Self.combined(results)
    }

    private static func combined(_ results: [ProviderResult?]) -> StreamResults {
        let completed = results.compactMap { $0 }
        return StreamResults(options: completed.flatMap(\.options), failures: completed.compactMap(\.failure))
            .playable()
    }
}
