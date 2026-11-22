import Foundation

/// Cached fixed-format date parsers. `DateFormatter` is expensive to create and is thread-safe
/// for parsing, so one shared instance per format replaces a new formatter on every call.
final class FixedDateParser: @unchecked Sendable {
    /// RFC 7231 HTTP dates, as used by `Retry-After`.
    static let http = FixedDateParser("EEE',' dd MMM yyyy HH':'mm':'ss z", timeZone: .gmt)
    /// RFC 822 dates from Newznab `pubDate`.
    static let rss = FixedDateParser("EEE, dd MMM yyyy HH:mm:ss Z", timeZone: nil)
    /// Compact ISO 8601 stamps used by S3 and GCS presigned URLs.
    static let signedURL = FixedDateParser("yyyyMMdd'T'HHmmss'Z'", timeZone: .gmt)

    private let formatter: DateFormatter

    private init(_ format: String, timeZone: TimeZone?) {
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let timeZone { formatter.timeZone = timeZone }
        formatter.dateFormat = format
    }

    func date(from string: String) -> Date? { formatter.date(from: string) }
}
