import Foundation

/// Stores complete validated articles, never a sparse file whose holes could be read as video.
public actor ArticleCache {
    struct Key: Hashable, Sendable { let file: Int; let index: Int }
    struct Entry: Sendable {
        let key: Key
        let offset: Int64
        let length: Int
        let fileSize: Int64
        let name: String?
        let url: URL
    }
    private struct Pending {
        let id: UUID; let task: Task<YEncDecodedSegment, Error>; var priority: ArticlePriority;
        let messageID: String
    }
    private let source: any ArticleSource
    private let directory: URL
    private let limit: Int
    private var entries: [Key: Entry] = [:]
    private var pending: [Key: Pending] = [:]
    private var lru: [Key] = []
    private var resident: Set<Key> = []
    private var pins: [Key: Int] = [:]
    private var bytes = 0
    private var stopped = false
    public init(source: any ArticleSource, directory: URL, limit: Int = 512 * 1024 * 1024) throws {
        guard limit >= 8 * 1024 * 1024 else { throw UsenetError.storage }
        self.source = source; self.directory = directory; self.limit = limit
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.protect(directory)
    }
    func entry(file: NZBFile, index: Int, priority: ArticlePriority) async throws -> Entry {
        guard !stopped, file.segments.indices.contains(index) else { throw UsenetError.cancelled }
        try Task.checkCancellation()
        let key = Key(file: file.id, index: index)
        if let entry = entries[key], resident.contains(key) { touch(key); return entry }
        let item: Pending
        if var current = pending[key] {
            if priority.rawValue > current.priority.rawValue {
                current.priority = priority; pending[key] = current; await source.promote(current.messageID)
            }
            item = current
        } else {
            let id = file.segments[index].messageID, source = source
            // Decode on the cooperative pool instead of serializing CPU work on the cache actor.
            let task = Task.detached(priority: Task.currentPriority) {
                let lines: [Data]
                do { lines = try await source.article(id, priority: priority) } catch let error as UsenetError
                    where error == .connection || error == .timeout
                {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(150))
                    lines = try await source.article(id, priority: priority)
                }
                try Task.checkCancellation()
                return try YEncDecoder.decode(bodyLines: lines)
            }
            item = Pending(id: UUID(), task: task, priority: priority, messageID: id); pending[key] = item
        }
        let decoded: YEncDecodedSegment
        do { decoded = try await item.task.value } catch {
            if pending[key]?.id == item.id { pending[key] = nil }
            if error is CancellationError { throw error }
            throw (error as? UsenetError) ?? UsenetError.corrupt
        }
        try Task.checkCancellation()
        guard !stopped else { throw UsenetError.cancelled }
        if let existing = entries[key], resident.contains(key) { touch(key); return existing }
        guard let size = decoded.header.size, size > 0, size <= 1 << 50,
            (file.segments.count == 1 || decoded.header.isMultipart),
            decoded.header.part.map({ $0 == file.segments[index].number }) ?? true,
            decoded.header.total.map({ $0 == file.segments.count }) ?? true
        else { pending[key] = nil; throw UsenetError.corrupt }
        let start = Int64(decoded.fileOffset), end = try checkedAdd(start, Int64(decoded.data.count))
        guard end <= size else { pending[key] = nil; throw UsenetError.corrupt }
        for existing in entries.values where existing.key.file == file.id {
            guard existing.fileSize == size else { pending[key] = nil; throw UsenetError.corrupt }
            if existing.key.index < index {
                guard existing.offset + Int64(existing.length) <= start else {
                    pending[key] = nil; throw UsenetError.corrupt
                }
            }
            if existing.key.index > index {
                guard end <= existing.offset else { pending[key] = nil; throw UsenetError.corrupt }
            }
        }
        guard index != 0 || start == 0, index != file.segments.count - 1 || end == size else {
            pending[key] = nil; throw UsenetError.corrupt
        }
        let path = directory.appendingPathComponent("\(file.id)-\(index).article")
        do { try decoded.data.write(to: path, options: .atomic); try Self.protect(path) } catch {
            pending[key] = nil; throw UsenetError.storage
        }
        let entry = Entry(
            key: key, offset: start, length: decoded.data.count, fileSize: Int64(size),
            name: decoded.header.name, url: path)
        entries[key] = entry; resident.insert(key); bytes += entry.length; pending[key] = nil; touch(key)
        evict(excluding: key)
        return entry
    }
    func data(file: NZBFile, index: Int, priority: ArticlePriority) async throws -> (Entry, Data) {
        let key = Key(file: file.id, index: index)
        pins[key, default: 0] += 1
        defer { if let count = pins[key], count > 1 { pins[key] = count - 1 } else { pins[key] = nil } }
        let value = try await entry(file: file, index: index, priority: priority)
        guard !stopped else { throw UsenetError.cancelled }
        do {
            let data = try Data(contentsOf: value.url)
            guard data.count == value.length else { throw UsenetError.corrupt }
            return (value, data)
        } catch {
            if resident.remove(value.key) != nil { bytes -= value.length }
            throw (error as? UsenetError) ?? UsenetError.storage
        }
    }
    func metadata(fileID: Int) -> [Int: Entry] {
        Dictionary(
            uniqueKeysWithValues: entries.values.filter { $0.key.file == fileID }.map { ($0.key.index, $0) })
    }
    func cancelPrefetch() {
        for (key, item) in pending where item.priority == .prefetch { item.task.cancel(); pending[key] = nil }
    }
    func prefetch(file: NZBFile, indices: Range<Int>) {
        for index in indices where file.segments.indices.contains(index) {
            let key = Key(file: file.id, index: index)
            guard !resident.contains(key), pending[key] == nil else { continue }
            Task { _ = try? await self.entry(file: file, index: index, priority: .prefetch) }
        }
    }
    public var storedBytes: Int { bytes }
    public func stop() async {
        stopped = true; pending.values.forEach { $0.task.cancel() }; pending = [:]
        await source.stop()
        try? FileManager.default.removeItem(at: directory)
        resident = []; entries = [:]; lru = []; bytes = 0
    }
    private func touch(_ key: Key) { lru.removeAll { $0 == key }; lru.append(key) }
    private func evict(excluding key: Key) {
        while bytes > limit,
            let candidate = lru.first(where: { $0 != key && resident.contains($0) && pins[$0] == nil }),
            let entry = entries[candidate]
        {
            do { try FileManager.default.removeItem(at: entry.url) } catch { break }
            resident.remove(candidate); lru.removeAll { $0 == candidate }; bytes -= entry.length
        }
    }
    private static func protect(_ url: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        var copy = url; var values = URLResourceValues(); values.isExcludedFromBackup = true;
        try copy.setResourceValues(values)
    }
}

public protocol ByteResource: Sendable {
    func size() async throws -> Int64
    func read(offset: Int64, count: Int, priority: ArticlePriority) async throws -> Data
}

public actor NZBFileReader: ByteResource {
    let file: NZBFile
    private let cache: ArticleCache
    private var lastEnd: Int64?
    public init(file: NZBFile, cache: ArticleCache) { self.file = file; self.cache = cache }
    public func size() async throws -> Int64 {
        try await cache.entry(file: file, index: 0, priority: .playback).fileSize
    }
    public func authoritativeName() async throws -> String {
        let name = try await cache.entry(file: file, index: 0, priority: .playback).name
        if let name, !(name as NSString).pathExtension.isEmpty { return (name as NSString).lastPathComponent }
        return file.name
    }
    public func verifyTail() async throws {
        _ = try await cache.entry(file: file, index: file.segments.count - 1, priority: .playback)
    }
    public func read(offset: Int64, count: Int, priority: ArticlePriority = .playback) async throws -> Data {
        let length = try await size()
        guard offset >= 0, count > 0, count <= 4 * 1024 * 1024, offset < length else {
            throw UsenetError.invalidRange
        }
        if priority == .playback, let lastEnd, abs(offset - lastEnd) > 4 * 1024 * 1024 {
            await cache.cancelPrefetch()
        }
        var result = Data(); result.reserveCapacity(count)
        var position = offset
        let requested = min(Int64(count), length - offset)
        while result.count < requested {
            try Task.checkCancellation()
            let index = try await locate(position, priority: priority)
            let (entry, data) = try await cache.data(file: file, index: index, priority: priority)
            let local = Int(position - entry.offset),
                amount = min(data.count - local, Int(requested) - result.count)
            guard local >= 0, amount > 0, local + amount <= data.count else { throw UsenetError.corrupt }
            result.append(data.subdata(in: local..<(local + amount))); position += Int64(amount)
            if priority == .playback, count >= 64 * 1024 {
                // About 16 MiB ahead, capped at 32 articles. Demand always precedes queued prefetch.
                let ahead = min(32, max(1, 16 * 1024 * 1024 / max(entry.length, 1)))
                await cache.prefetch(
                    file: file, indices: (index + 1)..<min(file.segments.count, index + 1 + ahead))
            }
        }
        if priority == .playback { lastEnd = position }; return result
    }
    private func locate(_ position: Int64, priority: ArticlePriority) async throws -> Int {
        let known = await cache.metadata(fileID: file.id)
        if let value = known.first(where: {
            position >= $0.value.offset && position < $0.value.offset + Int64($0.value.length)
        }) {
            return value.key
        }
        var low = 0, high = file.segments.count - 1
        while low <= high {
            let middle = low + (high - low) / 2
            let entry = try await cache.entry(file: file, index: middle, priority: priority)
            if position < entry.offset {
                high = middle - 1
            } else if position >= entry.offset + Int64(entry.length) {
                low = middle + 1
            } else {
                return middle
            }
        }
        throw UsenetError.missingArticle
    }
}
