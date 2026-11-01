//
//  FileAssembler.swift
//  DownloadEngine
//
//  Writes decoded segment bytes straight to disk at their authoritative byte offset (from the
//  yEnc =ypart header), into one sparse scratch file per NZB file. Positional writes at fixed
//  offsets make the whole thing idempotent and therefore resume-safe. Finalize truncates to the
//  true decoded size and renames the scratch file to its display name.
//
//  An actor: disk writes are serialized (the network, not the disk, is the bottleneck), which
//  trades a little throughput for guaranteed correctness over many concurrent workers.
//

import Foundation

actor FileAssembler {
    private let directory: URL

    private struct FileState {
        let partURL: URL  // "<fileID>.part" scratch file (unique per file, never collides)
        let finalName: String  // sanitized display name for the finished file
        let capacity: Int  // scratch size = declared total (upper bound); writes clamp to it
        var maxEnd: Int = 0  // highest byte offset written — the true decoded length so far
        var declaredSize: Int?  // authoritative decoded file size from the yEnc header, if seen
        var declaredName: String?  // authoritative name from the yEnc header, if seen
        var alreadyComplete = false  // the finished file already exists from a previous run
    }

    private var states: [String: FileState] = [:]  // fileID → state
    private var handles: [String: FileHandle] = [:]  // fileID → open write handle (LRU-bounded)
    private var lru: [String] = []  // fileIDs in most-recently-used order (tail = MRU)
    private static let maxOpenHandles = 48  // keep well under the process fd soft limit

    init(directory: URL) {
        self.directory = directory
    }

    /// Prepare a file's scratch storage. Returns true if the finished file already exists (a
    /// previous run finalized it) so the engine can treat it as done and never touch it again —
    /// re-creating the scratch file here would zero-clobber good output on resume.
    @discardableResult
    func prepare(fileID: String, filename: String, totalBytes: Int, decodedSize: Int? = nil) throws -> Bool {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let finalName = Self.sanitized(filename)
        let finalURL = directory.appendingPathComponent(finalName)
        let partURL = directory.appendingPathComponent(Self.sanitized(fileID) + ".part")

        // Already finalized on a prior run: keep hands off it.
        if !FileManager.default.fileExists(atPath: partURL.path),
            FileManager.default.fileExists(atPath: finalURL.path)
        {
            states[fileID] = FileState(
                partURL: partURL, finalName: finalName,
                capacity: max(0, totalBytes), alreadyComplete: true)
            return true
        }

        if !FileManager.default.fileExists(atPath: partURL.path) {
            guard FileManager.default.createFile(atPath: partURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        // Size the scratch file to the declared total so missing regions stay zero-filled (PAR2
        // repairs from those). Only ever grow it here — never truncate away resumed data.
        if totalBytes > 0 {
            let handle = try FileHandle(forWritingTo: partURL)
            let existing = (try? handle.seekToEnd()) ?? 0
            if existing < UInt64(totalBytes) { try handle.truncate(atOffset: UInt64(totalBytes)) }
            try? handle.close()
        }
        var state = FileState(partURL: partURL, finalName: finalName, capacity: max(0, totalBytes))
        // If a partial scratch file survived from a prior run, its length is a lower bound on
        // what's been written.
        if let size = (try? FileManager.default.attributesOfItem(atPath: partURL.path)[.size]) as? Int {
            state.maxEnd = min(size, state.capacity)
        }
        state.declaredSize = decodedSize
        states[fileID] = state
        excludeFromBackup(partURL)
        return false
    }

    /// Write a decoded segment at its authoritative offset. `declaredFileSize` is the yEnc
    /// whole-file size when known; it pins the truncation target on finalize. `declaredName` is the
    /// yEnc `name=`, which outranks the caller's filename: that one is parsed out of the NZB
    /// subject, and an unquoted subject ("A. B - Title.epub (1/0)") parses to garbage ("A.").
    func write(
        fileID: String, data: Data, at offset: Int,
        declaredFileSize: Int? = nil, declaredName: String? = nil
    ) throws {
        guard var state = states[fileID], !state.alreadyComplete else { return }

        if state.declaredName == nil,
            let declared = declaredName?.trimmingCharacters(in: .whitespacesAndNewlines), !declared.isEmpty
        {
            state.declaredName = Self.sanitized(declared)
            states[fileID] = state
        }

        guard offset >= 0 else { throw YEncError.emptyBody }
        let start = offset
        // Reject a segment whose offset/length runs past the declared file size (a corrupt or
        // hostile =ypart header) instead of ballooning the output file.
        let limit = state.capacity > 0 ? state.capacity : Int.max
        guard start <= limit else { throw YEncError.emptyBody }
        guard data.count <= limit - start else { throw YEncError.emptyBody }
        let writable = data.count
        guard writable > 0 else {
            if let s = declaredFileSize, s > 0 { state.declaredSize = s; states[fileID] = state }
            return
        }

        let handle = try handleForWriting(fileID: fileID, partURL: state.partURL)
        try handle.seek(toOffset: UInt64(start))
        try handle.write(contentsOf: writable == data.count ? data : data.prefix(writable))

        state.maxEnd = max(state.maxEnd, start + writable)
        if let s = declaredFileSize, s > 0 {
            state.declaredSize = min(s, state.capacity == 0 ? s : state.capacity)
        }
        states[fileID] = state
    }

    /// Close and rename the scratch file to its final name, truncating away the trailing zero pad
    /// so the output is exactly the decoded size. Returns the final URL.
    @discardableResult
    func finalize(fileID: String) throws -> URL? {
        guard let state = states[fileID] else { return nil }

        if state.alreadyComplete {
            return directory.appendingPathComponent(state.finalName)
        }

        closeHandle(fileID)

        // Truncate to the true decoded size: prefer the yEnc-declared size, else the furthest byte
        // we actually wrote. (The scratch file was padded up to the declared *encoded* total.)
        let trueSize = state.declaredSize ?? state.maxEnd
        if trueSize > 0, let handle = try? FileHandle(forWritingTo: state.partURL) {
            let current = (try? handle.seekToEnd()) ?? 0
            if current > UInt64(trueSize) { try? handle.truncate(atOffset: UInt64(trueSize)) }
            try? handle.synchronize()
            try? handle.close()
        }

        let finalURL = uniqueFinalURL(
            for: Self.betterName(declared: state.declaredName, fallback: state.finalName),
            excluding: state.partURL)
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try? FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: state.partURL, to: finalURL)
        excludeFromBackup(finalURL)
        return finalURL
    }

    func closeAll() {
        for handle in handles.values { try? handle.close() }
        handles.removeAll()
        lru.removeAll()
    }

    // MARK: - Handle cache (LRU)

    private func handleForWriting(fileID: String, partURL: URL) throws -> FileHandle {
        if let handle = handles[fileID] {
            touch(fileID)
            return handle
        }
        if handles.count >= Self.maxOpenHandles, let evict = lru.first {
            closeHandle(evict)
        }
        let handle = try FileHandle(forWritingTo: partURL)
        handles[fileID] = handle
        touch(fileID)
        return handle
    }

    private func touch(_ fileID: String) {
        lru.removeAll { $0 == fileID }
        lru.append(fileID)
    }

    private func closeHandle(_ fileID: String) {
        if let handle = handles.removeValue(forKey: fileID) {
            try? handle.synchronize()
            try? handle.close()
        }
        lru.removeAll { $0 == fileID }
    }

    // MARK: - Helpers

    /// If two files sanitize to the same display name, keep both by suffixing " (2)", " (3)"…
    private func uniqueFinalURL(for name: String, excluding partURL: URL) -> URL {
        let base = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: base.path) { return base }
        let ns = name as NSString
        let stem = ns.deletingPathExtension
        let ext = ns.pathExtension
        var n = 2
        while n < 1000 {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            let url = directory.appendingPathComponent(candidate)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
        return base
    }

    /// Pick between the yEnc header name and the subject-derived fallback. The header usually wins
    /// — it is what the poster actually named the file — except when it has no extension and the
    /// fallback does: obfuscated posts carry hash-like header names ("3osby74f5W5rYwETGFUetpuHxfkS")
    /// while the indexer's subject holds the real one. An extension-less `.par2` is especially bad,
    /// since PAR2 discovery would no longer recognize it by name.
    static func betterName(declared: String?, fallback: String) -> String {
        guard let declared else { return fallback }
        let declaredHasExtension = !(declared as NSString).pathExtension.isEmpty
        let fallbackHasExtension = !(fallback as NSString).pathExtension.isEmpty
        return (!declaredHasExtension && fallbackHasExtension) ? fallback : declared
    }

    /// Reduce an untrusted name to a safe single path component inside `directory`: no separators,
    /// no "."/".." traversal, no illegal characters, never empty.
    static func sanitized(_ name: String) -> String {
        // Collapse any path structure to the last component first (defends against "../x" and "/x").
        let last = (name as NSString).lastPathComponent
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var cleaned = last.components(separatedBy: illegal).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned == "." || cleaned == ".." { cleaned = "" }
        // Strip leading dots so a name can't become hidden or resolve oddly.
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "file" : String(cleaned.prefix(200))
    }

    private func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
