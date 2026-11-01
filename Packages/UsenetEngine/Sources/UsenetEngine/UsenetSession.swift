import Foundation

public actor UsenetSession {
    private let manifest: NZBManifest
    private let cache: ArticleCache
    private let readers: [Int: NZBFileReader]
    private var stopped = false
    private var keyStores: [RARKeyStore] = []
    public init(
        manifest: NZBManifest, source: any ArticleSource, cacheDirectory: URL,
        cacheLimit: Int = 512 * 1024 * 1024
    ) throws {
        self.manifest = manifest
        let cache = try ArticleCache(source: source, directory: cacheDirectory, limit: cacheLimit)
        self.cache = cache
        self.readers = Dictionary(
            uniqueKeysWithValues: manifest.files.map { ($0.id, NZBFileReader(file: $0, cache: cache)) })
    }
    public func catalog(password: String? = nil) async throws -> [UsenetVideo] {
        guard !stopped else { throw UsenetError.cancelled }
        let passwords = password.map { [$0] } ?? manifest.passwords
        let stores = passwords.flatMap { value -> [RARKeyStore] in
            let current = RARKeyStore(password: value)
            return value.unicodeScalars.contains(where: { $0.value > 0xffff })
                ? [current, RARKeyStore(password: value, legacyUnicode: true)] : [current]
        }
        keyStores = stores
        var names: [Int: String] = [:]
        var unknown = 0
        for file in manifest.files {
            if UsenetVideo.isVideo(file.name) || Self.volume(file.name) != nil {
                names[file.id] = file.name
            } else if !["par2", "sfv", "nfo", "txt", "srr", "jpg", "png"].contains(
                (file.name as NSString).pathExtension.lowercased()), unknown < 32
            {
                unknown += 1
                if let reader = readers[file.id] { names[file.id] = try await reader.authoritativeName() }
            }
        }
        var groups: [String: [(Int, Int)]] = [:]
        var result: [(Int, [UsenetVideo])] = []
        for file in manifest.files {
            guard let name = names[file.id], let reader = readers[file.id] else { continue }
            if UsenetVideo.isVideo(name) {
                async let size = reader.size()
                async let tail: Void = reader.verifyTail()
                let length = try await size; try await tail
                result.append(
                    (
                        file.id,
                        [
                            UsenetVideo(
                                id: 0, name: name,
                                extents: [VideoExtent(fileID: file.id, offset: 0, length: length)])
                        ]
                    ))
            } else if let (key, number) = Self.volume(name) {
                groups[key, default: []].append((number, file.id))
            }
        }
        for key in groups.keys.sorted() {
            let volumes = groups[key]!.sorted { $0.0 < $1.0 }
            guard let first = volumes.first, first.0 == 0 || first.0 == 1,
                volumes.enumerated().allSatisfy({ $0.element.0 == first.0 + $0.offset })
            else { throw UsenetError.missingArticle }
            var videos: [UsenetVideo]?
            var passwordFailure = UsenetError.encrypted
            // Try only supplied hints, sharing downloaded articles across attempts and archive sets.
            for keys in stores.isEmpty ? [nil] : stores.map({ Optional($0) }) {
                do { videos = try await archive(volumes, keys: keys); break } catch UsenetError.encrypted {
                    passwordFailure = .encrypted
                } catch UsenetError.badPassword { passwordFailure = .badPassword }
            }
            guard let videos else { throw passwordFailure }
            result.append((volumes.map(\.1).min()!, videos))
        }
        var videos: [UsenetVideo] = []
        for (_, items) in result.sorted(by: { $0.0 < $1.0 }) {
            for item in items {
                videos.append(
                    UsenetVideo(
                        id: videos.count, name: item.name, extents: item.extents, cipher: item.cipher,
                        plainLength: item.plainLength))
            }
        }
        guard !videos.isEmpty else { throw UsenetError.noVideo }
        return videos
    }
    private func archive(_ volumes: [(Int, Int)], keys: RARKeyStore?) async throws -> [UsenetVideo] {
        var scanned: [(Int, Int, RARVolume)] = []
        // Eight metadata reads at a time, sharing the same bounded provider pool as playback.
        try await withThrowingTaskGroup(of: (Int, Int, RARVolume).self) { group in
            var cursor = 0
            func schedule() {
                guard cursor < volumes.count else { return }
                let item = volumes[cursor], index = cursor; cursor += 1
                let reader = readers[item.1]!
                group.addTask { (index, item.1, try await StoredRAR.scan(reader, keys: keys)) }
            }
            for _ in 0..<min(8, volumes.count) { schedule() }
            while let item = try await group.next() { scanned.append(item); schedule() }
        }
        scanned.sort { $0.0 < $1.0 }
        let videos = try StoredRAR.videos(scanned.map { ($0.1, $0.2) }, startingAt: 0)
        for video in videos where video.cipher?.passwordChecked == false {
            let head = try await read(video: video, offset: 0, count: Int(min(video.length, 512)))
            guard Self.recognizesVideo(head) else { throw UsenetError.badPassword }
        }
        return videos
    }
    public func read(video: UsenetVideo, offset: Int64, count: Int, priority: ArticlePriority = .playback)
        async throws -> Data
    {
        guard !stopped else { throw UsenetError.cancelled }
        guard offset >= 0, count > 0, count <= 4 * 1024 * 1024, offset < video.length else {
            throw UsenetError.invalidRange
        }
        let end = min(video.length, try checkedAdd(offset, Int64(count)))
        if let cipher = video.cipher {
            let block = offset / 16 * 16, stop = (end + 15) / 16 * 16
            let start = block == 0 ? 0 : block - 16
            let bytes = try await physical(
                video: video, offset: start, count: Int(stop - start), priority: priority)
            let iv = block == 0 ? cipher.iv : Data(bytes.prefix(16))
            let encrypted = block == 0 ? bytes : Data(bytes.dropFirst(16))
            let decoded = try cipher.decrypt(encrypted, iv: iv)
            return decoded.subdata(in: Int(offset - block)..<Int(end - block))
        }
        return try await physical(video: video, offset: offset, count: Int(end - offset), priority: priority)
    }
    private func physical(video: UsenetVideo, offset: Int64, count: Int, priority: ArticlePriority)
        async throws -> Data
    {
        let end = try checkedAdd(offset, Int64(count))
        var logical: Int64 = 0, result = Data()
        for extent in video.extents {
            try Task.checkCancellation()
            let next = try checkedAdd(logical, extent.length)
            let start = max(offset, logical), stop = min(end, next)
            if stop > start {
                guard let reader = readers[extent.fileID] else { throw UsenetError.corrupt }
                var cursor = start
                while cursor < stop {
                    let amount = Int(min(4 * 1024 * 1024, stop - cursor))
                    let data = try await reader.read(
                        offset: extent.offset + cursor - logical, count: amount, priority: priority)
                    guard data.count == amount else { throw UsenetError.missingArticle }
                    result.append(data); cursor += Int64(amount)
                }
            }
            logical = next
            if logical >= end { break }
        }
        guard result.count == end - offset else { throw UsenetError.missingArticle }; return result
    }
    public func stop() async {
        stopped = true; for keys in keyStores { await keys.clear() }; keyStores = []; await cache.stop()
    }
    private static func recognizesVideo(_ data: Data) -> Bool {
        if data.starts(with: [0x1a, 0x45, 0xdf, 0xa3]) { return true }
        if data.count >= 12, data.starts(with: Data("RIFF".utf8)),
            data.subdata(in: 8..<12) == Data("AVI ".utf8)
        {
            return true
        }
        if data.count >= 8,
            ["ftyp", "moov", "mdat", "wide", "free"].contains(
                String(decoding: data.dropFirst(4).prefix(4), as: UTF8.self))
        {
            return true
        }
        if data.starts(with: [0, 0, 1]) { return true }
        if (data.count >= 189 && data[0] == 0x47 && data[188] == 0x47)
            || (data.count >= 197 && data[4] == 0x47 && data[196] == 0x47)
        {
            return true
        }
        return false
    }
    public var cachedBytes: Int { get async { await cache.storedBytes } }

    static func volume(_ name: String) -> (String, Int)? {
        let lower = (name as NSString).lastPathComponent.lowercased()
        if let regex = try? NSRegularExpression(pattern: #"^(.*)\.part(\d+)\.rar$"#),
            let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
            let base = Range(match.range(at: 1), in: lower),
            let number = Range(match.range(at: 2), in: lower), let value = Int(lower[number])
        {
            return (String(lower[base]), value)
        }
        if lower.hasSuffix(".rar") { return (String(lower.dropLast(4)), 0) }
        if let regex = try? NSRegularExpression(pattern: #"^(.*)\.([r-z])(\d{2})$"#),
            let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
            let base = Range(match.range(at: 1), in: lower),
            let letter = Range(match.range(at: 2), in: lower),
            let digits = Range(match.range(at: 3), in: lower), let value = Int(lower[digits]),
            let ascii = lower[letter].utf8.first
        {
            return (String(lower[base]), 1 + (Int(ascii) - 114) * 100 + value)
        }
        return nil
    }
}

public enum UsenetSelection {
    public static func candidates(_ videos: [UsenetVideo], fileIndex: Int?, pattern: String?) throws
        -> [UsenetVideo]
    {
        var values = videos
        if let index = fileIndex {
            guard videos.indices.contains(index) else { throw UsenetError.noVideo }; values = [videos[index]]
        }
        if let pattern, !pattern.isEmpty {
            var text = pattern, options: NSRegularExpression.Options = []
            if text.hasPrefix("/"), let end = text.lastIndex(of: "/"), end != text.startIndex {
                let flags = text[text.index(after: end)...]
                guard flags.allSatisfy({ $0 == "i" }) else { throw UsenetError.unsupported }
                if flags.contains("i") { options.insert(.caseInsensitive) }
                text = String(text[text.index(after: text.startIndex)..<end])
            }
            // Restrict the test build to bounded, non-recursive file-name patterns.
            guard text.utf8.count <= 256, !text.contains("("), !text.contains(")"), !text.contains("{"),
                !text.contains(#"\1"#), text.filter({ "*+?".contains($0) }).count <= 2,
                let regex = try? NSRegularExpression(pattern: text, options: options)
            else { throw UsenetError.unsupported }
            values = values.filter { name in
                name.name.utf8.count <= 2048
                    && regex.firstMatch(in: name.name, range: NSRange(name.name.startIndex..., in: name.name))
                        != nil
            }
        }
        guard !values.isEmpty else { throw UsenetError.noVideo }; return values
    }
}
