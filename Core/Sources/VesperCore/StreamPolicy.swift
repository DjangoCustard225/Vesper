import Foundation

public enum StreamPolicy {
    public static func freshSource(
        _ source: StreamSource, fetchedAt: Date,
        isolation: isolated (any Actor)? = #isolation,
        fetch: () async throws -> [StreamSource]
    ) async throws -> StreamSource {
        guard needsRefresh(source, fetchedAt: fetchedAt) else { return source }
        let sources = try await fetch()
        try Task.checkCancellation()
        guard let fresh = refreshedMatch(for: source, in: sources), isPlayable(fresh),
            !needsRefresh(fresh, fetchedAt: Date())
        else { throw PlaybackError.sourceChanged }
        return fresh
    }

    public static func identity(_ source: StreamSource) -> String {
        struct Identity: Encodable {
            let url: String?
            let external: String?
            let youtube: String?
            let hash: String?
            let file: Int?
            let request: [String: String]
            let response: [String: String]
        }
        let identity = Identity(
            url: source.url, external: source.externalUrl, youtube: source.ytId,
            hash: source.infoHash?.lowercased(), file: source.infoHash == nil ? nil : source.fileIdx ?? -1,
            request: source.behaviorHints?.proxyHeaders?.request ?? [:],
            response: source.behaviorHints?.proxyHeaders?.response ?? [:])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return ResponseCache.fingerprint(
            String(data: (try? encoder.encode(identity)) ?? Data(), encoding: .utf8) ?? "")
    }

    public static func unique(_ sources: [StreamSource]) -> [StreamSource] {
        var seen = Set<String>()
        return sources.filter { seen.insert(identity($0)).inserted }
    }

    public static func isPlayable(_ source: StreamSource) -> Bool {
        (try? StreamResolver.resolve(source)) != nil
    }

    public static func needsRefresh(_ source: StreamSource, fetchedAt: Date, now: Date = Date()) -> Bool {
        if now.timeIntervalSince(fetchedAt) >= 90 { return true }
        guard let raw = source.url ?? source.externalUrl, let components = URLComponents(string: raw) else {
            return false
        }
        for item in components.queryItems ?? [] where ["exp", "expires"].contains(item.name.lowercased()) {
            if let value = item.value, let seconds = Double(value), seconds.isFinite, seconds > 1_000_000_000,
                seconds <= now.timeIntervalSince1970 + 15
            {
                return true
            }
        }
        for prefix in ["x-amz-", "x-goog-"] {
            let values = components.queryItems ?? []
            if let stamp = values.first(where: { $0.name.lowercased() == prefix + "date" })?.value,
                let duration = values.first(where: { $0.name.lowercased() == prefix + "expires" })?.value,
                let seconds = Double(duration), seconds.isFinite, seconds >= 0
            {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")

                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
                if let date = formatter.date(from: stamp),
                    date.addingTimeInterval(seconds) <= now.addingTimeInterval(15)
                {
                    return true
                }
            }
        }
        return false
    }

    public static func refreshedMatch(for old: StreamSource, in sources: [StreamSource]) -> StreamSource? {
        let oldIdentity = identity(old)
        if let exact = sources.first(where: { identity($0) == oldIdentity }) { return exact }
        guard let oldURL = old.url ?? old.externalUrl, let key = stableURL(oldURL) else { return nil }
        let matches = sources.filter { candidate in
            guard let raw = candidate.url ?? candidate.externalUrl, stableURL(raw) == key,
                (candidate.url != nil) == (old.url != nil), candidate.name == old.name,
                candidate.behaviorHints?.filename == old.behaviorHints?.filename,
                candidate.behaviorHints?.videoHash == old.behaviorHints?.videoHash,
                candidate.behaviorHints?.videoSize == old.behaviorHints?.videoSize
            else { return false }
            return true
        }
        // Ambiguous results require the user to choose again; never substitute another file.
        return matches.count == 1 ? matches.first : nil
    }

    private static func stableURL(_ raw: String) -> String? {
        guard let url = try? AddonURL.http(raw),
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            ["https", "http"].contains(components.scheme ?? "")
        else { return nil }
        let expiring: Set<String> = [
            "token", "expires", "exp", "signature", "sig", "policy", "key-pair-id", "auth", "authorization",
            "hdnea", "hdnts", "jwt",
        ]
        components.queryItems = components.queryItems?.filter {
            !expiring.contains($0.name.lowercased()) && !$0.name.lowercased().hasPrefix("x-amz-")
                && !$0.name.lowercased().hasPrefix("x-goog-")
        }.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        components.fragment = nil
        return components.string
    }
}

public enum PlaybackError: LocalizedError {
    case sourceChanged

    public var errorDescription: String? {
        "This source has changed or expired. Refresh the list and choose a source again."
    }
}
