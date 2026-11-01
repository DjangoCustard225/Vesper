import Foundation

/// A complete-length byte range. Unknown totals are deliberately unsuitable for assembly.
public struct HTTPContentRange: Equatable, Sendable {
    public let lower: Int64
    public let upper: Int64
    public let total: Int64
    public var count: Int64 { upper - lower + 1 }
    public init?(_ value: String?) {
        guard let value else { return nil }
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let bounds = parts[1].split(separator: "/", omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }
        let range = bounds[0].split(separator: "-", omittingEmptySubsequences: false)
        func number(_ value: Substring) -> Int64? {
            guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
            return Int64(value)
        }
        guard range.count == 2, let lower = number(range[0]), let upper = number(range[1]),
            let total = number(bounds[1]), lower <= upper, upper < total
        else { return nil }
        self.lower = lower; self.upper = upper; self.total = total
    }
}

public enum HTTPDownloadError: LocalizedError, Sendable {
    case status(Int, String?), invalidRange, changed
    public var errorDescription: String? {
        switch self {
        case .status(let status, _): "The download server returned HTTP \(status)."
        case .invalidRange: "The server did not return the requested part of the file."
        case .changed: "The file changed on the server. Restart this download."
        }
    }
}

public enum HTTPDownloadPolicy {
    public static let maximumRetries = 4
    public static let blockSize: Int64 = 16 * 1024 * 1024
    public static let minimumParallelSize: Int64 = 32 * 1024 * 1024
    public static let maximumParallelSize: Int64 = 1 << 40

    public static func strongETag(_ value: String?) -> String? {
        guard let tag = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            tag.hasPrefix("\""), tag.hasSuffix("\""), tag.count >= 2,
            !tag.contains("\r"), !tag.contains("\n")
        else { return nil }
        return tag
    }
    public static func isIdentityEncoding(_ value: String?) -> Bool {
        value == nil || value?.isEmpty == true || value?.lowercased() == "identity"
    }
    public static func validateCompletion(
        status: Int, contentRange: String?, contentLength: Int64, actualBytes: Int64,
        encoding: String? = nil, mime: String?, prefix: Data
    ) throws {
        try DownloadPolicy.validate(status: status, mime: mime, prefix: prefix)
        guard actualBytes > 0 else { throw DownloadFailure.incomplete }
        if status == 206 {
            guard isIdentityEncoding(encoding), let range = HTTPContentRange(contentRange),
                range.upper == range.total - 1, actualBytes == range.total,
                contentLength < 0 || contentLength == range.count
            else { throw HTTPDownloadError.invalidRange }
        } else {
            guard contentRange == nil else { throw HTTPDownloadError.invalidRange }
            if isIdentityEncoding(encoding), contentLength >= 0, contentLength != actualBytes {
                throw DownloadFailure.incomplete
            }
        }
    }
    public static func retryDelay(
        status: Int?, code: Int?, retryAfter: String?, attempt: Int, now: Date = Date(), jitter: Double = 0
    ) -> TimeInterval? {
        guard (1...maximumRetries).contains(attempt),
            status.map({ [408, 429, 500, 502, 503, 504].contains($0) }) ?? code.map({
                [
                    NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
                    NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
                ].contains($0)
            }) ?? false
        else { return nil }
        var delay = min(60, pow(2, Double(attempt)) * 2) + min(1, max(0, jitter))
        if let retryAfter {
            if let seconds = Double(retryAfter), seconds.isFinite, seconds >= 0 {
                delay = max(delay, seconds)
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
                if let date = formatter.date(from: retryAfter) {
                    delay = max(delay, date.timeIntervalSince(now))
                }
            }
        }
        return delay.isFinite && delay <= 7 * 24 * 3600 ? delay : nil
    }
    public static func shouldRestartResume(code: Int?, status: Int?, wasResuming: Bool, recoveries: Int)
        -> Bool
    {
        guard recoveries == 0 else { return false }
        if status == 416 { return true }
        guard wasResuming else { return false }
        return code.map {
            [
                NSURLErrorBadURL, NSURLErrorCannotOpenFile, NSURLErrorFileDoesNotExist,
                NSURLErrorBadServerResponse, NSURLErrorCannotDecodeRawData,
                NSURLErrorCannotDecodeContentData,
            ].contains($0)
        } ?? false
    }
    public static func ranges(total: Int64) -> [Range<Int64>] {
        guard total > 0, total <= maximumParallelSize else { return [] }
        return stride(from: Int64(0), to: total, by: Int(blockSize)).map { $0..<min(total, $0 + blockSize) }
    }
}

public struct HTTPRangeIdentity: Codable, Equatable, Sendable {
    public let resource: String
    public let etag: String
    public let total: Int64
    public init?(sourceURL: String, etag: String?, total: Int64?) {
        guard let key = StreamPolicy.stableURL(sourceURL), let etag = HTTPDownloadPolicy.strongETag(etag),
            let total, total >= HTTPDownloadPolicy.minimumParallelSize,
            total <= HTTPDownloadPolicy.maximumParallelSize
        else { return nil }
        self.resource = ResponseCache.fingerprint(key); self.etag = etag; self.total = total
    }
}
