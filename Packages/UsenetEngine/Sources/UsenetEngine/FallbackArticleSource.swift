import Foundation

/// Tries providers in configured order without turning missing articles into playable bytes.
public actor FallbackArticleSource: ArticleSource {
    private let sources: [any ArticleSource]
    private var stopped = false

    public init(providers: [UsenetProvider]) throws {
        guard !providers.isEmpty else { throw UsenetError.providerRequired }
        sources = try providers.map { try NNTPPool(provider: $0) }
    }

    init(sources: [any ArticleSource]) { self.sources = sources }

    public func article(_ messageID: String, priority: ArticlePriority) async throws -> [Data] {
        try await fetch { try await $0.article(messageID, priority: priority) }
    }

    public func decodedArticle(_ messageID: String, priority: ArticlePriority) async throws
        -> YEncDecodedSegment
    {
        try await fetch { try await $0.decodedArticle(messageID, priority: priority) }
    }

    private func fetch<Value: Sendable>(
        _ operation: @Sendable (any ArticleSource) async throws -> Value
    ) async throws -> Value {
        var lastError = UsenetError.missingArticle
        for source in sources {
            try Task.checkCancellation()
            guard !stopped else { throw UsenetError.cancelled }
            do {
                let value = try await operation(source)
                try Task.checkCancellation()
                guard !stopped else { throw UsenetError.cancelled }
                return value
            } catch let error as UsenetError
                where
                [.missingArticle, .connection, .timeout, .authentication, .corrupt].contains(error)
            {
                lastError = error
            }
        }
        throw lastError
    }

    public func promote(_ messageID: String) async {
        guard !stopped else { return }
        for source in sources { await source.promote(messageID) }
    }

    /// The primary provider's connection limit, after any automatic reduction.
    public var connectionLimit: Int {
        get async { await (sources.first as? NNTPPool)?.connectionLimit ?? 0 }
    }
    /// Backups are only used on failure, so only the primary provider is warmed.
    public func warm(_ connections: Int) async {
        guard !stopped else { return }
        await sources.first?.warm(connections)
    }

    public func stop() async {
        stopped = true
        for source in sources { await source.stop() }
    }
}
