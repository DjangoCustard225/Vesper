import Foundation
import VesperCore

/// All persisted references are relative to this sandbox, including after app updates.
enum DownloadFiles {
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Vesper/Downloads", isDirectory: true)
    static let media = root.appendingPathComponent("Media", isDirectory: true)
    static let artwork = root.appendingPathComponent("Artwork", isDirectory: true)
    static let httpJobs = root.appendingPathComponent("HTTPJobs", isDirectory: true)
    static func httpDirectory(_ id: UUID) -> URL {
        httpJobs.appendingPathComponent(id.uuidString, isDirectory: true)
    }
    static let incoming = root.appendingPathComponent("Incoming", isDirectory: true)

    static func stagingURL(_ key: DownloadTaskKey) -> URL {
        incoming.appendingPathComponent(key.id.uuidString + "-" + key.attempt.uuidString)
    }

    static func protect(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    static func isArtwork(_ url: URL) -> Bool {
        url.isFileURL
            && url.resolvingSymlinksInPath().path.hasPrefix(artwork.resolvingSymlinksInPath().path + "/")
    }

    static func artworkURL(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        if let url = URL(string: raw), isArtwork(url) { return url }
        return try? AddonURL.http(raw)
    }

    static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    static func prefix(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try file.read(upToCount: 4096) ?? Data()
    }
}

struct DownloadProbe: Sendable {
    let total: Int64?
    let ext: String
    let etag: String?
    let modified: String?
    var rangeIdentity: HTTPRangeIdentity? = nil

    static func inspect(_ source: StreamSource, allowsCellular: Bool) async throws -> DownloadProbe {
        let url = try DownloadPolicy.url(for: source)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.allowsCellularAccess = allowsCellular
        request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw DownloadFailure.response }
        guard response.statusCode == 200 || response.statusCode == 206 else {
            throw HTTPDownloadError.status(
                response.statusCode, response.value(forHTTPHeaderField: "Retry-After"))
        }
        try DownloadPolicy.validate(status: response.statusCode, mime: response.mimeType, prefix: Data())
        var prefix = Data()
        for try await byte in bytes {
            prefix.append(byte)
            if prefix.count >= 4096 { break }
        }
        try Task.checkCancellation()
        try DownloadPolicy.validate(status: response.statusCode, mime: response.mimeType, prefix: prefix)
        let range = HTTPContentRange(response.value(forHTTPHeaderField: "Content-Range"))
        if response.statusCode == 206 {
            guard let range, range.lower == 0, range.upper == min(4095, range.total - 1),
                prefix.count == range.count,
                response.expectedContentLength < 0 || response.expectedContentLength == range.count,
                HTTPDownloadPolicy.isIdentityEncoding(response.value(forHTTPHeaderField: "Content-Encoding"))
            else { throw HTTPDownloadError.invalidRange }
        }
        return DownloadProbe(
            total: DownloadPolicy.totalBytes(
                contentRange: response.value(forHTTPHeaderField: "Content-Range"),
                contentLength: response.expectedContentLength),
            ext: DownloadPolicy.fileExtension(
                url: response.url ?? url,
                filename: source.behaviorHints?.filename ?? response.suggestedFilename,
                mime: response.mimeType, prefix: prefix),
            etag: response.value(forHTTPHeaderField: "ETag"),
            modified: response.value(forHTTPHeaderField: "Last-Modified"),
            rangeIdentity: response.statusCode == 206
                ? HTTPRangeIdentity(
                    sourceURL: url.absoluteString, etag: response.value(forHTTPHeaderField: "ETag"),
                    total: range?.total) : nil)
    }
}
