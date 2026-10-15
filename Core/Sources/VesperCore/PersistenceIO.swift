import Foundation

/// Shared file mechanics; repositories own schema validation and recovery decisions.
enum PersistenceIO {
    enum ReadError: Error { case tooLarge }

    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumBytes {
            throw ReadError.tooLarge
        }
        let data = try Data(contentsOf: url)
        // Check again in case the file changed after the resource-value lookup.
        guard data.count <= maximumBytes else { throw ReadError.tooLarge }
        return data
    }

    static func write(_ data: Data, _ url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    static func excludeFromBackup(_ url: URL) throws {
        #if os(iOS)
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #endif
    }
}
