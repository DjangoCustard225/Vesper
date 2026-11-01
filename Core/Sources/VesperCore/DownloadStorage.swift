import Foundation

public struct DownloadDiskState: Sendable {
    public var media: [String: Int64] = [:]
    public var artwork: Set<String> = []
    public var savedBytes: Int64 = 0
    public var incomingBytes: Int64 = 0
    public init() {}
}

/// File transactions never run on the UI actor. The app serializes commands around these calls.
public actor DownloadStorage {
    public nonisolated let root: URL
    private let repository: DownloadRepository
    private let fm = FileManager.default
    public init(root: URL, repository: DownloadRepository? = nil) {
        self.root = root
        self.repository = repository ?? DownloadRepository(url: root.appendingPathComponent("index.json"))
    }
    private func folder(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }
    private func path(_ folder: String, _ name: String) -> URL {
        self.folder(folder).appendingPathComponent(name)
    }
    public func load() throws -> DownloadLibrary {
        for name in ["Media", "Artwork", "Incoming", "Trash", "Exports"] {
            let url = folder(name)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try protect(url)
        }
        try protect(root)
        return try repository.load()
    }
    public func save(_ library: DownloadLibrary) throws { try repository.save(library) }
    public func stagedReceipt(_ key: DownloadTaskKey) -> DownloadReceipt? {
        let url = path("Incoming", key.id.uuidString + "-" + key.attempt.uuidString)
        guard fm.fileExists(atPath: url.path) else { return nil }
        // The delegate stages files only after validating their HTTP response and full size.
        return DownloadReceipt(location: url, status: 200, mime: nil, total: size(url))
    }
    private func protect(_ url: URL) throws {
        #if os(iOS)
        try fm.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        try PersistenceIO.excludeFromBackup(url)
    }
    public func diskState() -> DownloadDiskState {
        var state = DownloadDiskState()
        for name in ["Media", "Artwork", "Incoming"] {
            for url in contents(name) {
                let bytes = size(url)
                if name == "Media" { state.media[url.lastPathComponent] = bytes }
                if name == "Artwork" { state.artwork.insert(url.lastPathComponent) }
                if name == "Incoming" { state.incomingBytes += bytes } else { state.savedBytes += bytes }
            }
        }
        for workspace in ["UsenetJobs", "HTTPJobs"] {
            if let entries = fm.enumerator(
                at: folder(workspace),
                includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey])
            {
                for case let url as URL in entries {
                    if let values = try? url.resourceValues(forKeys: [
                        .isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey,
                    ]), values.isRegularFile == true {
                        state.incomingBytes += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                    }
                }
            }
        }
        return state
    }
    public func availableBytes() -> Int64 {
        #if os(iOS) || os(macOS)
        if let values = try? root.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]) {
            if let capacity = values.volumeAvailableCapacityForImportantUsage, capacity >= 0 {
                return capacity
            }
            if let capacity = values.volumeAvailableCapacity, capacity >= 0 { return Int64(capacity) }
        }
        #endif
        return ((try? fm.attributesOfFileSystem(forPath: root.path)[.systemFreeSize]) as? NSNumber)?
            .int64Value ?? 0
    }
    public func file(_ record: DownloadRecord) -> URL? {
        guard let name = record.fileName, DownloadPolicy.safeName(name) else { return nil }
        let url = path("Media", name)
        guard fm.fileExists(atPath: url.path), size(url) > 0,
            record.phase != .completed || size(url) == record.receivedBytes
        else { return nil }
        return url
    }
    public func complete(_ library: DownloadLibrary, key: DownloadTaskKey, receipt: DownloadReceipt) throws
        -> DownloadLibrary
    {
        defer { try? fm.removeItem(at: receipt.location) }
        guard let index = library.records.firstIndex(where: { $0.id == key.id && $0.attempt == key.attempt }),
            library.records[index].phase.isActive || library.records[index].phase == .paused
        else { return library }
        let record = library.records[index]
        try DownloadPolicy.validate(
            status: receipt.status, mime: receipt.mime, prefix: prefix(receipt.location))
        let bytes = size(receipt.location)
        guard bytes > 0, (receipt.total ?? record.expectedBytes).map({ $0 == bytes }) ?? true,
            let name = record.fileName, DownloadPolicy.safeName(name)
        else { throw DownloadFailure.incomplete }
        let destination = path("Media", name)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: receipt.location, to: destination)
        try protect(destination)
        var proposed = library
        proposed.records[index].phase = .completed
        proposed.records[index].receivedBytes = bytes; proposed.records[index].expectedBytes = bytes
        proposed.records[index].resumeData = nil; proposed.records[index].message = nil
        // Keep the verified final file even if saving the index fails. recover() completes the commit.
        try save(proposed)
        return proposed
    }
    public func recover(_ library: DownloadLibrary) throws -> DownloadLibrary {
        var proposed = library
        for index in proposed.records.indices {
            let record = proposed.records[index]
            if let name = record.fileName, DownloadPolicy.safeName(name) {
                let trashed = path("Trash", name), final = path("Media", name)
                if fm.fileExists(atPath: trashed.path), !fm.fileExists(atPath: final.path) {
                    try fm.moveItem(at: trashed, to: final)
                }
            }
            if record.phase.isActive || record.phase == .paused {
                let key = DownloadTaskKey(id: record.id, attempt: record.attempt)
                let staged = path("Incoming", key.id.uuidString + "-" + key.attempt.uuidString)
                if fm.fileExists(atPath: staged.path) {
                    proposed = try complete(
                        proposed, key: key,
                        receipt: DownloadReceipt(
                            location: staged, status: 200, mime: nil, total: size(staged)))
                    continue
                }
            }
            if record.phase != .completed, let url = file(record),
                record.expectedBytes.map({ $0 == size(url) }) ?? true
            {
                try DownloadPolicy.validate(status: 200, mime: nil, prefix: prefix(url))
                proposed.records[index].phase = .completed
                proposed.records[index].receivedBytes = size(url);
                proposed.records[index].expectedBytes = size(url)
                proposed.records[index].resumeData = nil; proposed.records[index].message = nil
            }
        }
        try save(proposed)
        return proposed
    }
    public func remove(_ ids: Set<UUID>, from library: DownloadLibrary) throws -> DownloadLibrary {
        let selected = library.records.filter { ids.contains($0.id) }
        var moves: [(URL, URL)] = []
        var proposed = library
        proposed.records.removeAll { ids.contains($0.id) }
        do {
            for record in selected {
                if let name = record.fileName, DownloadPolicy.safeName(name) {
                    let source = path("Media", name), target = path("Trash", name)
                    if fm.fileExists(atPath: source.path) {
                        try fm.moveItem(at: source, to: target); moves.append((source, target))
                    }
                }
            }
            try save(proposed)
        } catch {
            moves.forEach { try? fm.moveItem(at: $0.1, to: $0.0) }
            throw error
        }
        moves.forEach { try? fm.removeItem(at: $0.1) }
        let retained = Set(proposed.records.flatMap { $0.artwork.values })
        for name in Set(selected.flatMap { $0.artwork.values }) where !retained.contains(name) {
            try? fm.removeItem(at: path("Artwork", name))
        }
        return proposed
    }
    public func storeArtwork(_ data: Data, name: String) throws {
        guard DownloadPolicy.safeName(name), data.count <= 12 * 1024 * 1024 else {
            throw DownloadFailure.response
        }
        let url = path("Artwork", name)
        try data.write(to: url, options: .atomic); try protect(url)
    }
    public func reconcile(_ library: DownloadLibrary) {
        let owned = [
            "Media": Set(library.records.compactMap(\.fileName)),
            "Artwork": Set(library.records.flatMap { $0.artwork.values }), "Trash": Set<String>(),
        ]
        for (directory, names) in owned {
            for url in contents(directory) where !names.contains(url.lastPathComponent) {
                try? fm.removeItem(at: url)
            }
        }
        let retained = Set(library.records.filter { $0.phase != .completed }.map { $0.id.uuidString })
        for workspace in ["UsenetJobs", "HTTPJobs"] {
            for url in contents(workspace) where !retained.contains(url.lastPathComponent) {
                try? fm.removeItem(at: url)
            }
        }
        // Receipts can be staged concurrently by the URLSession delegate. Leave them for its callback.
        for url in contents("Exports") { try? fm.removeItem(at: url) }
    }
    public func export(_ record: DownloadRecord) throws -> URL {
        guard let source = file(record) else { throw DownloadFailure.missing }
        let ext = DownloadPolicy.fileExtension(
            url: source, filename: record.source.behaviorHints?.filename, mime: nil,
            prefix: try prefix(source))
        let directory = folder("Exports").appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try protect(directory)
        let destination = directory.appendingPathComponent(DownloadPlayback.exportName(record, ext: ext))
        // Same-volume hard link gives the share sheet a readable name without copying a large video.
        try fm.linkItem(at: source, to: destination)
        return destination
    }
    public func finishExport(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        guard
            directory.deletingLastPathComponent().standardizedFileURL == folder("Exports").standardizedFileURL
        else { return }
        try? fm.removeItem(at: directory)
    }
    private func contents(_ name: String) -> [URL] {
        (try? fm.contentsOfDirectory(at: folder(name), includingPropertiesForKeys: nil)) ?? []
    }
    private func size(_ url: URL) -> Int64 {
        ((try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
    private func prefix(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() };
        return try handle.read(upToCount: 4096) ?? Data()
    }
}
