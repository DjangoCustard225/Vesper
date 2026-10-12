import Foundation

public enum WatchProgressError: Error, LocalizedError {
    case unreadable, unsupportedVersion, writeFailed
    public var errorDescription: String? {
        switch self {
        case .unreadable: "Saved watch progress couldn’t be read. Its files have been preserved."
        case .unsupportedVersion: "Watch progress was saved by a newer Vesper version. Its files have been preserved."
        case .writeFailed: "Couldn’t save watch progress. Your previous progress has been kept."
        }
    }
}

public struct WatchProgressRepository: Sendable {
    private struct Envelope: Codable { let version: Int; let progress: WatchProgress }
    private struct Header: Decodable { let version: Int }
    public let url: URL
    public var backupURL: URL { url.appendingPathExtension("backup") }
    private let write: @Sendable (Data, URL) throws -> Void
    public init(url: URL, write: @escaping @Sendable (Data, URL) throws -> Void = { try LibraryRepository.atomicWrite($0, $1) }) {
        self.url = url; self.write = write
    }
    public static func decode(_ data: Data) throws -> WatchProgress {
        guard data.count <= 8 * 1024 * 1024 else { throw WatchProgressError.unreadable }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else { throw WatchProgressError.unreadable }
        guard header.version == 1 else { throw WatchProgressError.unsupportedVersion }
        guard let value = try? decoder.decode(Envelope.self, from: data), value.progress.isValid else { throw WatchProgressError.unreadable }
        return value.progress
    }
    private func read(_ url: URL) throws -> Data {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8 * 1024 * 1024 else { throw WatchProgressError.unreadable }
        return try Data(contentsOf: url)
    }
    public func load() throws -> (state: WatchProgress, recovered: Bool) {
        let loaded = try loadStoredProgress()
        // Remove retired source selections without rotating or merging progress backups.
        for file in [url, backupURL] {
            guard let data = try? read(file), let state = try? Self.decode(data),
                  let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let progress = envelope["progress"] as? [String: Any],
                  let records = progress["records"] as? [[String: Any]],
                  records.contains(where: { $0["lastStream"] != nil }) else { continue }
            do {
                try write(JSONEncoder().encode(Envelope(version: 1, progress: state)), file)
                try excludeFromBackup(file)
            } catch { throw WatchProgressError.writeFailed }
        }
        return loaded
    }
    private func loadStoredProgress() throws -> (state: WatchProgress, recovered: Bool) {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            do { return (try Self.decode(read(url)), false) }
            catch WatchProgressError.unsupportedVersion { throw WatchProgressError.unsupportedVersion }
            catch {}
        } else if !manager.fileExists(atPath: backupURL.path) { return (WatchProgress(), false) }
        guard let data = try? read(backupURL), let state = try? Self.decode(data) else { throw WatchProgressError.unreadable }
        return (state, true)
    }
    public func save(_ state: WatchProgress) throws {
        guard state.isValid else { throw WatchProgressError.writeFailed }
        let data = try JSONEncoder().encode(Envelope(version: 1, progress: state))
        _ = try Self.decode(data)
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: url.path) {
                let old = try read(url)
                do {
                    let previous = try Self.decode(old)
                    try write(JSONEncoder().encode(Envelope(version: 1, progress: previous)), backupURL)
                    try excludeFromBackup(backupURL)
                }
                catch WatchProgressError.unsupportedVersion { throw WatchProgressError.unsupportedVersion }
                catch WatchProgressError.unreadable {
                    let preserved = url.appendingPathExtension("corrupt-" + UUID().uuidString)
                    try write(old, preserved); try excludeFromBackup(preserved)
                }
            }
            try write(data, url)
            try excludeFromBackup(url)
        } catch let error as WatchProgressError { throw error }
        catch { throw WatchProgressError.writeFailed }
    }
    private func excludeFromBackup(_ url: URL) throws {
        #if os(iOS)
        var url = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #endif
    }
}
