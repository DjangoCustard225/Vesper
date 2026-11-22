import Foundation

/// Download counters for one streaming session, for diagnostics.
public struct ArticleCacheStatistics: Sendable, Equatable {
    public var articles = 0
    public var bytes = 0
    /// Articles requested a second time because the first request was slow while playback waited.
    public var hedges = 0
    /// Of those, how many the second request delivered first.
    public var hedgeWins = 0
    /// Smoothed time to download and decode one article.
    public var averageFetch: Duration = .zero
    /// Articles that went to disk because the in-memory tier was full.
    public var spilled = 0
}

/// Stores complete validated articles, never a sparse file whose holes could be read as video.
/// New articles live in memory; only when that tier is full do the least recently used ones move to
/// disk, so most streamed bytes are never written at all.
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
    private let memoryLimit: Int
    private var entries: [Key: Entry] = [:]
    private var pending: [Key: Pending] = [:]
    /// Recency stamps; eviction scans these only when over a limit, never on every access.
    private var lastUse: [Key: UInt64] = [:]
    private var clock: UInt64 = 0
    private var memory: [Key: Data] = [:]
    private var memoryBytes = 0
    private var onDisk: Set<Key> = []
    private var resident: Set<Key> = []
    private var pins: [Key: Int] = [:]
    private var bytes = 0
    private var stopped = false
    private var stats = ArticleCacheStatistics()
    private var fetchSamples = 0
    /// How long playback waits on an article before a second request, until timings are known.
    private let initialHedgeDelay: Duration
    public init(
        source: any ArticleSource, directory: URL, limit: Int = 512 * 1024 * 1024,
        memoryLimit: Int = 64 * 1024 * 1024
    ) throws {
        try self.init(
            source: source, directory: directory, limit: limit, memoryLimit: memoryLimit,
            initialHedgeDelay: .seconds(4))
    }
    init(
        source: any ArticleSource, directory: URL, limit: Int, memoryLimit: Int, initialHedgeDelay: Duration
    ) throws {
        guard limit >= 8 * 1024 * 1024 else { throw UsenetError.storage }
        self.initialHedgeDelay = initialHedgeDelay
        self.source = source; self.directory = directory; self.limit = limit
        self.memoryLimit = max(0, min(memoryLimit, limit))
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
            let id = file.segments[index].messageID, pendingID = UUID()
            let task = fetchTask(key: key, pendingID: pendingID, messageID: id, priority: priority)
            item = Pending(id: pendingID, task: task, priority: priority, messageID: id); pending[key] = item
        }
        let decoded: YEncDecodedSegment
        do { decoded = try await item.task.value } catch {
            if pending[key]?.id == item.id { pending[key] = nil }
            if error is CancellationError { throw error }
            throw (error as? UsenetError) ?? UsenetError.corrupt
        }
        defer { if pending[key]?.id == item.id { pending[key] = nil } }
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
        let entry = Entry(
            key: key, offset: start, length: decoded.data.count, fileSize: Int64(size),
            name: decoded.header.name, url: directory.appendingPathComponent("\(file.id)-\(index).article"))
        entries[key] = entry; resident.insert(key); bytes += entry.length; pending[key] = nil; touch(key)
        keep(key, decoded.data)
        if !resident.contains(key) { throw UsenetError.storage }
        evict(excluding: key)
        return entry
    }
    /// Downloads and decodes one article off the cache actor. If playback is waiting on it and it
    /// is slow compared with recent articles, a second request races the first on another socket.
    private func fetchTask(key: Key, pendingID: UUID, messageID id: String, priority: ArticlePriority)
        -> Task<YEncDecodedSegment, Error>
    {
        let source = source, hedgeAfter = hedgeDelay
        return Task.detached(priority: Task.currentPriority) { [weak self] in
            let clock = ContinuousClock(), started = clock.now
            let (decoded, hedged) = try await withThrowingTaskGroup(of: (YEncDecodedSegment, Bool)?.self) {
                group in
                group.addTask {
                    do { return (try await source.decodedArticle(id, priority: priority), false) } catch let
                        error
                        as UsenetError
                        where error == .connection || error == .timeout
                    {
                        try Task.checkCancellation()
                        try await Task.sleep(for: .milliseconds(150))
                        return (try await source.decodedArticle(id, priority: priority), false)
                    }
                }
                group.addTask {
                    try await Task.sleep(for: hedgeAfter)
                    while await self?.demanded(key, pendingID) == false {
                        try await Task.sleep(for: .milliseconds(250))
                    }
                    guard let self else { return nil }
                    await self.noteHedge()
                    do { return (try await source.decodedArticle(id, priority: .playback), true) } catch {
                        try Task.checkCancellation()
                        return nil  // The original request may still succeed.
                    }
                }
                defer { group.cancelAll() }
                while let result = try await group.next() {
                    if let result { return result }
                }
                throw UsenetError.connection
            }
            try Task.checkCancellation()
            await self?.record(started.duration(to: clock.now), bytes: decoded.data.count, hedged: hedged)
            return decoded
        }
    }
    private var hedgeDelay: Duration {
        guard fetchSamples >= 4 else { return initialHedgeDelay }
        return min(.seconds(8), max(.milliseconds(1500), stats.averageFetch * 3))
    }
    private func demanded(_ key: Key, _ id: UUID) -> Bool {
        pending[key]?.id == id && pending[key]?.priority == .playback
    }
    private func noteHedge() { stats.hedges += 1 }
    private func record(_ duration: Duration, bytes count: Int, hedged: Bool) {
        stats.articles += 1; stats.bytes += count
        if hedged { stats.hedgeWins += 1; return }
        // A won hedge measures the slow path badly, so only first-request times feed the average.
        fetchSamples += 1
        stats.averageFetch =
            fetchSamples == 1 ? duration : stats.averageFetch * 0.8 + duration * 0.2
    }
    public var statistics: ArticleCacheStatistics { stats }
    func data(file: NZBFile, index: Int, priority: ArticlePriority) async throws -> (Entry, Data) {
        let key = Key(file: file.id, index: index)
        pins[key, default: 0] += 1
        defer { if let count = pins[key], count > 1 { pins[key] = count - 1 } else { pins[key] = nil } }
        let value = try await entry(file: file, index: index, priority: priority)
        guard !stopped else { throw UsenetError.cancelled }
        if let data = memory[key], data.count == value.length { return (value, data) }
        do {
            let data = try Data(contentsOf: value.url)
            guard data.count == value.length else { throw UsenetError.corrupt }
            keep(key, data)  // Seek-back reads come in chunks; keep this one close.
            return (value, data)
        } catch {
            drop(key)
            throw (error as? UsenetError) ?? UsenetError.storage
        }
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
        resident = []; entries = [:]; lastUse = [:]; memory = [:]; memoryBytes = 0; onDisk = []; bytes = 0
    }
    private func touch(_ key: Key) { clock &+= 1; lastUse[key] = clock }
    /// Holds an article's bytes in memory, moving the least recently used ones to disk when full.
    private func keep(_ key: Key, _ data: Data) {
        if let previous = memory.updateValue(data, forKey: key) { memoryBytes -= previous.count }
        memoryBytes += data.count
        while memoryBytes > memoryLimit,
            let candidate = memory.keys.filter({ $0 != key }).min(by: { recency($0) < recency($1) })
        {
            spill(candidate)
        }
        if memoryBytes > memoryLimit { spill(key) }
    }
    private func recency(_ key: Key) -> UInt64 { lastUse[key] ?? 0 }
    private func spill(_ key: Key) {
        guard let data = memory.removeValue(forKey: key) else { return }
        memoryBytes -= data.count
        guard !onDisk.contains(key), let entry = entries[key], resident.contains(key) else { return }
        do {
            try data.write(to: entry.url, options: Self.writeOptions)
            onDisk.insert(key); stats.spilled += 1
        } catch {
            drop(key)
        }
    }
    /// Forgets an article entirely; it is downloaded again if needed.
    private func drop(_ key: Key) {
        guard let entry = entries[key], resident.remove(key) != nil else { return }
        bytes -= entry.length; lastUse[key] = nil
        if let data = memory.removeValue(forKey: key) { memoryBytes -= data.count }
        if onDisk.remove(key) != nil { try? FileManager.default.removeItem(at: entry.url) }
    }
    private func evict(excluding key: Key) {
        while bytes > limit,
            let candidate = lastUse.filter({
                $0.key != key && resident.contains($0.key) && pins[$0.key] == nil
            })
            .min(by: { $0.value < $1.value })?.key
        {
            drop(candidate)
        }
    }
    #if os(iOS)
    private static let writeOptions: Data.WritingOptions = .completeFileProtectionUntilFirstUserAuthentication
    #else
    private static let writeOptions: Data.WritingOptions = []
    #endif
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
        try await read(offset: offset, count: count, priority: priority, readAhead: Self.readAheadBytes)
    }
    /// Reads bytes and, for playback, keeps `readAhead` bytes beyond them downloading.
    public func read(offset: Int64, count: Int, priority: ArticlePriority, readAhead: Int) async throws
        -> Data
    {
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
                // The session sizes this to about 30 seconds of the video's bitrate (64 MiB until
                // it is known), so a large connection pool stays busy and one slow article never
                // stalls playback. Demand always precedes queued prefetch.
                let ahead = min(Self.readAheadArticles, max(1, readAhead / max(entry.length, 1)))
                await cache.prefetch(
                    file: file, indices: (index + 1)..<min(file.segments.count, index + 1 + ahead))
            }
        }
        if priority == .playback { lastEnd = position }; return result
    }
    static let readAheadBytes = 64 * 1024 * 1024
    static let readAheadArticles = 512

    /// Starts downloading the articles covering a byte range without waiting for them.
    public func prefetch(offset: Int64, length: Int64) async {
        guard length > 0, let first = try? await cache.entry(file: file, index: 0, priority: .prefetch)
        else { return }
        let partSize = Int64(max(first.length, 1)), last = file.segments.count
        let start = Int(max(0, offset) / partSize)
        // One article of margin each side covers parts that are not exactly equal.
        let end = Int(min(Int64(last), (max(0, offset) + length) / partSize + 2))
        guard start < end else { return }
        await cache.prefetch(file: file, indices: max(0, start - 1)..<end)
    }

    /// Posters split files into equal parts, so the article holding a byte is almost always
    /// `position / partSize`. Estimate from the first part, correct from what each fetched article
    /// reports, and fall back to bisection within the bounds learned so far.
    private func locate(_ position: Int64, priority: ArticlePriority) async throws -> Int {
        let last = file.segments.count - 1
        let first = try await cache.entry(file: file, index: 0, priority: priority)
        if position < Int64(first.length) { return 0 }
        let partSize = Int64(max(first.length, 1))
        var low = 1, high = last
        var guess = Int(min(Int64(last), position / partSize))
        for _ in 0..<4 where low <= high {
            guess = min(max(guess, low), high)
            let entry = try await cache.entry(file: file, index: guess, priority: priority)
            if position < entry.offset {
                high = guess - 1
                guess -= max(1, Int((entry.offset - position + partSize - 1) / partSize))
            } else if position >= entry.offset + Int64(entry.length) {
                low = guess + 1
                guess += max(1, Int((position - entry.offset - Int64(entry.length)) / partSize) + 1)
            } else {
                return guess
            }
        }
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
